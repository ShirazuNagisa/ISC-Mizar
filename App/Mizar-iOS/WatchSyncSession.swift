import Foundation
import WatchConnectivity
import MizarApp
import MizarKit

/// 手机侧的同步会话。
///
/// # 为什么不复用手机的令牌
///
/// 交给手表的是**派生的只读令牌**（见 `ServerPool.watchAccess`）：
/// 它在 Phecda 的设备列表里是一台独立设备、可以单独吊销，而角色由
/// **服务端**限制为不高于手机的。把手机自己的令牌复制一份过去会让
/// "手表只读"这句话只在客户端成立 —— 而客户端是可以被改的。
///
/// # 传输方式
///
/// `updateApplicationContext` 而不是 `transferUserInfo`：载荷是一份
/// **完整快照**，而"最新的一份覆盖旧的"正是我们想要的语义。用队列式
/// 的 `transferUserInfo` 会让手表按顺序收到一串历史快照，最后一条才是
/// 对的 —— 中间那些既没用又占带宽。
@MainActor
final class PhoneWatchSession: NSObject, WCSessionDelegate {

    static let shared = PhoneWatchSession()

    private weak var model: AppModel?

    /// 推送的决策与去重。
    ///
    /// 放在这里而不是把判断写在 `push()` 里：那几项判断**必须**能在
    /// macOS 上被测试覆盖，而本文件属于 Xcode 工程，`swift test` 看不到它。
    /// 见 `WatchPush` 里关于"模拟器跑不到这条路径"的说明。
    private let pusher = WatchPush(writer: WCSessionContextWriter())

    /// 激活会话并接上模型。
    func activate(model: AppModel) {
        self.model = model
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()

        // 配置一变就把快照推过去。模型在"服务端列表变了"与"连上了一台"
        // 之后都会调这个回调。
        model.onServersChanged = { [weak self] in
            await self?.push()
        }

        // 用户手动触发的同步。
        //
        // 自动同步覆盖不了的一种情况：**手表上的应用刚装好**，而手机的
        // 配置从那之后没变过 —— 于是 `updateApplicationContext` 不会触发
        // （它只在内容变化时投递）。没有这个入口，用户只能靠重启手机上的
        // 应用来碰运气。
        NotificationCenter.default.addObserver(forName: .mizarRequestWatchSync,
                                                object: nil, queue: .main) { [weak self] _ in
            // `force: true`：这个按钮的全部意义就是"内容没变也要再投一次"，
            // 因为对端可能是刚装好的。
            Task { @MainActor in await self?.push(force: true) }
        }
    }

    /// 把手表当前的配置同步过去。
    ///
    /// # 顺序在这里是有意义的
    ///
    /// 判断（支持不支持、激活没有、对端在不在）**全部**发生在碰
    /// `WCSession` 的投递 API 与取载荷之前：
    ///
    ///	对端没装应用时，`updateApplicationContext` 是一座到手表守护进程的
    ///	同步 XPC，而且注定失败。真机日志里那一串
    ///	`WCErrorCodeWatchAppNotInstalled` 就是它在主线程上一遍遍等回来的。
    ///	`isPaired` / `isWatchAppInstalled` 是本地属性，读它们不产生任何
    ///	跨进程调用 —— 一次注定失败的同步 XPC 因此变成一次属性读取。
    ///
    ///	取载荷（`prepareWatchSync`）会给**每台**服务端读一次 Keychain，
    ///	必要时还要派生一台手表设备（一次网络往返）。对端不在时那些活
    ///	全是白干的。
    @discardableResult
    func push(force: Bool = false) async -> WatchPushDecision {
        guard WCSession.isSupported() else { return .skippedUnsupported }
        let session = WCSession.default

        return await pusher.push(counterpart: WatchCounterpart(
            isSupported: true,
            isActivated: session.activationState == .activated,
            isPaired: session.isPaired,
            isWatchAppInstalled: session.isWatchAppInstalled
        ), force: force) { [model] in
            guard let payload = await model?.prepareWatchSync() else { return nil }
            return try? payload.encode()
        }
    }

    // MARK: - WCSessionDelegate

    /// 协议要求是 nonisolated 的：系统在自己的队列上调用它们，而本类
    /// 是主 actor 隔离的。这里只**取出可发送的数据**再跳回主 actor。
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {
        guard activationState == .activated else { return }
        Task { @MainActor in await self.push() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // 切换配对的手表之后必须重新激活，否则新表收不到任何东西 ——
        // 而症状是"换了手表之后同步就坏了"，用户完全无从下手。
        session.activate()
    }

    /// 手表主动索要（它可能在应用刚装好时就要一份）。
    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["request"] as? String == "sync" else {
            replyHandler([:])
            return
        }
        // **先把数据准备好，再回调**：`replyHandler` 不是 Sendable，而系统
        // 期望它在调用我们的那条队列上被调用。因此这里用一个不继承 actor
        // 的 `Task`，只在取数据那一步跳回主 actor。
        //
        // `nonisolated(unsafe)` 的依据：这个句柄**只被调用一次**，而且只从
        // 这一个任务里 —— 不存在并发访问。不用它的话，唯一的替代是让整个
        // 同步逻辑回到主队列上跑，而那会把"取数据"（可能要派生一台新设备，
        // 一次网络往返）也拖进去。
        nonisolated(unsafe) let reply = replyHandler
        Task {
            guard let data = await self.currentPayload() else {
                reply(["error": WatchSyncError.empty.errorDescription ?? ""])
                return
            }
            reply(["payload": data])
        }
    }

    /// 当前应当同步给手表的载荷（编码后的字节）。
    func currentPayload() async -> Data? {
        guard let model, let payload = await model.prepareWatchSync() else { return nil }
        return try? payload.encode()
    }
}

/// 把上下文交给 `WCSession` 的那一次调用。
///
/// # 为什么它必须离开主线程
///
/// `WCSession.updateApplicationContext` 返回的是 `BOOL` + `NSError**`，
/// 也就是"调用方要等一个结果"——它是一次到手表守护进程的**同步 XPC**。
/// 真机上日志会打成
/// `-[WCSession updateApplicationContext:error:]_block_invoke failed due to
/// WCErrorCodeWatchAppNotInstalled`：失败是从回复块里报出来的，说明这次
/// 调用确实等到了对端的回答。
///
/// 同步 XPC 的代价由**调用方所在的线程**承担。调用方是主 actor 时，
/// 那段等待就是系统弹「应用未响应」的那几秒。
///
/// # 为什么是专用串行队列，而不是 `Task.detached` 或协作线程池
///
/// 与 `KeychainTokenStore` 同一个理由（见 `ServerRecord.swift` 里那段
/// 说明）：这些调用是**阻塞**的，而 Swift 并发的协作线程池只准备了与
/// 核数相当的线程 —— 用它去承担阻塞会让池里别的任务排不上队。libdispatch
/// 会为阻塞的工作补线程，这正是它擅长的事。
///
/// # 换一条队列调用它是被支持的
///
/// `WCSession.h` 在协议那一节写着："All delegate methods will be called on
/// the same queue. **The delegate queue is a non-main serial queue.** It is the
/// client's responsibility to dispatch to another queue if necessary." ——
/// 框架自己就是在一条非主队列上回调的，把"另一条队列"当成调用方要自己
/// 安排的事。同一份头文件里 `activateSession` 那条注释也说明了为什么
/// **只有**投递需要挪走、激活不需要："If the WCSessionDelegate
/// session:activationDidCompleteWithState:error: is implemented this method
/// becomes an asynchronous call" —— 我们实现了那个方法，因此
/// `activate()` 是异步的，留在主 actor 上没有代价。
///
/// 串行而不是并发：同一时刻只应该有一次投递（`WatchPush` 已经保证了
/// 这一点，这里再串一层是因为队列本身就该有自己的语义，而不是靠调用方
/// 自觉）。
private struct WCSessionContextWriter: WatchContextWriter {

    private static let queue = DispatchQueue(label: "app.isc.mizar.watch-context")

    func deliver(_ payload: Data) async throws {
        // 与 `KeychainTokenStore.perform` 同构：调用方 await 的是续体，
        // 而不是阻塞在自己的线程上。
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result {
                    try WCSession.default.updateApplicationContext(["payload": payload])
                })
            }
        }
    }
}
