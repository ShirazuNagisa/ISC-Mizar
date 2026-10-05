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
/// # 为什么是骨架，而不是转圈，也不是空状态
///
/// "转圈"只说明进程在忙，它不告诉用户这一页**将要有**什么；而空状态
/// （"还没有站点"）在数据还没到的那几秒里是一句**假话** —— 用户会以为
/// 配置丢了，然后去做一些没必要的事（重新配对、重启内核）。
///
/// 骨架把页面的形状先摆出来，数据到了就地替换：感知是"内容立刻出现，
/// 正在填"，而不是"点了没反应"或"东西没了"。
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
        .accessibilityLabel(tr("正在读取…", "Loading…"))
    }
}

/// 整页的卡片骨架。
///
/// 用在"详情页已经在屏幕上、但数据还没到"的那一小段时间 ——
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
