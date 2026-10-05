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

/// 一场候选地址竞速的进度快照。
///
/// # 为什么是"已完成几条"而不是"正在试第几条"
///
/// 候选地址是**同时**发起的（见 `ServerSession.connect`），因此
/// "正在试第 3 条"是一句假话 —— 八条都在路上。真实且在变的是
/// "已经有几条没有回应"，而用户真正需要从这句话里读到的也只是
/// "它在动，不是死了"。
public struct ConnectProgress: Sendable, Equatable {
    /// 这一轮同时发起了几条候选地址。
    public let total: Int
    /// 其中已经**有结论（失败）**的条数。
    public let finished: Int
    /// 从发起那一刻到现在的秒数。
    public let elapsed: TimeInterval

    public init(total: Int, finished: Int, elapsed: TimeInterval) {
        self.total = total
        self.finished = finished
        self.elapsed = elapsed
    }
}

/// 进度回调。
///
/// 类型上钉住 `@MainActor`：它唯一的用途就是改界面状态，而如果放开成
/// 任意隔离域，调用方就得自己开一个 `Task` 跳回主 actor —— 那样每次
/// 回调的**顺序**不再有保证，界面上的数字会来回跳。
public typealias ConnectProgressHandler = @MainActor @Sendable (ConnectProgress) -> Void

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
    /// 候选地址探测的单次超时。
    ///
    /// 4 秒的依据：局域网内的连接要么在几十毫秒内成功，要么就是不在
    /// 这个网里。而一次连接可能有七八个地址 —— 它们现在是**同时**发起、
    /// 取最快的那一条（见 `connect`），因此这个值不再是"乘以地址数"
    /// 而是整场竞速的上限：最坏情况下用户最多等 4 秒多一点。
    static let probeTimeout: TimeInterval = 4

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

    public static let defaultTransport: TransportFactory = { spec in
        HTTPTransport(configuration: .init(baseURL: spec.baseURL, token: spec.token,
                                           trust: spec.trust, pinnedSPKI: spec.pinnedSPKI,
                                           language: spec.language, timeout: spec.timeout))
    }

    /// 服务端记录的当前快照。
    public func snapshot() -> ServerRecord { record }

    /// 用最新的记录替换会话里那一份（候选地址变了之后：内核报出了
    /// 公网子域名）。
    ///
    /// # 为什么是"换记录"而不是"重建会话"
    ///
    /// 重建会把**已经连上的那条链路**一起丢掉，而调用它的时刻恰好是
    /// "刚连上、正要去拉数据" —— 界面于是停在一个没有客户端的空会话上，
    /// 表现是"配对成功了，但主页永远什么都没有"。
    ///
    /// 这里要更新的其实只有"下次重连时先试哪几条地址"，当前的连接与
    /// 候选列表无关。
    public func updateRecord(_ newRecord: ServerRecord) {
        record = newRecord
    }

    /// 连接（或重连）。
    ///
    /// 返回最终状态，调用方不必再去读一次属性。
    ///
    /// - Parameter progress: 每有一条候选地址**有了结论**就回调一次。
    ///   它存在的理由是把"正在连"与"卡住了"在界面上分开：一场竞速最坏
    ///   要等满一次超时，而这段时间里界面如果只有一圈转动的菊花，
    ///   用户看到的和死机没有区别。回调让界面能显示"8 条里有 3 条
    ///   已经没回应了"，那是一个**在变**的数字。
    ///
    /// # 候选地址是**并行竞速**，不是逐个试
    ///
    /// 一台服务端通常有六到八条候选地址（IPv4、好几条全局 IPv6、ULA、
    /// `<hostname>.local`，再加一条公网域名）。逐个试的耗时是
    /// "候选数 × 单次超时"：离家在外时前七条全部等满 4 秒（28 秒），
    /// 而唯一能通的那条公网域名排在最后 —— 用户盯着一个"连接中"的
    /// 界面等半分钟，然后才看到数据。全部同时发起之后，总耗时约等于
    /// **最快那条**的耗时，也就是一次往返。
    ///
    /// 语义上有两处必须保留：
    ///
    ///   - **第一个成功者胜出**，其余立刻取消（不再花掉用户的时间）。
    ///   - **401 立刻中止整场竞速**。它意味着我们够到了内核，只是它不认
    ///     这个令牌 —— 换地址不会有不同的结果，继续等只是让用户多等
    ///     几秒；而它对应的下一步动作是"重新配对"，不是"检查网络"。
    @discardableResult
    public func connect(language: String = "zh-CN",
                        progress: ConnectProgressHandler? = nil) async -> SessionState {
        state = .connecting

        let targets = probeTargets(language: language)
        // 工厂在发任务**之前**读出来：子任务碰不到 actor 的属性，
        // 而 `TransportFactory` 本身是 Sendable 的，可以安全地带进去。
        let factory = makeTransport
        let startedAt = Date()

        var failures: [KernelError] = []
        var winner: (target: ProbeTarget, info: RemoteSelfInfo, client: KernelClient)?

        // 发起之前先报一次：界面据此**当帧**就能写出"正在同时试 8 条地址"，
        // 而不是先转半秒没有任何文字的圈。
        await progress?(ConnectProgress(total: targets.count, finished: 0,
                                        elapsed: Date().timeIntervalSince(startedAt)))

        await withTaskGroup(of: ProbeOutcome.self) { group in
            for target in targets {
                group.addTask { await Self.probe(target, using: factory) }
            }

            // 按完成的先后取结果，因此"最快的那个地址"决定结局。
            while let outcome = await group.next() {
                switch outcome {
                case .ok(let target, let info, let client):
                    winner = (target, info, client)
                    // 取消其余探测：它们的超时预算是 4 秒一条，
                    // 而我们已经不需要答案了。
                    group.cancelAll()
                    return
                case .unauthorized(let error):
                    failures.append(error)
                    group.cancelAll()
                    return
                case .failed(let error):
                    failures.append(error)
                    // 一条候选刚刚有了结论（失败）。**只有失败才报**：
                    // 成功与 401 都会立刻结束整场竞速，那时界面要走的是
                    // 另外两条路（显示数据 / 显示"需要重新配对"），
                    // 再报一次进度只会让最后一帧文字闪一下。
                    await progress?(ConnectProgress(total: targets.count,
                                                    finished: failures.count,
                                                    elapsed: Date().timeIntervalSince(startedAt)))
                }
            }
        }

        if let winner {
            // 连上之后把传输换成正常超时的：探测那条预算（4 秒）
            // 对指标、长轮询、启动站点这些真实请求都太短。
            client = winner.client
            info = winner.info
            role = winner.info.role
            address = Self.hostPort(winner.target.baseURL)
            state = .online
            return state
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

    /// 一条候选地址的探测计划。
    ///
    /// 两条 `TransportSpec` 一起算好（探测用短超时、连上之后用正常超时），
    /// 因为子任务里碰不到会话的状态：令牌、指纹、语言都必须在
    /// **发任务之前**就固定下来。
    private struct ProbeTarget: Sendable {
        let baseURL: URL
        let probeSpec: TransportSpec
        let liveSpec: TransportSpec
    }

    /// 一次探测的结局。
    private enum ProbeOutcome: Sendable {
        case ok(ProbeTarget, RemoteSelfInfo, KernelClient)
        /// 够到了内核但令牌不被接受 —— 与"连不上"是两件不同的事。
        case unauthorized(KernelError)
        case failed(KernelError)
    }

    /// 按"上次成功的优先，其余保持内核给的顺序"排出探测计划。
    ///
    /// 顺序在竞速里仍然有用：它决定子任务**发起的先后**，因此上次连通的
    /// 那条会最先出发。但它不再是串行的依据 —— 后面的地址同时也在试。
    private func probeTargets(language: String) -> [ProbeTarget] {
        record.candidates().compactMap { candidate in
            guard let baseURL = candidate.baseURL(scheme: record.scheme) else { return nil }
            return ProbeTarget(
                baseURL: baseURL,
                probeSpec: TransportSpec(baseURL: baseURL,
                                         trust: candidate.trust,
                                         pinnedSPKI: record.spkiSHA256,
                                         token: token,
                                         language: language,
                                         timeout: Self.probeTimeout),
                liveSpec: TransportSpec(baseURL: baseURL,
                                        trust: candidate.trust,
                                        pinnedSPKI: record.spkiSHA256,
                                        token: token,
                                        language: language))
        }
    }

    /// 探测一条候选地址。
    ///
    /// `nonisolated static`：它不读也不写会话的状态（全部输入都在
    /// `ProbeTarget` 里），因此可以并发地跑 —— 这正是竞速成立的前提。
    private nonisolated static func probe(_ target: ProbeTarget,
                                          using factory: TransportFactory) async -> ProbeOutcome {
        do {
            let info = try await KernelClient(transport: factory(target.probeSpec)).remoteSelf()
            // 探测通过之后换一条正常超时的传输：探测那 4 秒的预算
            // 对指标、长轮询、启动站点这些真实请求都太短。
            return .ok(target, info, KernelClient(transport: factory(target.liveSpec)))
        } catch let error as KernelError {
            // 401 单独成一类：调用方据此**立刻**中止整场竞速。
            return error.needsPairing ? .unauthorized(error) : .failed(error)
        } catch {
            // 取消也会落到这里（URLSession 取消时抛的是 URLError）。
            // 它只会进 `failures`，而 `classify` 不理会这类错误码，
            // 因此不会污染最终状态。
            return .failed(KernelError(code: "unreachable", message: error.localizedDescription))
        }
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
