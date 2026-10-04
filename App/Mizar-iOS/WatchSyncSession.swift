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
            Task { @MainActor in await self?.push() }
        }
    }

    /// 把手表当前的配置同步过去。
    func push() async {
        guard let model, WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard let payload = await model.prepareWatchSync() else { return }
        guard let data = try? payload.encode() else { return }

        do {
            // 载荷很小（几台服务端的地址与令牌），可以直接放进上下文。
            try session.updateApplicationContext(["payload": data])
        } catch {
            // 对端没装应用时这里会失败，而那不是错误 —— 用户可能只是
            // 还没在手表上装 Mizar。
            NSLog("ISC Mizar: 无法同步给手表：\(error.localizedDescription)")
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
