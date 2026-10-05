import Foundation
import Testing
import MizarApp
import MizarKit

/// 手机 → 手表的推送：**什么时候不该碰 `WCSession`**。
///
/// # 这组测试补的是模拟器上的一个真空
///
/// 真机上用户看到的那次「应用未响应」，症状来自一次注定失败的同步 XPC：
/// 手表上没装应用时 `updateApplicationContext` 仍然会被调用，而它是到
/// 手表守护进程的同步调用，调用方是主 actor。
///
/// 而这条路径**在模拟器上一行都不会执行** —— `WCSession.isSupported()`
/// 在那里是 false，`PhoneWatchSession.activate` 第一句就回头了。于是
/// 验收脚本全绿，真机却卡住。把判断从 `WCSession` 上摘下来放进
/// `WatchCounterpart` 之后，它才第一次变得可测。
@MainActor
struct WatchPushTests {

    /// 一个记账用的投递口。
    private actor RecordingWriter: WatchContextWriter {
        private(set) var deliveries: [Data] = []
        private var failuresRemaining: Int

        init(failingTimes: Int = 0) { self.failuresRemaining = failingTimes }

        func deliver(_ payload: Data) async throws {
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw WatchSyncError.empty
            }
            deliveries.append(payload)
        }

        var count: Int { deliveries.count }
    }

    /// 一个会一直挂着的投递口：用来制造"上一次还没结束"的时刻。
    private actor HangingWriter: WatchContextWriter {
        private(set) var count = 0
        func deliver(_ payload: Data) async throws {
            count += 1
            try await Task.sleep(for: .seconds(60))
        }
    }

    /// 一个慢投递口。
    private actor SlowWriter: WatchContextWriter {
        private let delay: Duration
        init(delay: Duration) { self.delay = delay }
        func deliver(_ payload: Data) async throws {
            try await Task.sleep(for: delay)
        }
    }

    private let ready = WatchCounterpart(isSupported: true, isActivated: true,
                                         isPaired: true, isWatchAppInstalled: true)

    /// 没配对手表时，一次投递都不该发生。
    @Test func withoutAPairedWatchNothingIsDelivered() async {
        let writer = RecordingWriter()
        let push = WatchPush(writer: writer)

        let decision = await push.push(counterpart: WatchCounterpart(
            isSupported: true, isActivated: true,
            isPaired: false, isWatchAppInstalled: false)) { Data("payload".utf8) }

        #expect(decision == .skippedNoCounterpart)
        #expect(await writer.count == 0)
    }

    /// **配对的那块表上没装应用时，一次投递都不该发生。**
    ///
    /// 这是整个文件里最重要的一条：真机日志里那串
    /// `WCErrorCodeWatchAppNotInstalled` 就是漏了这道判断的结果。而它不能
    /// 只是"失败被捕获" —— 那次调用本身就要等一个跨进程的回答。
    @Test func withoutTheWatchAppNothingIsDelivered() async {
        let writer = RecordingWriter()
        let push = WatchPush(writer: writer)

        let decision = await push.push(counterpart: WatchCounterpart(
            isSupported: true, isActivated: true,
            isPaired: true, isWatchAppInstalled: false)) { Data("payload".utf8) }

        #expect(decision == .skippedNoCounterpart)
        #expect(await writer.count == 0)
    }

    /// 判断必须发生在**取载荷之前**。
    ///
    /// `prepareWatchSync` 会给每台服务端读一次 Keychain，必要时还要向
    /// 服务端派生一台手表设备（一次网络往返）。对端不在时那些活全是白干的，
    /// 而"顺序"这种东西最容易在下一次改动里被无声地调换 —— 因此单独钉住。
    @Test func thePayloadIsNotEvenBuiltWhenTheCounterpartIsMissing() async {
        let writer = RecordingWriter()
        let push = WatchPush(writer: writer)
        let built = Flag()

        let decision = await push.push(counterpart: WatchCounterpart(
            isSupported: true, isActivated: true,
            isPaired: true, isWatchAppInstalled: false)) {
            built.raise()
            return Data("payload".utf8)
        }

        #expect(decision == .skippedNoCounterpart)
        #expect(!built.isRaised, "对端不在时不该去准备载荷")
    }

    /// 会话还没激活时不投递。
    ///
    /// 激活之前 `isPaired` / `isWatchAppInstalled` 一律读成 false，此时
    /// 投递必然失败；而且这两个属性本身要等激活之后才有意义。
    @Test func anInactiveSessionDeliversNothing() async {
        let writer = RecordingWriter()
        let push = WatchPush(writer: writer)

        let decision = await push.push(counterpart: WatchCounterpart(
            isSupported: true, isActivated: false,
            isPaired: true, isWatchAppInstalled: true)) { Data("payload".utf8) }

        #expect(decision == .skippedNotActivated)
        #expect(await writer.count == 0)
    }

    /// 会话没激活时，那两个属性**连读都不该读**。
    ///
    /// # 为什么这一条不能只靠上面那条
    ///
    /// 上面那条把 `isPaired: true` **按值**传进来，等于假设这两个值已经
    /// 取到了 —— 而取值本身才是代价所在：`WCSession` 的属性读取要与手表
    /// 守护进程打交道，调用方还是主 actor。一次注定被跳过的推送不该为它
    /// 付两遍。
    ///
    /// 按值传是拦不住的（参数在调用之前就求值了），因此取值是闭包 ——
    /// 有了闭包，这条测试才观察得到"到底读没读"。
    @Test func anInactiveSessionNeverReadsTheCounterpartProperties() {
        var reads = 0
        let counterpart = WatchCounterpart.current(
            isSupported: true,
            isActivated: false,
            isPaired: { reads += 1; return true },
            isWatchAppInstalled: { reads += 1; return true })

        #expect(reads == 0, "未激活时不该去读 isPaired / isWatchAppInstalled")
        #expect(counterpart == WatchCounterpart(isSupported: true, isActivated: false,
                                               isPaired: false, isWatchAppInstalled: false))
        #expect(!counterpart.hasInstalledCounterpart)
    }

    /// 激活之后才真的去读，并且如实反映读到的值。
    ///
    /// 少了这一条，上一条可以用"永远不读、一律填 false"通过 ——
    /// 而那会让同步彻底不工作。
    @Test func anActiveSessionReadsTheCounterpartProperties() {
        var reads = 0
        let counterpart = WatchCounterpart.current(
            isSupported: true,
            isActivated: true,
            isPaired: { reads += 1; return true },
            isWatchAppInstalled: { reads += 1; return false })

        #expect(reads == 2, "激活之后必须如实去读")
        #expect(counterpart.isPaired)
        #expect(!counterpart.isWatchAppInstalled)
        #expect(!counterpart.hasInstalledCounterpart)
    }

    /// 不支持 WatchConnectivity 的机器上不投递。
    @Test func anUnsupportedDeviceDeliversNothing() async {
        let writer = RecordingWriter()
        let push = WatchPush(writer: writer)

        let decision = await push.push(counterpart: WatchCounterpart(
            isSupported: false, isActivated: false,
            isPaired: false, isWatchAppInstalled: false)) { Data("payload".utf8) }

        #expect(decision == .skippedUnsupported)
        #expect(await writer.count == 0)
    }

    /// 内容没变就不重复投递。
    ///
    /// 冷启动时这个回调会从三处被调到（会话激活、服务端列表读完、
    /// 连通并拉完数据），而三处拿到的是**同一份**快照。
    @Test func anUnchangedPayloadIsNotDeliveredTwice() async {
        let writer = RecordingWriter()
        let push = WatchPush(writer: writer)
        let payload = Data("payload".utf8)

        #expect(await push.push(counterpart: ready) { payload } == .pushed)
        #expect(await push.push(counterpart: ready) { payload } == .skippedUnchanged)
        #expect(await writer.count == 1, "同一份快照只该投一次")
    }

    /// 内容真的变了就必须再投一次。
    @Test func aChangedPayloadIsDeliveredAgain() async {
        let writer = RecordingWriter()
        let push = WatchPush(writer: writer)

        #expect(await push.push(counterpart: ready) { Data("one".utf8) } == .pushed)
        #expect(await push.push(counterpart: ready) { Data("two".utf8) } == .pushed)
        #expect(await writer.count == 2)
    }

    /// 用户手动触发的同步，内容没变也要真的投一次。
    ///
    /// # 这条挡的是一个"按下去什么都不发生"的按钮
    ///
    /// "同步到 Apple Watch"覆盖的场景很具体：**手表上的应用刚装好**，
    /// 而手机上的配置从那之后没变过。此时内容确实没变，但那只表上一次
    /// 什么都没收到 —— 去重会把这个按钮变成死按钮。
    @Test func aManualSyncRedeliversTheSamePayload() async {
        let writer = RecordingWriter()
        let push = WatchPush(writer: writer)
        let payload = Data("payload".utf8)

        #expect(await push.push(counterpart: ready) { payload } == .pushed)
        #expect(await push.push(counterpart: ready, force: true) { payload } == .pushed)
        #expect(await writer.count == 2)
    }

    /// 一次投递还没结束时到达的第二次推送直接丢掉，不排队。
    ///
    /// 排队是错的：排在后面那一份的内容与前面那份往往一模一样，而它每
    /// 投一次都要付一次同步 XPC 的代价。
    @Test func overlappingPushesAreCoalescedInsteadOfQueued() async throws {
        let writer = HangingWriter()
        let push = WatchPush(writer: writer)

        let first = Task { await push.push(counterpart: ready) { Data("A".utf8) } }
        // 等第一次真的进到投递里（`Task` 要等当前同步段让出才会跑）。
        let reached = await waitUntil { await writer.count == 1 }
        #expect(reached, "第一次投递没有开始")

        let second = await push.push(counterpart: ready, force: true) { Data("B".utf8) }
        #expect(second == .skippedAlreadyRunning)
        #expect(await writer.count == 1, "第二次不该再发起一次投递")

        first.cancel()
        _ = await first.value
    }

    /// 投递失败时既不该崩，也不该把内容记成"已经送到"。
    ///
    /// 记成送到了的后果很隐蔽：手表上一个字都没有，而手机这边认为"同步
    /// 过了"，于是自动同步再也不投 —— 用户只能靠手动按钮碰运气。
    @Test func aFailedDeliveryIsReportedAndNotCached() async {
        let writer = RecordingWriter(failingTimes: 1)
        let push = WatchPush(writer: writer)
        let payload = Data("payload".utf8)

        guard case .failed = await push.push(counterpart: ready, build: { payload }) else {
            Issue.record("投递失败应当被报出来，而不是当成成功")
            return
        }
        // 失败之后内容不算送到 —— 同一份内容必须能再投一次。
        #expect(await push.push(counterpart: ready) { payload } == .pushed)
        #expect(await writer.count == 1)
    }

    /// 投递在挂着的这段时间里，主 actor 必须是**可用的**。
    ///
    /// # 这条钉的是"同步 XPC 不许挂在调用方线程上"
    ///
    /// `WatchContextWriter.deliver` 是 `async` 的 —— 这不是风格问题，而是
    /// 这条修复的**协议层面**的保证：真机上那段阻塞跑在专用队列上
    /// （见 `WCSessionContextWriter`），调用方（主 actor）在等待期间让出。
    /// 如果哪天有人把它改回同步签名，这条测试会先红。
    ///
    /// 真机上的那几秒无法在这里复现，因此这里验证的是**消除的是哪条阻塞
    /// 路径**，而不是"ANR 消失了"。
    @Test func aSlowDeliveryNeverBlocksTheMainActor() async {
        let writer = SlowWriter(delay: .milliseconds(300))
        let push = WatchPush(writer: writer)

        let clock = ContinuousClock()
        let begin = clock.now
        let task = Task { await push.push(counterpart: ready) { Data("A".utf8) } }

        // 投递在挂着时，主 actor 应当仍然能推进别的活。
        var ticks = 0
        while clock.now - begin < .milliseconds(150) {
            ticks += 1
            await Task.yield()
        }
        #expect(ticks > 100, "投递期间主 actor 只推进了 \(ticks) 次 —— 它被挂住了")

        _ = await task.value
    }

    // MARK: - 小工具

    /// 轮询一个条件（上限约 0.6 秒）。
    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<120 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

/// 一个只用来记录"有没有被调用过"的标记。
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() { lock.lock(); raised = true; lock.unlock() }
    var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}
