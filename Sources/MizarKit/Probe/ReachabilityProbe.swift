import Foundation
import Network

/// 可达性自检：手机当外部探针。
///
/// # 为什么这件事必须由手机做
///
/// 内核测不了自己的入站可达性。所有本机发起的连接都会走内部路径 ——
/// 同网段时走二层，跨网段时走 NAT 环回 —— 而这两种都与真实客户端的
/// 路径不同。实测过一次就知道这不是理论问题：用公共探测服务时，
/// 25 个节点里只有 2 个有 IPv6，而它们连不上中国移动的地址。
///
/// 而手机就在真实客户端要走的网络上，它要连的正是那个域名。
///
/// # 假阳性是这里最容易犯的错
///
/// 手机在自己家里的 Wi-Fi 上时，连公网地址**也会成功** —— 那个连接
/// 根本没出局域网（走二层或路由器的 NAT 环回）。把它当成"公网可达"
/// 是最坏的一种结论：用户会以为已经验证过了，而其实什么都没验证，
/// 之后在真正需要远程访问的时候才发现连不上。
///
/// 因此第一步永远是**先试局域网地址**：通了就说明"我就在这个网里"，
/// 这次探测直接作废（报 `sameLan`，内核记成 unknown）。

/// 一个要探测的目标。
public struct PublicTarget: Codable, Sendable, Hashable {
    /// 地址族标签：`host` / `ipv6` / `ipv4`。**只用于显示与归类**，
    /// 真正的判定来自探测结果。
    public var family: String
    /// 完整可请求的地址。
    public var url: String
    /// 给人看的地址。
    public var address: String?

    public init(family: String, url: String, address: String? = nil) {
        self.family = family
        self.url = url
        self.address = address
    }
}

/// 内核下发的探测计划。
public struct PublicProbePlan: Codable, Sendable, Hashable {
    public var host: String?
    public var port: Int
    public var targets: [PublicTarget]
    public var lanAddresses: [String]
    public var note: String?

    public init(host: String? = nil, port: Int, targets: [PublicTarget],
                lanAddresses: [String] = [], note: String? = nil) {
        self.host = host
        self.port = port
        self.targets = targets
        self.lanAddresses = lanAddresses
        self.note = note
    }

    /// 有没有可探测的公网目标。
    public var hasTargets: Bool { !targets.isEmpty }
}

/// 一次探测的结论。
public struct PublicCheckReport: Encodable, Sendable, Equatable {
    public var family: String
    public var reachable: Bool
    /// 手机判断"我和内核在同一个网络里"。为真时这次探测**不作数**。
    public var sameLan: Bool
    public var detail: String?

    public init(family: String, reachable: Bool, sameLan: Bool, detail: String? = nil) {
        self.family = family
        self.reachable = reachable
        self.sameLan = sameLan
        self.detail = detail
    }
}

/// 探测用到的网络动作。
///
/// 抽成协议只为一件事：**让这一层能被测试**。真实实现要连网络，
/// 而这里需要断言的恰恰是"先试局域网、公网不通时怎么报"这类分支 ——
/// 那些分支用真实网络根本覆盖不全（要真的切蜂窝、真的关防火墙）。
public protocol ProbeConnector: Sendable {
    /// 尝试建立一次 TCP 连接。
    ///
    /// 用 TCP 而不是 HTTPS：这一层要回答的是"端口通不通"。
    /// TLS 是否正常是另一件事，而它由 `fetch` 那条路覆盖 ——
    /// 混在一起会让"证书不对"和"连不上"报成同一句话，
    /// 而这两件事用户该做的事完全不同。
    func connect(host: String, port: Int, timeout: TimeInterval) async -> Bool

    /// 完整地请求一次 URL（含 TLS 校验）。
    func fetch(_ url: URL, timeout: TimeInterval) async -> Bool
}

/// 真实实现：Network.framework 建 TCP，URLSession 发请求。
public struct SystemProbeConnector: ProbeConnector {

    public init() {}

    public func connect(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)

        return await withCheckedContinuation { continuation in
            // 只允许结束一次：Network.framework 在超时与失败两条路上
            // 都可能回调，而重复 resume 会让整个进程崩掉。
            let done = Latch()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if done.claim() { continuation.resume(returning: true) }
                    connection.cancel()
                case .failed, .cancelled:
                    if done.claim() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if done.claim() { continuation.resume(returning: false) }
                connection.cancel()
            }
        }
    }

    public func fetch(_ url: URL, timeout: TimeInterval) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // 每次都是新的一次判断，不该被缓存影响。
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        var configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)

        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            // 只有 **200** 才算通。
            //
            // 401/403 说明连接建立了但被拒绝 —— 对这个探针来说那不是
            // 成功：我们要回答的是"这台机器在我们说的那个地址上、
            // 用它说的那个协议会应答吗"，而 401 意味着要么地址不对
            // （打到了别人的服务），要么前面挡着一个中间设备。
            return http.statusCode == 200
        } catch {
            return false
        }
    }
}

/// 只允许被认领一次的闸门。
///
/// `NWConnection` 在超时与失败两条路上都会回调，而
/// `withCheckedContinuation` 被 resume 两次会**直接让进程崩掉**。
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// 执行一次可达性自检。
public struct ReachabilityProbe: Sendable {

    let connector: any ProbeConnector
    /// 局域网探测与公网探测各自的超时。
    ///
    /// 局域网短（同网段要么秒通要么就是不在），公网长
    /// （要过 DNS、跨国路由、可能还有运营商的中间设备）。
    let lanTimeout: TimeInterval
    let publicTimeout: TimeInterval

    public init(connector: any ProbeConnector = SystemProbeConnector(),
                lanTimeout: TimeInterval = 2,
                publicTimeout: TimeInterval = 8) {
        self.connector = connector
        self.lanTimeout = lanTimeout
        self.publicTimeout = publicTimeout
    }

    /// 跑一遍探测计划。
    ///
    /// 返回的结论只有三种含义：
    ///
    ///   - `sameLan == true`：我就在这个网里，**这次探测不作数**；
    ///   - `reachable == true`：从这个网络位置真的连上了；
    ///   - 其余：连不上，`detail` 说明卡在哪一步。
    public func run(plan: PublicProbePlan) async -> PublicCheckReport {
        // 第一步永远是局域网 —— 它决定后面的一切算不算数。
        if await isOnSameLAN(plan) {
            return PublicCheckReport(
                family: "unknown", reachable: false, sameLan: true,
                detail: "手机与内核在同一个局域网里（\(plan.lanAddresses.first ?? "本机网段")），这次探测不作数。请在蜂窝数据或别的网络上再试。")
        }

        guard plan.hasTargets else {
            return PublicCheckReport(
                family: "unknown", reachable: false, sameLan: false,
                detail: plan.note ?? "内核还没有可探测的公网地址。")
        }

        var failures: [String] = []
        // 按内核给的顺序试：域名在前，然后 IPv6，最后 IPv4。
        // 顺序由内核决定，因为**它知道哪一条更可能是可达的那条**。
        for target in plan.targets {
            if await probe(target) {
                return PublicCheckReport(
                    family: target.family, reachable: true, sameLan: false,
                    detail: "从当前网络连上了 \(target.address ?? target.url)。")
            }
            failures.append(target.address ?? target.url)
        }

        return PublicCheckReport(
            family: plan.targets.first?.family ?? "unknown",
            reachable: false, sameLan: false,
            detail: "这几个地址都连不上：\(failures.joined(separator: "、"))。多半是路由器或运营商挡了入站连接。")
    }

    /// 手机是不是就在内核所在的局域网里。
    ///
    /// **任意一个局域网地址通就说明是。** 不必全试：地址列表里有
    /// IPv4、IPv6 与 `.local` 三种，而手机只可能走其中一条。
    private func isOnSameLAN(_ plan: PublicProbePlan) async -> Bool {
        for address in plan.lanAddresses {
            guard let (host, port) = Self.splitHostPort(address) else { continue }
            if await connector.connect(host: host, port: port, timeout: lanTimeout) {
                return true
            }
        }
        return false
    }

    /// 试一个公网目标。
    ///
    /// 域名走完整的 HTTPS（把 DNS、端口、TLS 与路径一起验证），
    /// 纯地址走 TCP（TLS 会因为证书是给域名的而对不上，
    /// 而那会把"端口通了"误报成"不通"）。
    private func probe(_ target: PublicTarget) async -> Bool {
        guard let url = URL(string: target.url), let host = url.host() else { return false }
        let port = url.port ?? (url.scheme == "http" ? 80 : 443)

        if target.family == "host" {
            return await connector.fetch(url, timeout: publicTimeout)
        }
        return await connector.connect(host: host, port: port, timeout: publicTimeout)
    }

    /// 拆开 `host:port`，处理 IPv6 的方括号。
    static func splitHostPort(_ address: String) -> (String, Int)? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (host, port)
        }

        // 没有方括号时，多于一个冒号就是**歧义**，只能拒绝。
        //
        // `2409:8a50::1` 可以被读成"主机 `2409:8a50::1`"
        // （一个没有端口的 IPv6），也可以被读成"主机 `2409:8a50:` 加端口 1"。
        // 两种读法都说得通，而猜错的后果是去打一个不存在的地址，
        // 报"不通"—— 用户完全不知道是解析错了。
        //
        // 内核发出来的 IPv6 一律带方括号（`net.JoinHostPort` 就是这么
        // 拼的），因此拒绝不会漏掉任何一种真实情况。
        if trimmed.filter({ $0 == ":" }).count > 1 {
            return nil
        }

        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[..<colon])
        guard let port = Int(trimmed[trimmed.index(after: colon)...]) else { return nil }
        return (host, port)
    }
}
