import Foundation
import Security

/// 走 HTTPS 的内核传输 —— Mizar 与 Phecda 唯一的实质差别就在这个文件里。
///
/// # 归一化：HTTP 不是信封
///
/// `libisc` 的 `isc_call` 返回 `{ok, status, body}`，而内核的 HTTP 接口
/// 返回**裸的响应体**加上一个状态码，错误走 problem+json。
///
/// 上层（`KernelAPI`、界面）认识的是信封，因此把 HTTP 归一化成信封这件事
/// **必须**发生在传输层，而不是散在几十个调用点里。它也顺带把"什么算失败"
/// 收在一处：非 2xx 一律抛 `KernelError`，而 `code` 取自 problem+json，
/// 因此上层的分支判断（`needsPairing`、`not_found`…）在两个应用里一致。
///
/// # 为什么不用 WebSocket
///
/// 手机进程会被系统挂起、会在 WiFi 与蜂窝之间切换。长轮询在这两件事之后
/// 只需要重新发一个请求，而 WebSocket 要重建握手、重新对齐游标，还要处理
/// 断线期间到达的事件。多出来的那点往返开销，换的是"不用维护一条随时会
/// 断的持久连接"。
public struct HTTPTransport: KernelTransport {

    public struct Configuration: Sendable {
        /// 服务端基址，例如 `https://192.168.1.10:8788`。
        public var baseURL: URL
        /// 设备令牌。
        public var token: String
        /// 固定的公钥指纹（base64url，无填充）。
        ///
        /// `nil` 表示**首次使用**：接受任何证书，但把看到的指纹记下来
        /// 交给调用方（`observedFingerprint`）。
        ///
        /// 这个模式只有一个合法用途 —— **手输配对码**。那条路径上客户端
        /// 拿不到二维码里的指纹，因此只能先连上去把指纹取回来，再让用户
        /// 与另一端的屏幕核对。核对通过才落库；不通过就丢弃令牌。
        ///
        /// 换句话说：`nil` **不等于**"不校验"，而是"校验推迟到用户确认"。
        /// 任何日常请求都必须带指纹。
        /// 信任模型。
        ///
        /// 三条路径各有各的可信来源，见 `TrustMode` 的说明。
        public var trust: TrustMode

        /// `.pin` 时的公钥指纹。
        public var pinnedSPKI: String?
        /// 发给内核的 `Accept-Language`。
        ///
        /// 用它而不是改服务端设置：语言是**客户端**的偏好，
        /// 而 Mizar 改一次服务端语言会连带影响 Phecda 与验证控制台。
        public var language: String
        /// 单次请求的超时（长轮询另有更长的上限）。
        public var timeout: TimeInterval

        public init(baseURL: URL, token: String, trust: TrustMode,
                    pinnedSPKI: String? = nil,
                    language: String = "zh-CN", timeout: TimeInterval = 15) {
            self.baseURL = baseURL
            self.token = token
            self.trust = trust
            // `.pin` 却没有指纹是一个**编程错误**，而不是运行时状况：
            // 放过去会让连接退化成"接受任何证书"，而那正是固定指纹
            // 要防的事。这里把它暴露在最显眼的地方。
            if trust == .pin && (pinnedSPKI ?? "").isEmpty {
                self.trust = .trustOnFirstUse
            }
            self.pinnedSPKI = trust == .system ? nil : pinnedSPKI
            self.language = language
            self.timeout = timeout
        }
    }

    private let config: Configuration
    private let session: URLSession
    private let recorder: PinRecorder

    public init(configuration: Configuration) {
        self.config = configuration
        let recorder = PinRecorder()
        self.recorder = recorder

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = configuration.timeout
        // 连不上就立刻失败：远程访问的三种失败（没开监听、端口不通、
        // 内核没跑）要尽快分辨出来，而等待连通性只会让界面一直转圈。
        cfg.waitsForConnectivity = false
        // 不做 cookie 与缓存：这是一个管理接口，任何本地缓存都可能让
        // 用户看到已经过期的状态。
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        self.session = URLSession(
            configuration: cfg,
            // `.system` 刻意**不装代理**：让 URLSession 走它默认的
            // 标准信任链评估。自己写一遍评估只是把系统已经做对的事
            // 重做一遍，而做错的方式（漏掉吊销检查、漏掉主机名匹配）
            // 恰好都是最危险的那些。
            delegate: configuration.trust == .system
                ? nil
                : PinningDelegate(trust: configuration.trust,
                                  pinnedSPKI: configuration.pinnedSPKI,
                                  recorder: recorder),
            delegateQueue: nil)
    }

    /// 最近一次握手看到的服务端公钥指纹。
    ///
    /// 只在"首次使用"模式下有意义（固定模式下它必然等于固定的那个）。
    public var observedFingerprint: String? { recorder.observed }

    public func call(_ method: String, _ path: String, body: Data?) async throws -> KernelReply {
        var request = try makeRequest(method, path, timeout: config.timeout)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request)
    }

    /// 长轮询事件。
    ///
    /// # 这里**不能**用 `URLComponents(resolvingAgainstBaseURL: false)`
    ///
    /// `url(for:)` 返回的是 `URL(string:relativeTo:)` 的结果 —— 它的 host
    /// 在 `baseURL` 里。而 `resolvingAgainstBaseURL: false` 会让
    /// `URLComponents` 把这个 URL 当成**纯相对路径**，于是 `components.url`
    /// 变成：
    ///
    ///     /v1/events/poll?since=0&timeout_ms=25000
    ///
    /// 一个没有 host 的 URL。`URLSession` 对它的回答是立刻返回
    /// `-1002 不支持的URL` —— **没有网络往返**，所以重试再多次也永远
    /// 不会成功，而日志里只会看到一串"不支持的URL"。
    ///
    /// 别的请求路径没这个问题：它们走 `makeRequest`，那里的 `URL` 仍然
    /// 带着 base。只有这一条手工拼了 query，也就在这一条上踩了坑。
    public func pollEvents(since: Int64, timeoutMilliseconds: Int) async throws -> EventBatch {
        // `resolvingAgainstBaseURL: true`：把 base 解析进去，拿到的才是
        // 一个绝对 URL。
        guard var components = URLComponents(
            url: try url(for: "/v1/events/poll"), resolvingAgainstBaseURL: true) else {
            throw KernelError(code: "bad_request", message: "无法构造长轮询地址")
        }
        components.queryItems = [
            URLQueryItem(name: "since", value: String(since)),
            URLQueryItem(name: "timeout_ms", value: String(timeoutMilliseconds)),
        ]
        guard let url = components.url, url.host != nil else {
            // 兜底：没有 host 的 URL 会被 URLSession 立刻拒绝，而那个错误
            // （"不支持的URL"）完全指不出这里。宁可在这里说清楚。
            throw KernelError(code: "bad_request", message: "长轮询地址缺少 host")
        }

        // 请求超时必须**大于**长轮询自身的挂起时间，否则每一次空闲的
        // 长轮询都会被 URLSession 掐断，而症状是"界面每 25 秒闪一次重连"。
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(&request)
        request.timeoutInterval = TimeInterval(timeoutMilliseconds) / 1000 + 15

        let reply = try await perform(request)
        return EventBatch(
            events: reply.body["events"].array,
            next: Int64(reply.body["next"].number),
            gap: reply.body["gap"].bool)
    }

    // MARK: - 内部

    private func url(for path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: config.baseURL) else {
            throw KernelError(code: "bad_request", message: "无法构造请求地址：\(path)")
        }
        return url
    }

    private func makeRequest(_ method: String, _ path: String, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        applyHeaders(&request)
        return request
    }

    private func applyHeaders(_ request: inout URLRequest) {
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.language, forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func perform(_ request: URLRequest) async throws -> KernelReply {
        recorder.clearFailure()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw KernelError(code: "unreachable", message: "服务端没有返回 HTTP 响应。")
            }
            return try Self.normalize(status: http.statusCode, data: data)
        } catch let error as KernelError {
            throw error
        } catch let error as URLError {
            throw Self.map(error, pinFailure: recorder.mismatch)
        } catch {
            throw KernelError(code: "unreachable", message: error.localizedDescription)
        }
    }

    /// 把 HTTP 响应归一化成 `isc_call` 的信封形状。
    static func normalize(status: Int, data: Data) throws -> KernelReply {
        let text = String(decoding: data, as: UTF8.self)
        let parsed = text.isEmpty ? JSONValue.null : ((try? JSONValue.parse(text)) ?? .null)

        if (200..<300).contains(status) {
            return KernelReply(status: status, body: parsed)
        }

        // problem+json（RFC 9457）。`code` 是内核给的机器可读串，
        // 而 `title` / `detail` 已经按请求的语言本地化过了 —— 直接用它，
        // 不要在客户端再翻译一遍，那会让两边的措辞漂移。
        let code = parsed["code"].string.isEmpty ? "http_\(status)" : parsed["code"].string
        let detail = parsed["detail"].string.isEmpty ? parsed["title"].string : parsed["detail"].string
        throw KernelError(code: code, status: status,
                          message: detail.isEmpty ? "HTTP \(status)" : detail)
    }

    /// 把 URLSession 的错误翻译成契约层的错误码。
    static func map(_ error: URLError, pinFailure: String?) -> KernelError {
        // 指纹不匹配时我们在挑战回调里**主动取消**了连接，因此它到这里
        // 是一个 `.cancelled` / `.serverCertificateUntrusted`。不看这个
        // 标记的话，用户看到的会是"已取消"，而真实原因是
        // "服务端身份变了" —— 两者该做的事情完全相反。
        if let pinFailure {
            return KernelError(code: "identity_changed", status: 0, message: pinFailure)
        }
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed:
            return KernelError(code: "unreachable", status: 0, message: error.localizedDescription)
        case .timedOut:
            return KernelError(code: "timeout", status: 0, message: error.localizedDescription)
        case .cancelled:
            return KernelError(code: "cancelled", status: 0, message: error.localizedDescription)
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected:
            // 走到这里说明挑战回调没有认领这次失败（例如证书本身坏了）。
            return KernelError(code: "identity_changed", status: 0,
                               message: error.localizedDescription)
        case .appTransportSecurityRequiresSecureConnection:
            return KernelError(code: "tls_blocked", status: 0, message: error.localizedDescription)
        default:
            return KernelError(code: "unreachable", status: 0, message: error.localizedDescription)
        }
    }
}

/// 记录最近一次指纹不匹配的说明。
///
/// 存在的理由：连接被取消之后，URLSession 只给出一个笼统的错误码，
/// 而"指纹不匹配"与"用户取消了"在错误码上是同一个。没有这个记录，
/// 客户端就没法把这两件事分开报。
final class PinRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: String?
    private var seen: String?

    /// 最近一次不匹配的说明。
    var mismatch: String? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }

    /// 最近一次握手看到的指纹（首次使用模式下由调用方拿去让用户核对）。
    var observed: String? {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    func record(mismatch message: String) {
        lock.lock(); defer { lock.unlock() }
        failure = message
    }

    func record(observed fingerprint: String) {
        lock.lock(); defer { lock.unlock() }
        seen = fingerprint
    }

    /// 只清失败、**不清已观察到的指纹**：指纹是在握手时记下的，
    /// 而调用方往往在请求结束之后才去读它。
    func clearFailure() {
        lock.lock(); defer { lock.unlock() }
        failure = nil
    }
}

/// 校验服务端证书的公钥指纹。
///
/// 自签证书没有可验证的链，因此这里**不**做链校验，只做公钥比对 ——
/// 而信任正是来自那个比对：指纹是用户在配对时通过二维码（或两端肉眼
/// 核对）建立的。
final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    /// 信任模型。构造函数**拒绝** `.system` —— 那种模式不该经过这里。
    ///
    /// 叫 `trustMode` 而不是 `trust`：代理方法里那个局部变量
    /// `trust` 是 `SecTrust`，两个名字撞上会让 `trust == .pin`
    /// 被解析成"SecTrust 上没有 pin 这个成员"。
    private let trustMode: TrustMode
    private let pinnedSPKI: String?
    private let recorder: PinRecorder

    init(trust: TrustMode, pinnedSPKI: String?, recorder: PinRecorder) {
        self.trustMode = trust
        self.pinnedSPKI = pinnedSPKI
        self.recorder = recorder
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certificates.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let actual = SpkiPinning.fingerprint(of: leaf) else {
            recorder.record(mismatch: "服务端证书无法解析，出于安全考虑已中止连接。")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        recorder.record(observed: actual)

        // 首次使用：接受，但把指纹留给调用方核对。
        guard trustMode == .pin, let pinnedSPKI else {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        guard actual == pinnedSPKI else {
            // 这条文案是用户会看到的那一句，因此必须说清楚**发生了什么**
            // 与**该做什么**。静默接受新证书是绝对不能有的行为：那意味着
            // 一次配对时的中间人可以永久篡改返回的一切（包括 DNS 记录）。
            recorder.record(mismatch:
                "服务器身份已变化：证书公钥与配对时固定的不一致。"
                + "如果确实换过机器或重置过内核，请在 Phecda 上重新配对。")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
