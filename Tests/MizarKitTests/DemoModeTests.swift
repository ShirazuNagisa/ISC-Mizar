#if MIZAR_DEMO
import Foundation
import Testing
@testable import MizarApp
import MizarKit

/// 演示模式：没有服务端也要走完四个页签。
///
/// # 这些测试默认**不跑**
///
/// 整个文件在 `#if MIZAR_DEMO` 里，因此 `./Scripts/test.sh` 的常规那一遍
/// 编译不到它（那一遍必须是生产语义）。它由 test.sh 里的第二遍
/// （`MIZAR_DEMO=1 swift test`）覆盖。
///
/// 为什么值得单独跑一遍：演示模式是**唯一**决定"审核员能不能用"的东西，
/// 而它最容易坏的方式不是崩溃，是"能编译、能启动、页签是空的"——
/// 那种坏法只有断言数据到位才看得见。
///
/// # 断言尽量走公开 API
///
/// 除了两张路由表，下面的断言都用 `AppModel` / `currentKernel()` 这些
/// **应用真正会调**的入口，而不是直接去读 `DemoData` 的字符串常量。
/// 前者能抓住"假数据与契约脱节"，后者只能抓住"常量被改名"。
@MainActor
struct DemoModeTests {

    /// 等一个条件成立。与 `AppModelTests` 里那一个同构。
    private func waitUntil(_ condition: () -> Bool,
                           timeout: Duration = .seconds(5)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// 应用壳那一句 `AppModel()` 拿到的必须是演示数据。
    @Test func theAppShellsOwnConstructionTurnsDemoModeOn() async {
        let model = AppModel()
        #expect(model.isDemo, "演示构建里 AppModel() 必须走演示接线")
    }

    /// **核心那一条**：不连任何服务端，四个页签的数据全部到位。
    ///
    /// 逐个页签列出它要渲染的字段（见 `OverviewView` / `ServicesView` /
    /// `ResourcesView` / `DNSView`），任何一个为空，对应那一页在审核员
    /// 眼里就是骨架屏或者"还没有…"。
    @Test func everyTabHasItsDataWithoutAnyServer() async {
        let model = AppModel()
        let started = ContinuousClock().now
        await model.enterForeground()

        // 等的是"两件事都到位"，而不是只等 `hasLoadedData`。
        //
        // `refreshAll()` 只装那七个列表接口就结束加载态；**指标走的是另一条
        // 路** —— `startMetricsPolling()` 里那 5 秒一圈的 `refreshMetrics()`，
        // 它的第一圈在 `refreshAll()` 之后才跑（见 `connectAndRefresh`）。
        // 只等前者的话，下面那几条指标断言是在赌一个后到的任务 —— 而它
        // 有时先到、有时后到。
        let loaded = await waitUntil { model.hasLoadedData && model.metrics != nil }
        let elapsed = ContinuousClock().now - started
        #expect(loaded, "演示模式必须自己把数据填上，实际状态 \(model.state(of: model.selectedServerID ?? "?"))")

        // 这一条同时证明**它没有去连网络**：演示服务端的候选地址是
        // 192.168.1.10 与一个公网域名，真的去连的话单条候选就要等满
        // 4 秒的探测超时（见 ServerSession.probeTimeout）。
        #expect(elapsed < .seconds(2), "演示数据不该走网络，实际用了 \(elapsed)")
        #expect(model.loading == nil, "数据到手之后不能还留着加载态 —— 否则界面画的是加载屏而不是页签")

        // 侧栏与状态。
        #expect(model.servers.count == 1, "演示模式给一台服务端，实际 \(model.servers.count) 台")
        #expect(model.selectedServerID == model.servers.first?.id)
        #expect(model.state(of: model.servers.first?.id ?? "") == .online)
        #expect(model.canWrite, "角色要是 operator，否则审核员看到的全是只读提示")

        // 概览页。
        #expect(model.metrics != nil, "概览页的指标卡要有数字")
        #expect(model.metrics?.footprint != nil, "概览页同时显示 footprint 与整机两个口径")
        #expect((model.metrics?.history?.count ?? 0) > 1, "那条迷你曲线至少要两个采样点才画得出来")
        #expect(!model.advisories.isEmpty, "概览页最上面那张「需要处理」卡")
        #expect(!model.certificates.isEmpty, "证书卡")
        #expect(model.ipStatus != nil, "地址卡")

        // 服务页。
        #expect(model.apps.count >= 3, "站点列表，实际 \(model.apps.count) 条")

        // 资源页。
        //
        // 这几条先取到局部变量再断言：`#expect` 的宏在
        // `!(model.metrics?.host.disks ?? []).isEmpty` 这种"前缀取反 +
        // 可选合并 + 成员访问"叠在一起时会漏掉一部分子表达式 ——
        // 它会把一个非空数组报成失败，而那是一个会让人去查资源的假警报。
        let disks = model.metrics?.host.disks ?? []
        #expect(disks.count == 2, "资源页的磁盘那一段，实际 \(disks.count) 条")
        #expect(model.metrics?.host.gpu != nil, "GPU 那一段")
        #expect((model.metrics?.apps ?? []).contains { $0.hasOwnProcess },
                "至少要有一个带独立进程的站点，否则「站点占用」那一段永远是空的")

        // DNS 页（凭据与动态解析任务来自全量刷新）。
        #expect(!model.credentials.isEmpty, "服务商凭据")
        #expect(!model.ddnsTasks.isEmpty, "动态解析任务")

        model.enterBackground()   // 收尾：停掉长轮询
    }

    /// DNS 页的区域与记录：界面走的是 `currentKernel()` 这两条**按参数**
    /// 的路径（`/v1/credentials/{id}/zones/...`），它们与上面那七个
    /// 无参数接口不是同一段路由。
    @Test func theDNSRoutesAnswerWithZonesAndRecords() async throws {
        let model = AppModel()
        await model.enterForeground()
        _ = await waitUntil { model.hasLoadedData }
        defer { model.enterBackground() }

        let credential = try #require(model.credentials.first)
        let kernel = try await model.currentKernel()

        let zones = try await kernel.zones(credentialID: credential.id)
        #expect(!zones.isEmpty, "选中凭据之后要能列出区域，否则记录那一段永远不出现")

        let zone = try #require(zones.first)
        let records = try await kernel.records(credentialID: credential.id, zone: zone.id)
        #expect(records.count >= 4, "记录列表，实际 \(records.count) 条")
        #expect(records.contains { $0.type == "CNAME" }, "记录里要有不同类型的样本")
    }

    /// 服务页的详情与写操作。
    ///
    /// 写操作也要答得上来：演示模式给的是 operator 角色，界面因此会画出
    /// 「重启」「停止」这些按钮 —— 一个按下去报错的按钮比没有按钮更糟。
    @Test func thePerSiteRoutesAndWritesAnswer() async throws {
        let model = AppModel()
        await model.enterForeground()
        _ = await waitUntil { model.hasLoadedData }
        defer { model.enterBackground() }

        let site = try #require(model.apps.first { $0.isRunning })
        let kernel = try await model.currentKernel()

        let logs = try await kernel.appLogs(site.id, tail: 300)
        #expect(!logs.isEmpty, "站点详情页那个日志 sheet 要有内容")

        // 这三条是界面上的按钮；演示模式必须让它们真的成功。
        try await kernel.restartApp(site.id)
        try await kernel.stopApp(site.id)
        try await kernel.startApp(site.id)

        let task = try #require(model.ddnsTasks.first)
        try await kernel.runDdnsTask(task.id)
        let toggled = try await kernel.setDdnsTask(task.id, enabled: !task.enabled)
        #expect(toggled.id == task.id)
    }

    /// 契约里的每一条路径都必须有对应载荷。
    ///
    /// # 它挡的是哪一种坏法
    ///
    /// 假传输对认不出的路径**抛 404**（刻意的：回一个空对象会被解成
    /// "你的服务器上确实没有站点"，那是一个安静的假事实）。于是漏一条
    /// 路径的后果是界面上冒出一句"演示模式没有为…准备数据"。
    /// 这条测试把那个 404 提前到 `swift test` 里。
    @Test func everyContractRouteHasAPayload() {
        let routes: [(String, String)] = [
            ("GET", "/v1/health"),
            ("GET", "/v1/meta"),
            ("GET", "/v1/remote/self"),
            ("POST", "/v1/remote/self/derive"),
            ("POST", "/v1/remote/self/push-token"),
            ("DELETE", "/v1/remote/self/push-token"),
            ("GET", "/v1/metrics"),
            ("GET", "/v1/advisories"),
            ("GET", "/v1/apps"),
            ("GET", "/v1/apps/\(DemoData.siteAPIID)"),
            ("GET", "/v1/apps/\(DemoData.siteAPIID)/logs?tail=300"),
            ("POST", "/v1/apps/\(DemoData.siteAPIID)/restart"),
            ("POST", "/v1/apps/\(DemoData.siteAPIID)/start"),
            ("POST", "/v1/apps/\(DemoData.siteAPIID)/stop"),
            ("GET", "/v1/ip/current"),
            ("GET", "/v1/credentials"),
            ("GET", "/v1/credentials/\(DemoData.credentialID)/zones"),
            ("GET", "/v1/credentials/\(DemoData.credentialID)/zones/\(DemoData.zoneID)/records"),
            ("POST", "/v1/credentials/\(DemoData.credentialID)/zones/\(DemoData.zoneID)/records"),
            ("PUT", "/v1/credentials/\(DemoData.credentialID)/zones/\(DemoData.zoneID)/records/rec-apex"),
            ("DELETE", "/v1/credentials/\(DemoData.credentialID)/zones/\(DemoData.zoneID)/records/rec-apex"),
            ("GET", "/v1/ddns-tasks"),
            ("POST", "/v1/ddns-tasks/\(DemoData.ddnsTaskID)/run"),
            ("POST", "/v1/ddns-tasks/\(DemoData.ddnsTaskID)/enable"),
            ("POST", "/v1/ddns-tasks/\(DemoData.ddnsTaskID)/disable"),
            ("GET", "/v1/certs"),
            ("POST", "/v1/certs/renew"),
            ("GET", "/v1/proxy/status"),
            ("POST", "/v1/remote/public/check"),
        ]
        for (method, route) in routes {
            let normalized = DemoTransport.route(from: route)
            #expect(DemoTransport.reply(for: normalized, method: method) != nil,
                    "\(method) \(route) 没有载荷 —— 界面上会出现「演示模式没有为…准备数据」")
        }
    }

    /// 认不出的路径要**报错**，不能回一个空对象。
    @Test func anUnknownRouteFailsLoudly() async {
        let transport = DemoTransport()
        await #expect(throws: KernelError.self) {
            _ = try await transport.call("GET", "/v1/does-not-exist", body: nil)
        }
    }

    /// 演示数据里必须带着归档脚本要找的那几个字符串。
    ///
    /// # 为什么两个地方各写一份
    ///
    /// `Scripts/archive.sh` 在**生产产物**里搜这几个字符串，搜到就说明
    /// 演示代码漏进了发布包（那是最严重的一种事故）。它用的是 shell，
    /// 读不到 Swift 常量，因此那份清单只能手写。
    ///
    /// 这条测试就是那两份清单之间的接线：谁改了演示域名而没有同步改
    /// 归档脚本，这里先红 —— 否则归档脚本会变成一条"永远通过"的检查，
    /// 而它保护的恰恰是不能出错的那一件事。
    @Test func theSentinelsArchiveScriptSearchesForAreStillPresent() {
        let everything = [
            DemoData.remoteSelf, DemoData.metrics, DemoData.advisories, DemoData.apps,
            DemoData.appLogs, DemoData.ipStatus, DemoData.credentials, DemoData.zones,
            DemoData.records, DemoData.ddnsTask, DemoData.certificates, DemoData.serverName,
            DemoData.record.spkiSHA256, DemoData.record.publicHost ?? "",
        ].joined()

        for sentinel in ["blog.example.com", "api.example.com", "mizar-demo"] {
            #expect(everything.contains(sentinel),
                    "演示数据里没有「\(sentinel)」—— 归档脚本的清单已经与它脱节了")
        }
    }

    /// 显式传参的构造**不受演示模式影响**。
    ///
    /// # 它为什么重要
    ///
    /// 演示接线只在"三个参数都没传"时生效（见 `AppModel.init`）。这一条
    /// 把它钉住：测试与验收工具全部显式传参，如果哪天有人把判据放宽成
    /// "MIZAR_DEMO 开着就换掉"，整整一批与演示无关的测试会安静地开始
    /// 拿假数据 —— 而它们仍然会绿。
    @Test func explicitParametersAreNeverReplacedByDemoWiring() async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mizar-demo-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = AppModel(directory: dir)
        await model.loadServers()

        #expect(model.servers.isEmpty,
                "显式给了目录就不该再塞演示服务端进来，实际 \(model.servers.count) 台")
    }
}
#endif
