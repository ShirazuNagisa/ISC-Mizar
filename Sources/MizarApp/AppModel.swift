import Foundation
import Observation
import MizarKit
import MizarUI

/// 应用的全部状态。
///
/// # 一台"当前服务器"而不是全部同时连
///
/// 用户可以保存几十台服务端，但一次只看一台。全部同时连上意味着几十条
/// 挂着 25 秒的长轮询与几十次 5 秒一次的指标请求 —— 电池先扛不住，
/// 而用户一次也只看得见一个屏幕。
///
/// 因此这里只维护**被选中的那一台**的数据；其余服务端只有在列表页上
/// 做一次轻量的状态探测（连上、拉到 `/v1/remote/self` 就走）。
///
/// # 数据字段为什么是"可选"而不是"上一次的值"
///
/// 切服务器时如果保留上一台的数据，界面会在新数据到达前显示**另一台机器**
/// 的指标 —— 那比空白危险得多（用户会以为新服务器 CPU 爆了）。
@MainActor
@Observable
public final class AppModel {

    // MARK: 服务端列表

    public private(set) var servers: [ServerRecord] = []
    /// 服务端列表是否已经读过一次（无论读出来是空的还是有内容）。
    ///
    /// 界面用它区分"还在读"与"确实一台都没有"：少了这个区分，冷启动的
    /// 第一帧会显示"还没有服务端，去扫码添加" —— 而用户明明有三台，
    /// 那句话会让人以为配置丢了。
    public private(set) var hasLoadedServers = false
    /// 每台服务端当前的连接状态。列表页据此画状态点。
    public private(set) var states: [String: SessionState] = [:]
    public var selectedServerID: String?

    // MARK: 当前服务器的数据

    public private(set) var metrics: MetricsSnapshot?
    public private(set) var apps: [AppRecord] = []
    public private(set) var advisories: [Advisory] = []
    public private(set) var ipStatus: IPStatus?
    public private(set) var certificates: [CertificateInfo] = []
    public private(set) var ddnsTasks: [DdnsTaskInfo] = []
    public private(set) var credentials: [CredentialInfo] = []
    public private(set) var proxyStatus: ProxyStatus?
    /// 服务端告诉我们的角色。**界面据它决定写控件可不可点** ——
    /// 而不是自己猜；真正的判定永远在服务端。
    public private(set) var role: String = "viewer"

    // MARK: 界面状态

    public var errorMessage: String?
    public var notice: String?
    public var isBusy = false
    /// 最近一次成功刷新数据的时间（下拉刷新时显示）。
    public private(set) var lastRefresh: Date?

    /// 当前这一次加载。
    ///
    /// # 为什么它是模型里的一份显式状态，而不是从 `states` 推出来的
    ///
    /// "该不该给用户看一个加载态"与"连接处于什么状态"不是同一个问题
    /// （见 `LoadingStatus` 的说明）。从 `states` 现推的话，每一个
    /// 调用点都要自己再判一次 `hasLoadedData`、再判一次是不是在途 ——
    /// 而漏掉任何一处的后果是**转圈停不下来**（界面永远停在加载屏上，
    /// 连重试按钮都出不来）。
    ///
    /// 因此这里的规则只有一条：**谁开始加载谁负责结束它**，
    /// 并且结束点与 `states` 落到终态的地方是同一处。
    public private(set) var loading: LoadingStatus?

    /// 这一次运行里，首屏有没有**露过面**。
    ///
    /// 它只回答一个问题：现在要不要把整个窗口盖住（`launchCover`）。
    /// 一旦有过一次"可以看了"，就不再盖 —— 那之后用户要的是侧栏
    /// （去换一台服务端、去重试），而不是又一块盖住一切的东西。
    private var hasRevealedInterface = false

    /// 最近一次竞速报上来的进度。失败时用它拼出"试了几条地址、用了多久"。
    private var lastAttempt: ConnectProgress?

    /// 这一次启动是什么时候开始的。
    ///
    /// 它给"正在打开 Mizar…"那一屏当秒表的起点。必须是一个**存下来的**
    /// 时间：每次求值都取 `Date()` 的话，那一行秒数会在每一帧重画时
    /// 归零，于是它显示出来的东西恰好与它要证明的相反。
    private let launchedAt = Date()

    /// 推送的注册与深链。
    ///
    /// 与模型放在一起而不是各视图各持一份：通知点开时驱动的正是这个模型，
    /// 而"待处理的目标"必须跨视图存活。
    public let push = PushCoordinator()

    /// 可达性自检的执行者。
    ///
    /// 默认用真实的网络连接；注入点存在的唯一理由是让这一层能被测试
    /// （真实验现在测试里要连网络，而这里要断言的是分支）。
    public let probe = ReachabilityProbe()

    private let pool: ServerPool
    private var metricsTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// 当前那一次"连接并拉全量"的后台任务。
    ///
    /// 它存在的理由只有一个：**用户切走时能把它掐掉**。切换服务器之后
    /// 上一次连接的结果已经没有意义了，而一次连接可能包含七八条候选
    /// 地址的探测 —— 不取消的话，切服务器就变成了"同时连两台"。
    private var connectTask: Task<Void, Never>?

    /// 正在跑的那一次连接属于哪台服务端（nil = 没有在跑）。
    ///
    /// # 它挡的是"一次开屏连三遍"
    ///
    /// 冷启动时 `startConnecting` 会被叫三次：应用壳的 `.task`、
    /// `scenePhase` 变成 `.active`、以及列表页的 `.task`。每一次都会
    /// `cancel()` 上一个再开一场**全新的候选地址竞速** —— 而一场竞速是
    /// 八到九条 TCP 连接，被取消的那一场也不会立刻收摊（它要等每条
    /// URLSession 请求自己注意到取消）。三场叠加起来就是真机日志里
    /// 那一串 `C2…C14`：一条谁也用不上的连接风暴。
    ///
    /// 有了这个标记，同一台服务端在**已经有一条连接在跑**时直接复用，
    /// 只有用户明确要求（"重试"按钮、切到另一台）才会掐掉重开。
    private var connectingServerID: String?

    /// 连接批次号。
    ///
    /// 用来回答"刚刚跑完的这一场还是不是当前那一场"：被取消的那一场
    /// 不能去改**新**那一场的状态（把 `.connecting` 抹成 `.idle` 会让
    /// 界面永远停在骨架屏上）。
    private var connectBatch = 0

    /// 会话轮换计数。
    ///
    /// 切服务器或重新连接时递增，让**在途的**刷新结果作废 —— 否则一次
    /// 慢请求会在切换之后把上一台机器的数据写进当前视图。
    private var generation = 0

    /// 构造。
    ///
    /// # 为什么令牌存储与传输工厂是参数
    ///
    /// 与 `AppModel.probe` 同样的理由：这一层有一半的行为是"什么时候**不**
    /// 去连"，而那种断言只有在能把网络动作换成假的、把令牌换成内存里那一份
    /// 之后才写得出来 —— 真 Keychain 要真账号，真网络要真服务端。
    /// 生产代码走的是两个默认值，与改动前逐字一致。
    public init(directory: URL? = nil,
                tokens: TokenStore = KeychainTokenStore(),
                makeTransport: @escaping TransportFactory = ServerSession.defaultTransport) {
        let root = directory ?? Self.defaultDirectory()
        self.pool = ServerPool(directory: root, tokens: tokens, makeTransport: makeTransport)
    }

    private static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ISC Mizar", isDirectory: true)
    }

    // MARK: - 服务端列表

    public func loadServers() async {
        await reloadRecords()
        if selectedServerID == nil { selectedServerID = servers.first?.id }

        // 先把选中的那一台接上（它在后台跑，这里不等），再去探测其余的。
        //
        // 顺序反过来是有代价的：主界面的数据会排在其他服务端的探测
        // 后面，而每一次探测都可能等满一次超时 —— 用户看得见的只有
        // 当前这一台，它必须先走。
        //
        // 一台都没有时走另一条路：没有可以加载的东西，首屏直接露出
        // 空状态（否则那块"正在打开 Mizar…"会一直盖着，而它永远等不到
        // 任何东西）。
        if let id = selectedServerID { startConnecting(id) } else { revealWithoutLoading() }

        // 列表页上每台服务端只做一次轻量探测，**不**拉全部数据 ——
        // 那会让打开列表变成一个几十次请求的动作。选中的那一台不走
        // 这里：它要的不只是状态点，还有页签里的数据（上面那一步）。
        for server in servers where server.id != selectedServerID && states[server.id] == nil {
            await probe(server.id)
        }
        await onServersChanged?()
    }

    /// 只读记录，不做任何网络动作。
    ///
    /// 与 `loadServers` 分开的理由是"谁在等它"：配对刚成功时弹窗要立刻
    /// 关掉，而状态点可以稍后再来 —— 让用户为了几个小球多等几秒是
    /// 没有道理的。
    private func reloadRecords() async {
        servers = await pool.records()
        hasLoadedServers = true
    }

    /// 轻量探测：连上、拿到角色、更新状态点。
    public func probe(_ id: String) async {
        do {
            let state = try await pool.connect(id: id)
            states[id] = state
            if state == .online, selectedServerID == id,
               let session = try? await pool.session(for: id) {
                role = await session.role
            }
        } catch let error as KernelError {
            states[id] = error.needsPairing
                ? SessionState.needsPairing(error.message)
                : SessionState.unreachable(error.message)
        } catch {
            states[id] = .unreachable(error.localizedDescription)
        }
    }

    public func state(of id: String) -> SessionState {
        states[id] ?? .idle
    }

    public var selectedServer: ServerRecord? {
        servers.first { $0.id == selectedServerID }
    }

    /// 选择一台服务端并开始拉它的数据。
    ///
    /// # 它为什么**不再** `await` 连接
    ///
    /// 一次连接最长要等一轮候选地址的超时（见 `ServerSession.connect`），
    /// 而调用它的是导航与推送深链 —— 让"点一下服务端"或"点开一条通知"
    /// 等一次网络往返，用户看到的就是"点了没反应"。
    ///
    /// 现在它只做三件同步的事：把选中项改掉、把状态标成"连接中"、
    /// 把加载态摆上（界面据此**当帧**画出转圈与第一句状态文字），
    /// 然后把连接交给后台任务。
    public func select(_ id: String) {
        let changed = selectedServerID != id
        if changed {
            // 在途的刷新结果必须作废：否则一次慢请求会在切换之后
            // 把上一台机器的数据写进当前视图（见 `generation`）。
            generation += 1
            selectedServerID = id
            // 清空上一台的数据：见类型头部关于"可选而不是保留上次值"的说明。
            clearServerData()
        }
        // 只有**换了一台**才掐掉在跑的那一次。
        //
        // `List(selection:)` 的 setter 会被系统调用多次（侧栏重新布局、
        // 键盘上下键、选中项被重新应用），而"重复选中同一台"本身不是
        // 一次新的意图 —— 每次重开一场竞速的话，光是列表页的绘制就能
        // 发出好几条连接。
        startConnecting(id, restart: changed)
    }

    /// 开始连接一台服务端，**不阻塞调用方**。
    ///
    /// - Parameters:
    ///   - force: 已经连上且数据在手时也重连（进前台、用户手动重试）。
    ///   - restart: 已经有一次连接在跑时**掐掉它重开**。只有用户明确的
    ///     要求（"重试"按钮、切到另一台）才为 true —— 冷启动那三次调用
    ///     不是三次意图，它们要的是同一件事。
    private func startConnecting(_ id: String, force: Bool = false, restart: Bool = false) {
        if !force, states[id] == .online, lastRefresh != nil { return }
        // 状态先落到"连接中"：界面据此**立刻**画转圈，
        // 而不是等连接结束才决定显示什么。
        states[id] = .connecting
        // 加载态在**同一处**摆上。它必须发生在下面那个"已经有一条在跑"
        // 的早返回之前：那种情况下这一台确实还在加载，界面要看的就是它。
        beginLoading(serverID: id, name: name(of: id), total: candidateCount(of: id))

        // 同一台服务端已经有一条连接在跑：复用它。
        if !restart, connectingServerID == id { return }

        // 一次只连一台：前一个连接还在跑时它已经过时了（用户切走了），
        // 让它继续只会多占一份网络与一份令牌探测。
        connectTask?.cancel()
        connectingServerID = id
        connectBatch += 1
        let batch = connectBatch
        connectTask = Task { [weak self] in
            await self?.connectAndRefresh(batch: batch)
            // 只有"跑完的这一场仍是当前那一场"才清标记：被取消的那一场
            // 跑完时不能把**新**那一场的标记抹掉，否则下一次进前台会
            // 以为没有连接在跑，再开一场。
            guard let self, self.connectBatch == batch else { return }
            self.connectingServerID = nil
        }
    }

    /// 这台服务端的候选地址有几条（并发竞速是**同时**发起全部）。
    ///
    /// 读的是记录而不是会话：会话要读一次 Keychain，而这句话在
    /// `select` 的同一帧里就要用上。数量算错只会让那一行文字偏一点，
    /// 而为此多一次 Keychain 读取是拿真的代价换一个装饰。
    private func candidateCount(of id: String) -> Int {
        servers.first { $0.id == id }?.candidates().count ?? 0
    }

    private func name(of id: String) -> String {
        servers.first { $0.id == id }?.name ?? tr2("服务端", "server")
    }

    /// 用户手动重试（"重试"按钮、下拉刷新）。
    ///
    /// `restart: true` —— 用户按下它就是因为刚才那一次没有给出他想要的
    /// 结果，复用一条已经在跑的连接会让这个按钮看起来没反应。
    public func retry() {
        guard let id = selectedServerID else { return }
        startConnecting(id, force: true, restart: true)
    }

    private func clearServerData() {
        metrics = nil
        apps = []
        advisories = []
        ipStatus = nil
        certificates = []
        ddnsTasks = []
        credentials = []
        proxyStatus = nil
        lastRefresh = nil
    }

    // MARK: - 配对

    /// 扫码配对。
    public func pair(payloadText: String, deviceName: String) async throws -> ServerRecord {
        let payload = try PairingPayload.parse(payloadText)
        let outcome = try await PairingService().pair(payload: payload, device: deviceInfo(deviceName))
        return try await adopt(outcome)
    }

    /// 从配对链接配对（`isc-remote://pair?d=...`）。
    ///
    /// 成功率不重要（用户可能点开一条过期的链接），因此失败只记在
    /// `errorMessage` 上，不抛错 —— 抛出去没人接，而用户什么都看不到。
    public func pairFromLink(_ link: String) async {
        do {
            _ = try await pair(payloadText: link, deviceName: "")
            notice = tr2("已连接到新的服务端。", "Connected to a new server.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 手输码探测（**不落库** —— 指纹要先给用户核对）。

    /// 用户核对过指纹之后落库。

    private func adopt(_ outcome: PairingService.Outcome) async throws -> ServerRecord {
        _ = try await pool.add(outcome)
        // 先选中，再读记录，**不**等连接。
        //
        // 配对弹窗要在这之后立刻关掉：用户要看到的是"配对成功了"，
        // 而数据由详情页的骨架自己填。原来这里等的是完整的一次连接
        // 加一次全量，于是扫完码之后会僵在"添加服务端"的转圈上。
        generation += 1
        selectedServerID = outcome.record.id
        clearServerData()
        await reloadRecords()
        if let id = selectedServerID { startConnecting(id) }
        return outcome.record
    }

    private func deviceInfo(_ name: String) -> PairingService.DeviceInfo {
        PairingService.DeviceInfo(
            // 版本随设备信息一起上报：契约出现不兼容时，Phecda 的设备列表里
            // "这台手机上的 Mizar 是哪个版本"是第一个要看的字段。
            name: name.isEmpty ? defaultDeviceName : name,
            platform: PlatformInfo.name,
            model: PlatformInfo.model,
            osVersion: PlatformInfo.systemVersion,
            // 用常量而不是 `Bundle.main`：这个模型在 `swift test` 与验收
            // 工具里也会被构造，而那两处都没有应用包 —— 读 Bundle 会安静地
            // 上报 null，Phecda 的设备列表里就是一片空白。
            appVersion: MizarVersion.reported)
    }

    private var defaultDeviceName: String { PlatformInfo.model }

    public func forget(_ id: String) {
        Task {
            _ = try? await pool.remove(id: id)
            if selectedServerID == id {
                selectedServerID = nil
                clearServerData()
                // 被移除的那一台如果正在加载，它的转圈要跟着停 ——
                // 否则界面会停在一块永远不会有结果的加载屏上，
                // 而用户刚刚才亲手把它删掉。
                finishLoading(serverID: id)
            }
            await loadServers()
        }
    }

    // MARK: - 刷新

    /// 连接当前服务端并拉一次全量。
    ///
    /// 它是**后台任务**的入口（见 `select` 与 `startConnecting`），
    /// 因此不假设调用方在等它，也不假设中途没有被取消。
    ///
    /// - Parameter batch: 发起它的那一场的批次号（见 `connectBatch`）。
    ///   它同时决定了两件事：跑完时要不要把状态落成终态，以及**要不要
    ///   清掉加载态** —— 被取消的那一场跑完时不能把用户刚切过去那一台的
    ///   转圈抹掉。
    public func connectAndRefresh(batch: Int = -1) async {
        // 进场时把批次号记下来：下面那个 `defer` 要判断"跑完的这一场
        // 还是不是当前那一场"（见 `connectBatch`）。
        let batch = batch < 0 ? connectBatch : batch
        // 这一次尝试的进度从零开始记：失败那句话里的"试了几条、等了多久"
        // 只能来自**这一场**，留着上一场的数字会让用户按着一个过期的
        // 结论去查网络。
        lastAttempt = nil

        // 冷启动时应用壳的 `.task` 与列表页的 `.task` 是并发跑的：
        // 读过记录不代表已经有人填过 `selectedServerID`。少了这一段，
        // 冷启动有一半的概率什么都不连 —— 界面上是四个空页签。
        if selectedServerID == nil {
            servers = await pool.records()
            hasLoadedServers = true
            selectedServerID = servers.first?.id
        }
        guard let id = selectedServerID else {
            // 一台服务端都没有：没有可以加载的东西，让首屏直接露出空状态。
            revealWithoutLoading()
            return
        }

        states[id] = .connecting
        // "连接中"不能是终态：被取消（用户切走了）时如果不落一个确定的
        // 状态，界面会永远停在加载屏上，连"重试"都出不来。
        //
        // 只在"自己仍是当前那一场"时落：被取消的那一场跑完时，新那一场
        // 可能已经开始了，而它刚把状态置成 `.connecting` —— 抹成 `.idle`
        // 会让加载屏卡在那里不动。
        defer {
            if connectBatch == batch {
                if states[id] == .connecting { states[id] = .idle }
                // 加载态与状态**在同一处**收尾。分开收的话，两个终态之间
                // 只要有一次没对齐，界面就会永远停在转圈上。
                finishLoading(serverID: id)
            }
        }

        do {
            let state = try await pool.connect(id: id) { [weak self] progress in
                self?.noteProgress(progress, serverID: id)
            }
            // 在途期间用户可能已经切到别的服务器：这一批结果属于上一台，
            // 写进去会让界面显示另一台机器的状态与数据。
            guard !Task.isCancelled, selectedServerID == id else { return }
            states[id] = enriched(state)
            guard state == .online else { return }
            if let session = try? await pool.session(for: id) {
                role = await session.role
                currentServerInfo = await session.info
                // 把服务端自述里的公网子域名记进本地记录。
                //
                // 二维码只带局域网地址（扫码时手机就在同一个网里），
                // 而公网那一条只有内核知道。不写下来的话，手机在外面
                // 永远只会去试局域网地址，然后全部超时。
                let plan = currentServerInfo?.public
                try? await pool.setPublicHost(plan?.host, port: plan?.port, for: id)
            }
            guard !Task.isCancelled, selectedServerID == id else { return }
            // 连上之后立刻换一句：用户从"在试地址"走到"在读数据"，
            // 这两件事的等待感受完全不同（前者不知道要多久，后者是确定的）。
            if let session = try? await pool.session(for: id),
               let address = await session.address {
                noteConnected(address: address, serverID: id)
            }
            await refreshAll()
            guard !Task.isCancelled, selectedServerID == id else { return }
            startMetricsPolling()
            startEventPolling()
            await onServersChanged?()
        } catch let error as KernelError {
            guard !Task.isCancelled, selectedServerID == id else { return }
            states[id] = error.needsPairing
                ? SessionState.needsPairing(error.message)
                : SessionState.unreachable(enriched(error.message))
        } catch {
            guard !Task.isCancelled, selectedServerID == id else { return }
            states[id] = SessionState.unreachable(enriched(error.localizedDescription))
        }
    }

    /// 把"试了几条地址、等了多久"拼进连不上的那句话里。
    ///
    /// # 为什么这句话值得存在
    ///
    /// 用户分不清"应用卡了"与"网络慢"，而这两件事的**证据**其实一直在
    /// 手上：刚刚有几条候选地址、每条等了多久，客户端全都知道。把它写
    /// 出来，那句"连不上"就从"没反应"变成了"它试了 8 条、用了 4 秒，
    /// 都不是" —— 前者让人怀疑应用，后者让人去查网络。
    ///
    /// 只用一条地址时不加这句：那时没有任何"试了很多次"的信息，
    /// 而多出来的数字只会让文案变长。
    private func enriched(_ state: SessionState) -> SessionState {
        guard case .unreachable(let detail) = state else { return state }
        return .unreachable(enriched(detail))
    }

    private func enriched(_ detail: String) -> String {
        guard let attempt = lastAttempt, attempt.total > 1 else { return detail }
        let seconds = max(1, Int(attempt.elapsed.rounded(.up)))
        return tr2("已经试过 \(attempt.total) 条地址、等了 \(seconds) 秒，都没有回应 —— ",
                   "Tried \(attempt.total) addresses over \(seconds) s, none answered — ") + detail
    }

    /// 拉取全部数据。
    ///
    /// 每一项**单独容错**：某一项失败不该让其余部分也空掉 —— 用户看到的
    /// 应该是"证书这块有问题"，而不是整个界面什么都没有。
    public func refreshAll() async {
        guard let id = selectedServerID else { return }
        let currentGeneration = generation

        // 会话是 actor，取一次就够；下面每一项都用同一个客户端。
        guard let session = try? await pool.session(for: id),
              let kernel = try? await session.kernel() else { return }

        // 七个请求完成了几个 —— 界面那一行"正在读取数据（3/7）"就是它。
        // 计数跨子任务共享，因此放一个 actor 里：一个普通的 `var` 会被
        // 并发写，而这不是"大概率没事"的那类问题。
        let counter = FetchCounter(total: 7, serverID: id)

        async let appsTask: [AppRecord]? = attempt(counter) { try await kernel.apps() }
        async let advisoriesTask: [Advisory]? = attempt(counter) { try await kernel.advisories() }
        async let ipTask: IPStatus? = attempt(counter) { try await kernel.currentIP() }
        async let certsTask: [CertificateInfo]? = attempt(counter) { try await kernel.certificates() }
        async let ddnsTask: [DdnsTaskInfo]? = attempt(counter) { try await kernel.ddnsTasks() }
        async let credentialsTask: [CredentialInfo]? = attempt(counter) { try await kernel.credentials() }
        async let proxyTask: ProxyStatus? = attempt(counter) { try await kernel.proxyStatus() }

        let results = await (appsTask, advisoriesTask, ipTask, certsTask, ddnsTask, credentialsTask, proxyTask)

        // 在途期间用户可能已经切到别的服务器 —— 那时这一批结果属于上一台，
        // 写进去会让界面显示另一台机器的数据。
        guard currentGeneration == generation, selectedServerID == id else { return }

        if let value = results.0 { apps = value }
        if let value = results.1 { advisories = value }
        if let value = results.2 { ipStatus = value }
        if let value = results.3 { certificates = value }
        if let value = results.4 { ddnsTasks = value }
        if let value = results.5 { credentials = value }
        if let value = results.6 { proxyStatus = value }
        lastRefresh = Date()
        // 数据到手，加载态就在**这一刻**结束 —— 而不是等 `connectAndRefresh`
        // 的收尾（那还要跑一次手表同步）。界面从转圈切到内容的时机，
        // 应该与"内容真的到了"是同一帧。
        finishLoading(serverID: id)
    }

    /// 当前这台服务端的数据是否已经拿到过至少一次。
    ///
    /// # 界面为什么要问这个
    ///
    /// 数据字段为空有两种完全不同的含义：**还没有拉到**（要画占位骨架）
    /// 与**确实没有内容**（"还没有站点"）。少了这个区分，连接中的那几秒
    /// 界面上写的是"还没有站点" —— 一句让人以为配置丢了的话。
    public var hasLoadedData: Bool { lastRefresh != nil }

    // MARK: - 加载态

    /// 整个窗口要不要被加载态盖住。
    ///
    /// # 为什么冷启动要盖住**整个**窗口，而切服务器不盖
    ///
    /// 冷启动时侧栏还是空的（记录刚读出来），两边都没有可看的东西，
    /// 而用户上一眼看到的是启动屏 —— 整屏盖住是连续的一步。更实际的是：
    /// iPhone 上 `NavigationSplitView` 冷启动显示的是**列表**那一侧，
    /// 只盖详情页的话，用户在最需要"它在动"的那几秒里什么都看不到。
    ///
    /// 切服务器不盖，因为那一刻用户的手正放在侧栏上（他刚点完）。
    /// 把侧栏也盖掉，他一台连不上就既看不到别的服务端、也点不了重试 ——
    /// 那才是真的"卡住了"。详情页那一侧照常显示加载态（`loading(for:)`）。
    public var launchCover: LoadingStatus? {
        // 记录还没读出来：此刻侧栏是空的、右侧也没有内容，先盖住。
        guard hasLoadedServers else { return .openingRecords(at: launchedAt) }
        guard let loading, !hasRevealedInterface else { return nil }
        return loading
    }

    /// 某台服务端是不是正在加载（详情页据此决定画加载态还是画页签）。
    public func loading(for serverID: String) -> LoadingStatus? {
        guard let loading, loading.serverID == serverID else { return nil }
        return loading
    }

    /// 开始一次加载。
    ///
    /// **手上已经有数据时不进加载态**：`enterForeground` 每次都会重连一次
    /// （长轮询停了，快照可能过期），而那不该把已经画好的读数换成一块
    /// 加载屏 —— 用户从后台切回来看到的是同一屏数字在刷新，而不是倒退。
    private func beginLoading(serverID: String, name: String, total: Int) {
        guard !hasLoadedData else { return }
        // 同一台服务端已经在加载时**不重开秒表**：`select` 会被系统调用
        // 多次（侧栏重排、键盘上下键），每次都从 0 开始的话，秒表会在
        // 一个连接里来回跳。
        if loading?.serverID == serverID { return }
        loading = .connecting(serverID: serverID, name: name, total: total)
    }

    /// 一次竞速的进度。见 `ServerSession.connect(progress:)`。
    private func noteProgress(_ progress: ConnectProgress, serverID: String) {
        lastAttempt = progress
        guard loading?.serverID == serverID else { return }
        loading?.racing(progress)
    }

    /// 已经连上了某个地址，接下来在拉数据。
    private func noteConnected(address: String, serverID: String) {
        guard loading?.serverID == serverID else { return }
        loading?.connected(address: address)
    }

    /// 结束一次加载。
    ///
    /// - Parameter serverID: 只结束这一台的加载。传别的服务端 id 时什么
    ///   都不做 —— 被取消的那一次连接**不能**把用户刚切过去那一台的
    ///   加载态抹掉（那会让界面永远停在上一台的旧界面上）。
    private func finishLoading(serverID: String? = nil) {
        if let loading, serverID == nil || loading.serverID == serverID {
            self.loading = nil
        }
        if loading == nil { hasRevealedInterface = true }
    }

    /// 没有东西可加载（一台服务端都没有）时，让首屏直接露面。
    private func revealWithoutLoading() {
        guard loading == nil else { return }
        hasRevealedInterface = true
    }

    public func refreshMetrics() async {
        guard let id = selectedServerID,
              let session = try? await pool.session(for: id),
              let kernel = try? await session.kernel() else { return }
        if let snapshot = try? await kernel.metrics() {
            metrics = snapshot
        }
    }

    /// 手机侧：准备一份可以交给手表的同步载荷。
    ///
    /// 每台服务端都会**派生一台独立的只读设备**（而不是把手机的令牌
    /// 复制一份）—— 那条约束在服务端成立，因此手表即使被改也写不了。
    ///
    /// 返回 nil 表示没有任何一台可以同步（例如全都还没连上过）。
    public func prepareWatchSync() async -> WatchSyncPayload? {
        var synced: [SyncedServer] = []
        for server in servers {
            // 只同步**已经连上过**的：派生需要用到该服务端的会话，
            // 而一台从没连上的服务端本来也没法给手表用。
            guard let access = try? await pool.watchAccess(for: server.id, device: watchDeviceInfo) else {
                continue
            }
            synced.append(access)
        }
        guard !synced.isEmpty else { return nil }
        return WatchSyncPayload(servers: synced)
    }

    /// 手表侧：应用从手机同步过来的配置。
    @discardableResult
    public func applyWatchSync(_ payload: WatchSyncPayload) async -> Int {
        var applied = 0
        for synced in payload.servers {
            if (try? await pool.applySynced(synced)) != nil { applied += 1 }
        }
        await loadServers()
        return applied
    }

    /// 手表在服务端上的自述信息。
    private var watchDeviceInfo: PairingService.DeviceInfo {
        PairingService.DeviceInfo(name: "Apple Watch", platform: "watchos",
                                  osVersion: PlatformInfo.systemVersion,
                                  appVersion: MizarVersion.reported)
    }

    /// 最近一次可达性自检的结论。
    ///
    /// 它同时被送到内核（由内核决定要不要写 A 记录），因此这里留着
    /// 是为了**界面能显示**——"我到底测过没有"是用户最容易搞混的一件事。
    public private(set) var reachability: PublicCheckReport?

    /// 正在探测中。
    public private(set) var probing = false

    /// 跑一次可达性自检，并把结果报给内核。
    ///
    /// # 为什么这件事只能由手机做
    ///
    /// 内核测不了自己的入站可达性：本机发起的连接走的是内部路径
    /// （同网段二层、跨网段 NAT 环回），与真实客户端的路径不同。
    /// 而手机就在真实客户端要走的网络上。
    ///
    /// # 假阳性
    ///
    /// 手机在自己家里的 Wi-Fi 上时，连公网地址**也会成功** ——
    /// 那个连接根本没出局域网。`ReachabilityProbe` 会先试局域网地址，
    /// 通了就报 `sameLan`，内核据此记成 unknown 而不是 reachable。
    @discardableResult
    public func checkReachability() async -> PublicCheckReport? {
        guard let plan = currentServerInfo?.public, plan.hasTargets else {
            errorMessage = tr2("这台服务端还没有可探测的公网地址。请先在 Phecda 上开启公网访问并同步一次。",
                               "This server has no public address to probe yet. Enable public access in Phecda and sync once.")
            return nil
        }
        probing = true
        defer { probing = false }

        let report = await probe.run(plan: plan)
        reachability = report

        // 报给内核。报失败不阻断界面显示 —— 结论本身对用户仍然有用，
        // 而"报不上去"只影响内核要不要写 A 记录。
        if let kernel = try? await currentKernel() {
            _ = try? await kernel.reportPublicCheck(report)
        }
        return report
    }

    /// 服务端列表或连接状态变化之后的回调。
    ///
    /// 由应用壳接到"把配置同步给手表"上。放在这里而不是让壳自己去观察
    /// 模型：同步的时机是"配置变了"，而只有模型知道那件事什么时候发生。
    public var onServersChanged: (@MainActor () async -> Void)?

    /// 服务端在最近一次 `remoteSelf` 里的自述。
    ///
    /// 界面用它回答"这台服务端支持什么" —— 例如有没有配推送。
    /// 依据来自**服务端**，而不是客户端自己记的一个开关。
    public private(set) var currentServerInfo: RemoteSelfInfo?

    /// 当前服务端的客户端。
    ///
    /// 视图用它做**纯读取**的操作（例如看日志），而那些操作不该走
    /// `execute` —— 那条路径会把整个界面切成忙碌态，可它并不改任何东西。
    ///
    /// 写操作仍然走 `execute`：它统一处理错误、刷新与 401 的改判。
    public func currentKernel() async throws -> KernelClient {
        guard let id = selectedServerID else {
            throw KernelError(code: "not_found", message: tr2("没有选中任何服务端。", "No server is selected."))
        }
        let session = try await pool.session(for: id)
        return try await session.kernel()
    }

    /// 执行一个会改动服务端状态的操作。
    public func execute(_ operation: @escaping () async throws -> Void) {
        Task {
            isBusy = true
            do {
                try await operation()
                await refreshAll()
            } catch let error as KernelError {
                // 401 必须把整台服务器改判成"需要重新配对"：否则界面会
                // 继续显示"已连接"，而用户反复点一个必然失败的按钮。
                if error.needsPairing {
                    states[selectedServerID ?? ""] = .needsPairing(error.message)
                    await markCurrentUnauthorized(error.message)
                }
                errorMessage = error.message
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func markCurrentUnauthorized(_ detail: String) async {
        guard let id = selectedServerID, let session = try? await pool.session(for: id) else { return }
        await session.markUnauthorized(detail)
        // 服务端拒绝了这份令牌：缓存里那一份不能再用了。下一次连接必须
        // 重新读 Keychain —— 用户可能刚在别处重新配对过，而继续用旧的
        // 只会重连出同一个 401。
        await pool.forgetToken(id: id)
        stopPolling()
    }

    // MARK: - 轮询

    private func startMetricsPolling() {
        metricsTask?.cancel()
        metricsTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshMetrics()
                // 5 秒：与内核的采样间隔一致。比它更快只会拿到同一个样本，
                // 而更慢会让"站点刚挂掉"在界面上延迟可见。
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// 事件长轮询。
    ///
    /// 用长轮询而不是 WebSocket：进程被系统挂起、在 WiFi 与蜂窝之间切换
    /// 之后，长轮询只需要重新发一个请求，而 WebSocket 要重建握手并重新
    /// 对齐游标（还要处理断线期间到达的事件）。
    private func startEventPolling() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let id = self.selectedServerID,
                      let session = try? await self.pool.session(for: id) else {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                do {
                    let batch = try await session.pollEvents()
                    if Task.isCancelled { return }
                    // 有事件、或者游标跌出了内核的环形缓冲 —— 两种都意味着
                    // 界面上的状态可能已经过期，重新拉一次全量。
                    //
                    // `gap` 时**不试图补齐**：事件描述的是"发生了什么变化"，
                    // 而客户端要的是"现在是什么样"。
                    if !batch.events.isEmpty || batch.gap {
                        await self.refreshAll()
                    }
                } catch let error as KernelError {
                    guard !Task.isCancelled else { return }
                    if error.needsPairing {
                        self.states[id] = .needsPairing(error.message)
                        // 长轮询先于重连发现令牌失效 —— 同样要把缓存里
                        // 那一份丢掉，否则重连会拿它再撞一次 401。
                        await self.pool.forgetToken(id: id)
                        return
                    }
                    // 网络抖动不是错误：等一会儿再来。用户不需要知道
                    // 每一条断掉的长轮询。
                    try? await Task.sleep(for: .seconds(3))
                } catch {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    public func stopPolling() {
        metricsTask?.cancel()
        eventTask?.cancel()
        metricsTask = nil
        eventTask = nil
    }

    /// 进入后台：让长轮询停下来。
    ///
    /// 不停的话系统会在挂起时把它们静默掐断，而恢复时我们手上会留着一堆
    /// 半死的连接 —— 那比"明确地停掉再重连"更难排查。
    public func enterBackground() {
        stopPolling()
    }

    /// 回到前台。
    ///
    /// 它**不**等连接完成：`scenePhase` 回到 active 时界面要立刻可用，
    /// 而连接最长要等一轮候选地址的超时。数据到了由 `states` 与各个
    /// 数据字段自己通知界面。
    ///
    /// `force`：从后台回来时必须重新连一次（长轮询已经停了，手上的
    /// 快照也可能已经过期），因此这里刻意不走"已经连上就跳过"的捷径。
    ///
    /// # 为什么**不**是 `restart`
    ///
    /// 冷启动时它会被叫两次：应用壳的 `.task` 一次，`scenePhase` 变成
    /// `.active` 一次（`.task` 跑起来的时候那一次还没到）。两次都掐掉
    /// 重开的话，第一场竞速刚发出去的八条连接会被丢掉重发一遍 ——
    /// 而两次要的是同一件事，没有理由为它付两遍代价。
    /// 真正需要"掐掉重来"的是用户按下重试，见 `retry()`。
    public func enterForeground() async {
        if servers.isEmpty {
            servers = await pool.records()
            hasLoadedServers = true
        }
        if selectedServerID == nil { selectedServerID = servers.first?.id }
        if let id = selectedServerID {
            startConnecting(id, force: true)
        } else {
            // 一台服务端都没有：见 `loadServers` 里的同一句。
            revealWithoutLoading()
        }
    }

    // MARK: - 小工具

    /// 把一次可能失败的数据拉取变成可选值。
    private func attempt<T>(_ work: () async throws -> T) async -> T? {
        do { return try await work() } catch { return nil }
    }

    /// 同上，但每完成一项就报一次进度（界面那行"（3/7）"）。
    ///
    /// 成功与失败**都算完成**：这两件事对"还要等多久"是同一件事，
    /// 而失败的那几项本来就是靠 `attempt` 单独容错的。
    private func attempt<T>(_ counter: FetchCounter, _ work: () async throws -> T) async -> T? {
        let value = try? await work()
        let step = await counter.advance()
        // 切走之后这一批属于上一台，进度不能再写进新那一台的加载态。
        if step.serverID == selectedServerID, loading?.serverID == step.serverID {
            loading?.fetching(done: step.done, of: step.total)
        }
        return value
    }

    public var canWrite: Bool { role == "operator" }
}

/// 模型层的取词。视图用 `MizarUI` 里的 `tr`，而模型层也要用同一套。
func tr2(_ zh: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
}

/// 一次全量刷新里已经完成了几个请求。
///
/// # 为什么必须是 actor
///
/// 它被七个并发的 `async let` 同时写。用一个 `var` 加注释说"其实不会
/// 真的并发"是不成立的：这正是 Swift 6 要拦下的那类事，而且它出错时
/// 表现出来只是界面上的数字偶尔跳一下 —— 没有人会为此去查。
private actor FetchCounter {
    private let total: Int
    private let serverID: String
    private var done = 0

    init(total: Int, serverID: String) {
        self.total = total
        self.serverID = serverID
    }

    func advance() -> (done: Int, total: Int, serverID: String) {
        done += 1
        return (done, total, serverID)
    }
}

/// 设备自述信息。
///
/// 放在这里而不是 MizarKit：`UIDevice` 属于 UIKit，而 MizarKit 要能在
/// macOS 上 `swift test`（见 Package.swift 的说明）。
enum PlatformInfo {
    static var name: String {
        #if os(iOS)
        "ios"
        #elseif os(watchOS)
        "watchos"
        #else
        "macos"
        #endif
    }

    static var model: String {
        #if canImport(UIKit)
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier.isEmpty ? "Apple 设备" : identifier
        #else
        return "Mac"
        #endif
    }

    static var systemVersion: String {
        #if canImport(UIKit)
        ProcessInfo.processInfo.operatingSystemVersionString
        #else
        ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}
