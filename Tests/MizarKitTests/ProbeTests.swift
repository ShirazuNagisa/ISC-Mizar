import Foundation
import Testing
@testable import MizarKit

/// 可达性自检。
///
/// # 这里最容易犯的错是**假阳性**
///
/// 手机在自己家里的 Wi-Fi 上时，连公网地址**也会成功** —— 那个连接
/// 根本没出局域网（走二层或路由器的 NAT 环回）。把它当成"公网可达"
/// 是最坏的一种结论：用户会以为已经验证过了，而其实什么都没验证，
/// 之后真正需要远程访问的时候才发现连不上。

/// 一个可编排的连接器。
actor StubConnector: ProbeConnector {
    /// 能连上的 host:port。
    private var reachable: Set<String>
    /// 能取到的 URL。
    private var fetchable: Set<String>
    private(set) var connectCalls: [String] = []
    private(set) var fetchCalls: [String] = []

    init(reachable: [String] = [], fetchable: [String] = []) {
        self.reachable = Set(reachable)
        self.fetchable = Set(fetchable)
    }

    func connect(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        connectCalls.append("\(host):\(port)")
        return reachable.contains("\(host):\(port)")
    }

    func fetch(_ url: URL, timeout: TimeInterval) async -> Bool {
        fetchCalls.append(url.absoluteString)
        return fetchable.contains(url.absoluteString)
    }
}

private func plan(lan: [String] = [], targets: [PublicTarget]) -> PublicProbePlan {
    PublicProbePlan(host: "mizar-abc.example.com", port: 8788,
                    targets: targets, lanAddresses: lan)
}

private let hostTarget = PublicTarget(family: "host",
                                      url: "https://mizar-abc.example.com:8788/v1/remote/ping",
                                      address: "mizar-abc.example.com")
private let v6Target = PublicTarget(family: "ipv6",
                                    url: "https://[2409:8a50::560]:8788/v1/remote/ping",
                                    address: "2409:8a50::560")
private let v4Target = PublicTarget(family: "ipv4",
                                    url: "https://120.227.48.210:8788/v1/remote/ping",
                                    address: "120.227.48.210")

/// **这条是整组测试里最重要的。**
///
/// 局域网通 → 这次探测不作数。不能报 reachable。
@Test func sameLANMakesTheProbeInconclusive() async {
    let connector = StubConnector(reachable: ["192.168.31.92:8788"])
    let probe = ReachabilityProbe(connector: connector)

    let report = await probe.run(plan: plan(lan: ["192.168.31.92:8788"],
                                            targets: [hostTarget, v6Target]))

    #expect(report.sameLan, "局域网通就说明我在这个网里 —— 必须报 sameLan")
    #expect(!report.reachable, "在同一个 Wi-Fi 下测出来的'通'什么都没证明")
    // 而且**不该**去试公网地址：那只会浪费几秒并可能得到一个
    // 靠 NAT 环回得来的假阳性。
    let fetched = await connector.fetchCalls
    #expect(fetched.isEmpty, "既然已知在同一局域网，就不该再去试公网地址")
}

/// 局域网不通时才去试公网。
@Test func probesPublicTargetsWhenNotOnTheSameLAN() async {
    let connector = StubConnector(fetchable: [hostTarget.url])
    let probe = ReachabilityProbe(connector: connector)

    let report = await probe.run(plan: plan(lan: ["192.168.31.92:8788"],
                                            targets: [hostTarget, v6Target]))

    #expect(!report.sameLan)
    #expect(report.reachable)
    #expect(report.family == "host")
}

/// 域名走完整的 HTTPS，纯地址走 TCP。
///
/// 对纯地址做 HTTPS 会因为证书是给域名的而失败，那会把
/// "端口通了"误报成"不通" —— 而这两件事用户该做的事完全不同。
@Test func hostTargetUsesHTTPAndAddressTargetsUseTCP() async {
    let connector = StubConnector(reachable: ["2409:8a50::560:8788"])
    let probe = ReachabilityProbe(connector: connector)

    let report = await probe.run(plan: plan(targets: [hostTarget, v6Target]))

    #expect(report.reachable, "IPv6 的 TCP 通了就该报可达")
    #expect(report.family == "ipv6")

    let fetched = await connector.fetchCalls
    let connected = await connector.connectCalls
    #expect(fetched.contains(hostTarget.url), "域名应当走 HTTPS")
    #expect(connected.contains("2409:8a50::560:8788"), "IPv6 应当走 TCP")
}

/// 全部不通时要说清楚**试过哪几个**。
///
/// "连不上"这三个字对用户没有用；他需要知道的是"我该去查路由器
/// 还是去查运营商"。
@Test func allFailuresListWhatWasTried() async {
    let connector = StubConnector()
    let probe = ReachabilityProbe(connector: connector)

    let report = await probe.run(plan: plan(targets: [hostTarget, v6Target, v4Target]))

    #expect(!report.reachable)
    #expect(!report.sameLan)
    #expect(report.detail?.contains("mizar-abc.example.com") == true)
    #expect(report.detail?.contains("2409:8a50::560") == true)
}

/// 没有可探测的地址时把内核给的那句话带出去。
@Test func emptyPlanUsesTheKernelsExplanation() async {
    let probe = ReachabilityProbe(connector: StubConnector())
    let report = await probe.run(plan: plan(lan: [], targets: []))

    #expect(!report.reachable)
    #expect(!report.sameLan)
    #expect(report.detail?.isEmpty == false)
}

/// IPv6 的方括号必须被正确拆开。
///
/// 从左边找冒号会把 `2409:8a50::1:8788` 拆成主机 `2409` ——
/// 于是探测会去打一个不存在的地址，报"不通"，而用户完全不知道
/// 是解析错了。
@Test func splitsIPv6HostPortCorrectly() {
    let v6 = ReachabilityProbe.splitHostPort("[2409:8a50:6a1:7450::560]:8788")
    #expect(v6?.0 == "2409:8a50:6a1:7450::560")
    #expect(v6?.1 == 8788)

    let v4 = ReachabilityProbe.splitHostPort("192.168.31.92:8788")
    #expect(v4?.0 == "192.168.31.92")
    #expect(v4?.1 == 8788)

    // 没有端口的一律拒绝，而不是猜一个。
    #expect(ReachabilityProbe.splitHostPort("2409:8a50::1") == nil)
    #expect(ReachabilityProbe.splitHostPort("") == nil)
    #expect(ReachabilityProbe.splitHostPort("host:notaport") == nil)
    // 方括号没闭合。
    #expect(ReachabilityProbe.splitHostPort("[2409::1:8788") == nil)
}
