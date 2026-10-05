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

    /// 选中一台服务端的**当帧**就应当是"连接中" + 加载态，
    /// 而不是"什么都还没发生"。
    ///
    /// 断言与 `select` 之间没有任何 await —— 这正是要点：如果 `select`
    /// 还是 `async`、还要等一次连接，这里读到的就会是 `.idle`，而界面
    /// 在那几秒里是一片空白（或一句"还没有数据"）。
    ///
    /// 加载态与"连接中"是两件事（见 `LoadingStatus`）：前者决定界面画
    /// 什么，后者决定状态点是什么颜色。这里两个一起断言，是因为它们必须
    /// 在**同一帧**就位 —— 只改其中一个，用户看到的都是一块不会动的东西。
    @Test func selectingAServerShowsLoadingImmediately() async {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = AppModel(directory: dir)
        model.select("srv-1")

        #expect(model.selectedServerID == "srv-1")
        #expect(model.state(of: "srv-1") == .connecting)
        #expect(model.loading?.serverID == "srv-1", "选中之后必须立刻有加载态可画")
        #expect(model.loading(for: "srv-1") != nil)
        #expect(model.loading(for: "别的服务端") == nil, "加载态不该串到别的服务端上")
        // 还没有拿到过数据 —— 这正是界面画加载态、而不是说"还没有站点"
        // 的依据。
        #expect(!model.hasLoadedData)
    }

    /// 一台服务端都没有时，"正在打开 Mizar…"不能一直盖着。
    ///
    /// # 为什么这一条值得单独钉
    ///
    /// 整屏加载态的判据里有一条是"记录还没读出来"。读完之后如果一台都
    /// 没有，就没有任何东西会去结束它 —— 屏幕会永远停在转圈上，而用户
    /// 要做的事（添加服务端）恰好被它盖住了。
    @Test func withNoServersTheLaunchCoverGoesAway() async {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = AppModel(directory: dir)
        #expect(model.launchCover != nil, "记录还没读出来时先盖住")
        #expect(model.launchCover?.serverID == nil)

        await model.enterForeground()
        #expect(model.launchCover == nil, "一台都没有时首屏必须露出来（空状态里有「添加服务端」）")
        #expect(model.hasLoadedServers)
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
        #expect(model.loading != nil)

        // 后台任务跑完（失败是立刻的，因此这个等待很短）。
        for _ in 0..<300 {
            if model.state(of: record.id) != .connecting { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let settled = model.state(of: record.id)
        #expect(settled != .connecting, "连接结束后不能停在「连接中」，否则加载屏永远不消失")
        #expect(settled != .online)
        // 加载态与状态在**同一处**收尾：落定了而转圈还在转，用户就永远
        // 等不到那个"重试"按钮。
        #expect(model.loading == nil, "失败之后必须撤掉加载态")
    }

    // MARK: - 加载态

    /// 连不上时那句错误必须**说清楚它试过什么**。
    ///
    /// # 它解决的是"用户分不清应用卡了与网络慢"
    ///
    /// 客户端其实一直知道答案：刚刚有几条候选地址、一共等了多久。把它写
    /// 出来，"连不上"就从一句没头没尾的失败变成"它试了 8 条、等了 4 秒，
    /// 都不是" —— 前者让人怀疑应用，后者让人去查网络。
    @Test func aFailedRaceSaysHowManyAddressesItTried() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let addresses = (1...8).map { "10.0.0.\($0):8788" }
        let record = makeRecord(addresses: addresses)
        try await ServerStore(directory: dir).upsert(record)
        let tokens = InMemoryTokenStore()
        try await tokens.setToken("tok", for: record.id)

        let model = AppModel(directory: dir, tokens: tokens,
                             makeTransport: { _ in UnreachableTransport() })
        // 先把列表读进来（`select` 里那句"正在同时尝试 N 条地址"的 N 来自
        // 记录里的候选地址），再**同步**地选一次：断言与 `select` 之间
        // 不能有 await，否则竞速可能已经跑完了。
        await model.loadServers()
        #expect(model.selectedServerID == record.id)
        model.select(record.id)
        #expect(model.loading?.detail.contains("8") == true,
                "第一条状态文字就该说明在试几条地址，实际 \(model.loading?.detail ?? "nil")")

        let settled = await waitUntil { model.state(of: record.id) != .connecting }
        #expect(settled, "八条候选都立刻失败，这场竞速该很快结束")

        guard case .unreachable(let detail) = model.state(of: record.id) else {
            Issue.record("期望 .unreachable，得到 \(model.state(of: record.id))")
            return
        }
        #expect(detail.contains("8"), "那句错误里要写清楚试了几条地址：\(detail)")
        #expect(detail.contains("秒"), "那句错误里也要写清楚等了多久：\(detail)")
        #expect(detail.contains("连不上这台服务端"), "原有的那句「该做什么」不能被挤掉：\(detail)")
        #expect(model.loading == nil)
    }

    /// 数据到手之后加载态必须消失，界面才能显示读数。
    @Test func dataArrivalEndsTheLoading() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = makeRecord()
        try await ServerStore(directory: dir).upsert(record)
        let tokens = InMemoryTokenStore()
        try await tokens.setToken("tok", for: record.id)

        let model = AppModel(directory: dir, tokens: tokens,
                             makeTransport: { _ in FakeServerTransport() })
        model.selectedServerID = record.id
        model.retry()

        let loaded = await waitUntil { model.hasLoadedData }
        #expect(loaded, "假服务端会立刻回答，数据该到")
        #expect(model.loading == nil, "数据到了就该撤掉加载态")
        #expect(model.state(of: record.id) == .online)
        model.enterBackground()   // 收尾：停掉长轮询
    }

    /// 加载态里那一行文字**必须随时间变化**。
    ///
    /// # 为什么这是硬要求而不是
    ///
    /// 一个转了 30 秒而一个字都没变的转圈，与死机给用户的感受完全一样。
    /// 这条测试盯着的是"（3/7）"那个计数：它是七个数据请求里完成的个数，
    /// 也是那几秒里唯一能证明"真的在干活"的东西。
    @Test func theLoadingDetailChangesWhileDataArrives() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = makeRecord()
        try await ServerStore(directory: dir).upsert(record)
        let tokens = InMemoryTokenStore()
        try await tokens.setToken("tok", for: record.id)

        // 每个请求比上一个多等 50 毫秒：七个数据请求于是**一个接一个**
        // 到齐，而不是同时到齐 —— 同时到齐的话那一行字只会闪一下，
        // 这条测试也就什么都证明不了。
        let model = AppModel(directory: dir, tokens: tokens,
                             makeTransport: { _ in FakeServerTransport(staggerMilliseconds: 50) })
        model.selectedServerID = record.id
        model.retry()

        var seen: Set<String> = []
        for _ in 0..<400 {
            if let detail = model.loading?.detail { seen.insert(detail) }
            if model.hasLoadedData { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        model.enterBackground()

        #expect(seen.contains { $0.contains("/7") },
                "加载态里必须出现「读到第几个」的进度，实际看到 \(seen.sorted())")
        #expect(seen.count >= 3, "状态文字必须在变，实际只有 \(seen.sorted())")
    }

    /// 从后台回到前台时的静默重连，不能把已经在屏幕上的读数换成加载屏。
    ///
    /// # 这条挡的是一个很具体的倒退
    ///
    /// `enterForeground` 每次都会重连（长轮询停了，快照可能过期），
    /// 而它会把状态重新标成 `.connecting`。如果加载态只看状态，用户每次
    /// 切回应用都会看到屏幕被一块转圈盖住 —— 而手上明明有上一次的读数。
    /// 那是比"看起来卡住"更糟的一种表现：像数据丢了。
    @Test func aBackgroundReconnectKeepsTheLiveDataOnScreen() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = makeRecord()
        try await ServerStore(directory: dir).upsert(record)
        let tokens = InMemoryTokenStore()
        try await tokens.setToken("tok", for: record.id)

        let model = AppModel(directory: dir, tokens: tokens,
                             makeTransport: { _ in FakeServerTransport() })
        model.selectedServerID = record.id
        model.retry()
        #expect(await waitUntil { model.hasLoadedData })

        model.enterBackground()
        await model.enterForeground()

        #expect(model.state(of: record.id) == .connecting, "回到前台确实会重连一次")
        #expect(model.loading == nil, "手上有数据时，重连不该用加载屏盖住它")
        // 收尾：掐掉在跑的那一场（它连的是一台不存在的服务端）。
        model.select("srv-nowhere")
    }

    /// 冷启动的整屏加载态：盖到第一次有结论为止。
    ///
    /// # 三条断言对应三种"永远转下去"的可能
    ///
    ///	刚读记录时盖着（否则第一帧是"还没有服务端"，而那是假话）
    ///	连的过程中盖着（否则 iPhone 上用户什么都看不到）
    ///	**失败之后必须撤掉** —— 这是最要命的一条：撤不掉的话，用户
    ///	永远等不到那个"重试"按钮，只能杀进程。
    @Test func theLaunchCoverCoversUntilTheFirstAnswer() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = makeRecord(addresses: (1...4).map { "10.0.0.\($0):8788" })
        try await ServerStore(directory: dir).upsert(record)
        let tokens = InMemoryTokenStore()
        try await tokens.setToken("tok", for: record.id)

        let model = AppModel(directory: dir, tokens: tokens,
                             makeTransport: { _ in UnreachableTransport() })
        #expect(model.launchCover != nil, "记录还没读出来时要盖住整个窗口")

        await model.enterForeground()
        #expect(model.launchCover?.serverID == record.id, "连接期间整个窗口都被盖住")

        let gone = await waitUntil { model.launchCover == nil }
        #expect(gone, "收到明确的失败之后整屏加载态必须撤掉")
        #expect(model.state(of: record.id) != .connecting)
    }

    /// 切服务器时，加载态跟着走，而且**不**盖住整个窗口。
    ///
    /// 两款界面的分工在这里定死：详情那一栏永远显示加载态；而整屏那一层
    /// 只在首屏出现过。用户在侧栏上点了另一台，侧栏必须留着 —— 一台连不
    /// 上的服务端如果连侧栏都被盖掉，他就既看不到别的服务端、也点不了
    /// 任何东西。
    @Test func switchingServersMovesTheLoadingWithoutCoveringTheSidebar() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = makeRecord(id: "srv-1", addresses: ["10.0.0.1:8788"])
        let second = makeRecord(id: "srv-2", addresses: ["10.0.0.2:8788"])
        try await ServerStore(directory: dir).upsert(first)
        try await ServerStore(directory: dir).upsert(second)
        let tokens = InMemoryTokenStore()
        try await tokens.setToken("tok", for: first.id)
        try await tokens.setToken("tok", for: second.id)

        // 第一台连不上、第二台永远挂着：这样"切过去"这件事本身是确定的。
        let model = AppModel(directory: dir, tokens: tokens,
                             makeTransport: { _ in UnreachableTransport() })
        await model.enterForeground()
        #expect(await waitUntil { model.launchCover == nil }, "第一台失败之后首屏露出来")

        model.select(second.id)
        #expect(model.loading?.serverID == second.id, "加载态必须跟着选中项走到新那一台")
        #expect(model.loading(for: first.id) == nil)
        #expect(model.launchCover == nil, "切服务器不该盖住侧栏")

        // 收尾：掐掉在跑的那一场。
        model.select("srv-nowhere")
    }

    /// 等一个条件成立（上限 3 秒）。
    ///
    /// 不用固定 `sleep`：机器快慢不同，固定值要么让整个测试变慢，要么在
    /// 慢机器上偶发失败 —— 而偶发失败的测试最后都会被人加长等待或者删掉。
    @MainActor
    private func waitUntil(_ condition: () -> Bool,
                           timeout: Duration = .seconds(3)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
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

    /// 服务端**关机**时，冷启动那三个触发点也必须只开一场竞速。
    ///
    /// # 上一条测试钉不住这一条，而真机上出事的正是这一条
    ///
    /// `coldLaunchStartsOneRaceNotThree` 用的是一台**挂住**的假服务端，
    /// 于是三次触发全都落在"已经有一条连接在跑"的窗口里 —— 靠"在跑就
    /// 复用"就能通过。而用户报的场景恰好相反：Phecda 没开，每条候选
    /// 地址被连接拒绝，**一场竞速几十毫秒就结束了**。后两声到达时上一场
    /// 已经跑完、`connectingServerID` 也被清掉了，于是各开一场新的。
    ///
    /// 去重因此不能是一个**时间**条件（"此刻有没有在跑"），必须是一个
    /// **意图**条件（"这一次前台会话里为这台连过了没有"）。
    @MainActor
    @Test func aFastFailingColdLaunchStillStartsOneRace() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let addresses = (1...8).map { "10.0.0.\($0):8788" }
        let record = makeRecord(addresses: addresses)
        try await ServerStore(directory: dir).upsert(record)
        let tokens = InMemoryTokenStore()
        try await tokens.setToken("tok", for: record.id)

        let started = ConnectionCounter()
        let model = AppModel(directory: dir, tokens: tokens, makeTransport: { _ in
            started.bump()
            return UnreachableTransport()
        })

        // 触发一：应用壳的 `.task`。等它**跑完** —— 这正是关键。
        // 服务端关机时它几十毫秒就结束了，而下面两声紧接着到达。
        await model.enterForeground()
        #expect(await waitForConnections(started, toReach: addresses.count),
                "第一声应当开一场竞速")
        try? await Task.sleep(for: .milliseconds(50))

        // 触发二、三：`scenePhase` 变 `.active`、列表页的 `.task`。
        await model.enterForeground()
        await model.loadServers()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(started.count == addresses.count,
                "一次冷启动只该有一场竞速（\(addresses.count) 条候选），实际发起了 \(started.count) 条")
    }

    /// 回到后台再回来是**新的一次**意图，必须重连。
    ///
    /// 与上一条是一对：去重做过头就会变成"从后台切回来不再刷新"，
    /// 而那时长轮询已经停了、快照也可能过期。少了这一条，上面那条修法
    /// 可以简单地通过"永远只连一次"来满足。
    @MainActor
    @Test func returningFromTheBackgroundStartsANewRace() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = makeRecord(addresses: ["10.0.0.1:8788"])
        try await ServerStore(directory: dir).upsert(record)
        let tokens = InMemoryTokenStore()
        try await tokens.setToken("tok", for: record.id)

        let started = ConnectionCounter()
        let model = AppModel(directory: dir, tokens: tokens, makeTransport: { _ in
            started.bump()
            return UnreachableTransport()
        })

        await model.enterForeground()
        #expect(await waitForConnections(started, toReach: 1), "第一次进前台要连")

        model.enterBackground()
        await model.enterForeground()
        #expect(await waitForConnections(started, toReach: 2),
                "回到前台必须再连一次（长轮询停了，快照可能过期）")
    }

    /// 下拉刷新是用户明确的"再试一次"，不能被去重吃掉。
    @MainActor
    @Test func pullToRefreshStillStartsANewRace() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = makeRecord(addresses: ["10.0.0.1:8788"])
        try await ServerStore(directory: dir).upsert(record)
        let tokens = InMemoryTokenStore()
        try await tokens.setToken("tok", for: record.id)

        let started = ConnectionCounter()
        let model = AppModel(directory: dir, tokens: tokens, makeTransport: { _ in
            started.bump()
            return UnreachableTransport()
        })

        await model.enterForeground()
        #expect(await waitForConnections(started, toReach: 1))

        await model.loadServers(reconnecting: true)
        #expect(await waitForConnections(started, toReach: 2),
                "下拉刷新的全部意义就是再试一次，它必须真的重开一场")
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

/// 一台永远连不上的服务端：每条候选地址都立刻失败。
///
/// 立刻失败是刻意的 —— 真实的 4 秒超时会让每条测试都慢一个数量级，
/// 而这里要断言的是**模型怎么处理这个结局**，不是等多久。
private actor UnreachableTransport: KernelTransport {
    func call(_ method: String, _ path: String, body: Data?) async throws -> KernelReply {
        throw KernelError(code: "unreachable", status: 0, message: "连不上")
    }

    func pollEvents(since: Int64, timeoutMilliseconds: Int) async throws -> EventBatch {
        EventBatch(events: [], next: since, gap: false)
    }
}

/// 一台会回答的假服务端。
///
/// # 为什么需要它
///
/// 上面那个"连不上"的桩能覆盖失败路径，而"连上之后界面显示什么"必须有
/// 一台会说话的机器才测得出来 —— 包括"数据一项一项到齐"这个只有
/// 多请求并发时才会出现的中间状态。
///
/// `staggerMilliseconds`：每个**后续**请求比上一个多等这么久。七个数据
/// 请求于是错开到齐，界面上那行"（3/7）"才有机会存在。默认 0 = 一起到齐。
private actor FakeServerTransport: KernelTransport {
    private let staggerMilliseconds: Int
    private var served = 0

    init(staggerMilliseconds: Int = 0) {
        self.staggerMilliseconds = staggerMilliseconds
    }

    func call(_ method: String, _ path: String, body: Data?) async throws -> KernelReply {
        let index = served
        served += 1
        if staggerMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(index * staggerMilliseconds))
        }
        return KernelReply(status: 200, body: try JSONValue.parse(Self.reply(for: path)))
    }

    /// 长轮询**挂住**而不是立刻返回空。
    ///
    /// 立刻返回空的话，`AppModel.startEventPolling` 会立刻再问一次 ——
    /// 那是一个把主 actor 占满的死循环（真实的 URLSession 请求天然不会
    /// 这样，因此这个坑只有假传输才踩得到）。
    func pollEvents(since: Int64, timeoutMilliseconds: Int) async throws -> EventBatch {
        try await Task.sleep(for: .seconds(60))
        return EventBatch(events: [], next: since, gap: false)
    }

    private static func reply(for path: String) -> String {
        switch true {
        case path.hasPrefix("/v1/remote/self"):
            #"{"role":"operator","device":{"id":"rfxkUCbz_mA62PLj","label":"iPhone","role":"operator","notifications_enabled":false,"os_version":"27.0","model":"iPhone18,1"},"server":{"name":"Mac-mini","version":"v0.2.0","api_version":"v2","spki_sha256":"TErcJ99SbmE1HNydX19qHAuNhRpsr5jH71UR2Zkw420","fingerprint_short":"4C4A-ECBE"}}"#
        case path.hasPrefix("/v1/ip/current"):
            "{}"
        case path.hasPrefix("/v1/proxy"):
            #"{"running":false,"port":0,"tls":false,"routes":0}"#
        case path.hasPrefix("/v1/metrics"):
            "{}"
        default:
            // 列表类接口的形状：`{"items": [...]}`。
            #"{"items":[]}"#
        }
    }
}

