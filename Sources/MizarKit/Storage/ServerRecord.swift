import Foundation
#if canImport(Security)
import Security
#endif

/// 一台已保存的服务端。
///
/// # 这里**没有**令牌
///
/// 设备令牌是等价于一份权限的东西，因此它只进 Keychain（见 `TokenStore`），
/// 而这个结构体是明文写在应用支持目录里的。把两者放在一起是最常见的
/// 偷懒做法，代价是"任何能读到这个文件的东西都能控制那台服务器"。
public struct ServerRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    /// 显示名。默认取配对码里服务端自报的名字。
    public var name: String
    public var scheme: String
    /// 候选地址（含端口），顺序来自配对码。
    public var addresses: [String]
    /// 固定的公钥指纹。
    public var spkiSHA256: String
    /// 这台设备的角色（`viewer` / `operator`）。**界面据它决定按钮可不可点。**
    ///
    /// 它是服务端在某一次 `GET /v1/remote/self` 里告诉我们的，存下来只是
    /// 为了在离线时也能画出一个合理的界面；真正的判定永远在服务端。
    public var role: String
    /// 上一次连通的地址。下次先试它。
    public var lastGoodAddress: String?
    public var lastSeenAt: Date?
    public var createdAt: Date
    public var notificationsEnabled: Bool
    /// 手表在这台服务端上的设备 id。
    ///
    /// 它存在的理由只有一个：**不要每次同步都新派生一台设备**。
    /// 手机每次打开都 `derive` 一次的话，Phecda 的设备列表里会堆出
    /// 一长串同名设备，而用户既不知道该吊销哪一个，也不知道多出来的
    /// 那些是谁。
    public var watchDeviceID: String?

    /// 公网子域名（由内核在用户的域名下自动建立）。
    ///
    /// 有它时这一条走**标准 TLS 信任链**，而不是固定指纹：公网路径
    /// 用的是受信任的证书，而固定指纹会在每次续期（换密钥）之后失效。
    public var publicHost: String?
    /// 公网路径的端口。为空表示与局域网相同。
    public var publicPort: Int?

    public init(id: String = UUID().uuidString,
                name: String,
                scheme: String,
                addresses: [String],
                spkiSHA256: String,
                role: String,
                lastGoodAddress: String? = nil,
                lastSeenAt: Date? = nil,
                createdAt: Date = Date(),
                notificationsEnabled: Bool = false,
                watchDeviceID: String? = nil,
                publicHost: String? = nil,
                publicPort: Int? = nil) {
        self.id = id
        self.name = name
        self.scheme = scheme
        self.addresses = addresses
        self.spkiSHA256 = spkiSHA256
        self.role = role
        self.lastGoodAddress = lastGoodAddress
        self.lastSeenAt = lastSeenAt
        self.createdAt = createdAt
        self.notificationsEnabled = notificationsEnabled
        self.watchDeviceID = watchDeviceID
        self.publicHost = publicHost
        self.publicPort = publicPort
    }

    /// 供手表使用的副本：角色强制为只读。
    ///
    /// 服务端**已经**保证派生令牌不高于父设备（那条约束在
    /// `remote.DeriveDevice` 里），这里再改一次角色是为了让手表上的
    /// 界面从一开始就不显示写操作 —— 而不是让它在点下去之后收到 403。
    public func asViewer() -> ServerRecord {
        var copy = self
        copy.role = "viewer"
        return copy
    }

    /// 按"上次成功者优先，其余保持内核给的顺序"排列候选地址。
    ///
    /// 不重排整个列表：内核给的顺序里含有客户端不知道的信息
    /// （哪些地址属于同一张网卡、哪一条是 IPv6…），打乱它只会让
    /// 每次连接的尝试顺序随实现细节变化。
    public func orderedAddresses() -> [String] {
        guard let last = lastGoodAddress, addresses.contains(last) else { return addresses }
        return [last] + addresses.filter { $0 != last }
    }

    /// 一条可以尝试的地址，连同它该用的信任模型。
    ///
    /// # 为什么信任模型要挂在**每一条地址**上
    ///
    /// 同一台服务端可以两条路都通：在家里走局域网（自签证书，
    /// 可信来源是配对时固定下来的公钥指纹），在外面走公网域名
    /// （受信任证书，可信来源是系统信任链）。
    ///
    /// 给整台服务端只记一个信任模型的话，两条路里必然有一条是错的 ——
    /// 而在公网那条上用固定指纹的后果特别隐蔽：证书续期换密钥之后
    /// 就再也连不上，而症状是"过一阵子连不上，重启一下又好了"。
    public func candidates() -> [ServerCandidate] {
        var out: [ServerCandidate] = []
        for address in orderedAddresses() {
            out.append(ServerCandidate(address: address, trust: .pin))
        }
        // 公网域名排在最后：在家时局域网两秒内就通了，而公网那条
        // 就算通也要绕出去再回来。`lastGoodAddress` 会把上次成功的
        // 那条提到最前，因此常用网络下不会每次都先等局域网超时。
        if let host = publicHost, !host.isEmpty {
            let address = publicPort.map { "\(host):\($0)" } ?? host
            if !out.contains(where: { $0.address == address }) {
                out.append(ServerCandidate(address: address, trust: .system))
            }
        }
        return out
    }

    public var canWrite: Bool { role == "operator" }
}

/// 一条可以尝试的地址，连同它该用的信任模型。
public struct ServerCandidate: Sendable, Hashable, Identifiable {
    public var address: String
    public var trust: TrustMode

    public var id: String { address }

    public init(address: String, trust: TrustMode) {
        self.address = address
        self.trust = trust
    }

    public func baseURL(scheme: String) -> URL? {
        URL(string: "\(scheme)://\(address)")
    }
}

/// 服务端列表的持久化。
///
/// 用一个 JSON 文件而不是 UserDefaults：列表是有序的、会被整体重写，
/// 而 UserDefaults 里塞结构体数组在排查时几乎读不出来（它是二进制 plist）。
/// 用 actor 而不是加锁的类：这些调用全部来自异步上下文，而手写锁在这里
/// 只会多一处可能忘记的地方。
public actor ServerStore {
    private let fileURL: URL
    private var records: [ServerRecord] = []
    private var loaded = false

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("servers.json")
    }

    /// 全部服务端，按用户排定的顺序。
    public func all() -> [ServerRecord] {
        loadIfNeeded()
        return records
    }

    public func record(id: String) -> ServerRecord? {
        loadIfNeeded()
        return records.first { $0.id == id }
    }

    /// 新增或整体替换一台服务端。
    public func upsert(_ record: ServerRecord) throws {
        loadIfNeeded()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try persist()
    }

    /// 删掉一台服务端，返回它是否原本存在。
    @discardableResult
    public func remove(id: String) throws -> Bool {
        loadIfNeeded()
        let before = records.count
        records.removeAll { $0.id == id }
        guard records.count != before else { return false }
        try persist()
        return true
    }

    /// 记下"这次是从哪个地址连上的"。
    ///
    /// 换 WiFi、改网段之后，候选列表里可能同时有好几个历史地址；记住
    /// 最近成功的那个，下一次就不用把每一个都试一遍。
    public func markSeen(id: String, address: String, at date: Date = Date()) throws {
        loadIfNeeded()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].lastGoodAddress = address
        records[index].lastSeenAt = date
        try persist()
    }

    /// 更新角色（服务端改了权限之后同步过来）。
    public func updateRole(id: String, role: String) throws {
        loadIfNeeded()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        guard records[index].role != role else { return }
        records[index].role = role
        try persist()
    }

    /// 调整顺序（用户拖动排序）。
    public func reorder(ids: [String]) throws {
        loadIfNeeded()
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let reordered = ids.compactMap { byID[$0] }
        // 只接受"完整的一份顺序"：缺项时保留原顺序，否则一次不完整的
        // 拖动会把没出现在列表里的服务端**静默删掉**。
        guard reordered.count == records.count else { return }
        records = reordered
        try persist()
    }

    // MARK: - 内部

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // 解不出来时**不报错也不清空文件**：保留原文件，让用户至少还能
        // 从备份或诊断里把它捞回来。清空是最不可逆的一种"容错"。
        records = (try? Self.makeDecoder().decode([ServerRecord].self, from: data)) ?? []
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.makeEncoder().encode(records).write(to: fileURL, options: .atomic)
    }

    /// 编码与解码**必须**共用同一份日期策略。
    ///
    /// 这不是洁癖：写成 ISO8601 而按默认策略（自 2001 年起的秒数）读回，
    /// 会让每一次重新打开应用都得到空列表 —— 而"服务端列表莫名清空"
    /// 是那种用户以为数据丢了、于是重新配对所有服务器的故障。
    /// 有一条测试专门钉住"写出去的能读回来"。
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// 设备令牌的存放处。
///
/// # 为什么是 `async` 而不是同步协议
///
/// Keychain 的 `SecItem*` 是一次到 `securityd` 的**同步 XPC**，真机上
/// 单次从 10 ms 起、锁屏或刚启动时到 100 ms 量级。同步协议把这个代价
/// 强加给**调用方所在的线程或执行器**：主 actor 上会直接卡住界面，
/// 而 `ServerPool` 这个 actor 上排着四条轮询循环的会话查询 ——
/// 一次 Keychain 命中会让它们全部等在后面（优先级反转）。
///
/// 改成 `async` 之后，"在哪里承担这段阻塞"变成**实现**的选择
/// （见 `KeychainTokenStore` 的专用队列），而调用方在等待期间一定
/// 是让出的。这不是为了并发而并发：它换来的是"取令牌时界面照常响应"。
public protocol TokenStore: Sendable {
    func token(for serverID: String) async throws -> String?
    func setToken(_ token: String?, for serverID: String) async throws
    func removeAll() async throws
}

/// Keychain 实现。
///
/// # 可访问性为什么是 AfterFirstUnlockThisDeviceOnly
///
///   - `AfterFirstUnlock` 而不是 `WhenUnlocked`：后台刷新（BGAppRefreshTask）
///     与 APNs 的处理要在锁屏状态下读令牌，而 `WhenUnlocked` 会让那些
///     场景静默失败 —— 症状是"锁屏时不推送"。
///   - `ThisDeviceOnly` 而不是可同步：令牌是**按设备签发**的（服务端把每台
///     设备当独立主体，可以单独吊销），让它跟着 iCloud 钥匙串跑到另一台
///     设备上，服务端那边的"这台设备"就成了一句假话。
public struct KeychainTokenStore: TokenStore {
    private let service: String

    /// 跑 `SecItem*` 的专用串行队列。
    ///
    /// # 为什么是"专用队列"而不是 `Task.detached` 或协作线程池
    ///
    /// 这些调用是**阻塞**的（同步 XPC），而 Swift 并发的协作线程池是给
    /// "不阻塞的活"准备的：池里只有与核数相当的线程，被同步 XPC 占住之后
    /// 别的任务（包括主 actor 的续体）排不上队，症状是"整个应用一顿"。
    /// libdispatch 的队列则会为阻塞的工作补线程，这正是它擅长的事。
    ///
    /// 串行而不是并发：同一时刻只应有一次 Keychain 操作 —— 读、写、删
    /// 之间有先后关系（`setToken` 就是"先删再加"）。
    private let queue = DispatchQueue(label: "app.isc.mizar.keychain")

    public init(service: String = "app.isc.mizar") {
        self.service = service
    }

    public func token(for serverID: String) async throws -> String? {
        try await perform { try Self.read(service: service, serverID: serverID) }
    }

    public func setToken(_ token: String?, for serverID: String) async throws {
        try await perform { try Self.write(token, service: service, serverID: serverID) }
    }

    public func removeAll() async throws {
        try await perform { try Self.removeEverything(service: service) }
    }

    /// 把一段同步的 Keychain 操作交给专用队列，只 await 结果。
    ///
    /// 调用方（哪怕它是主 actor）在等待期间是**挂在续体上**的，而不是
    /// 阻塞在自己的线程上 —— 这就是这个包装的全部意义。
    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    // MARK: - 真正的 Keychain 操作（只在上面那条队列上跑）

    /// 读令牌。
    ///
    /// # 为什么这些是 `static` 而不是实例方法
    ///
    /// 它们要进上面那个 `@Sendable` 闭包，而闭包**只能**捕获 Sendable 的
    /// 值。做成 `static` 之后进去的是 `service` 与 `serverID` 两个字符串，
    /// 而不是整个 store —— 也顺带说明了这些函数不依赖任何实例状态。
    private static func read(service: String, serverID: String) throws -> String? {
        #if canImport(Security)
        var query = baseQuery(service: service, serverID: serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.status(status)
        }
        return String(decoding: data, as: UTF8.self)
        #else
        return nil
        #endif
    }

    private static func write(_ token: String?, service: String, serverID: String) throws {
        #if canImport(Security)
        // 先删再加，而不是 SecItemUpdate：后者在条目不存在时会失败，
        // 于是"第一次配对"与"重新配对"会走两条不同的代码路径。
        try? delete(service: service, serverID: serverID)
        guard let token else { return }

        var query = baseQuery(service: service, serverID: serverID)
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        #endif
    }

    private static func removeEverything(service: String) throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
        #endif
    }

    #if canImport(Security)
    private static func baseQuery(service: String, serverID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID,
        ]
    }

    private static func delete(service: String, serverID: String) throws {
        let status = SecItemDelete(baseQuery(service: service, serverID: serverID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
    #endif
}

public enum KeychainError: Error, LocalizedError, Sendable {
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .status(let code):
            "钥匙串操作失败（\(code)）。"
        }
    }
}

/// 内存实现。测试用，也在 Keychain 不可用时作为降级。
///
/// # 为什么是 actor
///
/// 之前它是"一把 `NSLock` + `@unchecked Sendable`"，理由写的是"调用它的
/// 地方全都在一个会话的串行路径上"。那个前提在 `ServerPool` 变成 actor、
/// 四条轮询循环并发跑之后就**不再成立**了，而 `@unchecked` 不会因为前提
/// 消失就报错 —— 它只会安静地继续放行。
///
/// 协议本身已经是 `async`，因此这里不需要再为"多一次 await"付任何代价，
/// 而 actor 把互斥交给运行时，少一处"必须记得加锁"的地方。
/// 它不做任何阻塞调用，所以它待在协作线程池上是合适的（与
/// `KeychainTokenStore` 的专用队列相反）。
public actor InMemoryTokenStore: TokenStore {
    private var tokens: [String: String] = [:]

    public init() {}

    public func token(for serverID: String) throws -> String? {
        tokens[serverID]
    }

    public func setToken(_ token: String?, for serverID: String) throws {
        if let token { tokens[serverID] = token } else { tokens.removeValue(forKey: serverID) }
    }

    public func removeAll() throws {
        tokens.removeAll()
    }
}
