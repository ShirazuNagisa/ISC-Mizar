// swift-tools-version: 6.4
import PackageDescription

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
            ]
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
            ]
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
            ]
        ),
        .testTarget(name: "MizarKitTests", dependencies: ["MizarKit", "MizarApp"]),
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
