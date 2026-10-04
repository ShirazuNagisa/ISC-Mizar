import SwiftUI
import MizarKit
import MizarApp
import MizarUI

/// 服务：站点列表与生命周期操作。
struct ServicesView: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            if model.apps.isEmpty {
                ContentUnavailableView(
                    tr("还没有站点", "No sites yet"),
                    systemImage: "square.stack.3d.up.slash",
                    description: Text(tr("在 Phecda 上创建站点之后，这里会显示它们的状态。",
                                         "Sites created in Phecda show up here.")))
            }
            ForEach(model.apps) { app in
                NavigationLink {
                    ServiceDetailView(model: model, app: app)
                } label: {
                    row(app)
                }
            }
        }
        .refreshable { await model.refreshAll() }
    }

    private func row(_ app: AppRecord) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.callout).fontWeight(.medium)
                HStack(spacing: 6) {
                    StatePill(state: app.state, health: app.health)
                    if let uptime = uptime(app) {
                        Text(uptime).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let metrics = metrics(for: app) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(metrics.cpuPercent.formattedPercentValue)
                        .font(.caption).monospacedDigit()
                    Text(metrics.memoryBytes.formattedBytes)
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func metrics(for app: AppRecord) -> AppMetrics? {
        model.metrics?.apps.first { $0.appId == app.id }
    }

    private func uptime(_ app: AppRecord) -> String? {
        guard let sample = metrics(for: app), sample.uptimeSeconds > 0 else { return nil }
        return sample.uptimeSeconds.formattedDuration
    }
}

/// 一个站点的详情。
struct ServiceDetailView: View {
    @Bindable var model: AppModel
    let app: AppRecord

    @State private var logs: [String] = []
    @State private var showLogs = false

    var body: some View {
        List {
            Section(tr("状态", "Status")) {
                InfoRow(label: tr("状态", "State"), value: StateStyle.label(app.state))
                InfoRow(label: tr("健康", "Health"), value: app.health)
                InfoRow(label: tr("本地端口", "Local port"), value: ":\(app.localPort)", monospaced: true)
                if !app.kind.isEmpty {
                    InfoRow(label: tr("运行时", "Runtime"), value: app.kind)
                }
                if let restarts = app.restartCount, restarts > 0 {
                    InfoRow(label: tr("重启次数", "Restarts"), value: "\(restarts)",
                            tint: restarts > 3 ? .orange : nil)
                }
            }

            if let domains = app.domains, !domains.isEmpty {
                Section(tr("域名", "Domains")) {
                    ForEach(domains) { domain in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(domain.name)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            HStack(spacing: 8) {
                                Label(domain.routeReady == true ? tr("已绑定", "Bound") : tr("未绑定", "Not bound"),
                                      systemImage: domain.routeReady == true ? "checkmark.circle" : "circle.dashed")
                                if domain.certNeedsRenew == true {
                                    Label(tr("证书需续期", "Cert needs renewal"), systemImage: "clock.badge.exclamationmark")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let sample = model.metrics?.apps.first(where: { $0.appId == app.id }) {
                Section(tr("资源", "Resources")) {
                    if sample.hasOwnProcess {
                        InfoRow(label: "CPU", value: sample.cpuPercent.formattedPercentValue)
                        InfoRow(label: tr("内存", "Memory"), value: sample.memoryBytes.formattedBytes)
                        InfoRow(label: tr("运行时长", "Uptime"), value: sample.uptimeSeconds.formattedDuration)
                        InfoRow(label: "PID", value: "\(sample.pid)", monospaced: true)
                    } else {
                        // 静态站点由内核自己托管：显示一个假的 0% 会让用户
                        // 以为它没在干活，而它其实一直在正常服务。
                        Text(tr("这个站点由内核直接托管，没有独立进程可测。",
                                "This site is served directly by the kernel; there is no separate process to measure."))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let error = app.lastError, !error.isEmpty {
                Section(tr("最后一次错误", "Last error")) {
                    Text(error).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Button {
                    Task { await loadLogs() }
                    showLogs = true
                } label: {
                    Label(tr("查看日志", "View logs"), systemImage: "doc.text.magnifyingglass")
                }
                .disabled(!model.canWrite && logs.isEmpty)
            }

            actionsSection
        }
        .navigationTitle(app.name)
        .sheet(isPresented: $showLogs) {
            LogsSheet(title: app.name, lines: logs)
        }
    }

    @ViewBuilder private var actionsSection: some View {
        Section {
            if model.canWrite {
                if app.isRunning {
                    Button {
                        model.execute { try await model.currentKernel().restartApp(app.id) }
                    } label: {
                        Label(tr("重启", "Restart"), systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        model.execute { try await model.currentKernel().stopApp(app.id) }
                    } label: {
                        Label(tr("停止", "Stop"), systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        model.execute { try await model.currentKernel().startApp(app.id) }
                    } label: {
                        Label(tr("启动", "Start"), systemImage: "play.fill")
                    }
                }
            } else {
                // 只读设备：说清楚**为什么**按钮不见了。
                //
                // 直接隐藏会让用户以为应用缺了功能；而置灰一个按钮并
                // 不解释，用户会反复去点它。
                Label(tr("这台设备是只读的，不能启停站点。需要操作权限请在 Phecda 上重新配对。",
                         "This device is read-only and cannot start or stop sites. Re-pair it in Phecda for operator rights."),
                      systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(tr("操作", "Actions"))
        }
    }

    private func loadLogs() async {
        guard let client = try? await model.currentKernel() else { return }
        logs = (try? await client.appLogs(app.id, tail: 300)) ?? []
    }
}

/// 日志。
///
/// 单独一个 sheet 而不是把日志塞进详情页：一屏能看到的日志行越多越好，
/// 而详情页里还有状态、域名、资源——它们会把日志挤到屏幕外面。
struct LogsSheet: View {
    let title: String
    let lines: [String]

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 1) {
                    if lines.isEmpty {
                        Text(tr("没有日志。", "No log lines."))
                            .foregroundStyle(.secondary).padding()
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(title)
        }
    }
}
