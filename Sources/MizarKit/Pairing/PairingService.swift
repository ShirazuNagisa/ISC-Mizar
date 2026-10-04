import Foundation

/// 配对 —— 把一台服务端变成本机可以连的对象。
///
/// # 两条路径，信任的建立方式不同
///
/// **扫码**：二维码里带着服务端证书的公钥指纹。客户端在 TLS 握手时
/// 就比对它，不匹配直接断开。信任是**密码学意义上**建立起来的，
/// 用户不需要做任何判断。
///
/// **手输六位码**：没有二维码，因此客户端拿不到指纹。这里的做法是
/// 先连上去把指纹取回来，**让用户与 Phecda 屏幕上的那一串核对**，
/// 核对通过才把令牌落库；不通过就丢弃令牌并提示配对码可能已泄露。
///
/// 两条路径都不能省掉指纹：一次配对时的中间人足以长期冒名这台服务器
/// （它能篡改返回的一切，包括 DNS 记录），而用户不会有任何察觉。
public struct PairingService: Sendable {

    /// 客户端自报的设备信息。
    ///
    /// 只用于在 Phecda 的设备列表里显示，**不参与任何判定** ——
    /// 一台自称"iPad"的设备在权限上与手机完全等价。
    public struct DeviceInfo: Encodable, Sendable {
        public var name: String
        public var platform: String?
        public var model: String?
        public var osVersion: String?
        public var appVersion: String?

        public init(name: String, platform: String? = nil, model: String? = nil,
                    osVersion: String? = nil, appVersion: String? = nil) {
            self.name = name
            self.platform = platform
            self.model = model
            self.osVersion = osVersion
            self.appVersion = appVersion
        }
    }

    /// 服务端自述（配对响应里的一部分）。
    public struct ServerInfo: Decodable, Sendable {
        public let name: String
        public let version: String
        public let apiVersion: String
        public let platform: String?
        public let spkiSha256: String?
        public let fingerprintShort: String?
        public let apnsTopic: String?

        /// 这台服务端是否支持远程访问。
        ///
        /// 老版本内核的 `spki_sha256` 会是空的 —— 那时该做的是提示用户
        /// 更新 Phecda，而不是拿一个空指纹去落库（那会让之后每一次连接
        /// 都"指纹不匹配"）。
        public var supportsRemoteAccess: Bool { !(spkiSha256 ?? "").isEmpty }
    }

    /// 一次成功的配对。
    public struct Outcome: Sendable {
        public let record: ServerRecord
        /// 设备令牌。**只在这里出现一次**：服务端只存它的哈希。
        public let token: String
        public let deviceId: String
        public let role: String
        public let server: ServerInfo
    }

    /// 手输路径的中间结果：**还没落库**，等用户核对指纹。
    public struct PendingManualPairing: Sendable, Identifiable {
        public var id: String { outcome.record.id }

        public let outcome: Outcome
        public let baseURL: URL
        /// 用户要拿去与 Phecda 屏幕上核对的那一串。
        public var fingerprintShort: String { outcome.server.fingerprintShort ?? "" }
        public var serverName: String { outcome.server.name }
    }

    private let language: String
    private let timeout: TimeInterval
    private let makeTransport: TransportFactory

    public init(language: String = "zh-CN", timeout: TimeInterval = 15,
                makeTransport: @escaping TransportFactory = PairingService.defaultTransport) {
        self.language = language
        self.timeout = timeout
        self.makeTransport = makeTransport
    }

    /// 默认的传输工厂：真实的 HTTPS。
    public static let defaultTransport: TransportFactory = { url, spki, token, language in
        HTTPTransport(configuration: .init(baseURL: url, token: token,
                                           pinnedSPKI: spki, language: language))
    }

    // MARK: - 扫码路径

    /// 用二维码里的信息完成配对。
    ///
    /// 逐个尝试候选地址：手机可以在 WiFi 与蜂窝之间切换、可能走 IPv6、
    /// 而路由器给的地址随时会变。全部失败时**报最有用的那一个错误**，
    /// 见 `bestError`。
    public func pair(payload: PairingPayload, device: DeviceInfo) async throws -> Outcome {
        if payload.expired() { throw PairingError.expired }

        var failures: [Error] = []
        for baseURL in payload.baseURLs() {
            do {
                return try await pair(at: baseURL, pinnedSPKI: payload.spki,
                                      credential: .secret(payload.secret),
                                      device: device, payload: payload)
            } catch {
                failures.append(error)
            }
        }
        throw Self.bestError(failures)
    }

    // MARK: - 手输路径

    /// 用地址 + 六位码探测一台服务端。
    ///
    /// 返回的结果**没有落库**：调用方必须把 `fingerprintShort` 显示给用户，
    /// 与 Phecda 上的那一串核对，确认之后再调用 `commit`。
    public func probe(address: String, code: String, scheme: String = "https",
                      device: DeviceInfo) async throws -> PendingManualPairing {
        guard let normalized = PairingCode.normalize(code) else {
            throw PairingError.rejected("配对码应当是六位字母或数字。")
        }
        // 地址允许用户输入 `host:port`、`https://host:port` 或带路径的
        // 完整 URL —— 人们会从各种地方把它复制过来。
        guard let baseURL = Self.normalize(address: address, scheme: scheme) else {
            throw PairingError.rejected("地址无法解析，请检查后重试。")
        }

        let outcome = try await pair(at: baseURL, pinnedSPKI: nil,
                                     credential: .code(normalized),
                                     device: device, payload: nil)
        return PendingManualPairing(outcome: outcome, baseURL: baseURL)
    }

    // MARK: - 内部

    private enum Credential {
        case secret(String)
        case code(String)
    }

    /// 请求体。两个字段二选一。
    private struct PairRequest: Encodable {
        var secret: String?
        var code: String?
        var device: DeviceInfo
    }

    private struct PairResponse: Decodable {
        let deviceId: String
        let token: String
        let role: String
        let server: ServerInfo
    }

    private func pair(at baseURL: URL, pinnedSPKI: String?, credential: Credential,
                      device: DeviceInfo, payload: PairingPayload?) async throws -> Outcome {
        // 配对路径是唯一免鉴权的路径，因此传输上不带令牌。
        let transport = makeTransport(baseURL, pinnedSPKI, "", language)
        let client = KernelClient(transport: transport)

        var body = PairRequest(device: device)
        switch credential {
        case .secret(let value): body.secret = value
        case .code(let value): body.code = value
        }

        // 手工编码与解码，而不是走 KernelAPI 的泛型入口：配对响应只在
        // 这一个地方出现，为它建一个顶层模型没有意义；而手工这一步
        // 顺带能把"服务端返回的形状不对"报成一句可读的话。
        let requestBody = try JSONEncoder.mizar.encode(body)

        let reply: KernelReply
        do {
            reply = try await client.callRaw(
                "POST", "/v1/remote/pair",
                body: String(decoding: requestBody, as: UTF8.self))
        } catch let error as KernelError {
            // 只有**拿到了 HTTP 响应**的失败才谈得上"内核拒绝了我们"。
            //
            // 传输层的失败（连不上、超时、指纹不对）status 是 0，它们必须
            // 原样抛出去，由 `bestError` 按"哪个更能指导动作"来排序。
            // 把它们一律翻成 `.rejected` 会让一句"连不上"盖过真正的
            // "配对码已过期" —— 因为 .rejected 的优先级最高。
            guard error.status != 0 else { throw error }
            throw Self.mapPairingError(error)
        }

        let raw = try reply.body.data()
        let response: PairResponse
        do {
            response = try JSONDecoder.mizar.decode(PairResponse.self, from: raw)
        } catch {
            throw PairingError.unreadable
        }

        guard response.server.supportsRemoteAccess else {
            throw PairingError.rejected(
                "这台服务端的内核版本不支持远程访问，请先更新 Phecda。")
        }

        // 扫码路径的纵深防御：二维码里的指纹与响应里自报的必须是同一个。
        // TLS 层其实已经保证了这一点，但这条断言的价值在于它**与传输无关** ——
        // 将来换掉传输实现时它仍然成立。
        if let payload, let reported = response.server.spkiSha256, reported != payload.spki {
            throw PairingError.identityMismatch
        }

        // 服务端自报的指纹来自响应体，而响应体是在 TLS 建好之后才拿到的，
        // 因此它可信 —— 用它是正确的做法。
        //
        // 但注入的假传输（以及将来任何换掉的传输实现）未必会去**核对**它，
        // 因此"响应里必须有一个非空指纹"这一条由这里把关：落库一个空指纹
        // 会让此后每一次连接都报"身份已变化"，而用户完全不知道该怎么修。
        guard let effectiveSPKI = response.server.spkiSha256, !effectiveSPKI.isEmpty else {
            throw PairingError.identityMismatch
        }

        let record = ServerRecord(
            name: response.server.name,
            scheme: baseURL.scheme ?? "https",
            // 候选地址按配对时用的那一个排在最前 —— 它是刚刚被证明可用的。
            addresses: Self.mergeAddresses(primary: baseURL, from: payload),
            spkiSHA256: effectiveSPKI,
            role: response.role,
            lastGoodAddress: Self.hostPort(baseURL),
            lastSeenAt: Date(),
            createdAt: Date())

        return Outcome(record: record, token: response.token, deviceId: response.deviceId,
                       role: response.role, server: response.server)
    }

    /// 把"刚刚连上的地址"排到候选列表最前，其余保持内核给的顺序。
    ///
    /// 不重排整个列表：那个顺序里含有客户端不知道的信息（哪些地址属于
    /// 同一张网卡、哪一条是 IPv6），打乱它只会让每次连接的尝试顺序
    /// 随实现细节变化。
    static func mergeAddresses(primary: URL, from payload: PairingPayload?) -> [String] {
        let hostPort = Self.hostPort(primary)
        var addresses = payload?.addresses ?? []
        addresses.removeAll { $0 == hostPort }
        return [hostPort] + addresses
    }

    /// `URL` → `host:port`（IPv6 带方括号）。
    static func hostPort(_ url: URL) -> String {
        let host = url.host() ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        return host.contains(":") ? "[\(host)]\(port)" : "\(host)\(port)"
    }

    /// 把用户输入的地址规范化。
    ///
    /// 接受 `host:port`、`https://host:port`、以及带路径的完整 URL ——
    /// 人们会从浏览器地址栏、聊天记录、Phecda 的地址列表里把它复制过来，
    /// 而每一种都带着不同的前缀。
    static func normalize(address: String, scheme: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("://") {
            guard let url = URL(string: trimmed), let host = url.host(), !host.isEmpty else { return nil }
            // 只保留 scheme/host/port：路径与查询对内核接口没有意义，
            // 留着反而会让 URL(string:relativeTo:) 拼出奇怪的地址。
            var components = URLComponents()
            components.scheme = url.scheme
            components.host = host
            components.port = url.port
            return components.url
        }

        guard let url = URL(string: "\(scheme)://\(trimmed)"), let host = url.host(), !host.isEmpty else {
            return nil
        }
        return url
    }

    /// 把内核的错误码翻译成配对语义。
    static func mapPairingError(_ error: KernelError) -> PairingError {
        switch error.code {
        case "unauthorized":
            // 401 在配对路径上只有一个含义：码不对、已过期、或尝试次数用尽。
            // 服务端的 detail 已经把这些分开了，直接用它。
            .rejected(error.message)
        case "forbidden" where error.status == 429:
            .rejected(error.message.isEmpty ? "请求过于频繁，请稍后再试。" : error.message)
        case "not_found":
            // 路径不存在 = 这台服务端的内核没有远程面。
            .rejected("这台服务端没有开启远程访问，请先在 Phecda 上打开它。")
        default:
            .rejected(error.message.isEmpty ? "配对失败（\(error.code)）。" : error.message)
        }
    }

    /// 从一堆候选地址的失败里挑出**最有用的那一个**报给用户。
    ///
    /// 优先级不是随意的：
    ///
    ///	1. 内核明确拒绝了我们（`rejected`）—— 它说明请求**够到了**内核，
    ///	   而内核说的那句话正是用户该看的（码过期了？被限流了？）；
    ///	2. 指纹不匹配 —— 说明连到了别的机器，或者服务端换过密钥；
    ///	3. 全部候选都"证书对不上" —— 我们能到达的每一条路都不是那台服务器；
    ///	4. 连不上 / 超时 —— 最没有信息量的一类，只有前三条都不成立时才轮到它。
    ///
    /// 反过来（比如直接报最后一个错误）会让"配对码已过期"显示成
    /// "检查你的网络"，而用户该做的事完全不同。
    static func bestError(_ failures: [Error]) -> Error {
        if let rejected = failures.first(where: {
            if case PairingError.rejected = $0 { return true }
            return false
        }) {
            return rejected
        }
        if failures.contains(where: { ($0 as? PairingError) == .identityMismatch }) {
            return PairingError.identityMismatch
        }
        let identityFailures = failures.filter {
            ($0 as? KernelError)?.code == "identity_changed"
        }
        if !failures.isEmpty, identityFailures.count == failures.count {
            return PairingError.identityMismatch
        }
        return PairingError.noReachableAddress
    }
}

extension JSONEncoder {
    /// 契约层的编码器（snake_case + ISO8601），与解码器成对。
    ///
    /// 两者**必须**共用同一套键策略：写成 `spki_sha256` 而按
    /// `spkiSha256` 读，或者反过来，都会让请求静默地少一个字段 ——
    /// 而服务端的响应会是"缺少设备信息"这种与真正原因无关的话。
    static var mizar: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    /// 契约层的解码器。
    ///
    /// 与 ISC Phecda 的 `KernelClient.makeDecoder()` 配置一致
    /// （snake_case + 容忍带与不带小数秒的 ISO8601 时间戳）。
    static var mizar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.time(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(text, strategy: .iso8601) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "无法解析时间戳：\(text)"))
        }
        return decoder
    }
}
