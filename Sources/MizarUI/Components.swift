import SwiftUI
import Foundation
import MizarKit

/// 字节、速率、百分比与时长。
///
/// 单独放在一处而不是散在视图里：同一台机器上的"内存"与"磁盘"必须用
/// 同一个口径显示，否则用户会看到两个看起来不一致的数字并怀疑其中一个。
extension Int {
    /// 人类可读的字节数。
    ///
    /// 零单独处理：`ByteCountFormatter` 会说 "Zero KB"，而那是错的
    /// （它是零字节，不是一个千字节）。
    public var formattedBytes: String {
        if self == 0 { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .memory)
    }
}

extension Double {
    /// 传输速率。
    public var formattedRate: String {
        if self < 1 { return "0 B/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .decimal) + "/s"
    }

    /// 占比（0…1）显示成百分比。
    public var formattedPercent: String {
        String(format: "%.0f%%", self * 100)
    }

    /// 已经是一个百分比数字（0…100）。
    public var formattedPercentValue: String {
        String(format: "%.0f%%", self)
    }
}

extension Int64 {
    /// 时长。
    ///
    /// 超过一天就只说天：`uptime` 到了 37 天还显示 "888h" 对谁都没有用。
    public var formattedDuration: String {
        let seconds = Swift.max(0, self)
        if seconds < 60 { return "\(seconds) 秒" }
        if seconds < 3600 { return "\(seconds / 60) 分钟" }
        if seconds < 86_400 { return "\(seconds / 3600) 小时" }
        return "\(seconds / 86_400) 天"
    }
}

/// 一张指标卡。
///
/// # 高度是**钉死**的
///
/// 三张卡并排时，各自的内容行数不同（"42%" 与 "12.3 GB / 16 GB" 与
/// "0 B/s ↑ 0 B/s ↓"）会让它们长得不一样高，而那种参差看起来像界面坏了。
/// 因此第三行固定一个高度，而不是让它按内容伸缩 —— 这是 ISC-Phecda 那边
/// 用真实截图换来的教训（见 ISC-Core 的 D33）。
public struct MetricCard: View {
    public enum Detail: Equatable {
        case fraction(Double)
        case text(String)
    }

    public let title: String
    public let value: String
    public let detail: Detail
    public let symbol: String
    public let tint: Color
    /// 后端不支持时的说明。有值时卡片显示它而不是数字 ——
    /// 显示一个假的 0% 比什么都不显示更糟。
    public let unsupported: String?

    private static let detailHeight: CGFloat = 16

    public init(title: String, value: String, detail: Detail, symbol: String,
                tint: Color = .accentColor, unsupported: String? = nil) {
        self.title = title
        self.value = value
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
        self.unsupported = unsupported
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption).foregroundStyle(tint)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }

            if let unsupported {
                Text(unsupported)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Group {
                switch detail {
                case .fraction(let value):
                    ProgressBar(fraction: value, tint: tint)
                case .text(let text):
                    Text(text).font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .frame(height: Self.detailHeight, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cardRadius))
    }
}

/// 一条横向占比条。
public struct ProgressBar: View {
    public let fraction: Double
    public let tint: Color

    public init(fraction: Double, tint: Color = .accentColor) {
        self.fraction = fraction
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.4))
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

/// 一条迷你曲线。
///
/// 只用来表示"最近这段时间的趋势"，因此刻意**没有坐标轴、没有刻度、
/// 没有交互** —— 那些东西在这么小的尺寸上只会变成噪点。要看具体数字
/// 的人会去看它上面的那个值。
public struct Sparkline: View {
    public let values: [Double]
    public let tint: Color

    public init(values: [Double], tint: Color = .accentColor) {
        self.values = values
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { geometry in
            let points = normalized(in: geometry.size)
            if points.count > 1 {
                Path { path in
                    path.move(to: points[0])
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }

    private func normalized(in size: CGSize) -> [CGPoint] {
        guard values.count > 1, let maxValue = values.max(), maxValue > 0 else { return [] }
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            // 上限固定成 100：CPU 曲线的形状只有在纵轴固定时才有意义，
            // 按本次最大值缩放会让 3% 的波动看起来像满负荷。
            let ratio = min(1, max(0, value / 100))
            return CGPoint(x: CGFloat(index) * step,
                           y: size.height * (1 - ratio))
        }
    }
}

/// 空状态、错误状态与引导。
///
/// # 宽度与高度必须**同时**钉住
///
/// 这是 ISC-Core 的 D33 用一次真实缺陷换来的：一句很长的、不可断开的话
/// （比如一个 URL 或一句拼接出来的错误）会把自己的理想宽度与理想高度
/// 一起向上传播，把整个布局撑坏 —— 而症状是"某个完全无关的区域变成
/// 空白"。两个常量从这里引用，不允许各处自己写一个。
public struct EmptyHint: View {
    public let symbol: String
    public let title: String
    public let message: String
    public var action: (label: String, run: () -> Void)?

    public init(symbol: String, title: String, message: String,
                action: (label: String, run: () -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Theme.messageMaxWidth)
                .lineLimit(Theme.messageMaxLines)
                .fixedSize(horizontal: false, vertical: true)
                .selectableText()
            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(.glassProminent)
                    .padding(.top, 2)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 一行"标签 / 值"。
public struct InfoRow: View {
    public let label: String
    public let value: String
    public var monospaced: Bool
    public var tint: Color?

    public init(label: String, value: String, monospaced: Bool = false, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
        self.tint = tint
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(tint ?? .primary)
                .multilineTextAlignment(.trailing)
                // 长值（域名的逗号列表、IPv6 地址）必须能在窄屏上折行，
                // 而不是把整行撑宽。
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 一张分组的卡片。
public struct Card<Content: View>: View {
    public let title: String?
    @ViewBuilder public let content: Content

    public init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cardRadius))
    }
}


/// 连接中/还未拿到数据时的占位骨架。
///
/// # 它在新的加载态里还剩什么位置
///
/// 冷启动与服务端切换那两条路现在走 `LoadingPanel`（转圈 + 会变的状态
/// 文字）—— **静态**骨架在那两条路上是错的：它长得像"已经渲染完了但内容
/// 是空的"，而不是"正在加载"，用户的读法是"卡住了"。
///
/// 骨架仍然有用，但只在**局部**：页签已经在屏幕上、而某一项数据还没到
/// 的那一小段时间。那时把这一页的形状先摆出来（"这里会有一列东西"）比
/// 再插一个转圈更有信息量 —— 页面的骨架没有变，只是内容还没填。
///
/// # 它为什么在动
///
/// 静止的灰条与"界面冻住了"在视觉上是同一件事。一层缓慢的明暗呼吸
/// 是这里最便宜、也最不需要解释的存活信号（`SkeletonPulse`）。
///
/// # 为什么画的是几何形状，而不是给真实内容套 `.redacted`
///
/// `.redacted(reason: .placeholder)` 的前提是"内容已经在手上、只是还不能
/// 显示"（余额、还没揭晓的分数）—— 而这里手上**什么都没有**，没有东西
/// 可以遮蔽。骨架要的是"这一页将要有几行、每行大概多高"，那必须自己画。
public struct SkeletonRows: View {
    /// 画几行。默认三行：它足够表达"这里是一列东西"，
    /// 再多只会让骨架屏自己变成一个需要等的画面。
    public let rows: Int
    /// 行高。默认取正文字号。
    public let height: CGFloat

    public init(rows: Int = 3, height: CGFloat = 14) {
        self.rows = rows
        self.height = height
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<rows, id: \.self) { index in
                // 首行短一点：一列"短标题 + 长内容"比几行等长的灰条
                // 更像真实内容正在加载，而不是一块遮罩。
                RoundedRectangle(cornerRadius: 4)
                    .frame(width: index == 0 ? 64 : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: height)
            }
        }
        .foregroundStyle(.quaternary)
        .skeletonPulse()
        .accessibilityLabel(tr("正在读取…", "Loading…"))
    }
}

/// 整页的卡片骨架。
///
/// 用在"详情页已经在屏幕上、但某一项数据还没到"的那一小段时间 ——
/// 页签内部的骨架管不到它。它自己**不带** `ScrollView`：调用方要么
/// 已经在滚动容器里（页签），要么自己包一层。
public struct SkeletonCards: View {
    public let cards: Int

    public init(cards: Int = 3) {
        self.cards = cards
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<cards, id: \.self) { index in
                Card {
                    SkeletonRows(rows: index == 1 ? 2 : 3)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(tr("正在读取…", "Loading…"))
    }
}

/// 数据到位之前的那一块加载态。
///
/// # 它要回答的问题是"应用是不是死了"
///
/// 用户分不清"网络慢"与"应用卡了"，而这两件事在屏幕上的区别只有一个：
/// **有没有东西在变**。因此这里刻意同时给三个层次的"在动"：
///
///	1. `ProgressView` —— 系统画的转圈。它由渲染服务驱动，**不占主线程**
///	   （这一条是前提：如果主线程真的被占住，什么动画都会停，
///	   再好的加载态也救不了）。
///	2. `title` / `detail` —— **会变**的文字。`detail` 由模型推进
///	   （"8 条地址中已有 3 条没有回应" → "正在读取数据（4/7）"），
///	   它不是装饰：一个转了 30 秒而一个字都没变的转圈，与死机给用户的
///	   感受是一样的。
///	3. `ElapsedLine` —— 等了多久。**只在超过 1 秒之后出现**，向上计数，
///	   没有进度条、没有百分比、没有预计剩余时间。理由是取舍：短等待
///	   不需要它（多一行文字只是噪音），而长等待里它把"卡住了"变成
///	   "这件事确实慢，已经 7 秒了" —— 让人能做决定的是时长，不是动画。
///	   反过来做成倒计时或假的百分比，只会把"我在等"变成"我该催它"。
///	   （门槛为什么从 3 秒改成 1 秒，见 `ElapsedLine`。）
///
/// # 为什么它自带一层不透明背景
///
/// 它的用法有两种：盖住整个窗口（冷启动）与只盖详情页（切换服务端）。
/// 两种都要**挡住**下面还没准备好的界面 —— 半透明的加载态会让用户看到
/// 底下那个"还没有服务端"的空状态，而那正是这一层要避免的误读。
public struct LoadingPanel: View {
    public let title: String
    public let detail: String
    /// 这次加载是什么时候开始的。
    public let startedAt: Date

    public init(title: String, detail: String, startedAt: Date) {
        self.title = title
        self.detail = detail
        self.startedAt = startedAt
    }

    public var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                // 宽度与高度都要钉住（ISC-Core 的 D33）：状态文字里有
                // 地址（可能是很长的 IPv6），它会把自己的理想宽度向上
                // 传播，把整块布局撑坏。
                .frame(maxWidth: Theme.messageMaxWidth)
                .fixedSize(horizontal: false, vertical: true)

            ElapsedLine(startedAt: startedAt)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        // 转圈与文字是同一个"正在做这件事"的整体：VoiceOver 逐个读
        // 会把一句完整的状态拆成三段。
        .accessibilityElement(children: .combine)
    }
}

/// 已经等了多久。
///
/// 秒数由 `TimelineView` 每秒推进一次 —— 这个视图只有一块很小的文字，
/// 因此每秒重画的代价可以忽略；而它换来的正是"屏幕上有东西在动"这一条
/// 最直接的证据。
///
/// # 第几秒开始显示：1 秒，而不是 3 秒
///
/// 一开始写的是 3 秒，理由是"短等待不需要它"。在模拟器上实拍之后这个
/// 数字被改掉了：一场候选地址竞速的超时预算只有 4 秒（
/// `ServerSession.probeTimeout`），而**一条都不回应**（Phecda 关机、
/// 或者手机连着一个不再存在的网段）时，那 4 秒里没有任何一条失败可报
/// —— 状态文字整段不变。3 秒的门槛意味着秒表只来得及露一秒，甚至一次
/// 都不露：实测时那一行自始至终没出现过，屏幕上就是一个不动的转圈加
/// 一句不变的字，正是这一层要消灭的东西。
///
/// 1 秒的依据：局域网里的连接正常在几十毫秒内结束，这个数字根本不会
/// 出现；而超过一秒的等待，已经是用户开始怀疑"是不是卡住了"的时刻。
///
/// # 为什么空间是**预留**的
///
/// 那一行始终占着位置，只是用透明度淡入。否则它出现的那一刻会把上面
/// 三行整体顶上去十几点 —— 一次莫名其妙的跳动比多一行小字更容易让人
/// 以为界面出了问题。
private struct ElapsedLine: View {
    let startedAt: Date

    private static let threshold: TimeInterval = 1

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let seconds = Int(context.date.timeIntervalSince(startedAt).rounded(.down))
            Text(tr("已等待 \(seconds) 秒", "\(seconds) s and counting"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .opacity(seconds >= Int(Self.threshold) ? 1 : 0)
                // 每秒都变的东西不该被反复播报：用户要听的是状态，
                // 不是一只秒表。
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// 给骨架加一层缓慢的明暗呼吸。
    ///
    /// 降低动效打开时**不动**：那是一个明确的系统偏好，而这里的动画
    /// 本来只是"我还活着"的信号 —— 加载态上面的转圈与状态文字仍然
    /// 在告诉用户同一件事。
    func skeletonPulse() -> some View {
        modifier(SkeletonPulse())
    }
}

private struct SkeletonPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.45 : 0.95)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}


extension View {
    /// 让文本可被选中复制。
    ///
    /// watchOS 上不存在这个能力（手表上没有"选中并复制"这回事），
    /// 因此那里它是空操作。包成一处而不是在每个调用点写 `#if`：
    /// 后者会让二十几个地方各带一个条件，而漏掉任何一个都是一次
    /// "手表构建才失败"的编译错误。
    public func selectableText() -> some View {
        #if os(watchOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }
}
