import SwiftUI

/// 演示构建里的一条"演示数据"徽标；生产构建里它什么都不画。
///
/// # 它为什么在 MizarUI 里，而不是直接写在需要它的那个屏幕上
///
/// 需要它的地方是**手表**，而手表的屏幕在 Xcode 工程里
/// （`App/Mizar-watchOS/MizarWatchApp.swift`）—— 那里**拿不到**
/// `MIZAR_DEMO` 这个编译条件：它由 `Package.swift` 只装在包的 target 上
/// （见 Package.swift 的说明）。
///
/// 因此判据放在这里、调用点写成无条件的 `DemoBadge()`：
///
///	演示构建：一条橙色提示；
///	生产构建：`EmptyView()` —— 连一个字符串都不剩。
///
/// 注意这个类型在生产构建里**也存在**（只是 body 是空的）。整体包在
/// `#if` 里是不行的：那样调用点在生产构建里会找不到类型，编译不过。
///
/// # 手表为什么也需要它
///
/// 一开始的判断是"演示模式只在 iOS 生效"。实际不是：手表链接的是同一个
/// `MizarApp`，`AppModel()` 于是给出同一份演示数据 —— 手表上会显示
/// "书房的 Mac mini · 已连接"和一串指标。**没有这条徽标，那一切看起来
/// 完全是真的**，而"演示模式必须看得出来是演示"是这件事的硬要求。
public struct DemoBadge: View {
    public init() {}

    public var body: some View {
        #if MIZAR_DEMO
        HStack(spacing: 4) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.orange)
            Text(tr("演示数据", "Demo data"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        #else
        // 生产构建：这里没有视图，也没有"演示""demo"这类字样。
        EmptyView()
        #endif
    }
}
