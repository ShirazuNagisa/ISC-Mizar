import Foundation

/// 服务端列表的**导航**选中项。
///
/// # 它为什么不能直接用 `AppModel.selectedServerID`
///
/// 这两个问题看起来是同一个（"现在看的是哪一台"），但在 iPhone 上不是。
///
/// 紧凑宽度下的 `NavigationSplitView` 把"列表的选中项"当作**导航状态**用：
/// 它是靠这个值决定该显示列表还是详情。用户从详情返回列表时，系统会把
/// 这个值写成 `nil` —— 那是"回到列表"，同时也是它**为自己**做的复位
/// （"为下一次选择做准备"）。这一点在 Apple 开发者社区里被反复确认过。
///
/// 而 `selectedServerID` 回答的是另一个问题："我正在看哪一台的数据"。
/// 它**不能**因为用户返回列表就变空：那会让 iPad 上的详情栏一起空掉
/// （两台设备上是同一份代码），也会把这个应用的"一次只看一台"那条不变量
/// 弄丢。
///
/// # 两个都必须保住，否则症状是"点不进去"
///
/// 原来的绑定是
///
///     Binding(get: { model.selectedServerID },
///             set: { if let id = $0 { model.select(id) } })
///
/// 那个 `if let` 把系统写回来的 `nil` **吞掉了**：界面显示的值一直是
/// 同一台，于是系统那一侧的选中状态永远回不到"可以再选一次"。回到列表
/// 之后，那一行**再也点不进去** —— 点下去 selection 从 A 变成 A，
/// 没有任何变化，也就没有任何导航。
///
/// 因此这里的分工是：
///
///	系统写什么就存什么（包括 nil）—— 这一步是让"再选一次"成立的前提。
///	nil 只表示"界面回到了列表"，**不**去动模型里正在看的那一台。
///	模型换了当前那一台时（配对、通知深链、删掉当前这台）单向同步回来，
///	  列表的高亮才不会与详情对不上。
///
/// 做成一个能被 `swift test` 直接驱动的值类型，而不是把这三句话写在视图
/// 里：视图里那一段是断言不出来的，而这三条恰好是"点不进去"这类缺陷
/// 唯一会出问题的地方。
///
/// `nonisolated`：它只是一组纯值变换，与界面线程无关（本 target 默认隔离
/// 在主 actor 上）。挂在主 actor 上的话，测试与视图都要为它多一次跳转，
/// 而它换来的只是"这段逻辑必须跑在界面上"这样一句不成立的话。
public nonisolated struct ServerListSelection: Equatable, Sendable {

    /// 界面这一侧的选中项。nil = 正看着列表。
    public private(set) var highlighted: String?

    /// 上一次从模型同步过来的那一台。
    ///
    /// 它的唯一用途是**不要**在用户返回列表之后把高亮又拉回来：
    /// 系统把选中项清成 nil 之后，模型那边并没有任何变化，同步逻辑
    /// 不该因此再写一次。
    private var syncedFromModel: String?

    public init(highlighted: String? = nil) {
        self.highlighted = highlighted
        self.syncedFromModel = highlighted
    }

    /// `List(selection:)` 的 getter。
    public var value: String? { highlighted }

    /// `List(selection:)` 的 setter 的决策。
    ///
    /// - Parameter newValue: 系统写回来的值，**可能是 nil**。
    /// - Returns: 要交给 `AppModel.select` 的服务端 id；nil 表示这一次
    ///   写入只是"回到了列表"，没有任何要打开的东西。
    @discardableResult
    public mutating func apply(_ newValue: String?) -> String? {
        // 先原样存下来。这一句是整件事的关键：吞掉 nil 就等于告诉系统
        // "选中项没变"，系统的复位因此永远做不成。
        highlighted = newValue
        return newValue
    }

    /// 模型换了"正在看哪一台" → 列表跟着高亮。
    ///
    /// 已经同步过的值不再重复写：用户返回列表（`apply(nil)`）之后模型
    /// 并没有变，这里再写一次会把高亮拉回来，于是列表又变成"已经进入过"
    /// 的样子 —— 那正是"再选一次"失效的那种状态。
    public mutating func syncFromModel(_ open: String?) {
        guard open != syncedFromModel else { return }
        syncedFromModel = open
        highlighted = open
    }
}
