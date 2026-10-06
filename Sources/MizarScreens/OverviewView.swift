import SwiftUI
import MizarKit
import MizarApp
import MizarUI

/// 概览：这台服务器现在怎么样。
///
/// 顺序是按"用户打开应用时最想知道什么"排的：先看有没有事要处理
/// （建议），再看资源，最后才是设备信息与证书这类偶尔才看一眼的东西。
struct OverviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            if model.hasLoadedData {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.advisories.isEmpty {
                        Card(tr("需要处理", "Needs attention")) {
                            ForEach(model.advisories) { advisory in
                                AdvisoryRow(advisory: advisory)
                            }
                        }
                    }

                    metricsRow

                    if let metrics = model.metrics, let history = metrics.history, history.count > 1 {
                        Card(tr("最近的 CPU", "Recent CPU")) {
                            Sparkline(values: history.map(\.cpuPercent))
                                .frame(height: 44)
                            Text(tr("最近 \(history.count) 个采样点（每 5 秒一个）",
                                    "Last \(history.count) samples (one every 5 s)"))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }

                    if !model.apps.isEmpty { sitesCard }
                    if !model.certificates.isEmpty { certificatesCard }
                    if let ip = model.ipStatus { addressCard(ip) }
                }
                .padding(16)
            } else {
                // 还没拉到任何数据：画骨架。
                //
                // 保留那四个写着"—"的指标卡也不算错，但"——"读起来像
                // "这台机器真的没有这个数值"；而骨架明确表示"马上就来"。
                SkeletonCards(cards: 2)
            }
        }
        .refreshable { await model.refreshAll(); await model.refreshMetrics() }
    }

    /// 四张卡：CPU / GPU 一行，内存 / 网络 一行（自适应网格，窄屏自动换行）。
    ///
    /// # 口径
    ///
    /// CPU / 内存 / 网络 是**那台服务器上这套东西自己的占用**（内核 + 站点
    /// 进程树），不是整机。GPU 是唯一保留设备级口径的 —— macOS 没有按进程
    /// 归因 GPU 的途径 —— 因此它的值下面明确写着"整机 GPU"。
    ///
    /// 两种口径并排摆着而不说明，用户会把设备级的 56% 读成"这套东西吃了
    /// 56% GPU"，而那正是 footprint 这个口径要消灭的误导。
    private var metricsRow: some View {
        let host = model.metrics?.host
        let footprint = model.metrics?.footprint
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            MetricCard(
                title: tr("CPU", "CPU"),
                value: footprint.map { $0.cpuPercent.formattedPercentValue } ?? "—",
                detail: .fraction(footprint?.cpuFraction ?? 0),
                symbol: "cpu",
                unsupported: footprint == nil ? tr("这台内核还不支持", "This kernel is too old") : nil)

            MetricCard(
                title: tr("GPU", "GPU"),
                value: model.metrics?.host.gpu?.utilizationPercent.map { $0.formattedPercentValue } ?? "—",
                detail: .text(gpuDetail),
                symbol: "cube.transparent",
                tint: .orange,
                // 三态：没有 GPU 字段 = 这台机器没有可采样的 GPU；
                // `unsupported` = 这个平台还没实现。两者都不能显示成 0%。
                unsupported: gpuUnsupported)

            MetricCard(
                title: tr("内存", "Memory"),
                value: footprint.map { $0.memoryBytes.formattedBytes } ?? "—",
                detail: .text(host.map { tr("整机 \($0.memoryUsedBytes.formattedBytes) / \($0.memoryTotalBytes.formattedBytes)",
                                            "device \($0.memoryUsedBytes.formattedBytes) / \($0.memoryTotalBytes.formattedBytes)") } ?? ""),
                symbol: "memorychip",
                tint: .purple,
                unsupported: footprint == nil ? tr("这台内核还不支持", "This kernel is too old") : nil)

            MetricCard(
                title: tr("网络", "Network"),
                value: footprint?.netRxBytesPerSec.map { $0.formattedRate } ?? "—",
                detail: .text(footprint?.netTxBytesPerSec.map { "↑ \($0.formattedRate)" } ?? tr("这套东西的流量", "traffic of this stack")),
                symbol: "network",
                tint: .teal,
                unsupported: networkUnsupported)
        }
    }

    /// GPU 值下面那一行：是设备级的，所以写"整机"。
    private var gpuDetail: String {
        guard let gpu = model.metrics?.host.gpu else { return "" }
        let name = gpu.name ?? "GPU"
        return tr("整机 · \(name)", "device · \(name)")
    }

    /// 网络的三态与 GPU 同构：没读到就是没读到，不能显示成 0。
    private var networkUnsupported: String? {
        guard let footprint = model.metrics?.footprint else {
            return tr("这台内核还不支持", "This kernel is too old")
        }
        if footprint.hasNetwork { return nil }
        switch footprint.netBackend {
        case "unsupported": return tr("此平台不支持按进程统计", "No per-process sampling here")
        case "unavailable": return tr("本次未读到", "No reading this time")
        default: return tr("本次未读到", "No reading this time")
        }
    }

    private var gpuUnsupported: String? {
        guard let gpu = model.metrics?.host.gpu else {
            return tr("此平台不支持", "Not supported here")
        }
        if !gpu.isSupported { return tr("此平台不支持", "Not supported here") }
        if gpu.utilizationPercent == nil { return tr("本次未读到", "No reading this time") }
        return nil
    }

    private var sitesCard: some View {
        Card(tr("站点", "Sites")) {
            ForEach(model.apps) { app in
                HStack(spacing: 10) {
                    StatePill(state: app.state, health: app.health)
                    Text(app.name).font(.callout)
                    Spacer(minLength: 0)
                    if let domains = app.domains, !domains.isEmpty {
                        Text(domains.map(\.name).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(":\(app.localPort)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var certificatesCard: some View {
        Card(tr("证书", "Certificates")) {
            ForEach(model.certificates) { certificate in
                InfoRow(
                    label: certificate.domains.joined(separator: ", "),
                    value: certificateValue(certificate),
                    tint: (certificate.daysRemaining ?? 99) <= 14 ? .orange : nil)
            }
        }
    }

    private func certificateValue(_ certificate: CertificateInfo) -> String {
        if let error = certificate.error, !error.isEmpty { return error }
        guard let days = certificate.daysRemaining else { return tr("未知", "Unknown") }
        if days < 0 { return tr("已过期", "Expired") }
        return tr("\(days) 天后到期", "expires in \(days) d")
    }

    private func addressCard(_ ip: IPStatus) -> some View {
        Card(tr("地址", "Addresses")) {
            if let ipv4 = ip.ipv4, !ipv4.isEmpty {
                InfoRow(label: "IPv4", value: ipv4.joined(separator: ", "), monospaced: true)
            }
            if let ipv6 = ip.globalIpv6, !ipv6.isEmpty {
                InfoRow(label: "IPv6", value: ipv6.joined(separator: ", "), monospaced: true)
            }
            if (ip.ipv4 ?? []).isEmpty && (ip.globalIpv6 ?? []).isEmpty {
                Text(tr("没有可用的公网地址。", "No public address."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// 一条建议。
///
/// 内核给的建议里，`action` 可能是"跳转到某个界面"或"发一个请求"。
/// 手机端只处理前者能对应的少数情况，其余的原样显示 —— 一个点了没反应的
/// 按钮比没有按钮更糟。
struct AdvisoryRow: View {
    let advisory: Advisory

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text(advisory.title).font(.callout)
                if let detail = advisory.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch advisory.severity {
        case "blocking": "exclamationmark.octagon.fill"
        case "warning": "exclamationmark.triangle.fill"
        default: "info.circle.fill"
        }
    }

    private var color: Color {
        switch advisory.severity {
        case "blocking": .red
        case "warning": .orange
        default: .accentColor
        }
    }
}
