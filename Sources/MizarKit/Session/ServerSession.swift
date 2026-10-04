import Foundation

/// 一台服务端的连接状态。
///
/// 五种状态对应**五种不同的下一步动作**，这是这个类型存在的全部理由：
/// 把"连不上"与"令牌被吊销了"都显示成"连接失败"，用户会去检查网络，
/// 而真正该做的是重新配对。
public enum SessionState: Sendable, Equatable {
    case idle
    case connecting
    case online
    /// 一个地址都连不上（网络、端口、内核没运行）。
    case unreachable(String)
    /// 内核在，但它不认我们的令牌（被吊销或重新配对过）。
    case needsPairing(String)
    /// 证书公钥与配对时固定的不一致 —— 对端不是原来那台机器。
    case identityChanged(String)

    public var isOnline: Bool { self == .online }

    public var summary: String {
        switch self {
        case .idle: "未连接"
        case .connecting: "连接中…"
        case .online: "已连接"
        case .unreachable(let detail): detail
        case .needsPairing(let detail): detail
        case .identityChanged(let detail): detail
        }
    }
}

/// 与一台服务端的一条会话。
///
/// # 为什么是一个 actor
///
/// 它持有四样会被并发读写的东西：连接状态、当前地址、游标、已连上的
/// 客户端。界面在刷新、事件长轮询在跑、用户可能同时点了"重启站点" ——
/// 这些都在同一个会话上。把它们关进一个 actor 比在十几处调用点小心
/// 地加锁要可靠得多。
///
/// # 地址降级
///
/// 一台服务端通常有多个候选地址（IPv4、IPv6、`<hostname>.local`）。
/// 手机在 WiFi 与蜂窝之间切换、路由器重新分配地址之后，原来那条路会
/// 失效，而其余的可能仍然通 —— 因此每次连接都按"上次成功的优先"的
/// 顺序把候选**逐个试一遍**，而不是只试一条。
public actor ServerSession {

    public private(set) var state: SessionState = .idle
    /// 当前这台设备在服务端上的角色。界面据它决定写控件可不可点。
    public private(set) var role: String
    /// 刚刚连上的那个地址。
    public private(set) var address: String?
    /// 最近一次 `self` 的结果。
    public private(set) var info: RemoteSelfInfo?

    private var record: ServerRecord
    private let token: String
    private let makeTransport: TransportFactory
    private var client: KernelClient?
    /// 事件游标。0 表示"从现在开始"（内核的约定）。
    private var cursor: Int64 = 0

    public init(record: ServerRecord, token: String,
                makeTransport: @escaping TransportFactory = ServerSession.defaultTransport) {
        self.record = record
        self.token = token
        self.role = record.role
        self.makeTransport = makeTransport
    }

    public static let defaultTransport: TransportFactory = { url, spki, token, language in
        HTTPTransport(configuration: .init(baseURL: url, token: token,
                                           pinnedSPKI: spki, language: language))
    }

    /// 服务端记录的当前快照。
    public func snapshot() -> ServerRecord { record }

    /// 连接（或重连）。
    ///
    /// 返回最终状态，调用方不必再去读一次属性。
    @discardableResult
    public func connect(language: String = "zh-CN") async -> SessionState {
        state = .connecting

        var failures: [KernelError] = []
        for baseURL in record.baseURLs() {
            let transport = makeTransportWithToken(baseURL, language: language)
            let candidate = KernelClient(transport: transport)
            do {
                let selfInfo = try await candidate.remoteSelf()
                client = candidate
                info = selfInfo
                role = selfInfo.role
                address = Self.hostPort(baseURL)
                state = .online
                return state
            } catch let error as KernelError {
                failures.append(error)
                // 401 意味着我们**够到了内核**，只是它不认这个令牌。
                // 换一个地址不会有不同的结果，而继续试只会让用户多等
                // 好几秒 —— 尤其是在蜂窝网络上，每个地址都要等超时。
                if error.needsPairing { break }
            } catch {
                failures.append(KernelError(code: "unreachable", message: error.localizedDescription))
            }
        }

        client = nil
        address = nil
        state = Self.classify(failures)
        return state
    }

    /// 当前可用的客户端。没连上时抛错 —— 界面据此显示重试入口。
    public func kernel() throws -> KernelClient {
        guard let client else {
            throw KernelError(code: "unreachable", status: 0, message: state.summary)
        }
        return client
    }

    /// 拉一批事件。
    ///
    /// 游标在内部推进；`gap` 为 true 时**游标仍然推进**，因为那一批之后
    /// 的事件是连续的 —— 客户端要做的是重新拉一次全量状态，而不是重放。
    @discardableResult
    public func pollEvents(timeoutMilliseconds: Int32 = 25_000) async throws -> EventBatch {
        let client = try kernel()
        let envelope = try await client.events(since: cursor, timeoutMilliseconds: timeoutMilliseconds)
        let batch = EventBatch(events: envelope["events"].array,
                               next: Int64(envelope["next"].number),
                               gap: envelope["gap"].bool)
        if batch.next > 0 { cursor = batch.next }
        return batch
    }

    /// 把角色同步回本地（服务端改了权限之后）。
    public func refreshSelf() async throws {
        let client = try kernel()
        let selfInfo = try await client.remoteSelf()
        info = selfInfo
        role = selfInfo.role
        if record.role != selfInfo.role {
            record.role = selfInfo.role
        }
    }

    /// 断开。
    public func disconnect() {
        client = nil
        address = nil
        state = .idle
    }

    /// 令牌被吊销之后把这个会话标成需要重新配对。
    ///
    /// 由**收到 401 的调用方**触发：一次普通的接口调用也可能先于重连
    /// 发现令牌失效，而那时状态还停在 `.online`，界面会继续显示"已连接"
    /// 并让用户反复点一个必然失败的按钮。
    public func markUnauthorized(_ detail: String) {
        client = nil
        address = nil
        state = .needsPairing(detail.isEmpty ? "这台服务器需要重新配对。" : detail)
    }

    /// 记下"这次是从哪个地址连上的"。
    public func noteAddress(_ hostPort: String) {
        address = hostPort
        record.lastGoodAddress = hostPort
        record.lastSeenAt = Date()
    }

    // MARK: - 内部

    private func makeTransportWithToken(_ baseURL: URL, language: String) -> any KernelTransport {
        makeTransport(baseURL, record.spkiSHA256, token, language)
    }

    static func hostPort(_ url: URL) -> String {
        let host = url.host() ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        return host.contains(":") ? "[\(host)]\(port)" : "\(host)\(port)"
    }

    /// 把一组失败归成一个状态。
    ///
    /// 优先级是有讲究的：`needsPairing` 与 `identityChanged` 都比
    /// "连不上"更能指导下一步动作，而"连不上"只在没有任何一个地址
    /// 够到内核时才成立。
    static func classify(_ failures: [KernelError]) -> SessionState {
        if let pairing = failures.first(where: { $0.needsPairing }) {
            return .needsPairing(pairing.message)
        }
        if let identity = failures.first(where: { $0.code == "identity_changed" }) {
            return .identityChanged(identity.message)
        }
        // 全部候选都失败时给一句**能指导动作**的话，而不是把最后一个
        // 网络错误的原文端上来。
        return .unreachable(
            "连不上这台服务端。请确认它与手机在同一网络，并且 Phecda（或内核服务）正在运行、远程访问已开启。")
    }
}
