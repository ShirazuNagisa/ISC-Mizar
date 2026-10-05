import Foundation
import Testing
@testable import MizarKit

/// 手机 → 手表的同步载荷。
///
/// # 这一层值得测什么
///
/// 手机与手表是**两个可以独立更新**的应用（手表上那个往往晚几天才更新
/// 完）。因此"新的手机 + 旧的手表"是一种正常状态而不是异常 ——
/// 而它必须表现成一句"请更新手表上的应用"，不是一堆解不出来的字段。

/// 会话连上时内核给的自述。
private let watchSelfResponse = #"""
{
  "role": "operator",
  "device": { "id": "phone-1", "label": "iPhone", "role": "operator",
              "notifications_enabled": false, "os_version": "27.0" },
  "server": { "name": "Mac-mini", "version": "v0.2.0", "api_version": "v2" }
}
"""#

private func makeRecord(name: String = "Mac-mini") -> ServerRecord {
    ServerRecord(id: "srv-1", name: name, scheme: "https",
                 addresses: ["10.0.0.5:8788", "[fd00::1]:8788"],
                 spkiSHA256: "AAAA", role: "operator",
                 createdAt: Date(timeIntervalSince1970: 1_800_000_000))
}

@Test func syncPayloadRoundTrips() throws {
    let payload = WatchSyncPayload(servers: [
        SyncedServer(record: makeRecord(), token: "tok-1"),
    ])
    let decoded = try WatchSyncPayload.decode(try payload.encode())

    #expect(decoded.version == WatchSyncPayload.currentVersion)
    #expect(decoded.servers.count == 1)
    #expect(decoded.servers[0].token == "tok-1")
    // 地址必须原样带过去：手表连的是**同一批**候选地址，
    // 少一个就少一次连上的机会。
    #expect(decoded.servers[0].record.addresses == ["10.0.0.5:8788", "[fd00::1]:8788"])
    #expect(decoded.servers[0].record.spkiSHA256 == "AAAA")
}

/// 版本更高的载荷要报"请更新应用"，而不是"数据无法解析"。
@Test func syncPayloadRejectsNewerVersions() throws {
    let future = """
    {"version": 99, "generatedAt": "2030-01-01T00:00:00Z", "servers": [], "extra": {"a": 1}}
    """
    let caught = #expect(throws: WatchSyncError.self) {
        _ = try WatchSyncPayload.decode(Data(future.utf8))
    }
    guard let error = caught, case .unsupportedVersion(let version) = error else {
        Issue.record("应当报版本不支持")
        return
    }
    #expect(version == 99)
    // 这句话是给**用户**看的：它要说出该做什么（更新手表上的应用）。
    #expect(error.errorDescription?.contains("Apple Watch") == true)
}

/// 手表拿到的记录角色被强制为只读。
///
/// 服务端**已经**保证派生令牌不高于父设备，这里再改一次是为了让手表上的
/// 界面从一开始就不显示写操作 —— 而不是让用户点下去之后收到 403。
@Test func syncedRecordIsAlwaysViewer() {
    let parent = makeRecord()
    #expect(parent.role == "operator")

    let viewer = parent.asViewer()
    #expect(viewer.role == "viewer")
    // 其余字段一个都不能变 —— 改角色只是换个视角看同一条记录。
    #expect(viewer.id == parent.id)
    #expect(viewer.addresses == parent.addresses)
    #expect(viewer.spkiSHA256 == parent.spkiSHA256)
    #expect(viewer.name == parent.name)
    // 原记录不受影响（值语义）。
    #expect(parent.role == "operator")
}

/// `watchDeviceID` 必须能随记录一起持久化。
///
/// 它的存在理由只有一个：**不要每次同步都新派生一台设备**。丢了它，
/// Phecda 的设备列表里会堆出一长串同名设备，而用户既不知道该吊销哪一个。
@Test func watchDeviceIDPersists() throws {
    var record = makeRecord()
    record.watchDeviceID = "watch-dev-9"
    #expect(record.watchDeviceID == "watch-dev-9")

    let decoded = try WatchSyncPayload.decode(try WatchSyncPayload(servers: [
        SyncedServer(record: record, token: "tok"),
    ]).encode())
    #expect(decoded.servers[0].record.watchDeviceID == "watch-dev-9")
}

/// 手表令牌与主令牌分开放的键不能相同。
///
/// 放在同一个键下会让"吊销手表"变成"把手机也一起清掉"。
@Test func watchTokenUsesASeparateKey() {
    let main = "srv-1"
    let watch = ServerPool.watchTokenKey("srv-1")
    #expect(watch != main)
    #expect(watch.hasPrefix("srv-1"))
}

/// `<serverID>#watch` 这个形状必须稳定：改掉它等于让所有已经同步过的
/// 手表在下次同步时被当成"没派生过"，从而多出一台设备。
@Test func watchTokenKeyIsStable() {
    #expect(ServerPool.watchTokenKey("abc") == "abc#watch")
}

// MARK: - 派生与装载（对着一个桩传输）

/// 手机为手表派生只读访问权，手表把它装进本地。
///
/// # 这条路径上最容易错的两件事
///
/// 1. **重复派生**：每次同步都派生一台新设备，会在 Phecda 的设备列表里
///    堆出一长串同名设备，而用户既不知道该吊销哪一个。
/// 2. **角色没有被约束**：服务端会拒绝"派生比父设备更高的角色"（那条
///    约束在 `remote.DeriveDevice` 里），而客户端如果请求 `operator`，
///    用户看到的会是一次莫名其妙的 403。
@MainActor
@Test func derivesWatchAccessOnceAndReusesIt() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mizar-watch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    // 桩：`POST /v1/remote/self/derive` 返回一台只读设备与它的令牌。
    let stub = StubTransport()
    // 派生之前会话必须先连上 —— 而"连上"在内核看来就是一次
    // `GET /v1/remote/self`。少了它，派生会因为"没有可用的连接"
    // 而失败，而那个错误看起来像派生的功能坏了。
    await stub.enqueue("GET", "/v1/remote/self", .ok(watchSelfResponse))
    await stub.enqueue("POST", "/v1/remote/self/derive", .ok("""
    {"device_id": "watch-1", "token": "watch-token", "role": "viewer"}
    """))
    let tokens = InMemoryTokenStore()
    let pool = ServerPool(directory: dir, tokens: tokens,
                          makeTransport: { _ in stub })

    _ = try await pool.add(PairingService.Outcome(
        record: ServerRecord(id: "srv-1", name: "Mac-mini", scheme: "https",
                             addresses: ["10.0.0.5:8788"], spkiSHA256: "AAAA",
                             role: "operator", createdAt: Date()),
        token: "phone-token", deviceId: "phone-1", role: "operator",
        server: try JSONDecoder.mizar.decode(PairingService.ServerInfo.self,
            from: Data(#"{"name":"Mac-mini","version":"v1","api_version":"v2"}"#.utf8))))

    let device = PairingService.DeviceInfo(name: "Apple Watch", platform: "watchos",
                                           osVersion: "27.0")

    // 派生需要一条已经建立的连接（内核在派生时会核对父设备是谁）。
    _ = try await pool.session(for: "srv-1").connect()

    let first = try await pool.watchAccess(for: "srv-1", device: device)
    #expect(first.token == "watch-token")
    // 交给手表的那一份角色必须是 viewer —— 这条在服务端也成立，
    // 这里再改一次是为了让手表界面从一开始就不显示写操作。
    #expect(first.record.role == "viewer")
    #expect(first.record.watchDeviceID == "watch-1")

    // 第二次同步**不该**再派生一台设备。
    let second = try await pool.watchAccess(for: "srv-1", device: device)
    #expect(second.token == "watch-token")
    #expect(second.record.watchDeviceID == "watch-1")

    let derives = await stub.calls.filter { $0.contains("derive") }
    #expect(derives.count == 1, "只应当派生一次，实际 \(derives.count) 次")

    // 手表的令牌与手机的分开存：放在同一个键下会让"吊销手表"
    // 变成"把手机也一起清掉"。
    let phoneToken = try await tokens.token(for: "srv-1")
    let watchToken = try await tokens.token(for: ServerPool.watchTokenKey("srv-1"))
    #expect(phoneToken == "phone-token")
    #expect(watchToken == "watch-token")
}

/// 手表侧装载：令牌与记录一起落地，且先落令牌。
@MainActor
@Test func watchAppliesSyncedServers() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mizar-watchapply-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let tokens = InMemoryTokenStore()
    let pool = ServerPool(directory: dir, tokens: tokens,
                          makeTransport: { _ in StubTransport() })

    var record = ServerRecord(id: "srv-1", name: "Mac-mini", scheme: "https",
                              addresses: ["10.0.0.5:8788"], spkiSHA256: "AAAA",
                              role: "operator", createdAt: Date())
    record.watchDeviceID = "watch-1"

    try await pool.applySynced(SyncedServer(record: record.asViewer(), token: "watch-token"))

    let stored = await pool.records()
    #expect(stored.count == 1)
    #expect(stored[0].role == "viewer")
    #expect(stored[0].name == "Mac-mini")
    #expect(try await tokens.token(for: "srv-1") == "watch-token")

    // 手表没有摄像头，因此它**从不自己配对** —— 缺令牌时的表现必须是
    // "需要重新配对"，而不是静默地从列表里消失。
    let reloaded = ServerPool(directory: dir, tokens: InMemoryTokenStore(),
                              makeTransport: { _ in StubTransport() })
    #expect(await reloaded.records().count == 1)
}
