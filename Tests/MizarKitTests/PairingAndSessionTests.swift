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

/// 401 之后必须**立刻**放弃整场竞速，不等其余地址。
///
/// 它意味着我们够到了内核，只是它不认这个令牌 —— 换地址不会有不同结果，
/// 而对面的下一步动作是"重新配对"，不是"检查网络"。
///
/// # 这条测试在"并行竞速"之下测的是同一件事，但断言换了
///
/// 地址现在是**同时**发起的，因此"别的地址没有被试过"不再成立（它们
/// 已经在路上了）。能保留、也更该断言的是：**不等它们**。这里把另一条
/// 地址做成"永远不回答"，而 401 那条要等对手开跑之后再回答 —— 于是
/// "整场竞速在 401 到达时就收摊"这件事是确定的，而不是看调度运气。
@Test func sessionStopsAtTheFirstUnauthorized() async {
    let hanging = HangingTransport()
    let unauthorized = UnauthorizedAfterRivalStarts(rival: hanging)

    let session = ServerSession(record: makeRecord(), token: "tok", makeTransport: { spec in
        let transport: any KernelTransport = spec.baseURL.absoluteString == "https://10.0.0.5:8788"
            ? unauthorized : hanging
        return transport
    })

    let clock = ContinuousClock()
    let started = clock.now
    let state = await session.connect()
    let elapsed = clock.now - started

    guard case .needsPairing(let detail) = state else {
        Issue.record("期望 .needsPairing，得到 \(state)")
        return
    }
    #expect(detail.contains("吊销"))
    #expect(await hanging.started == 1, "两条地址都应当被试到（它们是并行的）")
    #expect(await hanging.cancelled == 1, "401 之后那条在途的探测必须被取消，而不是等它超时")
    // 对手要挂 60 秒。串行实现会等到它超时，竞速实现应当立刻返回。
    #expect(elapsed < .seconds(5), "401 到达之后不该继续等别的地址，实际用了 \(elapsed)")
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

/// 候选地址是**同时**试的，总耗时约等于最快那条。
///
/// # 这条测试钉住的是用户报告里的那半分钟
///
/// 一台服务端有六到八条候选地址（IPv4、几条全局 IPv6、ULA、`.local`、
/// 公网域名）。逐个试的耗时是"候选数 × 单次超时"：离家在外时前七条
/// 全部等满 4 秒，而唯一能通的那条公网域名排在**最后**。
///
/// 这里把可用的那条放在最后，前面四条都挂住 60 秒 —— 于是"并行"与
/// "串行"的差别不是几毫秒的抖动，而是 2 秒与 4 分钟的差别。
@Test func sessionRacesEveryCandidateAtOnce() async {
    let hanging = (0..<4).map { _ in HangingTransport() }
    let winner = GatedSuccessTransport(rivals: hanging, body: selfResponse)

    var addresses: [String] = []
    var routes: [String: any KernelTransport] = [:]
    for (index, transport) in hanging.enumerated() {
        let address = "10.0.0.\(index + 1):8788"
        addresses.append(address)
        routes["https://\(address)"] = transport
    }
    // 能通的那条排在最后 —— 与"公网域名排在局域网候选之后"一致。
    addresses.append("public.example.com:8788")
    routes["https://public.example.com:8788"] = winner
    let byAddress = routes

    let session = ServerSession(record: makeRecord(addresses: addresses), token: "tok",
                                makeTransport: { byAddress[$0.baseURL.absoluteString] ?? StubTransport() })

    let clock = ContinuousClock()
    let started = clock.now
    let state = await session.connect()
    let elapsed = clock.now - started

    #expect(state == .online)
    #expect(await session.address == "public.example.com:8788")
    #expect(elapsed < .seconds(3), "竞速应当约等于最快那条的耗时，实际 \(elapsed)")
    for transport in hanging {
        #expect(await transport.started == 1, "每一条候选都应当被同时发起")
        #expect(await transport.cancelled == 1, "赢家出现之后，在途的探测必须被取消")
    }
}

/// 竞速的进度必须**在每条候选得到结论时**报出来，而且不能倒退。
///
/// # 这条测试钉的是界面上那一行字
///
/// 一场竞速最坏要等满一次超时（4 秒），而这 4 秒里屏幕上如果只有一个
/// 转圈、一行字都不变，用户读到的就是"卡住了" —— 而系统此刻可能正在
/// 判定这个应用有没有响应。进度数字是那段等待里**唯一会变的东西**。
@MainActor
@Test func sessionReportsEveryFailedCandidateAsProgress() async {
    // 四条都连不上（工厂给不出传输 → 立刻失败）。
    let addresses = (1...4).map { "10.0.0.\($0):8788" }
    let session = ServerSession(record: makeRecord(addresses: addresses), token: "tok",
                                makeTransport: factory([:]))

    let recorder = ProgressRecorder()
    _ = await session.connect { recorder.record($0) }

    let events = recorder.events
    #expect(events.first?.total == 4, "第一条进度必须已经说明这一轮有几条候选")
    #expect(events.first?.finished == 0, "第一条进度里还没有任何一条失败")
    #expect(events.last?.finished == 4, "四条全部失败之后必须报到 4，实际 \(events.map(\.finished))")
    #expect(events.map(\.finished) == events.map(\.finished).sorted(),
            "进度不能倒退：界面上的数字往回跳比不动更像出错")
    #expect(events.allSatisfy { $0.elapsed >= 0 })
}

/// 有赢家时，进度里**永远不会**出现"全部都失败了"。
///
/// 这条不是数学洁癖：界面把那个数字直接写成"8 条里 8 条没有回应"，
/// 而一次**成功**的连接要是先闪一下这句话，用户看到的就是一次自相
/// 矛盾的结论（"都说没回应，可它连上了"）。
@MainActor
@Test func aWinningRaceNeverReportsEveryAddressAsFailed() async {
    let hanging = (0..<4).map { _ in HangingTransport() }
    let winner = GatedSuccessTransport(rivals: hanging, body: selfResponse)

    var addresses: [String] = []
    var routes: [String: any KernelTransport] = [:]
    for (index, transport) in hanging.enumerated() {
        let address = "10.0.0.\(index + 1):8788"
        addresses.append(address)
        routes["https://\(address)"] = transport
    }
    addresses.append("public.example.com:8788")
    routes["https://public.example.com:8788"] = winner
    let byAddress = routes

    let session = ServerSession(record: makeRecord(addresses: addresses), token: "tok",
                                makeTransport: { byAddress[$0.baseURL.absoluteString] ?? StubTransport() })

    let recorder = ProgressRecorder()
    let state = await session.connect { recorder.record($0) }

    #expect(state == .online)
    #expect(!recorder.events.isEmpty, "发起竞速时至少要有第一条进度")
    #expect(recorder.events.allSatisfy { $0.finished < $0.total },
            "有赢家时不可能出现「全部都失败」，实际 \(recorder.events.map { "\($0.finished)/\($0.total)" })")
}

/// 收集进度回调。
///
/// 回调被声明成 `@MainActor`（见 `ConnectProgressHandler`），因此这里也
/// 挂在主 actor 上 —— 换个隔离域就得自己加锁，而那就等于把"顺序有保证"
/// 这件事从类型上丢掉，再在实现里手工补回来。
@MainActor
private final class ProgressRecorder {
    private(set) var events: [ConnectProgress] = []
    func record(_ progress: ConnectProgress) { events.append(progress) }
}

/// 竞速之下，"够到了内核但身份不对"仍然比"连不上"更该被报出来。
///
/// 这两句话对应两个完全不同的动作：一个是"去 Phecda 上核对这台机器"，
/// 一个是"检查网络与内核"。报错了后者，用户会把一个身份问题当成网络
/// 问题查下去。
@Test func sessionRacingPrefersIdentityChangeOverUnreachable() async {    let reachable = StubTransport()
    await reachable.enqueue("GET", "/v1/remote/self",
                            .failure("identity_changed", 0, "服务器身份已变化。"))

    let session = ServerSession(
        record: makeRecord(addresses: ["192.168.1.10:8788", "10.0.0.5:8788", "Mac-mini.local:8788"]),
        token: "tok",
        makeTransport: factory(["https://192.168.1.10:8788": reachable]))

    let state = await session.connect()

    guard case .identityChanged = state else {
        Issue.record("期望 .identityChanged，得到 \(state)")
        return
    }
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

// MARK: - 竞速用的传输

/// 一条永远不回答、但**响应取消**的候选地址。
///
/// 60 秒这个数字是刻意的：它比 `ServerSession.probeTimeout`（4 秒）大一个
/// 数量级，因此"等到超时"与"被取消"在耗时上是两回事，断言不会因为机器
/// 慢而变得模糊。真实世界里对应的是"这条地址在这个网络上根本不通" ——
/// 请求发出去，直到超时才失败。
///
/// 响应取消这一点必须与 URLSession 一致：赢家出现之后其余探测要能立刻
/// 收摊（`withTaskGroup` 会等所有子任务结束，一个不响应取消的桩会把
/// `connect` 一起拖住，测试也就测不出真实行为了）。
actor HangingTransport: KernelTransport {
    private(set) var started = 0
    private(set) var cancelled = 0

    func call(_ method: String, _ path: String, body: Data?) async throws -> KernelReply {
        started += 1
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            cancelled += 1
            throw error
        }
        throw KernelError(code: "unreachable", message: "这条地址不该有回答")
    }

    func pollEvents(since: Int64, timeoutMilliseconds: Int) async throws -> EventBatch {
        EventBatch(events: [], next: since, gap: false)
    }
}

/// 一条能通、但要等所有对手都开跑之后再回答的地址。
///
/// 没有这个"等"的话，"并行发起"这件事会因为调度顺序而无法断言：赢家
/// 可能在其余子任务被调度之前就返回了。真实网络里它对应的是"这条地址
/// 最快" —— 我们要测的正是"最快的赢，而不是序号最前的赢"。
actor GatedSuccessTransport: KernelTransport {
    private let rivals: [HangingTransport]
    private let payload: String

    init(rivals: [HangingTransport], body: String) {
        self.rivals = rivals
        self.payload = body
    }

    func call(_ method: String, _ path: String, body: Data?) async throws -> KernelReply {
        for _ in 0..<2_000 {
            var waiting = 0
            for rival in rivals {
                if await rival.started == 0 { waiting += 1 }
            }
            if waiting == 0 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return KernelReply(status: 200, body: try JSONValue.parse(payload))
    }

    func pollEvents(since: Int64, timeoutMilliseconds: Int) async throws -> EventBatch {
        EventBatch(events: [], next: since, gap: false)
    }
}

/// 一条"等对手开跑之后再回 401"的地址。
///
/// 等这一步是为了让断言确定：无论调度顺序如何，401 到达时另一条探测
/// 一定已经在路上 —— 于是"401 之后不等它"才是真的被验证了。
actor UnauthorizedAfterRivalStarts: KernelTransport {
    private let rival: HangingTransport

    init(rival: HangingTransport) {
        self.rival = rival
    }

    func call(_ method: String, _ path: String, body: Data?) async throws -> KernelReply {
        for _ in 0..<2_000 {
            if await rival.started > 0 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        throw KernelError(code: "unauthorized", status: 401,
                          message: "这台设备已被吊销，请重新配对。")
    }

    func pollEvents(since: Int64, timeoutMilliseconds: Int) async throws -> EventBatch {
        EventBatch(events: [], next: since, gap: false)
    }
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

/// 数一数"读了几次令牌"的存储。
///
/// 存在的理由：Keychain 的每一次读都是一次到 `securityd` 的同步 XPC。
/// 这个桩把"读了几次"变成可断言的事实 —— 否则它只是一个在真机上才
/// 能感觉到、而谁也不会去数的开销。
actor CountingTokenStore: TokenStore {
    private let inner = InMemoryTokenStore()
    private(set) var reads = 0

    func token(for serverID: String) async throws -> String? {
        reads += 1
        return try await inner.token(for: serverID)
    }

    func setToken(_ token: String?, for serverID: String) async throws {
        try await inner.setToken(token, for: serverID)
    }

    func removeAll() async throws {
        try await inner.removeAll()
    }
}

/// 令牌**不是**每个请求都去 Keychain 取一次。
///
/// # 这条测试挡的是"会话重建 → 再读一次 Keychain"
///
/// 会话自己攥着令牌，但会话会失效重建（拿到公网地址、手表同步、列表页
/// 每台服务端各建一次会话）。没有这一层缓存的话，重新连一次就是又一次
/// 同步 XPC —— 而它发生在用户按"重试"的那一刻。
@Test func poolReadsTheTokenOncePerRun() async throws {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let tokens = CountingTokenStore()
    let stub = StubTransport()
    await stub.enqueue("GET", "/v1/remote/self", .ok(selfResponse))
    let pool = makePool(directory: dir, tokens: tokens,
                        transports: ["https://192.168.1.10:8788": stub])

    let record = makeRecord(addresses: ["192.168.1.10:8788"])
    try await tokens.setToken("tok", for: record.id)
    try await ServerStore(directory: dir).upsert(record)

    _ = try await pool.session(for: record.id)   // 第一次：这里才该读 Keychain
    _ = try await pool.session(for: record.id)   // 命中缓存
    _ = try await pool.connect(id: record.id)    // 仍然命中缓存
    // 换公网地址会让会话失效重建 —— 这是最典型的"重建"路径。
    try await pool.setPublicHost("mizar-abc.example.com", port: 8788, for: record.id)
    _ = try await pool.session(for: record.id)   // 重建：还是命中缓存

    let reads = await tokens.reads
    #expect(reads == 1, "一台服务端在一次运行里只该读一次 Keychain，实际 \(reads) 次")
}

/// 写公网地址**不能**把已经连上的会话丢掉。
///
/// # 这条测试挡的是"配对成功了，但主页永远什么都没有"
///
/// `AppModel.connectAndRefresh` 的顺序是：连接 → 把服务端自述里的公网
/// 子域名写进记录 → 拉全部数据。中间那一步原来是 `sessions[id] = nil`
/// （因为会话里存着改之前的那份候选地址），于是紧接着的全量刷新拿到的是
/// **一个还没连上的新会话**：`session.kernel()` 抛错，七个数据字段一个都
/// 不写 —— 界面上就是一个永远填不上的空页面（骨架屏版本里是永远转不完
/// 的占位）。
///
/// 这个缺陷是在 iOS 模拟器上跑真链路时由**截图**暴露的：左上角写着
/// "已连接 · 21:22"，右边却只有占位卡片。单元测试里每一层都是对的，
/// 错的是它们被调用的顺序。
@Test func recordingThePublicHostKeepsTheLiveSession() async throws {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let tokens = InMemoryTokenStore()
    let stub = StubTransport()
    await stub.enqueue("GET", "/v1/remote/self", .ok(selfResponse))
    let pool = makePool(directory: dir, tokens: tokens,
                        transports: ["https://192.168.1.10:8788": stub])

    let record = makeRecord(addresses: ["192.168.1.10:8788"])
    try await tokens.setToken("tok", for: record.id)
    try await ServerStore(directory: dir).upsert(record)

    #expect(try await pool.connect(id: record.id) == .online)

    // 连接之后写公网地址 —— 与 `connectAndRefresh` 的顺序一致。
    try await pool.setPublicHost("mizar-abc.example.com", port: 8788, for: record.id)

    // 紧接着的那次全量刷新必须还能拿到同一个已连接的会话。
    let session = try await pool.session(for: record.id)
    #expect(await session.state == .online, "写公网地址不该把连接丢掉")
    _ = try await session.kernel()   // 会话被丢掉的话这里会抛错
    #expect(await session.snapshot().publicHost == "mizar-abc.example.com",
            "候选地址仍然要更新 —— 否则公网那条要等下次启动才生效")
}

/// 令牌被服务端拒了之后必须**重新**去 Keychain 取，而不是继续用缓存那份。
///
/// # 为什么这很重要
///
/// 用户可能在别处（另一台手机、Phecda 的页面）重新配对过，而本地这份
/// 令牌已经作废。401 之后若还用缓存里那份重连，用户会陷入"一直在重新
/// 配对、一直在 401"的循环 —— 而他手上那份新令牌始终没有被用上。
@Test func poolForgetsARejectedTokenAndUsesTheNewOne() async throws {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let tokens = InMemoryTokenStore()
    let record = makeRecord(addresses: ["192.168.1.10:8788"])
    try await tokens.setToken("stale", for: record.id)
    try await ServerStore(directory: dir).upsert(record)

    let ok = StubTransport()
    await ok.enqueue("GET", "/v1/remote/self", .ok(selfResponse))
    let rejected = StubTransport()
    await rejected.enqueue("GET", "/v1/remote/self",
                           .failure("unauthorized", 401, "这台设备已被吊销，请重新配对。"))

    // 传输按**令牌**分流：只有新令牌才连得上。于是"用的是哪一份令牌"
    // 由连接结果直接证明，不必去偷看内部状态。
    let pool = ServerPool(directory: dir, tokens: tokens, makeTransport: { spec in
        spec.token == "fresh" ? ok : rejected
    })

    let first = try await pool.connect(id: record.id)
    #expect(first == .needsPairing("这台设备已被吊销，请重新配对。"))

    // 在别处重新配对：Keychain 里换成了新的那一份。
    try await tokens.setToken("fresh", for: record.id)

    let second = try await pool.connect(id: record.id)
    #expect(second == .online, "401 之后必须重新读 Keychain，否则永远撞同一个 401")
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
    #expect(try await tokens.token(for: outcome.record.id) == "tok-1")
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
    try await tokens.setToken("tok", for: record.id)
    try await ServerStore(directory: dir).upsert(record)

    #expect(try await pool.remove(id: record.id))
    #expect(await pool.records().isEmpty)
    #expect(try await tokens.token(for: record.id) == nil, "令牌必须一起清掉")
}

@Test func poolConnectsAndSyncsTheRoleBackIntoTheRecord() async throws {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let tokens = InMemoryTokenStore()
    // 记录里写的是 viewer，而服务端说是 operator —— 以服务端为准。
    var record = makeRecord(addresses: ["192.168.1.10:8788"])
    record.role = "viewer"
    try await tokens.setToken("tok", for: record.id)
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
