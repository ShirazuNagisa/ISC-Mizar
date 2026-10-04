import Foundation
import Testing
@testable import MizarKit

/// 多服务端的持久化。
///
/// 这一层出错的症状都很具体：顺序错乱（用户排好的列表每次启动都变回原样）、
/// 不完整的重排把服务端**静默删掉**、令牌被写进明文文件。

private func makeRecord(name: String, addresses: [String] = ["192.168.1.10:8788"],
                        publicHost: String? = nil, publicPort: Int? = nil) -> ServerRecord {
    ServerRecord(name: name,
                 scheme: "https",
                 addresses: addresses,
                 spkiSHA256: "TErcJ99SbmE1HNydX19qHAuNhRpsr5jH71UR2Zkw420",
                 role: "viewer",
                 publicHost: publicHost,
                 publicPort: publicPort)
}

@Test func serverStoreRoundTripsThroughDisk() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mizar-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ServerStore(directory: dir)
    let first = makeRecord(name: "一号机")
    let second = makeRecord(name: "二号机")
    try await store.upsert(first)
    try await store.upsert(second)

    // 换一个实例读：证明它真的落盘了，而不是留在内存里。
    let reopened = ServerStore(directory: dir)
    let all = await reopened.all()
    #expect(all.count == 2)
    #expect(all.map(\.name) == ["一号机", "二号机"])
    #expect(await reopened.record(id: first.id)?.spkiSHA256 == first.spkiSHA256)
}

@Test func serverStoreUpsertReplacesInsteadOfDuplicating() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mizar-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ServerStore(directory: dir)
    var record = makeRecord(name: "改名前")
    try await store.upsert(record)

    record.name = "改名后"
    try await store.upsert(record)

    let all = await store.all()
    #expect(all.count == 1)
    #expect(all.first?.name == "改名后")
}

@Test func serverStoreRemoveReportsWhetherItExisted() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mizar-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ServerStore(directory: dir)
    let record = makeRecord(name: "A")
    try await store.upsert(record)

    #expect(try await store.remove(id: record.id))
    #expect(try await store.remove(id: record.id) == false)
    #expect(await store.all().isEmpty)
}

/// 不完整的重排必须被忽略，而不是把缺项删掉。
///
/// 这是最有破坏力的一条：拖动排序只用到**当前屏幕上**的行，而手机上的
/// 列表可能是折叠的、或者只加载了一部分。照单删掉不在列表里的服务端，
/// 会让"我拖了一下顺序，结果两台服务器没了"。
@Test func serverStoreIgnoresIncompleteReorder() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mizar-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ServerStore(directory: dir)
    let a = makeRecord(name: "A")
    let b = makeRecord(name: "B")
    let c = makeRecord(name: "C")
    for record in [a, b, c] { try await store.upsert(record) }

    // 只给两项：缺了 C。
    try await store.reorder(ids: [c.id, a.id])
    #expect(await store.all().count == 3, "不完整的顺序不该改变任何东西")

    // 给全了才生效。
    try await store.reorder(ids: [c.id, b.id, a.id])
    #expect(await store.all().map(\.name) == ["C", "B", "A"])
}

@Test func serverStoreRemembersTheAddressThatWorked() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mizar-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ServerStore(directory: dir)
    let record = makeRecord(name: "多地址",
                            addresses: ["192.168.1.10:8788", "10.0.0.5:8788", "Mini.local:8788"])
    try await store.upsert(record)

    try await store.markSeen(id: record.id, address: "10.0.0.5:8788")

    let updated = try #require(await store.record(id: record.id))
    // 上次成功的排到最前，其余保持内核给的顺序 —— 不重排整个列表，
    // 因为那个顺序里含有客户端不知道的信息。
    #expect(updated.orderedAddresses() == ["10.0.0.5:8788", "192.168.1.10:8788", "Mini.local:8788"])
}

@Test func serverRecordOrderingSurvivesAMissingAddress() {
    // lastGoodAddress 指向一个已经不在列表里的地址时（换过网络、
    // 内核重签后换了候选），必须退回原始顺序而不是把它插到最前面 ——
    // 那会让客户端每次都先试一个已经不存在的地址。
    var record = makeRecord(name: "过期地址",
                            addresses: ["192.168.1.10:8788", "Mini.local:8788"])
    record.lastGoodAddress = "10.0.0.5:8788"
    #expect(record.orderedAddresses() == ["192.168.1.10:8788", "Mini.local:8788"])
}

@Test func serverRecordBuildsBaseURLs() {
    let record = makeRecord(name: "双栈",
                            addresses: ["192.168.1.10:8788", "[240e::1]:8788"])
    let urls = record.candidates().compactMap { $0.baseURL(scheme: record.scheme) }
    #expect(urls.count == 2)
    // IPv6 的方括号必须被 URL 解析器接受 —— 少了它这条候选永远连不上，
    // 而纯 IPv4 的用户永远测不到。
    #expect(urls[1].absoluteString == "https://[240e::1]:8788")
}

/// 同一台服务端的两条路各有各的信任模型。
///
/// **这条是域名支持的核心理由。** 局域网路径用的是自签证书，可信来源
/// 是配对时固定的公钥指纹；公网路径用的是受信任证书，可信来源是系统
/// 信任链。给整台服务端只记一个信任模型的话，两条路里必然有一条是错的：
///
///   - 公网路径固定指纹 → 证书续期换密钥之后再也连不上，而症状是
///     "过一阵子连不上，重启一下又好了"；
///   - 局域网路径用系统信任链 → 自签证书永远验证不过，局域网直接不可用。
@Test func candidatesCarryPerAddressTrustMode() {
    let record = makeRecord(name: "双路",
                            addresses: ["192.168.1.10:8788"],
                            publicHost: "mizar-abc.example.com")
    let candidates = record.candidates()

    #expect(candidates.count == 2)
    #expect(candidates[0].address == "192.168.1.10:8788")
    #expect(candidates[0].trust == .pin, "局域网走自签证书，只能固定指纹")
    #expect(candidates[1].address == "mizar-abc.example.com")
    #expect(candidates[1].trust == .system, "公网走受信任证书，必须用系统信任链")
}

/// 公网候选排在局域网之后，而且端口可以不同。
@Test func publicCandidateUsesItsOwnPort() {
    let record = makeRecord(name: "双路",
                            addresses: ["192.168.1.10:8788"],
                            publicHost: "mizar-abc.example.com",
                            publicPort: 9443)
    let candidates = record.candidates()
    #expect(candidates.last?.address == "mizar-abc.example.com:9443")
}

/// 没有公网域名时行为**完全不变**。
///
/// 这是升级路径上的关键：老记录里没有 publicHost 字段，解码之后它是
/// nil，候选列表必须与加这个功能之前一模一样。
@Test func candidatesWithoutPublicHostAreUnchanged() {
    let record = makeRecord(name: "只有局域网",
                            addresses: ["192.168.1.10:8788", "[240e::1]:8788"])
    let candidates = record.candidates()
    #expect(candidates.count == 2)
    #expect(candidates.allSatisfy { $0.trust == .pin })
}

@Test func serverStoreKeepsRecordsWhenTheFileIsCorrupt() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mizar-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // 一份被手工改坏的文件。它不该让应用崩，也不该被**静默清空** ——
    // 那样用户丢掉的是全部服务端配置，且没有任何东西提示他发生了什么。
    let file = dir.appendingPathComponent("servers.json")
    try Data("{ not json".utf8).write(to: file)

    let store = ServerStore(directory: dir)
    #expect(await store.all().isEmpty)
    #expect(FileManager.default.fileExists(atPath: file.path), "坏文件应当被保留而不是删除")

    // 而且仍然可以正常写入：坏文件不该让这一层彻底不可用。
    try await store.upsert(makeRecord(name: "重建"))
    #expect(await store.all().count == 1)
}

@Test func inMemoryTokenStoreBehavesLikeKeychain() throws {
    let store = InMemoryTokenStore()
    #expect(try store.token(for: "a") == nil)

    try store.setToken("secret", for: "a")
    #expect(try store.token(for: "a") == "secret")

    // 覆盖写：重新配对之后旧令牌必须被替换，而不是留下两条。
    try store.setToken("newer", for: "a")
    #expect(try store.token(for: "a") == "newer")

    try store.setToken(nil, for: "a")
    #expect(try store.token(for: "a") == nil)

    try store.setToken("x", for: "b")
    try store.removeAll()
    #expect(try store.token(for: "b") == nil)
}

/// 令牌**不能**出现在服务端记录里。
///
/// 这一条是结构性的：`ServerRecord` 会被明文写进应用支持目录，而设备令牌
/// 等价于一份权限。把两者放在一起是最常见的偷懒做法，代价是"任何能读到
/// 这个文件的东西都能控制那台服务器"。
@Test func serverRecordCarriesNoToken() throws {
    let record = makeRecord(name: "无令牌")
    let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
    #expect(!json.lowercased().contains("token"))
}

/// 公网子域名必须被写进记录，否则手机在外面只会试局域网地址。
///
/// # 这条测试挡的是"层与层之间没接线"
///
/// `ServerRecord.publicHost` 存在、`candidates()` 会用它、标准 TLS 也
/// 实现了 —— 但**没有任何地方写它**。每一层单独测都是绿的，而合起来
/// 那几条代码永远不执行：手机离开家之后会依次试七八个局域网地址、
/// 全部超时，然后报"连不上"，而内核其实在公网上好好地问候着。
///
/// 这类缺陷单元测试抓不到，因为每个单元都是对的。
@MainActor
@Test func publicHostIsRecordedAndBecomesACandidate() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mizar-public-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let tokens = InMemoryTokenStore()
    let pool = ServerPool(directory: dir, tokens: tokens,
                          makeTransport: { _ in StubTransport() })

    _ = try await pool.add(PairingService.Outcome(
        record: makeRecord(name: "双路"), token: "tok", deviceId: "d1", role: "operator",
        server: try JSONDecoder.mizar.decode(PairingService.ServerInfo.self,
            from: Data(#"{"name":"Mac-mini","version":"v1","api_version":"v2"}"#.utf8))))

    // 配对时只有局域网地址。
    var record = try #require(await pool.records().first)
    #expect(record.publicHost == nil)
    #expect(record.candidates().allSatisfy { $0.trust == .pin })

    // 服务端自述里带了公网子域名。
    try await pool.setPublicHost("mizar-abc.example.com", port: 8788, for: record.id)

    record = try #require(await pool.records().first)
    #expect(record.publicHost == "mizar-abc.example.com", "公网子域名没有被写进记录")

    let candidates = record.candidates()
    #expect(candidates.count == 2)
    #expect(candidates.last?.address == "mizar-abc.example.com:8788")
    #expect(candidates.last?.trust == .system, "公网那一条必须走标准信任链，而不是固定指纹")
}
