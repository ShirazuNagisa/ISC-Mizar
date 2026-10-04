import Foundation

/// 本机上保存的全部服务端，以及它们各自的会话。
///
/// # 它解决的是"多台服务端"这件事的三个具体问题
///
///	1. **令牌按服务端分开**：每台服务端的令牌是它自己签发的，混在一起
///	   会让"删掉一台"变成"把所有令牌都清掉"。
///	2. **会话按需创建**：一台服务端可能有几十台，但用户一次只看一台。
///	   全部同时连上会让手机在后台维持几十条长轮询 —— 电池先扛不住。
///	3. **顺序由用户决定**：列表的顺序是用户排的，不是按 id 或创建时间。
public actor ServerPool {

    private let store: ServerStore
    private let tokens: TokenStore
    private let language: String
    private let makeTransport: TransportFactory
    private var sessions: [String: ServerSession] = [:]

    public init(directory: URL,
                tokens: TokenStore = KeychainTokenStore(),
                language: String = "zh-CN",
                makeTransport: @escaping TransportFactory = ServerSession.defaultTransport) {
        self.store = ServerStore(directory: directory)
        self.tokens = tokens
        self.language = language
        self.makeTransport = makeTransport
    }

    /// 全部服务端，按用户排定的顺序。
    public func records() async -> [ServerRecord] {
        await store.all()
    }

    /// 取一台服务端的会话（没有就建一个）。
    ///
    /// 建会话**不会**立刻发起连接 —— 连接是一个显式的动作，因为它是
    /// 会失败的、会超时的，而"打开列表页"不该触发几十次网络请求。
    public func session(for id: String) async throws -> ServerSession {
        if let existing = sessions[id] { return existing }

        guard let record = await store.record(id: id) else {
            throw KernelError(code: "not_found", message: "这台服务端已经不在列表里了。")
        }
        guard let token = try tokens.token(for: id), !token.isEmpty else {
            // 记录还在但令牌没了 —— 只可能是 Keychain 被清过（换机恢复、
            // 用户在设置里清了它）。这时**不能**静默地删掉记录：用户看到
            // 的应该是"这台服务器需要重新配对"，而不是它凭空消失了。
            throw KernelError(code: "unauthorized", status: 401,
                              message: "这台服务端需要重新配对。")
        }

        let session = ServerSession(record: record, token: token, makeTransport: makeTransport)
        sessions[id] = session
        return session
    }

    /// 连接一台服务端。
    public func connect(id: String) async throws -> SessionState {
        let session = try await session(for: id)
        let state = await session.connect(language: language)

        // 连上之后把角色与地址同步回记录：角色来自**服务端**，
        // 而记录里的那一份只用于离线时画界面。
        if state == .online, let address = await session.address {
            try? await store.markSeen(id: id, address: address)
            if let info = await session.info {
                try? await store.updateRole(id: id, role: info.role)
            }
        }
        return state
    }

    /// 把一次配对的结果存下来，并返回它的会话。
    ///
    /// 顺序是刻意的：**先落令牌再落记录**。反过来的话，一次在两步之间
    /// 的崩溃会留下一条"有服务端但没有令牌"的记录，而它在界面上显示的
    /// 是"需要重新配对" —— 用户会去重新配对，然后得到两条一模一样的记录。
    @discardableResult
    public func add(_ outcome: PairingService.Outcome) async throws -> ServerSession {
        try tokens.setToken(outcome.token, for: outcome.record.id)
        do {
            try await store.upsert(outcome.record)
        } catch {
            // 记录写不进去就把令牌撤回：留着一个用不上的令牌只会让
            // 下次配对时的"覆盖写"多一次无谓的 Keychain 操作。
            try? tokens.setToken(nil, for: outcome.record.id)
            throw error
        }

        let session = ServerSession(record: outcome.record, token: outcome.token,
                                    makeTransport: makeTransport)
        sessions[outcome.record.id] = session
        return session
    }

    /// 删掉一台服务端：令牌、记录、会话一起清。
    @discardableResult
    public func remove(id: String) async throws -> Bool {
        sessions[id] = nil
        try tokens.setToken(nil, for: id)
        return try await store.remove(id: id)
    }

    /// 改角色（服务端改了权限之后从会话同步过来）。
    public func updateRole(id: String, role: String) async {
        try? await store.updateRole(id: id, role: role)
    }

    /// 用户拖动排序。
    public func reorder(ids: [String]) async {
        try? await store.reorder(ids: ids)
    }

    /// 断开全部会话。
    ///
    /// 应用进入后台时调用：让长轮询停下来，而不是让系统在挂起时
    /// 把它们静默地掐断（后者会在恢复时留下一堆半死的连接）。
    public func disconnectAll() async {
        for session in sessions.values {
            await session.disconnect()
        }
    }

    /// 记下这台服务端的公网子域名。
    ///
    /// # 它为什么必须存在
    ///
    /// 二维码里带的是**局域网**候选地址（`Candidates`）—— 那是对的，
    /// 因为扫码时手机就在同一个网里。但服务端还可以从公网访问，
    /// 而那一条只有内核知道（它在用户的域名下建了子域名）。
    ///
    /// 没有这个写入点的话：`ServerRecord.publicHost` 永远是 nil，
    /// 于是候补列表里永远只有局域网地址，而"支持域名 + 标准 TLS"
    /// 那几层代码**永远不会被执行** —— 每一层都有测试，
    /// 而层与层之间没有接线。
    ///
    /// 地址变了就更新，没变就不写：这个方法每次连接后都会被调，
    /// 而每次都写盘是没必要的。
    public func setPublicHost(_ host: String?, port: Int?, for id: String) async throws {
        guard var record = await store.record(id: id) else { return }
        let normalized = (host?.isEmpty ?? true) ? nil : host
        if record.publicHost == normalized && record.publicPort == port {
            return
        }
        record.publicHost = normalized
        record.publicPort = port
        try await store.upsert(record)
        // 会话里存着**改之前**的那份记录，而它决定了候选地址列表 ——
        // 不重建的话，刚拿到的公网地址要等下次重启才生效。
        sessions[id] = nil
    }

    /// 手表令牌在钥匙串里的键。
    ///
    /// 与主令牌分开存：手表的令牌是**另一台设备**的凭据，把它们放在
    /// 同一个键下会让"吊销手表"变成"把手机也一起清掉"。
    static func watchTokenKey(_ serverID: String) -> String { "\(serverID)#watch" }

    /// 取（必要时派生）手表的只读访问权。
    ///
    /// 已经派生过就复用 —— 每次同步都新派生一台设备会在 Phecda 的设备
    /// 列表里堆出一长串同名设备，而用户既不知道该吊销哪一个。
    public func watchAccess(for id: String,
                            device: PairingService.DeviceInfo,
                            force: Bool = false) async throws -> SyncedServer {
        guard var record = await store.record(id: id) else {
            throw KernelError(code: "not_found", message: "这台服务端已经不在列表里了。")
        }

        let key = Self.watchTokenKey(id)
        if !force, record.watchDeviceID != nil, let token = try tokens.token(for: key) {
            return SyncedServer(record: record.asViewer(), token: token)
        }

        let session = try await session(for: id)
        guard let kernel = try? await session.kernel() else {
            throw WatchSyncError.noDerivedAccess(record.name)
        }

        let derived = try await kernel.deriveDevice(role: "viewer",
                                                    label: "Apple Watch",
                                                    device: device)
        try tokens.setToken(derived.token, for: key)

        // **只记设备 id，不改父设备的角色** —— 手表是另一台设备，
        // 而这条记录描述的是手机自己。
        record.watchDeviceID = derived.deviceId
        try await store.upsert(record)

        return SyncedServer(record: record.asViewer(), token: derived.token)
    }

    /// 手表侧：把一台同步过来的服务端装进本地。
    ///
    /// 顺序与 `add(_:)` 一致：**先落令牌再落记录** —— 反过来的话，
    /// 一次在两步之间的崩溃会留下一条"有服务端但没有令牌"的记录，
    /// 而它在界面上显示"需要重新配对"。
    @discardableResult
    public func applySynced(_ synced: SyncedServer) async throws -> ServerSession {
        try tokens.setToken(synced.token, for: synced.record.id)
        try await store.upsert(synced.record)
        sessions[synced.record.id] = nil
        return try await session(for: synced.record.id)
    }

    /// 丢掉全部令牌（"从本机移除全部数据"）。
    public func removeAllTokens() throws {
        try tokens.removeAll()
    }
}
