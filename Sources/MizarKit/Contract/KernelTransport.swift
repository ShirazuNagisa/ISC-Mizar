import Foundation

/// 与一台内核通信所需的全部能力。
///
/// # 为什么要有这一层
///
/// Phecda 通过 `libisc` 的 C ABI 在本进程内派发请求，Mizar 通过 HTTPS
/// 走网络 —— 两者的**功能面完全相同**（同一个 OpenAPI 契约），只有传输
/// 不同。把传输抽成一个协议之后，上层的 `KernelAPI`（几十个方法、
/// 45 个模型）在两个仓库里逐字一致，而差异被压到这一个协议的两个实现里。
///
/// 另一个好处在测试：契约测试可以注入一个假的传输，从而在不启动内核、
/// 不联网的情况下断言"发出去的请求长什么样、回来的载荷怎么解"。
public protocol KernelTransport: Sendable {
    /// 发一次请求。
    ///
    /// 返回的是与 `isc_call` 同构的信封（`{ok, status, body}`）——
    /// **归一化由传输层完成**，见 `HTTPTransport` 里的说明。
    func call(_ method: String, _ path: String, body: Data?) async throws -> KernelReply

    /// 游标式长轮询。
    func pollEvents(since: Int64, timeoutMilliseconds: Int) async throws -> EventBatch
}

/// 造一个连向某个地址的传输。
///
/// 四个参数分别是：地址、固定的公钥指纹（`nil` = 首次使用，见
/// `HTTPTransport.Configuration.pinnedSPKI`）、令牌（配对时为空串）、
/// 语言。
///
/// # 为什么要把它做成可注入的
///
/// 配对与连接这两件事最需要测试的部分**不是网络**，而是它们的决策：
/// 候选地址该按什么顺序试、几个地址都失败之后该报哪一个错、401 之后
/// 该进入什么状态。这些用真实的 HTTPS 服务端来测既慢又难构造
/// （要起一个能返回各种错误的服务端），而注入一个假传输之后，
/// 它们全部变成纯粹的断言。
public typealias TransportFactory = @Sendable (_ baseURL: URL, _ pinnedSPKI: String?,
                                               _ token: String, _ language: String) -> any KernelTransport

/// 一批事件。
public struct EventBatch: Sendable, Equatable {
    public let events: [JSONValue]
    /// 下次请求应当携带的游标。
    public let next: Int64
    /// 为 true 表示游标已跌出内核的环形缓冲，中间的事件已经丢了。
    ///
    /// 此时**不要试图补齐** —— 全量重拉一次状态即可。事件描述的是
    /// "发生了什么变化"，而客户端要的是"现在是什么样"。
    public let gap: Bool

    public init(events: [JSONValue], next: Int64, gap: Bool) {
        self.events = events
        self.next = next
        self.gap = gap
    }
}

/// 契约层的统一入口。
///
/// 类型名与 Phecda 的 `KernelClient` 一致，方法签名也一致 —— 这不是巧合：
/// `KernelAPI.swift` 是逐字复制的，因此它认识的那个类型必须长得一样。
/// 差别只在构造：Phecda 不给参数（它走进程内的 C 调用），Mizar 注入一个传输。
public final class KernelClient: Sendable {
    private let transport: any KernelTransport

    public init(transport: any KernelTransport) {
        self.transport = transport
    }

    public func call(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> KernelReply {
        try await callRaw(method, path, body: body?.text())
    }

    public func callRaw(_ method: String, _ path: String, body payload: String?) async throws -> KernelReply {
        try await transport.call(method, path, body: payload.map { Data($0.utf8) })
    }

    /// 拉一批事件。
    ///
    /// 返回形状与 `isc_events_json` 一致（`{events, next, gap}`），
    /// 因此上层的事件循环在两个应用里是同一份代码。
    public func events(since: Int64, timeoutMilliseconds: Int32 = 300) async throws -> JSONValue {
        let batch = try await transport.pollEvents(
            since: since, timeoutMilliseconds: Int(timeoutMilliseconds))
        return .object([
            "events": .array(batch.events),
            "next": .number(Double(batch.next)),
            "gap": .bool(batch.gap),
        ])
    }

    /// 把一段用户可控的标识符安全地放进 URL 路径。
    ///
    /// 允许 RFC 3986 的 unreserved 集合（字母数字与 `-._~`）而不是只允许
    /// 字母数字：内核的 id 是 base64url 与 UUID，全都含 `-` 或 `_`，
    /// 每个都百分号编码虽然仍然正确，但会让日志与错误信息里的 URL 难以辨认。
    /// `/`、`?`、`#` 依然被编码，因此注入不了路径或查询。
    public static func pathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
