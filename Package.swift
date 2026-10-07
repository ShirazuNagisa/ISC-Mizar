// swift-tools-version: 6.4
import PackageDescription
// 清单里要读环境变量（见下面的 MIZAR_DEMO）：tools-version 6 起 Foundation
// 不再随 PackageDescription 一起进来，因此这一行是必需的。
import Foundation

// ---- 演示模式：一个**编译期**开关 ----------------------------------------
//
// # 为什么是编译期而不是运行时
//
// 运行时开关意味着假数据、假站点、假 DNS 记录这些代码与字符串**都会进
// 生产包**。两个后果都是不可接受的：审核员可能在设置里翻到它，而更糟的
// 是"看起来正常、其实在显示假数据"——这个应用存在的全部价值就是那几行
// 数字**是真的**。
//
// 编译期开关让 #if MIZAR_DEMO 之外的一切在生产构建里根本不存在，
// 而这一点是可以验证的：`nm`/`strings` 在生产二进制里搜不到演示数据的
// 标志性字符串（见 Scripts/archive.sh 里的那一步）。
//
// # 为什么用环境变量来驱动，而不是写死
//
// 写死一个 `.define("MIZAR_DEMO")` 就等于演示模式永远开着；而"发版前记得
// 把它注释掉"是那种一定会忘的约定。反过来，写死成"注释掉"则演示模式无法
// 构建。因此它必须是一个**外部**输入：
//
//	MIZAR_DEMO=1 swift build          # 演示构建
//	MIZAR_DEMO=1 ./Scripts/build-ios.sh
//	./Scripts/archive.sh              # 归档脚本里显式 unset（见该脚本）
//
// 危险方向只有一个：开发者终端里 export 过 MIZAR_DEMO=1，然后直接跑归档。
// 那个方向由 archive.sh 兜底——它先 unset，再在产物里验一遍"没有演示
// 字符串"，验不过就失败。
let demoMode = ProcessInfo.processInfo.environment["MIZAR_DEMO"] == "1"

/// 演示构建才带上的编译条件。
///
/// 只装在 MizarApp（数据入口与假内核）与 MizarScreens（"演示数据"横幅）：
/// MizarKit 不装 —— 假内核只是**实现**了它的 `KernelTransport` 协议，
/// 协议本身不需要知道演示模式的存在。
let demoSettings: [SwiftSetting] = demoMode ? [.define("MIZAR_DEMO")] : []

// ISC Mizar —— Phecda 服务端的移动端客户端（iOS / iPadOS / watchOS）。
//
// # 为什么代码分成两个 target
//
//	MizarKit   传输、契约模型、配对、持久化。**只依赖 Foundation**，
//	           因此在 macOS 上就能用 `swift test` 完整验证 ——
//	           而这一块恰好是最需要测试的部分（配对、指纹固定、地址降级、
//	           令牌存储），它们在模拟器上跑既慢又难断言。
//	MizarUI    跨平台的 SwiftUI 组件。它要编译到 iOS 与 watchOS 两边，
//	           因此刻意不碰 UIKit 与 AppKit —— 一旦引入，两个平台就会
//	           各自长出一份分支。
//
// 屏幕本身（App/ 下的 Xcode 工程）不在这个包里：应用包需要 .xcodeproj，
// 而 SwiftPM 不产出 .app。
let package = Package(
    name: "ISC-Mizar",
    platforms: [.iOS("27.0"), .watchOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "MizarKit", targets: ["MizarKit"]),
        .library(name: "MizarUI", targets: ["MizarUI"]),
        .library(name: "MizarApp", targets: ["MizarApp"]),
        .library(name: "MizarScreens", targets: ["MizarScreens"]),
    ],
    targets: [
        .target(
            name: "MizarKit",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .target(
            name: "MizarUI",
            dependencies: ["MizarKit"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ] + demoSettings
        ),
        // 应用层：状态机。
        //
        // # 为什么它也在包里，而不是只存在于 Xcode 工程里
        //
        // Xcode 工程里的代码只能在模拟器（或真机）上编译 —— 那意味着
        // 每次改一行视图都要等一次完整的应用构建，而大部分错误（类型不
        // 匹配、改了模型忘了改调用点）其实是编译期的。
        //
        // 放进包里之后 `swift build` 在 macOS 上就能把这一层全部编译一遍，
        // 而 Xcode 工程只剩下三个很薄的东西：`@main`、Info.plist 与
        // entitlements。
        //
        // 这个 target **要编译到 watchOS**，因此它只放状态机，
        // 不放任何屏幕 —— 屏幕在下面那个 target 里。
        .target(
            name: "MizarApp",
            dependencies: ["MizarKit", "MizarUI"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ] + demoSettings
        ),
        // 屏幕：只在 iOS / iPadOS 上编译。
        //
        // # 为什么不与状态机放在同一个 target 里
        //
        // 手表应用也链接 MizarApp，而它**不需要**这些屏幕。放在一起的话，
        // iPhone 上的每一个视图都要写 `#if !os(watchOS)` —— 那会让二十几个
        // 文件各带一个条件，而其中任何一个漏掉都是一个"手表构建才失败"
        // 的编译错误。按 target 切开之后，平台的边界由构建系统来守。
        //
        // 它同时也在 macOS 上编译：`swift build` 因此能验证全部屏幕代码，
        // 不必等一次完整的模拟器构建。
        .target(
            name: "MizarScreens",
            dependencies: ["MizarKit", "MizarUI", "MizarApp"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ] + demoSettings
        ),
        .testTarget(name: "MizarKitTests", dependencies: ["MizarKit", "MizarApp"],
                    swiftSettings: demoSettings),
        // 验收工具：对着**真实内核**跑一遍配对与连接。
        //
        // 它不是产品的一部分（因此没有对应的 product），存在的理由只有一个：
        // 单元测试里的假传输证明不了"真的能连上"。自签证书的固定、TLS 握手、
        // 候选地址降级这几件事只有在真链路上才能验证 —— 而它们恰好是
        // 这个功能里最可能出问题、也最难在模拟器上排查的部分。
        .executableTarget(
            name: "MizarAcceptance",
            dependencies: ["MizarKit"],
            path: "Tools/MizarAcceptance"),
    ]
)
