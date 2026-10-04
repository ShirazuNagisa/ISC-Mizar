import Foundation
import Testing
@testable import MizarKit

/// 一个假的传输。
///
/// 配对与连接最需要测试的部分**不是网络**，而是它们的决策：候选地址按什么
/// 顺序试、几个地址都失败之后报哪一个错、401 之后进入什么状态。用真实的
/// HTTPS 服务端来测这些既慢又难构造（要起一个能按需返回各种错误的服务端），
/// 而注入这个假传输之后，它们全部变成纯粹的断言。
actor StubTransport: KernelTransport {

    struct Reply {
        var body: JSONValue
        var status: Int

        static func ok(_ json: String) -> Reply {
            Reply(body: (try? JSONValue.parse(json)) ?? .null, status: 200)
        }

        static func failure(_ code: String, _ status: Int, _ message: String) -> Reply {
            Reply(body: .object(["code": .string(code), "detail": .string(message)]), status: status)
        }
    }

    /// 按 `"METHOD path"` 排队的响应；用完之后落到 `fallback`。
    private var queue: [String: [Result<Reply, KernelError>]] = [:]
    private var recorded: [String] = []
    private let fallback: Result<Reply, KernelError>

    init(fallback: Result<Reply, KernelError> = .failure(KernelError(code: "unreachable", message: "连不上"))) {
        self.fallback = fallback
    }

    func enqueue(_ method: String, _ path: String, _ result: Result<Reply, KernelError>) {
        queue["\(method) \(path)", default: []].append(result)
    }

    func enqueue(_ method: String, _ path: String, _ reply: Reply) {
        enqueue(method, path, .success(reply))
    }

    var calls: [String] { recorded }

    func call(_ method: String, _ path: String, body: Data?) async throws -> KernelReply {
        let key = "\(method) \(path)"
        recorded.append(key)
        var result = fallback
        if var pending = queue[key], !pending.isEmpty {
            result = pending.removeFirst()
            queue[key] = pending
        }

        switch result {
        case .success(let reply):
            if !(200..<300).contains(reply.status) {
                throw KernelError(code: reply.body["code"].string,
                                  status: reply.status,
                                  message: reply.body["detail"].string)
            }
            return KernelReply(status: reply.status, body: reply.body)
        case .failure(let error):
            throw error
        }
    }

    func pollEvents(since: Int64, timeoutMilliseconds: Int) async throws -> EventBatch {
        recorded.append("GET /v1/events/poll?since=\(since)")
        return EventBatch(events: [], next: since, gap: false)
    }
}

// MARK: - 测试用的服务端响应

private let pairResponse = #"""
{
  "device_id": "rfxkUCbz_mA62PLj",
  "token": "sL2R9S_nwh9K-ziwsToLzcGpWgg7d9B7BSCh4Izv3xU",
  "role": "operator",
  "server": {
    "name": "Mac-mini",
    "version": "v0.2.0",
    "api_version": "v2",
    "platform": "darwin",
    "spki_sha256": "TErcJ99SbmE1HNydX19qHAuNhRpsr5jH71UR2Zkw420",
    "fingerprint_short": "4C4A-ECBE"
  }
}
"""#

private let selfResponse = #"""
{
  "role": "operator",
  "device": {
    "id": "rfxkUCbz_mA62PLj",
    "label": "iPhone",
    "role": "operator",
    "notifications_enabled": false,
    "os_version": "27.0",
    "model": "iPhone18,1"
  },
  "server": {
    "name": "Mac-mini",
    "version": "v0.2.0",
    "api_version": "v2",
    "spki_sha256": "TErcJ99SbmE1HNydX19qHAuNhRpsr5jH71UR2Zkw420",
    "fingerprint_short": "4C4A-ECBE"
  }
}
"""#

private let payloadText = #"""
{"v":1,"kind":"isc-remote","name":"Mac-mini","scheme":"https","addresses":["192.168.1.10:8788","10.0.0.5:8788","Mac-mini.local:8788"],"spki":"TErcJ99SbmE1HNydX19qHAuNhRpsr5jH71UR2Zkw420","secret":"cSDEmeUwrYcoWLAvYCjHo1G9ALevbA1p_OaBXteclnw","exp":4102444800}
"""#

private func makePayload() throws -> PairingPayload {
    try PairingPayload.parse(payloadText)
}

/// 造一个"按地址分发假传输"的工厂。
private func factory(_ byAddress: [String: StubTransport], defaultFallback: StubTransport? = nil) -> TransportFactory {
    { spec in
        byAddress[spec.baseURL.absoluteString] ?? defaultFallback ?? StubTransport()
    }
}

private let device = PairingService.DeviceInfo(name: "iPhone", platform: "ios", osVersion: "27.0")

// MARK: - 配对：扫码路径

@Test func pairingSucceedsOnTheFirstReachableAddress() async throws {
    let stub = StubTransport()
    await stub.enqueue("POST", "/v1/remote/pair", .ok(pairResponse))

    let service = PairingService(makeTransport: factory([
        "https://192.168.1.10:8788": stub
    ]))
    let outcome = try await service.pair(payload: try makePayload(), device: device)

    #expect(outcome.token == "sL2R9S_nwh9K-ziwsToLzcGpWgg7d9B7BSCh4Izv3xU")
    #expect(outcome.role == "operator")
    #expect(outcome.record.name == "Mac-mini")
    #expect(outcome.record.spkiSHA256 == "TErcJ99SbmE1HNydX19qHAuNhRpsr5jH71UR2Zkw420")
    #expect(outcome.record.canWrite)
    // 刚刚被证明可用的地址排在最前，其余保持内核给的顺序。
    #expect(outcome.record.addresses == ["192.168.1.10:8788", "10.0.0.5:8788", "Mac-mini.local:8788"])
    #expect(outcome.record.lastGoodAddress == "192.168.1.10:8788")
}

@Test func pairingFallsThroughToTheNextAddress() async throws {
    let first = StubTransport()          // 默认 unreachable
    let second = StubTransport()
    await second.enqueue("POST", "/v1/remote/pair", .ok(pairResponse))

    let service = PairingService(makeTransport: factory([
        "https://192.168.1.10:8788": first,
        "https://10.0.0.5:8788": second,
    ]))
    let outcome = try await service.pair(payload: try makePayload(), device: device)

    #expect(outcome.record.lastGoodAddress == "10.0.0.5:8788")
    let firstCalls = await first.calls
    #expect(firstCalls.count == 1, "第一个地址应当被试过一次")
    #expect(outcome.record.addresses.first == "10.0.0.5:8788")
}

/// 一个连不上、另一个够到了内核但被拒绝 —— 该报**后者**。
///
/// 反过来（报最后一个错误、或者报"都连不上"）会把"配对码过期了"
/// 显示成"检查你的网络"，而用户该做的事完全不同。
@Test func pairingPrefersTheMostActionableFailure() async throws {
    let unreachable = StubTransport()
    let reachable = StubTransport()
    await reachable.enqueue("POST", "/v1/remote/pair",
                      .failure("unauthorized", 401, "配对码不正确，或该会话已过期。"))

    let service = PairingService(makeTransport: factory([
        "https://192.168.1.10:8788": reachable,
        "https://10.0.0.5:8788": unreachable,
    ]))

    do {
        _ = try await service.pair(payload: try makePayload(), device: device)
        Issue.record("应当失败")
    } catch let error as PairingError {
        guard case .rejected(let detail) = error else {
            Issue.record("期望 .rejected，得到 \(error)")
            return
        }
        #expect(detail.contains("配对码"))
    }
}

/// 全部地址都连不上时给一句能指导动作的话。
@Test func pairingReportsUnreachableWhenNoAddressAnswers() async throws {
    let service = PairingService(makeTransport: factory([:]))
    do {
        _ = try await service.pair(payload: try makePayload(), device: device)
        Issue.record("应当失败")
    } catch let error as PairingError {
        #expect(error == .noReachableAddress)
        #expect(error.errorDescription?.contains("同一网络") == true)
    }
}

/// 响应里自报的指纹与二维码里的不一致 —— 拒绝。
///
/// TLS 层其实已经保证了这一点，但这条断言的价值在于它**与传输无关**：
/// 将来换掉传输实现时它仍然成立。
@Test func pairingRejectsFingerprintMismatch() async throws {
    let stub = StubTransport()
    let tampered = pairResponse.replacingOccurrences(
        of: "TErcJ99SbmE1HNydX19qHAuNhRpsr5jH71UR2Zkw420",
        with: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    await stub.enqueue("POST", "/v1/remote/pair", .ok(tampered))

    let service = PairingService(makeTransport: factory(["https://192.168.1.10:8788": stub]))
    do {
        _ = try await service.pair(payload: try makePayload(), device: device)
        Issue.record("指纹不一致时应当拒绝")
    } catch let error as PairingError {
        #expect(error == .identityMismatch)
    }
}

/// 老版本内核没有远程面：给它一个**明确的**提示，而不是落库一个空指纹。
///
/// 落库空指纹的后果是此后每一次连接都报"服务器身份已变化"，
/// 而用户完全不知道该怎么修。
@Test func pairingRejectsAKernelWithoutRemoteAccess() async throws {
    let stub = StubTransport()
    let old = pairResponse
        .replacingOccurrences(of: #""spki_sha256": "TErcJ99SbmE1HNydX19qHAuNhRpsr5jH71UR2Zkw420","#,
                              with: #""spki_sha256": "","#)
    await stub.enqueue("POST", "/v1/remote/pair", .ok(old))

    let service = PairingService(makeTransport: factory(["https://192.168.1.10:8788": stub]))
    do {
        _ = try await service.pair(payload: try makePayload(), device: device)
        Issue.record("没有远程面的内核应当被拒绝")
    } catch let error as PairingError {
        guard case .rejected(let detail) = error else {
            Issue.record("期望 .rejected，得到 \(error)")
            return
        }
        #expect(detail.contains("更新"))
    }
}

@Test func pairingRejectsExpiredPayload() async throws {
    let expired = payloadText.replacingOccurrences(of: "4102444800", with: "1000000000")
    let payload = try PairingPayload.parse(expired)
    let service = PairingService(makeTransport: factory([:]))

    do {
        _ = try await service.pair(payload: payload, device: device)
        Issue.record("过期的配对码应当被拒绝，而且不该发起任何请求")
    } catch let error as PairingError {
        #expect(error == .expired)
    }
}

// MARK: - 配对：手输路径




// MARK: - 会话

private func makeRecord(addresses: [String] = ["192.168.1.10:8788", "10.0.0.5:8788"]) -> ServerRecord {
    ServerRecord(name: "Mac-mini", scheme: "https", addresses: addresses,
                 spkiSHA256: "TErcJ99SbmE1HNydX19qHAuNhRpsr5jH71UR2Zkw420",
                 role: "viewer")
}

@Test func sessionConnectsAndLearnsItsRole() async {
    let stub = StubTransport()
    await stub.enqueue("GET", "/v1/remote/self", .ok(selfResponse))

    let session = ServerSession(record: makeRecord(), token: "tok",
                                makeTransport: factory(["https://192.168.1.10:8788": stub]))
    let state = await session.connect()

    #expect(state == .online)
    #expect(await session.role == "operator")
    #expect(await session.address == "192.168.1.10:8788")
}

/// 401 之后必须**立刻**停止，不再试别的地址。
///
/// 它意味着我们够到了内核，只是它不认这个令牌 —— 换地址不会有不同结果，
/// 而继续试只会让用户多等好几秒（每个地址都要走一次超时）。
@Test func sessionStopsAtTheFirstUnauthorized() async {
    let first = StubTransport()
    await first.enqueue("GET", "/v1/remote/self", .failure("unauthorized", 401, "这台设备已被吊销，请重新配对。"))
    let second = StubTransport()
    await second.enqueue("GET", "/v1/remote/self", .ok(selfResponse))

    let session = ServerSession(record: makeRecord(), token: "tok", makeTransport: factory([
        "https://192.168.1.10:8788": first,
        "https://10.0.0.5:8788": second,
    ]))
    let state = await session.connect()

    guard case .needsPairing(let detail) = state else {
        Issue.record("期望 .needsPairing，得到 \(state)")
        return
    }
    #expect(detail.contains("吊销"))
    let firstCalls = await first.calls
    let secondCalls = await second.calls
    #expect(firstCalls.count == 1)
    #expect(secondCalls.isEmpty, "401 之后不该再试其它地址")
}

@Test func sessionReportsIdentityChangeSeparatelyFromUnreachable() async {
    let stub = StubTransport()
    await stub.enqueue("GET", "/v1/remote/self",
                 .failure("identity_changed", 0, "服务器身份已变化。"))

    let session = ServerSession(record: makeRecord(addresses: ["192.168.1.10:8788"]),
                                token: "tok",
                                makeTransport: factory(["https://192.168.1.10:8788": stub]))
    let state = await session.connect()

    guard case .identityChanged = state else {
        Issue.record("期望 .identityChanged，得到 \(state)")
        return
    }
}

/// 全部地址都连不上时，文案要能指导动作。
@Test func sessionUnreachableMessageIsActionable() async {
    let session = ServerSession(record: makeRecord(), token: "tok", makeTransport: factory([:]))
    let state = await session.connect()

    guard case .unreachable(let detail) = state else {
        Issue.record("期望 .unreachable，得到 \(state)")
        return
    }
    #expect(detail.contains("Phecda"))
    #expect(detail.contains("远程访问"))
}

@Test func sessionPollsEventsWithAnAdvancingCursor() async throws {
    let stub = StubTransport()
    await stub.enqueue("GET", "/v1/remote/self", .ok(selfResponse))

    let session = ServerSession(record: makeRecord(addresses: ["192.168.1.10:8788"]),
                                token: "tok",
                                makeTransport: factory(["https://192.168.1.10:8788": stub]))
    await session.connect()

    // 首次游标是 0，内核的约定是"从现在开始"（不是从头）。
    _ = try await session.pollEvents(timeoutMilliseconds: 0)
    _ = try await session.pollEvents(timeoutMilliseconds: 0)
    let calls = await stub.calls
    #expect(calls.contains("GET /v1/events/poll?since=0"))
}

@Test func sessionKernelThrowsWhileOffline() async {
    let session = ServerSession(record: makeRecord(), token: "tok", makeTransport: factory([:]))
    await session.connect()

    do {
        _ = try await session.kernel()
        Issue.record("没连上时不该给出客户端")
    } catch let error as KernelError {
        #expect(error.code == "unreachable")
    } catch {
        Issue.record("期望 KernelError")
    }
}

/// 一次普通调用先于重连发现令牌失效时，界面必须立刻停止假装在线。
@Test func sessionCanBeMarkedUnauthorizedFromOutside() async {
    let stub = StubTransport()
    await stub.enqueue("GET", "/v1/remote/self", .ok(selfResponse))

    let session = ServerSession(record: makeRecord(addresses: ["192.168.1.10:8788"]),
                                token: "tok",
                                makeTransport: factory(["https://192.168.1.10:8788": stub]))
    await session.connect()
    #expect(await session.state == .online)

    await session.markUnauthorized("这台设备已被吊销，请重新配对。")
    #expect(await session.state == .needsPairing("这台设备已被吊销，请重新配对。"))
    // 状态变了之后不能再给出客户端 —— 否则界面会继续点一个必然失败的按钮。
    do {
        _ = try await session.kernel()
        Issue.record("被吊销之后不该还给出客户端")
    } catch {
        // 预期
    }
}

/// 候选地址的排列：上次成功的排最前，其余保持原顺序。
@Test func sessionTriesTheLastGoodAddressFirst() async {
    var record = makeRecord(addresses: ["192.168.1.10:8788", "10.0.0.5:8788", "Mac-mini.local:8788"])
    record.lastGoodAddress = "Mac-mini.local:8788"

    let stub = StubTransport()
    await stub.enqueue("GET", "/v1/remote/self", .ok(selfResponse))

    let session = ServerSession(record: record, token: "tok",
                                makeTransport: factory(["https://Mac-mini.local:8788": stub]))
    let state = await session.connect()

    #expect(state == .online)
    #expect(await session.address == "Mac-mini.local:8788")
}

// MARK: - 服务端池

private func makePool(directory: URL, tokens: TokenStore,
                      transports: [String: StubTransport] = [:]) -> ServerPool {
    ServerPool(directory: directory,
               tokens: tokens,
               makeTransport: { spec -> any KernelTransport in
                   if let stub = transports[spec.baseURL.absoluteString] { return stub }
                   return HTTPTransport(configuration: .init(baseURL: spec.baseURL,
                                                             token: spec.token, trust: spec.trust,
                                                             pinnedSPKI: spec.pinnedSPKI,
                                                             language: spec.language,
                                                             timeout: spec.timeout))
               })
}

private func tempDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mizar-pool-\(UUID().uuidString)")
}

@Test func poolStoresTokenAndRecordTogether() async throws {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let tokens = InMemoryTokenStore()
    let pool = makePool(directory: dir, tokens: tokens)

    let outcome = PairingService.Outcome(
        record: makeRecord(), token: "tok-1",
        deviceId: "dev-1", role: "operator",
        server: try JSONDecoder.mizar.decode(PairingService.ServerInfo.self,
            from: Data(#"{"name":"Mac-mini","version":"v1","api_version":"v2"}"#.utf8)))

    let session = try await pool.add(outcome)

    #expect(await pool.records().count == 1)
    #expect(try tokens.token(for: outcome.record.id) == "tok-1")
    #expect(await session.snapshot().name == "Mac-mini")
}

/// 记录还在但令牌没了（换机恢复、用户清了 Keychain）时，
/// 报"需要重新配对"，而**不是**让这台服务端凭空消失。
@Test func poolReportsMissingTokenInsteadOfDroppingTheServer() async throws {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let tokens = InMemoryTokenStore()
    let pool = makePool(directory: dir, tokens: tokens)
    let record = makeRecord()
    // 直接写记录，不写令牌 —— 模拟"令牌丢了但记录还在"。
    try await ServerStore(directory: dir).upsert(record)

    do {
        _ = try await pool.session(for: record.id)
        Issue.record("缺少令牌时应当报错")
    } catch let error as KernelError {
        #expect(error.needsPairing)
    }
    #expect(await pool.records().count == 1, "记录不该被删掉")
}

@Test func poolRemovesTokenRecordAndSessionTogether() async throws {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let tokens = InMemoryTokenStore()
    let pool = makePool(directory: dir, tokens: tokens)
    let record = makeRecord()
    try tokens.setToken("tok", for: record.id)
    try await ServerStore(directory: dir).upsert(record)

    #expect(try await pool.remove(id: record.id))
    #expect(await pool.records().isEmpty)
    #expect(try tokens.token(for: record.id) == nil, "令牌必须一起清掉")
}

@Test func poolConnectsAndSyncsTheRoleBackIntoTheRecord() async throws {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let tokens = InMemoryTokenStore()
    // 记录里写的是 viewer，而服务端说是 operator —— 以服务端为准。
    var record = makeRecord(addresses: ["192.168.1.10:8788"])
    record.role = "viewer"
    try tokens.setToken("tok", for: record.id)
    try await ServerStore(directory: dir).upsert(record)

    let stub = StubTransport()
    await stub.enqueue("GET", "/v1/remote/self", .ok(selfResponse))

    let pool = makePool(directory: dir, tokens: tokens,
                        transports: ["https://192.168.1.10:8788": stub])
    let state = try await pool.connect(id: record.id)

    #expect(state == .online)
    let stored = try #require(await pool.records().first)
    #expect(stored.role == "operator", "角色必须以服务端为准")
    #expect(stored.lastGoodAddress == "192.168.1.10:8788")
}

/// 二维码里的公网子域名必须进得了记录。
///
/// # 这条测的是"扫一次，从此在哪都能用"
///
/// 二维码的 `addresses` 只有局域网候选（那是扫码时手机所在的网络）。
/// 公网那一条是**独立字段**，因为它用的信任模型不同：局域网是自签
/// 证书 + 固定指纹，公网是受信任证书 + 系统信任链。
///
/// 少了这个传递，扫一次只在**家里**有用 —— 出门之后手机手上只有
/// `192.168.x.x` 与 `.local`，全部超时，而内核其实在公网上等着。
/// 它会靠第一次连上之后的自述自愈，但那要求用户先回一次家。
@Test func pairingPayloadCarriesThePublicHostIntoTheRecord() throws {
    // 内核生成的载荷（含公网子域名）。
    let raw = """
    {
      "v": 1, "kind": "isc-remote", "name": "Mac-mini", "scheme": "https",
      "addresses": ["192.168.31.92:8788"],
      "spki": "AAAA", "secret": "s3cret", "exp": 4000000000,
      "public_host": "mizar-abc.example.com", "public_port": 8788
    }
    """
    let payload = try PairingPayload.parse(raw)
    #expect(payload.publicHost == "mizar-abc.example.com")
    #expect(payload.publicPort == 8788)

    // 两条候选的信任模型必须不同 —— 混用会让公网路径固定在
    // 一个续期就会换掉的密钥上。
    let record = ServerRecord(
        name: payload.name, scheme: payload.scheme,
        addresses: payload.addresses, spkiSHA256: payload.spki, role: "operator",
        publicHost: payload.publicHost, publicPort: payload.publicPort)
    let candidates = record.candidates()
    #expect(candidates.count == 2)
    #expect(candidates[0].trust == .pin)
    #expect(candidates[1].trust == .system)
}

/// 老版本的载荷（没有公网字段）必须照常工作。
///
/// 内核与 App 是两个独立更新的东西，而"新 App 扫旧内核的码"是
/// 升级期间的常态。
@Test func pairingPayloadWithoutPublicHostStillWorks() throws {
    let raw = """
    {
      "v": 1, "kind": "isc-remote", "name": "Mac-mini", "scheme": "https",
      "addresses": ["192.168.31.92:8788"],
      "spki": "AAAA", "secret": "s3cret", "exp": 4000000000
    }
    """
    let payload = try PairingPayload.parse(raw)
    #expect(payload.publicHost == nil, "没有这个字段时应当是 nil，而不是解析失败")
    #expect(payload.addresses.count == 1)
}

/// 配对链接与二维码装的是**同一份载荷**。
///
/// # 这条挡的是"扫得进、粘不进"
///
/// 链接由**内核**生成（`QRLink`），Mizar 这边只负责解析。如果哪天
/// 有人在这边自己拼一遍链接，两个实现就会漂移 —— 而症状是某个
/// 版本组合上"二维码能扫、链接粘不进去"，只在特定版本对上出现。
///
/// 这里用内核真实生成的载荷做往返：`link()` → `parse()` 必须逐字段相等。
@Test func pairingLinkRoundTripsToTheSamePayload() throws {
    let original = PairingPayload(
        name: "Mac-mini", scheme: "https",
        addresses: ["192.168.31.92:8788", "[2409:8a50:6a1:7450::560]:8788"],
        spki: "TErcJ99SbmE1HNydX19qHAuNhRpsr5jH71UR2Zkw420",
        secret: "S0me-High-Entropy-Secret", exp: 4_000_000_000,
        publicHost: "mizar-abc.example.com", publicPort: 8788)

    let text = try original.link()
    #expect(text.hasPrefix("isc-remote://pair?d="))

    let parsed = try PairingPayload.parse(text)
    #expect(parsed == original, "往返之后载荷变了 —— 链接与二维码会各说各话")
    #expect(parsed.publicHost == "mizar-abc.example.com")
}

/// 粘贴时两边带的空白必须被容忍。
///
/// 用户从聊天窗口复制过来的东西常常带换行或首尾空格，而因为一个
/// 看不见的换行就报"链接无效"是最让人恼火的一类失败。
@Test func pairingLinkToleratesSurroundingWhitespace() throws {
    let original = PairingPayload(
        name: "Mac-mini", scheme: "https", addresses: ["192.168.1.10:8788"],
        spki: "AAAA", secret: "s", exp: 4_000_000_000)
    let text = try original.link()

    let parsed = try PairingPayload.parse("  \n\(text)\n  ")
    #expect(parsed.secret == original.secret)
}
