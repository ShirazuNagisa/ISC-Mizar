#if os(iOS)
import SwiftUI
import UIKit
import MizarKit
import MizarApp
import MizarUI

/// 首启权限引导页。
///
/// # 它为什么是一步一步的，而不是一张"三个权限"的清单
///
/// 一个刚装好、还没画出任何界面的应用连着弹三次系统权限框，用户的本能是
/// 一路点"不允许" —— 而这三个选择之后都很难挽回。因此这里一次只显示一步：
/// 先讲清楚"为什么需要它"，再由用户按下按钮，系统弹窗**只在那之后**出现。
///
/// 把三步排成一页也做得到（三个按钮并排），但那等于把"要不要现在问"
/// 全部交给用户的手速 —— 而按顺序走完的引导天然不会连弹。
///
/// # 局域网那一步没有按钮
///
/// iOS 没有"申请局域网权限"的 API，权限框只在应用第一次真的访问局域网
/// 地址时出现。因此那一步是**说明**，不是一次申请；给它一个按钮的后果是
/// 那个按钮什么都不做。见 `PermissionStep.isRequestable` 与
/// `PermissionOnboarding.presentation`。
///
/// # 为什么「跳过」一直都在
///
/// 引导是一次性的，而写这个标记的动作发生在**用户**按下任何一个前进
/// 按钮的时候。一个不能跳过的引导会让"我只是想看看这个应用"变成必须先
/// 回答三个权限问题 —— 那是卸载的理由。
public struct PermissionOnboardingView: View {
    private let push: PushCoordinator
    private let onFinish: () -> Void

    @State private var flow = PermissionFlow()
    @State private var state: PermissionStepState = .notDetermined
    @State private var busy = false
    @Environment(\.scenePhase) private var scenePhase

    /// 只接一个 `PushCoordinator`（而不是整个 `AppModel`）：这一页需要
    /// 的全部内容就是"通知权限现在是什么状态"，而 `AppModel` 会把
    /// 服务器列表、连接状态、事件流一起拖进来 —— 一个权限页不该依赖
    /// 任何一台服务端能不能连上。
    public init(push: PushCoordinator, onFinish: @escaping () -> Void) {
        self.push = push
        self.onFinish = onFinish
    }

    private var center: PermissionCenter { PermissionCenter(push: push) }

    private var presentation: PermissionStepPresentation {
        PermissionOnboarding.presentation(for: flow.current, state: state)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 文案可以滚动，按钮钉在底部。
            //
            // # 为什么不是两个 Spacer 把文案顶到中间
            //
            // 那样写在大字号下会**溢出**：`fixedSize(vertical:)` 的文本
            // 不会被压缩，于是"局域网"那一步（说明 + 补充说明最长）在
            // 辅助功能字号下会把按钮挤出屏幕 —— 而这是用户第一次打开
            // 应用看到的一屏，一个够不到的按钮等于应用不能用。
            //
            // `containerRelativeFrame` 让它在放得下时仍然垂直居中
            // （滚动视图的高度就是容器高度），放不下时才真的滚起来。
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)

                    Text(flow.progress)
                        .font(.caption).foregroundStyle(.tertiary)

                    Text(presentation.title)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(presentation.reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: Theme.messageMaxWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .selectableText()

                    if let footnote = presentation.footnote {
                        Text(footnote)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: Theme.messageMaxWidth, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .selectableText()
                    }

                    // 已经允许之后给一个明确的回执。少了它，用户按完"允许"
                    // 会停在同一个页面上，分不清是成功了还是按钮没反应。
                    if presentation.action == .granted {
                        Label(tr("已允许", "Allowed"), systemImage: "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(.green)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .containerRelativeFrame(.vertical, alignment: .center)
            }

            VStack(spacing: 12) {
                Button {
                    Task { await primary() }
                } label: {
                    HStack {
                        if busy { ProgressView().controlSize(.small) }
                        Text(PermissionOnboarding.primaryLabel(for: presentation,
                                                               isLast: flow.isLast))
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(busy)
                // 已经允许之后按钮只是"下一步"，不再需要强调色；
                // 一直用它反而会让"这里还有事要做"的暗示留着不走。
                .opacity(presentation.action == .granted ? 0.85 : 1)

                Button(tr("跳过", "Skip")) { finish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        // 引导页是**首启**的一屏，因此它不套在导航栈里：没有可以返回的
        // 上一页，而一个返回箭头会让人以为"退出去就能不看权限"。
        //
        // 背景必须是**不透明**的：它是盖在服务器列表之上的（见
        // `ISCMizarApp`），半透明会让下面的空状态按钮透出来 —— 用户会去
        // 点那些按钮，而点击落在引导页上，什么都不会发生。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(.systemBackground).ignoresSafeArea())
        // 每一步进来时重新读一次系统状态 —— 而不是只在开始时读一次：
        // 用户可能刚从系统设置里改完回来（下面那个 scenePhase 也管这件事），
        // 也可能在上一步里刚回答完弹窗。
        .task(id: flow.current) {
            state = await center.state(for: flow.current)
        }
        .onChange(of: scenePhase) { _, phase in
            // 从系统设置返回。不去系统设置的那条路径（点"允许"）由
            // `primary()` 自己刷新，两者不重叠。
            guard phase == .active else { return }
            Task { state = await center.state(for: flow.current) }
        }
    }

    /// 每一步的图标。
    ///
    /// 与 `PermissionStep` 绑在一起而不是由 `presentation` 带出来：
    /// SF Symbol 的名字是**界面**的事，而 `presentation` 里那些字符串
    /// 要能被 `swift test` 覆盖（MizarApp 里没有 SwiftUI）。
    private var symbol: String {
        switch flow.current {
        case .camera: "qrcode.viewfinder"
        case .notifications: "bell.badge"
        case .localNetwork: "wifi"
        }
    }

    /// 主按钮被按下。
    private func primary() async {
        busy = true
        defer { busy = false }

        switch presentation.action {
        case .request:
            state = await center.request(flow.current)
            // 允许了就自动前进：用户已经回答完了，再让他点一次"下一步"
            // 只是多一次点击。被拒时**留在原地** —— 这一页会变成
            // "去系统设置开启"，那才是他现在需要看到的。
            if state == .granted { advance() }

        case .openSettings:
            center.openSettings()

        case .granted, .none:
            advance()
        }
    }

    /// 前进一步；已经是最后一步时结束引导。
    private func advance() {
        if !flow.advance() { finish() }
    }

    private func finish() {
        onFinish()
    }
}
#endif
