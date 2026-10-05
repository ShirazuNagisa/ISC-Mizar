import Foundation
import MizarKit

/// 手表那边的状况 —— "这一份快照要不要投出去"的全部输入。
///
/// # 为什么是一个普通结构体，而不是直接用 `WCSession`
///
/// `WCSession` 只有 iOS / watchOS 有，而"什么时候该推、什么时候**根本
/// 不该碰它**"这件事必须能在 macOS 上用 `swift test` 覆盖。
///
/// 这不是洁癖。真机上那次「应用未响应」正好是这条判断缺失造成的，而它
/// 恰好是**模拟器上唯一跑不到的一类缺陷**：模拟器里 `WCSession.isSupported()`
/// 是 false，整条同步路径连一行都不会执行 —— 于是验收脚本全绿，真机却卡住。
/// 把判断从 `WCSession` 上摘下来之后，那个缺口才有测试能钉住。
public nonisolated struct WatchCounterpart: Sendable, Equatable {
    /// 这台设备支持 WatchConnectivity。
    public var isSupported: Bool
    /// 会话已经激活（没激活时下面两个属性一律读成 false，读它们没有意义）。
    public var isActivated: Bool
    /// 配对了手表。
    public var isPaired: Bool
    /// **那块表上装了本应用。**
    ///
    /// 这一条是这个类型存在的主要理由：没装应用时
    /// `updateApplicationContext` 必定失败，而它是一次到手表守护进程的
    /// **同步 XPC** —— 调一次就阻塞调用方线程一次。
    public var isWatchAppInstalled: Bool

    public init(isSupported: Bool, isActivated: Bool,
                isPaired: Bool, isWatchAppInstalled: Bool) {
        self.isSupported = isSupported
        self.isActivated = isActivated
        self.isPaired = isPaired
        self.isWatchAppInstalled = isWatchAppInstalled
    }

    /// 对端齐不齐（配对了**且**装了应用）。
    ///
    /// 合成一个判断而不是在两个调用点各写一次 `&&`：这两个条件必须同时
    /// 成立才谈得上投递，而漏掉任意一个的后果都是给一次注定失败的同步
    /// XPC 买单。
    public var hasInstalledCounterpart: Bool { isPaired && isWatchAppInstalled }

    /// 按"只在会话激活之后才去读那两个属性"的顺序构造对端状况。
    ///
    /// # 为什么两个取值是**闭包**而不是布尔
    ///
    /// `isPaired` / `isWatchAppInstalled` 只在会话激活之后才有意义（未激活
    /// 时它们恒为 false），而 `WCSession` 的属性读取属于"要与手表守护进程
    /// 打交道"的那一类 —— 而调用方是**主 actor**。未激活时读它们等于为一次
    /// 注定被 `skippedNotActivated` 挡掉的推送白付两遍跨进程代价。
    ///
    /// 传布尔值是拦不住这件事的：参数在调用**之前**就求值了，判断写得再
    /// 对也没用。取值做成闭包之后，"未激活时根本不去读"这句话才有可能被
    /// 断言到 —— 见 `WatchPushTests.anInactiveSessionNeverReadsTheCounterpartProperties`。
    public static func current(isSupported: Bool,
                               isActivated: Bool,
                               isPaired: () -> Bool,
                               isWatchAppInstalled: () -> Bool) -> WatchCounterpart {
        guard isActivated else {
            return WatchCounterpart(isSupported: isSupported, isActivated: false,
                                    isPaired: false, isWatchAppInstalled: false)
        }
        return WatchCounterpart(isSupported: isSupported, isActivated: true,
                                isPaired: isPaired(),
                                isWatchAppInstalled: isWatchAppInstalled())
    }
}

/// 一次推送的结论。
///
/// 返回枚举而不是 `Bool`：调用点要能把"为什么没推"说清楚，而
/// "没配对"与"表上没装应用"对用户是两句不同的话。
public nonisolated enum WatchPushDecision: Equatable, Sendable {
    case pushed
    /// 这台设备不支持 WatchConnectivity。
    case skippedUnsupported
    /// 会话还没激活。
    case skippedNotActivated
    /// 没配对，或者那块表上没装应用 —— **不该发起同步 XPC**。
    case skippedNoCounterpart
    /// 手上没有任何一台可以同步的服务端。
    case skippedNoPayload
    /// 与上一次成功投递的内容一模一样。
    case skippedUnchanged
    /// 已经有一次投递在跑。
    case skippedAlreadyRunning
    case failed(String)
}

/// 真正把上下文交给 WatchConnectivity 的那个口子。
///
/// 抽成协议的**唯一**理由是测试：真实现要做一次同步 XPC，而这里最需要
/// 断言的恰恰是"哪几种情况下它根本不该被调用"。没有这个口子，
/// "没装手表应用时不要再调 `updateApplicationContext`"就只能靠人读代码。
///
/// `nonisolated`：本 target 默认隔离在主 actor 上，而一个具体实现完全可能
/// 是一个 actor（测试里就是）。"在哪个执行器上承担这段阻塞"是实现的自由，
/// 因此这个协议本身不能替它做主。
public nonisolated protocol WatchContextWriter: Sendable {
    /// 投递一份上下文。
    ///
    /// **这是一次阻塞调用**（同步 XPC）。实现必须自己决定在哪个线程上
    /// 承担这段阻塞 —— 调用方（主 actor）在等待期间一定是让出的，
    /// 这一点由实现保证，不能推给调用方。
    func deliver(_ payload: Data) async throws
}

/// 手机 → 手表的推送。
///
/// # 它解决的两个具体问题
///
/// 1. **注定失败的同步 XPC**。原来的代码是"先调用再 `catch`"，而
///    `updateApplicationContext` 不是一次普通的函数调用：它要等手表
///    守护进程回一句结果（真机日志里那句
///    `-[WCSession updateApplicationContext:error:]_block_invoke` 就是
///    它等回来的回复块）。对端没装应用时它一定失败，而这次失败完全
///    可以在调用**之前**用一个本地属性读出来。现在的顺序是：
///    先看 `isPaired` / `isWatchAppInstalled`，不满足就直接回头 ——
///    连载荷都不去准备。
///
/// 2. **一次开屏推三遍**。`onServersChanged` 在冷启动时会从三处被调到
///    （会话激活、服务端列表读完、连接并拉完数据），而每一遍都会走一次
///    上面那次 XPC。`running` + `delivered` 把这一串压成最多一次。
///
/// # 为什么"内容没变就不推"要与"用户手动推"分开
///
/// 自动推送跳过相同内容是对的（内容没变，推了也白推）。但用户按
/// 「同步到 Apple Watch」时**必须**真的投一次：那个按钮覆盖的正是
/// "手表上的应用刚装好、而手机上的配置从那之后没变过" ——
/// `updateApplicationContext` 只在**内容变化**时投递，不去重的话
/// 那个按钮会变成一个按下去什么都不发生的按钮。
@MainActor
public final class WatchPush {

    private let writer: any WatchContextWriter

    /// 已经有一次投递在跑。
    private var running = false

    /// 最近一次**成功投递**的内容。
    ///
    /// 只活在进程内（进程一重启就是 nil）：这样"这次启动之前手表上刚装好
    /// 应用"这种情况不会被当成"内容没变"而跳过 —— 那只表上一次根本没收到
    /// 过任何东西。
    private var delivered: Data?

    public init(writer: any WatchContextWriter) {
        self.writer = writer
    }

    /// 推一次。
    ///
    /// - Parameters:
    ///   - counterpart: 手表那边的状况。**所有**判断都在调 XPC 之前做完。
    ///   - force: 用户明确要求的一次同步（跳过"内容没变"那一关）。
    ///   - build: 取载荷。它可能很贵（每台服务端一次 Keychain 读，
    ///     必要时还有一次到服务端的网络往返），因此**只有在确定要推的
    ///     时候才调用它** —— 顺序在这里是有意义的，不是风格问题。
    @discardableResult
    public func push(counterpart: WatchCounterpart,
                     force: Bool = false,
                     build: () async -> Data?) async -> WatchPushDecision {
        guard counterpart.isSupported else { return .skippedUnsupported }
        guard counterpart.isActivated else { return .skippedNotActivated }
        guard counterpart.hasInstalledCounterpart else { return .skippedNoCounterpart }
        // 判重必须发生在**第一个 await 之前**：`running` 一旦在挂起点之后
        // 才置上，三次同时到达的推送会全部穿过这道门。
        guard !running else { return .skippedAlreadyRunning }

        running = true
        defer { running = false }

        guard let payload = await build() else { return .skippedNoPayload }
        if !force, payload == delivered { return .skippedUnchanged }

        do {
            try await writer.deliver(payload)
        } catch {
            // 对端没装应用已经不在这里了（上面就挡住了）。走到这一句的
            // 是一次真的失败，因此值得说出来 —— 而它不该把界面打断。
            return .failed(error.localizedDescription)
        }
        delivered = payload
        return .pushed
    }
}
