import Foundation
import WatchConnectivity
import MizarApp
import MizarKit

/// 手表侧的同步会话。
///
/// 手表没有摄像头也没有键盘，因此它**从不自己配对** —— 配置全部来自
/// 手机。这里的职责只有两件：接住手机推过来的快照，以及在应用刚起来
/// 而还没有快照时主动要一份。
@MainActor
final class WatchSyncSession: NSObject, WCSessionDelegate {

    static let shared = WatchSyncSession()

    private weak var model: AppModel?

    func activate(model: AppModel) {
        self.model = model
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - WCSessionDelegate

    /// 协议要求是 nonisolated 的：`WCSessionDelegate` 的方法由系统在
    /// 它自己的队列上调用，而本类是主 actor 隔离的。因此这里只**取出
    /// 可发送的数据**（`Data`），再跳回主 actor 去处理。
    ///
    /// 直接跨过去会是一处数据竞争：`[String: Any]` 里装的是任意对象。
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {
        guard activationState == .activated else { return }

        // 激活之后先看有没有已经送达的快照。
        let delivered = session.receivedApplicationContext["payload"] as? Data
        Task { @MainActor in
            if let delivered {
                self.applyPayload(delivered)
            } else {
                self.requestSync()
            }
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["payload"] as? Data else { return }
        Task { @MainActor in self.applyPayload(data) }
    }

    /// 主动向手机索要一份。
    ///
    /// 需要它的场景很具体：**手表上的应用刚装好**，而手机的配置从那之后
    /// 没变过 —— 于是 `updateApplicationContext` 不会触发（它只在内容
    /// 变化时投递）。没有这一条，用户会看到一台空列表，而手机那边一切正常。
    func requestSync() {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["request": "sync"]) { [weak self] reply in
            guard let data = reply["payload"] as? Data else { return }
            Task { @MainActor in self?.applyPayload(data) }
        } errorHandler: { error in
            NSLog("ISC Mizar Watch: 向手机索要配置失败：\(error.localizedDescription)")
        }
    }

    /// 应用一份载荷。
    ///
    /// 与"向手机索要"共用同一条路径：两条路各解一次的话，它们迟早会
    /// 在某个字段上分叉，而那种缺陷只在"手表刚装好"或者"手机刚改过配置"
    /// 其中一种情况下显形。
    func applyPayload(_ data: Data) {
        do {
            let payload = try WatchSyncPayload.decode(data)
            Task { @MainActor in
                guard let model else { return }
                _ = await model.applyWatchSync(payload)
            }
        } catch {
            // 版本不匹配是最可能的原因，而用户该做的是更新手表上的应用 ——
            // 因此把这句话显示出来，而不是静默地留一个空列表。
            model?.errorMessage = error.localizedDescription
        }
    }
}
