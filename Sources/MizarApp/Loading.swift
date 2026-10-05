import Foundation
import MizarKit

/// 界面在数据到位之前要显示的加载态。
///
/// # 它为什么不等于 `SessionState.connecting`
///
/// `SessionState` 回答的是"这台服务端的**连接**处于什么状态"，而这里回答
/// 的是"界面现在能不能显示东西"。两者在三种情况下会分叉：
///
///	连上了但数据还在拉（`online` + 七个请求在途）—— 连接已经成功，
///	而界面上什么都没有。少了这一层，那几秒会显示"还没有站点"。
///
///	从后台回来时的静默重连 —— `enterForeground` 会把状态重新标成
///	`connecting`，可**手上已经有数据**了。这时把界面换成转圈是倒退：
///	用户切回来看到的应该是上次的读数在刷新，而不是又一块加载屏。
///	（`AppModel.beginLoading` 里那条 `hasLoadedData` 判断就是这件事。）
///
///	读本机记录的那几百毫秒 —— 那一段根本还没有"当前服务端"，
///	可第一帧已经画出来了。少了它，冷启动的第一帧是"还没有服务端，
///	去扫码添加"，而用户明明有三台。
///
/// # 为什么文字在模型里就拼好
///
/// 视图层（`MizarUI` 的 `LoadingPanel`）只认识 `title` / `detail` 两个
/// 字符串，不认识"候选地址""竞速"这些概念。这样"加载时到底说了什么"
/// 在一个地方能读全，并且能在 `swift test` 里断言 —— 而 SwiftUI 的
/// 布局断言不出来。
public struct LoadingStatus: Equatable, Sendable {
    /// 正在加载哪台服务端。还在读本机记录时为 nil。
    public var serverID: String?
    /// 那台服务端的名字（读记录时为 nil）。
    public var serverName: String?
    /// 已经连上的地址。连上之前为 nil。
    public var address: String?

    /// 主句：正在做什么。
    public var title: String
    /// 副句：**会随时间变化**的那一行。它变了，才说明真的在动。
    public var detail: String
    /// 这一次加载是什么时候开始的。界面用它显示"已经等了 N 秒"。
    public var startedAt: Date

    public init(serverID: String? = nil,
                serverName: String? = nil,
                address: String? = nil,
                title: String,
                detail: String,
                startedAt: Date = Date()) {
        self.serverID = serverID
        self.serverName = serverName
        self.address = address
        self.title = title
        self.detail = detail
        self.startedAt = startedAt
    }

    // MARK: - 三个阶段的文案

    /// 还在读本机保存的服务端列表。
    ///
    /// 这一条必须存在：`servers` 为空有"读完了确实没有"与"还没读"两种
    /// 含义，而第一帧只有后者是真的。见 `AppModel.hasLoadedServers`。
    public static func openingRecords(at date: Date = Date()) -> LoadingStatus {
        LoadingStatus(
            title: tr2("正在打开 Mizar…", "Opening Mizar…"),
            detail: tr2("正在读取本机保存的服务端", "Reading the servers saved on this device"),
            startedAt: date)
    }

    /// 开始连一台服务端：所有候选地址已经同时发出。
    public static func connecting(serverID: String, name: String,
                                  total: Int, at date: Date = Date()) -> LoadingStatus {
        LoadingStatus(
            serverID: serverID,
            serverName: name,
            title: tr2("正在连接 \(name)…", "Connecting to \(name)…"),
            detail: racingDetail(total: total, finished: 0),
            startedAt: date)
    }

    /// 已经连上某个地址，接下来是拉数据。
    public mutating func connected(address: String) {
        self.address = address
        detail = tr2("已连上 \(address)，正在读取数据…",
                     "Connected to \(address); reading data…")
    }

    /// 竞速的进度变了。
    ///
    /// 连上之后就不再报竞速进度了 —— 那时用户要看的是"在拉什么数据"，
    /// 而"8 条里 3 条没回应"已经是一句历史。
    public mutating func racing(_ progress: ConnectProgress) {
        guard address == nil else { return }
        detail = Self.racingDetail(total: progress.total, finished: progress.finished)
    }

    /// 七个数据请求完成了几个。
    public mutating func fetching(done: Int, of total: Int) {
        // 连上之后的每一行都带上那个地址：它是用户唯一能自己核对的
        // 东西（"我扫的那台机器是 192.168.1.10"）。
        let prefix = address.map { tr2("已连上 \($0) · ", "Connected to \($0) · ") } ?? ""
        detail = prefix + tr2("正在读取数据（\(done)/\(total)）",
                              "Reading data (\(done)/\(total))")
    }

    /// 竞速那一行的文案。
    ///
    /// 第一句刻意**不提失败**："同时尝试 8 条地址"说的是"我们在做什么"，
    /// 而"1 条没回应"在 0.1 秒内就会出现 —— 过早报失败只会让人以为要
    /// 出事。第二句才是进度，它随每一条候选得到结论而变化。
    private static func racingDetail(total: Int, finished: Int) -> String {
        // 只有一条候选地址时说"同时尝试 1 条"是一句古怪的话，而它恰好是
        // 最常见的一种配置 —— 只连局域网的一台机器。
        if total <= 1 {
            return tr2("正在等这台服务端回应", "Waiting for this server to answer")
        }
        if finished == 0 {
            return tr2("正在同时尝试 \(total) 条地址",
                       "Trying \(total) addresses at once")
        }
        return tr2("\(total) 条地址中已有 \(finished) 条没有回应",
                   "\(finished) of \(total) addresses have not answered")
    }
}
