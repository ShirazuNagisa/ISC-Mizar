import Foundation
import Testing
import MizarApp
import MizarKit

/// 应用层：进入详情页时的状态推进。
///
/// # 这里测的是"什么时候界面能看到东西"
///
/// 用户报告里最难查的一条是"点一下服务端，右边什么都没有"：它既不是
/// 崩溃也不是错误，只是一个空窗期 —— 而空窗期的成因几乎总是"某个 await
/// 挡在渲染前面"。`AppModel.select` 因此必须是**同步**的：它只能把状态
/// 改成"连接中"就返回，连接交给后台任务。这几条测试钉住的就是那件事。
///
/// 它们不需要网络：选中的服务端要么不在列表里（立刻失败），要么没有
/// 令牌（立刻变成"需要重新配对"）—— 两条路径都不依赖真实服务端。
@MainActor
struct AppModelTests {

    private func tempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mizar-appmodel-\(UUID().uuidString)")
    }

    private func makeRecord(id: String = "srv-1") -> ServerRecord {
        ServerRecord(id: id, name: "Mac-mini", scheme: "https",
                     addresses: ["192.168.1.10:8788"],
                     spkiSHA256: "TErcJ99SbmE1HNydX19qHAuNhRpsr5jH71UR2Zkw420",
                     role: "operator")
    }

    /// 选中一台服务端的**当帧**就应当是"连接中"，而不是"什么都还没发生"。
    ///
    /// 断言与 `select` 之间没有任何 await —— 这正是要点：如果 `select`
    /// 还是 `async`、还要等一次连接，这里读到的就会是 `.idle`，而界面
    /// 在那几秒里是一片空白（或一句"还没有数据"）。
    @Test func selectingAServerShowsTheSkeletonImmediately() async {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = AppModel(directory: dir)
        model.select("srv-1")

        #expect(model.selectedServerID == "srv-1")
        #expect(model.state(of: "srv-1") == .connecting)
        // 还没有拿到过数据 —— 这正是界面画骨架、而不是说"还没有站点"
        // 的依据。
        #expect(!model.hasLoadedData)
    }

    /// 切服务器会清空上一台的数据。
    ///
    /// 保留上一台的指标会让用户以为**新**服务器 CPU 爆了 —— 那比空白
    /// 危险得多。这条与上一条一起说明"选中"这个动作改了什么。
    @Test func selectingAnotherServerClearsThePreviousData() async {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = AppModel(directory: dir)
        model.select("srv-1")
        model.select("srv-2")

        #expect(model.selectedServerID == "srv-2")
        #expect(model.metrics == nil)
        #expect(model.apps.isEmpty)
        #expect(!model.hasLoadedData)
    }

    /// 连接失败（或根本连不起来）之后，"连接中"必须落到一个确定的状态。
    ///
    /// # 为什么要有这一条
    ///
    /// `connectAndRefresh` 里有一个 `defer`：被取消或提前返回时不能把
    /// 状态留在 `.connecting`。留在那儿的话，界面会**永远**停在骨架屏上
    /// —— 连"重试"按钮都不会出现（那个按钮只在具体状态里画）。
    @Test func aFailedConnectionNeverStaysInConnecting() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 记录在，但令牌没有（模拟 Keychain 被清过）—— `session(for:)`
        // 会报"需要重新配对"，而不可能连上。
        let record = makeRecord()
        try await ServerStore(directory: dir).upsert(record)

        let model = AppModel(directory: dir)
        model.selectedServerID = record.id
        model.retry()
        #expect(model.state(of: record.id) == .connecting)

        // 后台任务跑完（失败是立刻的，因此这个等待很短）。
        for _ in 0..<300 {
            if model.state(of: record.id) != .connecting { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let settled = model.state(of: record.id)
        #expect(settled != .connecting, "连接结束后不能停在「连接中」，否则骨架屏永远不消失")
        #expect(settled != .online)
    }
}
