import Foundation
import UserNotifications
import MizarKit
import MizarUI

/// 一条推送要带我们去哪儿。
///
/// # 为什么是结构化的 kind + id，而不是一个 URL
///
/// URL 的格式会随界面结构变化（今天 `/apps/<id>`，明天可能是
/// `/sites/<id>`），而 kind/id 表达的是"哪台服务器的哪个东西" ——
/// 那是稳定的。内核发通知时不需要知道手机上的路由长什么样，
/// 而界面改版也不需要同步改内核。
public struct PushRoute: Sendable, Equatable {
    /// 通知来自哪台服务端（用名字匹配，因为内核不知道本机给它的 id）。
    public let serverName: String?
    public let kind: String
    public let id: String?

    public init(serverName: String?, kind: String, id: String?) {
        self.serverName = serverName
        self.kind = kind
        self.id = id
    }

    /// 从通知载荷里解析。
    ///
    /// 认不出的 kind **不报错也不丢弃**：调用方会退回到"打开应用看看"，
    /// 而那比一个点了没反应的链接好得多。内核将来加了新的 kind
    /// （比如"证书"），旧版本的客户端不该因此崩掉或静默失败。
    public init?(userInfo: [AnyHashable: Any]) {
        // 两种形状都要认：应用壳把通知载荷**压平**成 [String: String]
        // 之后再跨 actor 传过来（一个装着任意类型的字典不是 Sendable），
        // 而内核发出去的原始载荷是嵌套的。两者表达的是同一件事。
        if let flat = userInfo as? [String: String], let kind = flat["kind"], !kind.isEmpty {
            self.init(serverName: flat["server"], kind: kind, id: flat["id"])
            return
        }

        guard let route = userInfo["route"] as? [String: Any],
              let kind = route["kind"] as? String, !kind.isEmpty else {
            return nil
        }
        let server = userInfo["server"] as? [String: Any]
        self.init(serverName: server?["name"] as? String,
                  kind: kind,
                  id: route["id"] as? String)
    }
}

extension Notification.Name {
    /// 请求向系统注册远程通知。
    ///
    /// 由界面发出、由应用壳处理：`UIApplication.registerForRemoteNotifications`
    /// 只有 iOS 有，而界面层要在 macOS 上也能编译。用一个通知把这一步
    /// 交给壳，比在包里塞一个 `#if os(iOS)` 要好 —— 后者会让"哪些代码
    /// 真的会在手表上跑"变得需要读懂条件编译。
    public static let mizarRequestPushRegistration = Notification.Name("app.isc.mizar.request-push")
}

/// 推送的注册、登记与深链。
///
/// # 它为什么在包里而不是在应用壳里
///
/// 除了"向系统注册"那一步（`UIApplication.registerForRemoteNotifications`，
/// 只有 iOS 有），其余全是可测的逻辑：权限被拒之后怎么办、令牌怎么
/// 登记到**当前**服务端、通知点开之后该去哪儿。把那些放进包里之后，
/// 它们可以在 macOS 上用 `swift test` 覆盖。
@MainActor
public final class PushCoordinator {

    /// 通知点开之后等待被消费的目标。
    ///
    /// 存这里而不是直接驱动界面：通知可能在应用**还没起来**的时候被
    /// 点开，而那时模型刚构造、服务器列表还没读出来。
    public private(set) var pendingRoute: PushRoute?

    /// 最近一次登记的结果，供设置页显示。
    public private(set) var lastRegistrationError: String?

    public init() {}

    /// 向用户申请通知权限。
    ///
    /// **不在启动时申请**：一个刚装好、还不知道是干什么的应用弹权限框，
    /// 用户的本能是点"不允许" —— 而那个选择之后很难挽回（要跑去系统
    /// 设置里改）。这里由设置页或首次添加服务器之后触发。
    public func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            lastRegistrationError = error.localizedDescription
            return false
        }
    }

    /// 这台设备当前的授权状态。
    public func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 把 APNs 令牌登记到当前服务端。
    ///
    /// 只登记给**当前**那一台：每台服务端是独立的主体，各自签发自己的
    /// 设备令牌，而一个 APNs 令牌同时登记到多台服务端意味着每台都会给
    /// 这台设备推送 —— 用户不会想把五台服务器的告警混在一个通知列表里。
    /// 切到别的服务器时，界面会再登记一次。
    public func registerDeviceToken(_ hexToken: String, in model: AppModel) async {
        guard !hexToken.isEmpty else { return }
        do {
            let kernel = try await model.currentKernel()
            try await kernel.registerPushToken(hexToken, environment: Self.environment, topic: nil)
            lastRegistrationError = nil
        } catch {
            lastRegistrationError = error.localizedDescription
        }
    }

    public func unregister(in model: AppModel) async {
        guard let kernel = try? await model.currentKernel() else { return }
        try? await kernel.unregisterPushToken()
    }

    /// 处理一条收到的通知（点击或前台展示）。
    public func handle(userInfo: [AnyHashable: Any], in model: AppModel) async {
        guard let route = PushRoute(userInfo: userInfo) else { return }

        // 先按名字把服务器切过去 —— 用户有多台服务端，而通知只说了
        // 它来自哪一台。
        if let name = route.serverName,
           let match = model.servers.first(where: { $0.name == name }),
           match.id != model.selectedServerID {
            await model.select(match.id)
        }
        pendingRoute = route
    }

    /// 界面消费掉目标之后调用。
    public func consumeRoute() -> PushRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    /// APNs 环境。
    ///
    /// Debug 构建装的是开发版描述文件，它的令牌只对沙箱有效 ——
    /// 用错环境的症状是 `BadDeviceToken`，而那个错误看起来像
    /// "令牌不对"，用户会去反复重装应用。
    public nonisolated static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    /// 把 APNs 给的那串字节转成十六进制。
    ///
    /// 系统给的是 `Data`，而内核（以及 Apple 的 HTTP 接口）要的是
    /// **小写十六进制字符串**。直接 `String(data:encoding:)` 会得到
    /// 一堆乱码，而它在服务端看起来只是一个"格式不对的令牌"。
    /// 纯函数，因此显式 `nonisolated`：它没有任何状态，而让它挂在
    /// 主 actor 上只会让后台线程（以及测试）多一次跳转。
    public nonisolated static func hexToken(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
