import Testing
import UserNotifications
@testable import MizarKit
@testable import MizarApp

/// 首启权限引导的逻辑。
///
/// # 为什么这些测试值得存在
///
/// 引导页上会出错的地方只有一处：**被拒之后给什么出路**。给错了就是一个
/// 按下去永远失败的按钮 —— 用户会反复点它，而每次点都只是再被系统静默
/// 拒绝一次（`requestAuthorization` 在已经决定过之后不显示任何界面）。
///
/// 另一处是**局域网**：iOS 没有"申请局域网权限"的 API，给它做一个按钮的
/// 后果是那个按钮什么都不做。这一条是这里最该被钉死的规则。
///
/// 这些函数的隔离来自 `MizarApp` 的 `defaultIsolation(MainActor.self)`
/// （它们要调 `tr`），因此测试也标 `@MainActor`。
///
/// 文案的断言刻意**不引入 `tr`**：那需要测试 target 直接依赖 MizarUI，
/// 而"这一句究竟是中文还是英文"正是本仓库里最不值得断言的东西。这里断言
/// 的是结构与分支 —— 那才是会真的坏掉的部分。

// MARK: - 顺序

/// 三步的顺序按"用户什么时候真的需要它"排。
///
/// 顺序本身是产品决定，因此把它写成断言：改它是可以的，但那要是一次
/// **有意的**修改，而不是某次重构顺手换掉的。
@Test func permissionStepsAreOrderedByWhenTheyAreNeeded() {
    #expect(PermissionStep.allCases == [.camera, .notifications, .localNetwork])
}

// MARK: - 局域网：只能是说明

/// 局域网**永远**不可申请。
///
/// 这一条是本次改动里最容易做错的地方：给它一个"允许"按钮看起来很自然
/// （另外两项都有），而那个按钮按下去不会有任何系统弹窗 —— 用户会以为
/// 应用坏了。
@Test func localNetworkIsNeverRequestable() {
    #expect(PermissionStep.localNetwork.isRequestable == false)
    #expect(PermissionStep.camera.isRequestable)
    #expect(PermissionStep.notifications.isRequestable)
}

/// 无论传进来什么状态，局域网那一步都不能变成一个按钮。
///
/// 逐个状态地断言，而不是只断言 `isRequestable`：真正会被渲染出来的是
/// `presentation`，而"状态传错了"是这里唯一会出的事。
@MainActor
@Test func localNetworkStepNeverOffersAnAction() {
    for state in [PermissionStepState.notDetermined, .granted, .denied, .notRequestable] {
        let presentation = PermissionOnboarding.presentation(for: .localNetwork, state: state)
        #expect(presentation.action == .none, "状态 \(state) 下局域网不该有按钮")
        // 必须解释"为什么没有按钮"，否则用户会把这一页读成卡住了。
        #expect(presentation.footnote?.isEmpty == false, "状态 \(state) 下局域网必须给出说明")
    }
}

// MARK: - 被拒之后

/// 被拒之后给的是"去系统设置"，而不是一个再点一次的"允许"。
@MainActor
@Test func deniedPermissionOffersSystemSettings() {
    for step in [PermissionStep.camera, .notifications] {
        let presentation = PermissionOnboarding.presentation(for: step, state: .denied)
        #expect(presentation.action == .openSettings, "\(step) 被拒后应当引导去系统设置")
        #expect(presentation.footnote?.isEmpty == false, "\(step) 被拒后应当说明系统不会再问")
    }
}

/// 还没问过时给的是"允许"。
@MainActor
@Test func undeterminedPermissionOffersARequest() {
    for step in [PermissionStep.camera, .notifications] {
        #expect(PermissionOnboarding.presentation(for: step, state: .notDetermined).action == .request)
    }
}

/// 已经允许之后不再显示一个"允许"按钮。
///
/// 那会让用户以为还没生效，于是反复点一个**不会弹框**的按钮。
@MainActor
@Test func grantedPermissionOffersNoSecondPrompt() {
    for step in [PermissionStep.camera, .notifications] {
        #expect(PermissionOnboarding.presentation(for: step, state: .granted).action == .granted)
    }
}

/// 主按钮的字必须与它真正会做的事一致。
///
/// 一个写着"允许"却什么都不弹的按钮是这次改动最坏的失败形态，因此这里
/// 逐个 action 地钉住它：四种情况里只有"现在真的会弹系统框"那一种的措辞
/// 与另外三种不同。
@MainActor
@Test func primaryLabelMatchesWhatTheButtonActuallyDoes() {
    func label(_ step: PermissionStep, _ state: PermissionStepState, last: Bool = false) -> String {
        PermissionOnboarding.primaryLabel(
            for: PermissionOnboarding.presentation(for: step, state: state), isLast: last)
    }

    let allow = label(.camera, .notDetermined)
    let settings = label(.camera, .denied)
    let next = label(.camera, .granted)
    let done = label(.camera, .granted, last: true)

    #expect(allow != settings, "「允许」与「去系统设置」不能是同一句话")
    #expect(allow != next)
    #expect(settings != next)
    // 最后一步换一个说法，否则引导走完了却还写着"下一步"。
    #expect(next != done)
    // 说明性的那一步与"已经允许"一样，都只是往前走。
    #expect(label(.localNetwork, .notRequestable) == next)
    // "去系统设置"是唯一的出路，与这是第几步无关。
    #expect(label(.camera, .denied, last: true) == settings)
}

// MARK: - 推进

/// 走完三步之后 `advance` 返回 false（调用方据此关闭引导），
/// 而且**下标不会越界** —— 越界会渲染出一个空白的引导页。
@Test func permissionFlowStopsAtTheEndWithoutOverrunning() {
    var flow = PermissionFlow(steps: [.camera, .localNetwork])

    #expect(flow.current == .camera)
    #expect(flow.isLast == false)
    #expect(flow.advance() == true)

    #expect(flow.current == .localNetwork)
    #expect(flow.isLast)

    // 已经到最后一步：再推一次只是"该结束了"，而不是把下标推出去。
    #expect(flow.advance() == false)
    #expect(flow.current == .localNetwork)
    #expect(flow.advance() == false)
    #expect(flow.current == .localNetwork)
}

/// 进度文案要随步骤变化，并且在最后一步仍然读得出总数。
///
/// 不断言具体字面（那随语言变），只断言"第几步"和"共几步"两个数字都在，
/// 且相邻两步的说法不同。
@MainActor
@Test func permissionFlowProgressAdvances() {
    var flow = PermissionFlow(steps: [.camera, .notifications, .localNetwork])
    let first = flow.progress

    #expect(first.contains("1"))
    #expect(first.contains("3"), "总数必须出现在进度里")

    _ = flow.advance()
    let second = flow.progress
    #expect(second != first)
    #expect(second.contains("2"))

    _ = flow.advance()
    #expect(flow.progress.contains("3"))
    #expect(flow.isLast)
}

// MARK: - 一次性

/// 引导只出现一次 —— 这就是"一次性"的全部含义。
@MainActor
@Test func onboardingIsOneShot() {
    #expect(PermissionOnboarding.shouldPresent(completed: false))
    #expect(PermissionOnboarding.shouldPresent(completed: true) == false)
}

/// 标记带版本后缀。
///
/// 不带版本的话，把引导内容改成四步之后老用户永远看不到新增的那一步；
/// 而改这个字符串是一次**需要人做**的决定（旧标记作废，所有人再看一次）。
@MainActor
@Test func onboardingMarkerIsVersioned() {
    #expect(PermissionOnboarding.completedKey.hasSuffix(".v1"))
    #expect(PermissionOnboarding.completedKey.hasPrefix("app.isc.mizar."))
}

// MARK: - 文案

/// 每一步都得有标题与理由。
///
/// 理由不是可选的：一个不知道用途的权限框，用户的本能是点"不允许"。
@MainActor
@Test func everyStepExplainsItself() {
    for step in PermissionStep.allCases {
        for state in [PermissionStepState.notDetermined, .granted, .denied, .notRequestable] {
            let presentation = PermissionOnboarding.presentation(for: step, state: state)
            #expect(presentation.title.isEmpty == false, "\(step)/\(state) 没有标题")
            #expect(presentation.reason.isEmpty == false, "\(step)/\(state) 没有说明")
        }
    }
}

/// 三步的标题必须互不相同。
///
/// 三次看到同一句话会把引导读成"它在重复问同一件事"，而用户于是开始
/// 一路点下去 —— 那正是这次拆分要避免的。
@MainActor
@Test func eachStepHasItsOwnTitle() {
    let titles = PermissionStep.allCases.map {
        PermissionOnboarding.presentation(for: $0, state: .notDetermined).title
    }
    #expect(Set(titles).count == titles.count, "有步骤的标题撞车了：\(titles)")
}

// MARK: - 系统授权状态 → 引导状态

/// 通行与安静送达都算"能收到"。
///
/// `provisional`（安静送达）这一条容易被漏掉：用户没有点过"允许"，
/// 系统给的也不是 `.authorized`，但通知**确实会送到**。漏掉它的症状是
/// 引导页与设置页一直劝用户去开一个已经开着的开关。
///
/// `ephemeral`（App Clip）只写在 `swift test` 跑不到的地方（macOS 上没有
/// 这个 case），因此这里只覆盖前两个 —— 它在实现里与 `provisional`
/// 同一支。
@MainActor
@Test func authorizedNotificationStatesCountAsGranted() {
    for status in [UNAuthorizationStatus.authorized, .provisional] {
        #expect(PermissionOnboarding.state(forAuthorization: status) == .granted,
                "\(status) 应当算已授权")
    }
}

/// 拒绝与未决定必须分开。
///
/// 合成一个布尔的话，被拒的用户会看到一个"允许"按钮 —— 而它按下去
/// 什么都不会发生（系统只会问一次）。这正是一次真实的改动：
/// 设置页里原来就是一个 `Bool`。
@MainActor
@Test func deniedAndUndeterminedNotificationStatesStayApart() {
    #expect(PermissionOnboarding.state(forAuthorization: .denied) == .denied)
    #expect(PermissionOnboarding.state(forAuthorization: .notDetermined) == .notDetermined)
}

/// 映射结果直接决定按钮：被拒 → 去系统设置，未决定 → 允许。
@MainActor
@Test func notificationStateDrivesTheButton() {
    let denied = PermissionOnboarding.presentation(
        for: .notifications,
        state: PermissionOnboarding.state(forAuthorization: .denied))
    let fresh = PermissionOnboarding.presentation(
        for: .notifications,
        state: PermissionOnboarding.state(forAuthorization: .notDetermined))

    #expect(denied.action == .openSettings)
    #expect(fresh.action == .request)
    #expect(denied.action != fresh.action)
}
