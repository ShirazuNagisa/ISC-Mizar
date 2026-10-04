import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks
import MizarApp
import MizarKit
import MizarScreens

/// iOS / iPadOS 的应用入口。
///
/// # 这个文件是整条构建链上最薄的一层
///
/// 全部逻辑与屏幕都在 `MizarApp`（SwiftPM 包里），因此它们能在 macOS 上
/// 用 `swift build` 编译、用 `swift test` 验证。这里只做三件 Xcode 工程
/// 才能做的事：声明 `@main`、接住应用生命周期事件、声明能力（推送）。
@main
struct ISCMizarApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    PhoneWatchSession.shared.activate(model: model)
                    await model.enterForeground()
                    await ingestPairingLinkFromEnvironment()
                }
                // 配对链接。
                //
                // 与"从剪贴板粘贴"走的是**同一条**代码路径：链接的内容就是
                // 二维码里的那段 payload。多一条路径最怕的是两处解析逻辑
                // 分叉，因此这里只做一次转发。
                .onOpenURL { url in
                    Task { await model.pairFromLink(url.absoluteString) }
                }
                // 通知点开之后落在这里。模型会把服务器切过去，
                // 界面再消费 `push.consumeRoute()` 去定位到具体那一项。
                .onReceive(NotificationCenter.default.publisher(for: .mizarPushRoute)) { note in
                    guard let userInfo = note.userInfo else { return }
                    Task { await model.push.handle(userInfo: userInfo, in: model) }
                }
                // 界面请求开启推送 → 向系统注册。授权被拒时**不注册**：
                // 注册了也拿不到令牌，而系统日志里会多一条看不懂的失败。
                .onReceive(NotificationCenter.default.publisher(for: .mizarRequestPushRegistration)) { _ in
                    Task {
                        guard await model.push.requestAuthorization() else { return }
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
                // 系统给了令牌（或注册失败）。
                .onReceive(NotificationCenter.default.publisher(for: .mizarDeviceToken)) { note in
                    guard let token = note.userInfo?["token"] as? String else { return }
                    Task { await model.push.registerDeviceToken(token, in: model) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // 明确停掉长轮询：不停的话系统会在挂起时把它们静默掐断，
                // 恢复时我们手上会留着一堆半死的连接。
                model.enterBackground()
            case .active:
                Task { await model.enterForeground() }
            default:
                break
            }
        }
    }
}


private extension ISCMizarApp {
    /// 从环境变量里读一条配对链接。
    ///
    /// # 它为什么存在
    ///
    /// `Scripts/acceptance-ios.sh` 要在模拟器上跑完整条配对链路 ——
    /// 那是**唯一**能回答"iOS 的 ATS 会不会挡住自签证书"的办法，
    /// 而 macOS 上跑通证明不了这一条。
    ///
    /// 模拟器上没有摄像头（扫不了码），而 `simctl openurl` 会弹出系统的
    /// "在 ISC Mizar 中打开？"确认框，脚本点不掉它。因此留这一个入口。
    ///
    /// # 它为什么不是安全问题
    ///
    /// 环境变量只能在**进程启动时由启动方**设置。在真机上，别的应用无法
    /// 给本应用设环境变量 —— 唯一的启动方是系统本身。而模拟器上本来就
    /// 没有可信边界可言。
    ///
    /// 顺带一提：它走的是与扫码、粘贴**完全相同**的那条路径
    /// （`model.pairFromLink`），因此不会有一条只有测试才会走的分支。
    func ingestPairingLinkFromEnvironment() async {
        guard let link = ProcessInfo.processInfo.environment["MIZAR_PAIR_LINK"],
              !link.isEmpty else { return }
        await model.pairFromLink(link)
    }
}


extension Notification.Name {
    /// 通知被点开时广播。
    ///
    /// 用一个通知而不是把 AppDelegate 直接接到模型上：模型在 SwiftUI 的
    /// `@State` 里，而 AppDelegate 的生命周期比它长 —— 直接持有会让
    /// "启动时点开通知"和"运行中点开通知"变成两条不同的路径
    /// （前者发生在模型还没建好的时候）。
    static let mizarPushRoute = Notification.Name("app.isc.mizar.push-route")
}

/// 应用代理：接住系统给的那几件事。
///
/// SwiftUI 的 `App` 协议没有对应的钩子，因此这一个类必须存在。
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        registerBackgroundTask()
        return true
    }

    // MARK: - 推送

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // 系统给的是字节，而内核要的是小写十六进制 —— 直接当字符串用
        // 会得到一堆乱码，而它在服务端看起来只是"格式不对的令牌"。
        let hex = PushCoordinator.hexToken(from: deviceToken)
        NotificationCenter.default.post(name: .mizarDeviceToken, object: nil,
                                        userInfo: ["token": hex])
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        NotificationCenter.default.post(name: .mizarDeviceToken, object: nil,
                                        userInfo: ["error": error.localizedDescription])
    }

    /// 前台收到通知时也显示出来。
    ///
    /// 默认行为是**不显示** —— 而那恰好错在最需要它的时候：用户正盯着
    /// 应用看一个站点挂了没有，而通知悄无声息地过去了。
    ///
    /// `nonisolated`：协议要求的参数（`UNNotification`）不是 Sendable，
    /// 因此它的异步实现不能被隔离在主 actor 上。这个方法本来也不需要
    /// 任何状态，隔离只会让编译器报错。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// 用户点了通知。
    ///
    /// 这里**只取出需要的两个字符串**再跳回主 actor：`userInfo` 是
    /// `[AnyHashable: Any]`，而一个装着任意类型的字典跨 actor 传递正是
    /// Swift 6 要拦的那类事。顺带它也让"通知载荷里到底有什么"
    /// 在这一个地方就说清楚了。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        var payload: [String: String] = [:]
        if let route = info["route"] as? [String: Any] {
            payload["kind"] = route["kind"] as? String
            payload["id"] = route["id"] as? String
        }
        if let server = info["server"] as? [String: Any] {
            payload["server"] = server["name"] as? String
        }
        await MainActor.run {
            NotificationCenter.default.post(name: .mizarPushRoute, object: nil, userInfo: payload)
        }
    }

    // MARK: - 后台刷新

    /// 后台刷新兜底。
    ///
    /// 它的定位是**兜底**而不是主力：真正的即时提醒由内核推。它的价值在
    /// 于那几种推送覆盖不到的情况 —— 内核没配 APNs、用户关了推送权限、
    /// 或者只是想在打开应用之前先看一眼。
    ///
    /// 时机完全由系统决定（它会看用户的使用习惯与电池状态），因此这里
    /// 不假设它多久跑一次，而是每次都重新排一次。
    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundRefresh.identifier,
                                        using: nil) { task in
            self.handleBackgroundRefresh(task)
        }
    }

    private func handleBackgroundRefresh(_ task: BGTask) {
        scheduleBackgroundRefresh()
        let work = Task {
            let model = await MainActor.run { AppModel() }
            await model.enterForeground()
            await MainActor.run { model.enterBackground() }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundRefresh.identifier)
        // 不早于 15 分钟之后：更密没有意义（系统也不会给），
        // 而它会让这一条排在调度队列里挡住别的应用。
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// 后台刷新的标识符。
enum BackgroundRefresh {
    /// 必须与 Info.plist 里 `BGTaskSchedulerPermittedIdentifiers` 的那一条
    /// 逐字一致 —— 不一致时系统**静默拒绝**注册，而症状是"后台刷新
    /// 永远不跑"，没有任何错误信息。
    static let identifier = "app.isc.mizar.refresh"
}

extension Notification.Name {
    /// APNs 令牌到手（或注册失败）。
    static let mizarDeviceToken = Notification.Name("app.isc.mizar.device-token")
}
