import Foundation
import Testing
import MizarApp
import MizarKit

/// 应用层：进入详情页时的状态推进。
///
/// # 这里测的是"什么时候界面能看到东西"
///
/// 用户报告里最难查的一条是"点一下服务端，右边什么都没有"：它既不是
/// 崩溃也不是错误，只是一个空窗期 —— 而空窗期的成因几乎总是"某个 await
/// 挡在渲染前面"。`AppModel.select` 因此必须是**同步**的：它只能把状态
/// 改成"连接中"就返回，连接交给后台任务。这几条测试钉住的就是那件事。
///
/// 它们不需要网络：选中的服务端要么不在列表里（立刻失败），要么没有
/// 令牌（立刻变成"需要重新配对"）—— 两条路径都不依赖真实服务端。
@MainActor
struct AppModelTests {

    private func tempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mizar-appmodel-\(UUID().uuidString)")
    }

    private func makeRecord(id: String = "srv-1",
                            addresses: [String] = ["192.168.1.10:8788"]) -> ServerRecord {
        ServerRecord(id: id, name: "Mac-mini", scheme: "https",
                     addresses: addresses,
                     spkiSHA256: "TErcJ99SbmE1HNydX19qHAuNhRpsr5jH71UR2Zkw420",
                     role: "operator")
    }

    /// 选中一台服务端的**当帧**就应当是"连接中"，而不是"什么都还没发生"。
    ///
    /// 断言与 `select` 之间没有任何 await —— 这正是要点：如果 `select`
    /// 还是 `async`、还要等一次连接，这里读到的就会是 `.idle`，而界面
    /// 在那几秒里是一片空白（或一句"还没有数据"）。
    @Test func selectingAServerShowsTheSkeletonImmediately() async {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = AppModel(directory: dir)
        model.select("srv-1")

        #expect(model.selectedServerID == "srv-1")
        #expect(model.state(of: "srv-1") == .connecting)
        // 还没有拿到过数据 —— 这正是界面画骨架、而不是说"还没有站点"
        // 的依据。
        #expect(!model.hasLoadedData)
    }

    /// 切服务器会清空上一台的数据。
    ///
    /// 保留上一台的指标会让用户以为**新**服务器 CPU 爆了 —— 那比空白
    /// 危险得多。这条与上一条一起说明"选中"这个动作改了什么。
    @Test func selectingAnotherServerClearsThePreviousData() async {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = AppModel(directory: dir)
        model.select("srv-1")
        model.select("srv-2")

        #expect(model.selectedServerID == "srv-2")
        #expect(model.metrics == nil)
        #expect(model.apps.isEmpty)
        #expect(!model.hasLoadedData)
    }

    /// 连接失败（或根本连不起来）之后，"连接中"必须落到一个确定的状态。
    ///
    /// # 为什么要有这一条
    ///
    /// `connectAndRefresh` 里有一个 `defer`：被取消或提前返回时不能把
    /// 状态留在 `.connecting`。留在那儿的话，界面会**永远**停在骨架屏上
    /// —— 连"重试"按钮都不会出现（那个按钮只在具体状态里画）。
    @Test func aFailedConnectionNeverStaysInConnecting() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 记录在，但令牌没有（模拟 Keychain 被清过）—— `session(for:)`
        // 会报"需要重新配对"，而不可能连上。
        let record = makeRecord()
        try await ServerStore(directory: dir).upsert(record)

        let model = AppModel(directory: dir)
        model.selectedServerID = record.id
        model.retry()
        #expect(model.state(of: record.id) == .connecting)

        // 后台任务跑完（失败是立刻的，因此这个等待很短）。
        for _ in 0..<300 {
            if model.state(of: record.id) != .connecting { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let settled = model.state(of: record.id)
        #expect(settled != .connecting, "连接结束后不能停在「连接中」，否则骨架屏永远不消失")
        #expect(settled != .online)
    }

    // MARK: - 冷启动只该有一场竞速

    /// 冷启动时"连接"这个动作会被三个地方分别触发一次，而它只该发生一次。
    ///
    /// # 这条钉住的是真机日志里那一串 `C2…C14`
    ///
    /// 三个触发点都是真的：
    ///
    ///	应用壳的 `.task` → `enterForeground()`（`ISCMizarApp.swift:55`）
    ///	`scenePhase` 第一次变成 `.active` → `enterForeground()`（同文件 :105）
    ///	列表页的 `.task` → `loadServers()` → `startConnecting`（`ServerListView.swift:45`）
    ///
    /// 它们要的是同一件事。而改之前每一次都会掐掉上一场、**重开一场
    /// 完整的候选地址竞速** —— 一场是八到九条 TCP 连接，而被取消的那一场
    /// 也不会立刻收摊（每条 URLSession 请求要自己注意到取消）。三场叠加
    /// 起来就是一次开屏二十多条连接，全部注定失败，每条还各打两行内核日志。
    ///
    /// 断言用"传输工厂被调用了几次"来表达"发起了几条候选连接"：工厂是
    /// 每个候选地址调一次，因此八次 = 恰好一场竞速。
    @MainActor
    @Test func coldLaunchStartsOneRaceNotThree() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 八条候选，全部挂住 —— 于是整场竞速在测试期间一直是"在跑"，
        // 三次触发全都落在同一个窗口里。
        let addresses = (1...8).map { "10.0.0.\($0):8788" }
        let record = makeRecord(addresses: addresses)
        try await ServerStore(directory: dir).upsert(record)
        let tokens = InMemoryTokenStore()
        try await tokens.setToken("tok", for: record.id)

        let started = ConnectionCounter()
        let model = AppModel(directory: dir, tokens: tokens, makeTransport: { _ in
            started.bump()
            return HangingTransport()
        })

        await model.enterForeground()   // 应用壳的 .task
        await model.enterForeground()   // scenePhase 变成 .active
        await model.loadServers()       // 列表页的 .task

        // 让三次触发背后的那场竞速真的跑起来（`startConnecting` 不阻塞
        // 调用方，它只把工作交给后台任务）。
        try? await Task.sleep(for: .milliseconds(300))

        #expect(started.count == addresses.count,
                "一次冷启动只该有一场竞速（\(addresses.count) 条候选），实际发起了 \(started.count) 条")

        // 收尾：切到一台不存在的服务端会把在跑的那一场掐掉，
        // 否则那八条挂住的连接要等满 60 秒才散。
        model.select("srv-nowhere")
    }

    /// 用户按下"重试"必须真的重开一场，不能被上面那个复用逻辑吃掉。
    ///
    /// # 为什么这两条要放在一起
    ///
    /// "同一台服务端已经有一条连接在跑时就复用它"与"用户要重试就给一场
    /// 新的"是一对取舍：少了后一条，那个按钮会在连接卡住时变成一个按下去
    /// 什么都不发生的按钮 —— 而它恰恰是用户在卡住时唯一会点的东西。
    @MainActor
    @Test func manualRetryStillStartsANewRace() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = makeRecord(addresses: ["10.0.0.1:8788"])
        try await ServerStore(directory: dir).upsert(record)
        let tokens = InMemoryTokenStore()
        try await tokens.setToken("tok", for: record.id)

        let started = ConnectionCounter()
        let model = AppModel(directory: dir, tokens: tokens, makeTransport: { _ in
            started.bump()
            return HangingTransport()
        })

        await model.enterForeground()
        let first = await waitForConnections(started, toReach: 1)
        #expect(first, "第一次进入前台应当发起一次连接")

        model.retry()
        let second = await waitForConnections(started, toReach: 2)
        #expect(second, "用户按下重试就该重新发起一次连接")

        model.select("srv-nowhere")
    }

    /// 等工厂被调用到指定次数（上限约 2 秒）。
    private func waitForConnections(_ counter: ConnectionCounter, toReach target: Int) async -> Bool {
        for _ in 0..<200 {
            if counter.count >= target { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

/// 线程安全的计数器。
///
/// `TransportFactory` 是 `@Sendable` 的**同步**闭包，因此这里不能用 actor
/// （那需要 await），只能用一把锁。
private final class ConnectionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

