import Foundation
import UserNotifications
import MizarUI

// 本文件是首启权限引导的逻辑层。
//
// # 先纠正一个说法
//
// 用户说的"互联网权限"在 iOS 上**不存在** —— 联网不需要任何授权，一个
// 应用只要能拿到 socket 就能上网。真实存在且与本应用相关的只有三项：
//
//	相机      `NSCameraUsageDescription`，扫配对二维码用
//	通知      `UNUserNotificationCenter.requestAuthorization`
//	局域网    `NSLocalNetworkUsageDescription`，连局域网里的 Phecda 时系统弹
//
// 把不存在的"互联网权限"做成一个开关，只会让用户去找一个永远找不到的设置。
//
// # 为什么"该显示什么"要抽成纯函数
//
// 引导页上唯一会出错的地方是**被拒之后给什么出路**：给错了就是一个按下去
// 永远失败的按钮（用户会反复点，而每次点都只是再被系统静默拒绝一次）。
// 那个判断与 UIKit / AVFoundation 无关，因此它放在这里，能被
// `swift test` 在 macOS 上覆盖 —— 而视图里只剩渲染。

// MARK: - 步骤

/// 首启权限引导里的一步。
///
/// # 顺序为什么是相机 → 通知 → 局域网
///
/// 按"用户会在什么时候真的需要它"排，而不是按它们在设置里的排列顺序：
///
///	相机    全新安装的第一件事是扫码添加服务端；没有它只剩粘贴配对链接
///	通知    配对之后，用户关心的是"服务器出事时我能不能知道"
///	局域网  它不是一次申请，而是第一次连局域网地址时由系统自己弹
///
/// 局域网放最后还有一个理由：这一步**没有按钮**，它是一段说明。放在
/// 前面会让整个引导看起来像卡在了某个点不动。
public nonisolated enum PermissionStep: String, CaseIterable, Sendable {
    case camera
    case notifications
    case localNetwork

    /// 这一步能不能由我们主动触发系统弹窗。
    ///
    /// 只有局域网是 false，而这一条**必须**处理对：iOS 没有"申请局域网
    /// 权限"的 API，权限框只在应用第一次真的去访问一个局域网地址时出现。
    /// 给它做一个"允许"按钮的后果是那个按钮什么都不做 —— 用户点了、
    /// 什么都没发生、于是以为应用坏了。
    public var isRequestable: Bool {
        self != .localNetwork
    }
}

/// 一步权限当前的状态。
public nonisolated enum PermissionStepState: Equatable, Sendable {
    /// 还没问过 —— 现在申请，系统会弹框。
    case notDetermined
    /// 已经允许。
    case granted
    /// 用户拒绝过（或系统策略不允许）。
    ///
    /// **系统不会再弹第二次**：`requestAuthorization` 在已经决定过之后
    /// 直接返回旧结果，不显示任何界面。改只能去系统设置里改。
    case denied
    /// 这一项无法主动申请（局域网）。
    case notRequestable
}

/// 引导页上这一步该给用户什么按钮。
public nonisolated enum PermissionAction: Equatable, Sendable {
    /// "允许" —— 按下去会弹系统框。
    case request
    /// "去系统设置开启" —— 已经拒过，系统不会再弹。
    case openSettings
    /// 已经允许，没有按钮，只显示状态。
    case granted
    /// 这一步只是说明，没有任何按钮。
    case none
}

/// 一步在界面上的样子。
///
/// 文案在这里就取好（而不是在视图里），因此"引导页上会说什么"
/// 只有一个地方能读到。
public nonisolated struct PermissionStepPresentation: Equatable, Sendable {
    public let step: PermissionStep
    public let title: String
    /// 为什么需要它。**必须在系统弹窗之前**让用户看到 —— 一个不知道
    /// 用途的权限框，用户的本能是点"不允许"。
    public let reason: String
    public let action: PermissionAction
    /// 补充说明。局域网那一步靠它把"为什么没有按钮"讲清楚。
    public let footnote: String?
}

// MARK: - 纯决策

/// 引导页的文案与分支决策。
public enum PermissionOnboarding {

    /// "已经走过引导"的标记。
    ///
    /// 带版本后缀：把引导内容改成两页之后，旧标记会让老用户看不到新增的
    /// 那一步；而直接沿用同一个 key 又会让刚装好的用户也跳过它。改内容
    /// 时**显式**把 v1 改成 v2，是一个需要人做一次决定的地方。
    public static let completedKey = "app.isc.mizar.permission-onboarding.v1"

    /// 决定一步该长什么样。
    ///
    /// 对局域网的判断放在 `step` 这一层而不是 `state` 那一层：这样无论
    /// 传进来什么状态，它都不可能变成一个按钮。"不小心传错了状态"是
    /// 这里唯一会出的事，而它不该能把说明变成一次注定失败的申请。
    public static func presentation(for step: PermissionStep,
                                    state: PermissionStepState) -> PermissionStepPresentation {
        switch step {
        case .localNetwork:
            return PermissionStepPresentation(
                step: step,
                title: tr("连接局域网里的 Phecda", "Reach Phecda on your local network"),
                reason: tr("服务端就在同一个 Wi-Fi 下时，应用会直接连它的局域网地址 —— 比绕到公网快，也不依赖域名解析对不对。",
                           "When the server is on the same Wi-Fi, the app connects to its local address directly — faster than going out to the internet, and it does not depend on DNS."),
                // 没有按钮，而且**不能有**。
                action: .none,
                footnote: tr("这一项没有开关可以提前打开：iOS 只会在应用第一次真的去连局域网地址时弹窗询问。因此上面没有按钮 —— 到那一步照常点「允许」就行。",
                             "There is no switch to turn this on ahead of time: iOS only asks the first time the app actually reaches a local-network address. That is why there is no button above — just tap Allow when that prompt appears."))

        case .camera:
            let title = tr("扫描配对二维码", "Scan pairing codes")
            let reason = tr("添加服务端时用它扫 Phecda 上显示的那个二维码。不给也不会卡住：还能改用「粘贴配对链接」。",
                            "Used to scan the code Phecda shows when you add a server. Declining does not block you — you can paste the pairing link instead.")
            switch state {
            case .notDetermined, .notRequestable:
                return PermissionStepPresentation(step: step, title: title, reason: reason,
                                                  action: .request, footnote: nil)
            case .granted:
                return PermissionStepPresentation(step: step, title: title, reason: reason,
                                                  action: .granted, footnote: nil)
            case .denied:
                return PermissionStepPresentation(
                    step: step, title: title, reason: reason, action: .openSettings,
                    footnote: tr("系统只会问一次，现在再点「允许」也不会弹框。要在系统设置里把它打开。",
                                 "The system only asks once; tapping Allow again would not show a prompt. It has to be turned on in Settings."))
            }

        case .notifications:
            let title = tr("接收服务端告警", "Get server alerts")
            let reason = tr("站点启动失败、证书签发失败、解析更新失败时会推到这台设备。应用不在前台时，这是唯一能及时知道的方式。",
                            "Pushed to this device when a site fails to start, a certificate fails to issue, or a DNS update fails. While the app is in the background this is the only way to find out in time.")
            switch state {
            case .notDetermined, .notRequestable:
                return PermissionStepPresentation(step: step, title: title, reason: reason,
                                                  action: .request, footnote: nil)
            case .granted:
                return PermissionStepPresentation(step: step, title: title, reason: reason,
                                                  action: .granted, footnote: nil)
            case .denied:
                return PermissionStepPresentation(
                    step: step, title: title, reason: reason, action: .openSettings,
                    footnote: tr("系统只会问一次，现在再点「允许」也不会弹框。要在系统设置里把它打开。",
                                 "The system only asks once; tapping Allow again would not show a prompt. It has to be turned on in Settings."))
            }
        }
    }

    /// 把系统的通知授权状态映射成引导用的状态。
    ///
    /// 放在这里而不是塞进 `PermissionCenter`：后者是 `#if os(iOS)` 的，
    /// 而**设置页也要做同一个判断** —— 设置页在 macOS 上也要编译
    /// （`swift build` 靠它把屏幕全部类型检查一遍）。一个平台无关的纯
    /// 函数因此比两处各写一份 `switch` 安全：两份的话，`provisional`
    /// 这类少见状态迟早只在一处被处理，而症状是"设置页说没授权、
    /// 引导页说授权了"。
    public static func state(forAuthorization status: UNAuthorizationStatus) -> PermissionStepState {
        switch status {
        case .authorized, .provisional, .ephemeral:
            // provisional（安静送达）与 ephemeral（App Clip）都算"能收到"。
            // 把它们算成未决定会让界面反复劝用户去开一个已经开着的开关。
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            // 认不出的新状态当成"还没决定"：那会再问一次，而系统在已经
            // 决定过的情况下不会弹框，因此最坏也只是白问。反过来（当成
            // 已拒绝）会把用户推进系统设置里改一个可能不需要改的开关。
            return .notDetermined
        }
    }

    /// 主按钮上的字。
    ///
    /// 它跟着 `action` 走，因此"已经允许"与"无需申请"这两种情况都落到
    /// "下一步"，而被拒时永远不会出现一个写着"允许"却什么都不弹的按钮
    /// —— 那正是这一整套拆分的理由。
    public static func primaryLabel(for presentation: PermissionStepPresentation,
                                    isLast: Bool) -> String {
        switch presentation.action {
        case .request:
            return tr("允许", "Allow")
        case .openSettings:
            return tr("去系统设置开启", "Open Settings")
        case .granted, .none:
            return isLast ? tr("开始使用", "Get started") : tr("下一步", "Next")
        }
    }

    /// 引导是否该出现。
    ///
    /// 只认那一个标记：这是"一次性"的全部含义。抽成函数而不是直接写
    /// `if !done`，是为了让"什么情况下不该再打扰用户"有一个能被读到的
    /// 地方 —— 将来若要加"已经有服务端的老用户不弹"，改的是这里。
    public static func shouldPresent(completed: Bool) -> Bool {
        !completed
    }
}

// MARK: - 推进

/// 引导页的进度状态机。
///
/// 单独一个类型而不是在视图里做下标运算：越界会渲染出一个**空白的引导
/// 页**，而那是用户第一次打开这个应用时看到的东西 —— 一个白屏，没有
/// 任何解释，也没有任何按钮。
public nonisolated struct PermissionFlow: Equatable, Sendable {
    public let steps: [PermissionStep]
    public private(set) var index: Int

    /// 只走**可以主动申请**的步骤。
    ///
    /// 局域网那一步仍然要在页面上出现（用户需要知道有这么一回事），
    /// 但它不是一个"问"的动作，因此它排在最后，且不影响"还剩几步"。
    public init(steps: [PermissionStep] = PermissionStep.allCases) {
        self.steps = steps
        self.index = 0
    }

    public var current: PermissionStep {
        steps[min(index, steps.count - 1)]
    }

    public var isLast: Bool { index >= steps.count - 1 }

    /// "第 1 步，共 3 步"。
    ///
    /// 它是整个类型里**唯一**需要主 actor 的成员（`tr` 在主 actor 上），
    /// 因此单独标出来，而不是把整个状态机拖上去。
    @MainActor public var progress: String {
        tr("第 \(index + 1) 步，共 \(steps.count) 步",
           "Step \(index + 1) of \(steps.count)")
    }

    /// 前进一步。返回 false 表示已经走完（调用方据此关闭引导）。
    ///
    /// 返回布尔而不是让调用方自己 `index += 1`：越界那一下必须由这里
    /// 消化掉，而不是留给两个调用点各自记得判断一次。
    public mutating func advance() -> Bool {
        guard !isLast else { return false }
        index += 1
        return true
    }
}

// MARK: - 系统交互

#if os(iOS)
import AVFoundation
import UIKit

/// 读取与申请系统权限。
///
/// # 为什么它是 struct 而不是 ObservableObject
///
/// 它自己不持有任何状态 —— 状态的真相在系统那里（`AVCaptureDevice`、
/// `UNUserNotificationCenter`）。让视图持有一份副本，只会多出一个
/// "界面显示的和系统里实际的不一致"的窗口。
///
/// # 通知为什么走 PushCoordinator
///
/// "向用户要通知权限"与"拿到权限之后向 APNs 注册"是同一件事的两半，
/// 而后者只有应用壳做得了（`UIApplication.registerForRemoteNotifications`
/// 在界面包里没有）。因此这里复用壳已经在听的那一条路径，而不是另开一条
/// —— 两条路径最怕的是其中一条忘了注册，症状是"权限给了但收不到通知"。
@MainActor
public struct PermissionCenter {
    private let push: PushCoordinator

    public init(push: PushCoordinator) {
        self.push = push
    }

    /// 读取一步的当前状态。
    public func state(for step: PermissionStep) async -> PermissionStepState {
        switch step {
        case .camera:
            return Self.cameraState()
        case .localNetwork:
            return .notRequestable
        case .notifications:
            // 映射与设置页**共用**同一个函数：两处各写一份 `switch` 的话，
            // 症状是"设置页说没授权、引导页说授权了"，而用户只看到其中
            // 一页，于是那个矛盾永远不会被发现。
            return PermissionOnboarding.state(forAuthorization: await push.authorizationStatus())
        }
    }

    /// 申请一步。返回申请之后的状态。
    ///
    /// 对已经拒绝过的步骤，这里**什么都不做**并原样返回 `.denied` ——
    /// 判断留给调用方（它拿到的 `presentation` 会给出"去系统设置"）。
    /// 在这里直接调系统 API 不会弹任何东西，只会让调用方以为问过了。
    public func request(_ step: PermissionStep) async -> PermissionStepState {
        // 不可主动申请的步骤在这里就回头 —— 连系统 API 都不碰。
        //
        // 视图只对可申请的步骤画按钮，因此正常情况下走不到这一支。留着它
        // 是为了让"局域网不能申请"在**调用层面**也成立，而不是只靠
        // `presentation` 那一处的判断。一个误传进来的 `.localNetwork`
        // 在这里的后果是"什么都没发生"，而不是一次静默的、注定失败的
        // 系统调用。
        guard step.isRequestable else { return .notRequestable }

        switch step {
        case .camera:
            guard Self.cameraState() == .notDetermined else { return Self.cameraState() }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            return granted ? .granted : .denied

        case .notifications:
            let before = await state(for: .notifications)
            guard before == .notDetermined else { return before }
            let granted = await push.requestAuthorization()
            if granted {
                // 这里再发一次"要注册"是**故意**的：上面那次调用已经把
                // 结果定下来了，壳收到之后 `requestAuthorization` 会立刻
                // 返回同一个答案（不再弹框），接着去注册。引导页需要拿到
                // 结果才能决定下一页显示什么，而注册只有壳做得了 ——
                // 于是两边各做自己那一半，共享同一条路径。
                NotificationCenter.default.post(name: .mizarRequestPushRegistration, object: nil)
            }
            return granted ? .granted : .denied

        case .localNetwork:
            // 上面那个 guard 已经挡掉了；这一支只是为了穷尽 switch。
            return .notRequestable
        }
    }

    /// 打开本应用在系统设置里的那一页。
    ///
    /// 相机与通知的开关都在那一页上，因此被拒之后这是唯一能走通的路。
    /// 局域网**不在**那一页 —— 它在「隐私与安全性 → 本地网络」下，
    /// 没有可以直达的链接，因此局域网那一步不给这个按钮。
    public func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// 相机授权状态。
    ///
    /// `restricted` 与 `denied` 归成一类：两者都**问不出结果**（前者是
    /// 家长控制或 MDM 限制的），而给用户的出路是同一条 —— 去系统设置看。
    /// 分开显示只会多一句用户无从下手的解释。
    ///
    /// 模拟器上没有摄像头，状态也可能停在 `.denied`；那是预期内的，
    /// 引导页上还有「跳过」。
    private static func cameraState() -> PermissionStepState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }
}
#endif
