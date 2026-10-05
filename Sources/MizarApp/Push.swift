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
        //
        // `select` 是**同步**的（连接交给后台任务）：这里若等它，下面
        // 那句 `pendingRoute = route` 就会跟着等一次完整连接，而界面
        // 要消费这个目标才能跳到通知指的那一项 —— 于是点开通知之后
        // 会有好几秒毫无反应。切换本身就是定位目标所需要的全部。
        if let name = route.serverName,
           let match = model.servers.first(where: { $0.name == name }),
           match.id != model.selectedServerID {
            model.select(match.id)
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
    /// 用错环境的症状是 `BadDeviceToken` —— 它看起来像"令牌不对"，
    /// 实际上是"你把开发版装到了真机上"。因此这个字符串值得算准。
    ///
    /// `static let` 而不是计算属性：算它要读一遍应用包里的描述文件，
    /// 而这是一个会出现在界面上的值 —— 计算属性意味着**每画一帧**都同步
    /// 读一次磁盘。`let` 的惰性初始化只做一次，且是线程安全的。
    public nonisolated static let environment: String =
        PushEnvironment.current(profile: PushEnvironment.embeddedProfile())

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

    /// 记下一次**注册失败**。
    ///
    /// 由应用壳在 `didFailToRegisterForRemoteNotificationsWithError` 时
    /// 调用。以前那句话是直接丢掉的，于是设置页显示"就绪"而用户一条通知
    /// 都收不到 —— 唯一能解释它的文本恰好被扔了。
    public func recordRegistrationFailure(_ message: String) {
        lastRegistrationError = message
    }
}

/// APNs 环境与它的判据。
///
/// # 为什么不是 `#if DEBUG`
///
/// `#if DEBUG` 回答的是"这份代码是怎么编译的"，而这个字符串要回答的是
/// "**这份构建是怎么签名的**" —— 决定令牌属于哪个环境的是签名时嵌进去的
/// `aps-environment` 权限，不是编译开关。两者在下面这些情况里会分叉：
///
///	用 Release 配置直接装到真机上调试（描述文件是 development，令牌属于沙箱）
///	TestFlight / App Store（Release 编译，production 令牌）
///
/// 分叉的代价不小：走错环境的令牌会让 Apple 回 `BadDeviceToken`，而内核
/// 把这个错误理解成"令牌失效了"，于是**把这台设备的令牌清掉**。用户看到
/// 的是"通知一直收不到，而且每次都得重新登记一遍"。
///
/// 描述文件就躺在应用包里（`embedded.mobileprovision`），它的
/// `Entitlements.aps-environment` 正是签名时用的那个值。读它比猜准。
///
/// 读不到时（模拟器上没有描述文件）才退回 `#if DEBUG`：模拟器上的推送
/// 走的是沙箱，而它总是用 Debug 配置跑起来的。
///
/// 整个类型 `nonisolated`：它是一组纯函数，而所在 target 默认隔离在
/// 主 actor 上。让它挂在主 actor 上的后果是 `PushCoordinator.environment`
/// 那个 `nonisolated` 属性读不到它 —— 而"APNs 环境"本来就不该和界面
/// 线程有任何关系。
public nonisolated enum PushEnvironment {
    public static let sandbox = "sandbox"
    public static let production = "production"

    /// 决定当前构建该上报哪个环境。
    ///
    /// `builtForDebugging` 只在读不到描述文件时用作兜底，显式传进来
    /// （而不是在里面写 `#if`）以便这个函数能被测试覆盖到两种分支。
    public static func current(profile: Data?, builtForDebugging: Bool = isDebugBuild) -> String {
        if let profile, let value = environment(inProfile: profile) {
            return value
        }
        return builtForDebugging ? sandbox : production
    }

    #if DEBUG
    /// 这份代码是不是以 Debug 配置编译的。
    public static let isDebugBuild = true
    #else
    public static let isDebugBuild = false
    #endif

    /// 从描述文件的内容里读出 `aps-environment`。
    ///
    /// # 为什么是扫字符串而不是解析 plist
    ///
    /// `embedded.mobileprovision` 是一个 CMS/PKCS#7 签名块，里面**嵌着**
    /// 一份 XML plist —— `PropertyListSerialization` 直接吃不下它。而这里
    /// 只需要一个键的值，为此引入一个 ASN.1 解析器（或者一个第三方库）
    /// 不划算。
    ///
    /// 用 `.isoLatin1` 解码：它在 0…255 上是**双射**的，因此二进制段不会
    /// 让解码失败（`.utf8` 会），而我们要找的那几个标签都是纯 ASCII。
    public static func environment(inProfile data: Data) -> String? {
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        guard let keyRange = text.range(of: "<key>aps-environment</key>") else { return nil }
        guard let open = text.range(of: "<string>", range: keyRange.upperBound..<text.endIndex),
              let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex) else {
            return nil
        }
        let raw = text[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 描述文件里写的是 `development` / `production`，而内核的契约
        // （`RemotePushTokenRequest.environment`）用的是 `sandbox` /
        // `production`。这一处转换是两边唯一的接缝，因此写死在这里。
        switch raw {
        case "development": return sandbox
        case "production": return production
        default: return nil
        }
    }

    /// 应用包里那份描述文件的内容。
    ///
    /// 真机上有它；模拟器上没有（模拟器不做描述文件签名），因此返回 nil
    /// 是**预期内**的，不是错误。
    public static func embeddedProfile() -> Data? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") else {
            return nil
        }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }
}
