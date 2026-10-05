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

    /// 会话轮换计数。
    ///
    /// 切服务器或重新连接时递增，让**在途的**刷新结果作废 —— 否则一次
    /// 慢请求会在切换之后把上一台机器的数据写进当前视图。
    private var generation = 0

    public init(directory: URL? = nil) {
        let root = directory ?? Self.defaultDirectory()
        self.pool = ServerPool(directory: root)
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
        if let id = selectedServerID { startConnecting(id) }

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
    /// 现在它只做两件同步的事：把选中项改掉、把状态标成"连接中"
    /// （界面据此**立刻**画出骨架），然后把连接交给后台任务。
    public func select(_ id: String) {
        if selectedServerID != id {
            // 在途的刷新结果必须作废：否则一次慢请求会在切换之后
            // 把上一台机器的数据写进当前视图（见 `generation`）。
            generation += 1
            selectedServerID = id
            // 清空上一台的数据：见类型头部关于"可选而不是保留上次值"的说明。
            clearServerData()
        }
        startConnecting(id)
    }

    /// 开始连接一台服务端，**不阻塞调用方**。
    ///
    /// `force` 为 false 时，已经连上且数据在手就不重复连：列表页每次
    /// 刷新、详情页每次重新出现都会走到这里，而每一次重连都是七八条
    /// 候选地址的探测。
    private func startConnecting(_ id: String, force: Bool = false) {
        if !force, states[id] == .online, lastRefresh != nil { return }
        // 状态先落到"连接中"：界面据此**立刻**画骨架，
        // 而不是等连接结束才决定显示什么。
        states[id] = .connecting
        // 一次只连一台：前一个连接还在跑时它已经过时了（用户切走了），
        // 让它继续只会多占一份网络与一份令牌探测。
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            await self?.connectAndRefresh()
        }
    }

    /// 用户手动重试（"重试"按钮、下拉刷新）。
    public func retry() {
        guard let id = selectedServerID else { return }
        startConnecting(id, force: true)
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
            }
            await loadServers()
        }
    }

    // MARK: - 刷新

    /// 连接当前服务端并拉一次全量。
    ///
    /// 它是**后台任务**的入口（见 `select` 与 `startConnecting`），
    /// 因此不假设调用方在等它，也不假设中途没有被取消。
    public func connectAndRefresh() async {
        // 冷启动时应用壳的 `.task` 与列表页的 `.task` 是并发跑的：
        // 读过记录不代表已经有人填过 `selectedServerID`。少了这一段，
        // 冷启动有一半的概率什么都不连 —— 界面上是四个空页签。
        if selectedServerID == nil {
            servers = await pool.records()
            hasLoadedServers = true
            selectedServerID = servers.first?.id
        }
        guard let id = selectedServerID else { return }

        states[id] = .connecting
        // "连接中"不能是终态：被取消（用户切走了）时如果不落一个确定的
        // 状态，界面会永远停在骨架屏上，连"重试"都出不来。
        defer { if states[id] == .connecting { states[id] = .idle } }

        do {
            let state = try await pool.connect(id: id)
            // 在途期间用户可能已经切到别的服务器：这一批结果属于上一台，
            // 写进去会让界面显示另一台机器的状态与数据。
            guard !Task.isCancelled, selectedServerID == id else { return }
            states[id] = state
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
            await refreshAll()
            guard !Task.isCancelled, selectedServerID == id else { return }
            startMetricsPolling()
            startEventPolling()
            await onServersChanged?()
        } catch let error as KernelError {
            guard !Task.isCancelled, selectedServerID == id else { return }
            states[id] = error.needsPairing
                ? SessionState.needsPairing(error.message)
                : SessionState.unreachable(error.message)
        } catch {
            guard !Task.isCancelled, selectedServerID == id else { return }
            states[id] = SessionState.unreachable(error.localizedDescription)
        }
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

        async let appsTask: [AppRecord]? = attempt { try await kernel.apps() }
        async let advisoriesTask: [Advisory]? = attempt { try await kernel.advisories() }
        async let ipTask: IPStatus? = attempt { try await kernel.currentIP() }
        async let certsTask: [CertificateInfo]? = attempt { try await kernel.certificates() }
        async let ddnsTask: [DdnsTaskInfo]? = attempt { try await kernel.ddnsTasks() }
        async let credentialsTask: [CredentialInfo]? = attempt { try await kernel.credentials() }
        async let proxyTask: ProxyStatus? = attempt { try await kernel.proxyStatus() }

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
    }

    /// 当前这台服务端的数据是否已经拿到过至少一次。
    ///
    /// # 界面为什么要问这个
    ///
    /// 数据字段为空有两种完全不同的含义：**还没有拉到**（要画占位骨架）
    /// 与**确实没有内容**（"还没有站点"）。少了这个区分，连接中的那几秒
    /// 界面上写的是"还没有站点" —— 一句让人以为配置丢了的话。
    public var hasLoadedData: Bool { lastRefresh != nil }

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
    public func enterForeground() async {
        if servers.isEmpty {
            servers = await pool.records()
            hasLoadedServers = true
        }
        if selectedServerID == nil { selectedServerID = servers.first?.id }
        if let id = selectedServerID { startConnecting(id, force: true) }
    }

    // MARK: - 小工具

    /// 把一次可能失败的数据拉取变成可选值。
    private func attempt<T>(_ work: () async throws -> T) async -> T? {
        do { return try await work() } catch { return nil }
    }

    public var canWrite: Bool { role == "operator" }
}

/// 模型层的取词。视图用 `MizarUI` 里的 `tr`，而模型层也要用同一套。
func tr2(_ zh: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
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
