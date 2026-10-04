import SwiftUI
import MizarKit
import MizarApp
import MizarUI

/// 资源：主机与站点的资源占用。
///
/// # 为什么"不支持的平台"要显式说出来
///
/// 内核在它没实现采样的平台上会返回 `backend: "unsupported"` 与一堆零。
/// 界面如果把那些零画出来，用户看到的是"这台机器什么都没占用" ——
/// 而事实是"我们不知道"。前者会让他放心，后者会让他去查。
struct ResourcesView: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            if model.metrics?.host.metricsUnsupported == true {
                Section {
                    Text(tr("这台服务器所在的平台还没有实现资源采样。",
                            "The platform this server runs on does not implement resource sampling yet."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                hostSection
            }

            disksSection
            gpuSection
            appsSection
        }
        .refreshable { await model.refreshMetrics() }
    }

    @ViewBuilder private var hostSection: some View {
        let host = model.metrics?.host
        Section(tr("主机", "Host")) {
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "CPU", value: host.map { $0.cpuPercent.formattedPercentValue } ?? "—")
                ProgressBar(fraction: (host?.cpuPercent ?? 0) / 100)
                    .frame(height: 5)
            }
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: tr("内存", "Memory"),
                        value: host.map { "\($0.memoryUsedBytes.formattedBytes) / \($0.memoryTotalBytes.formattedBytes)" } ?? "—")
                ProgressBar(fraction: host?.memoryFraction ?? 0, tint: .purple)
                    .frame(height: 5)
            }
            InfoRow(label: tr("下载", "Download"), value: host.map { $0.netRxBytesPerSec.formattedRate } ?? "—")
            InfoRow(label: tr("上传", "Upload"), value: host.map { $0.netTxBytesPerSec.formattedRate } ?? "—")
            if let backend = host?.backend, !backend.isEmpty {
                // 把采样后端显示出来：出问题时"这个数字是怎么来的"
                // 是第一个要回答的问题。
                InfoRow(label: tr("采样方式", "Sampling"),
                        value: backend == "unsupported" ? tr("不支持", "Unsupported") : backend)
            }
            if let history = model.metrics?.history, history.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("最近 5 分钟", "Last 5 minutes"))
                        .font(.caption).foregroundStyle(.secondary)
                    Sparkline(values: history.map(\.cpuPercent))
                        .frame(height: 56)
                }
            }
        }
    }

    @ViewBuilder private var disksSection: some View {
        Section(tr("磁盘", "Disks")) {
            if let disks = model.metrics?.host.disks, !disks.isEmpty {
                ForEach(disks) { disk in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(disk.mountPoint)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Text(disk.fraction.formattedPercent)
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(disk.fraction > 0.9 ? .red : .secondary)
                        }
                        ProgressBar(fraction: disk.fraction,
                                    tint: disk.fraction > 0.9 ? .red : .accentColor)
                            .frame(height: 5)
                        Text("\(disk.usedBytes.formattedBytes) / \((disk.usedBytes + disk.freeBytes).formattedBytes)"
                             + (disk.fsType.map { " · \($0)" } ?? ""))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text(tr("这台服务器没有报告磁盘，或者它的平台还不支持。",
                        "This server reported no disks, or its platform does not support it yet."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var gpuSection: some View {
        Section(tr("GPU", "GPU")) {
            if let gpu = model.metrics?.host.gpu, gpu.isSupported,
               let utilization = gpu.utilizationPercent {
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(label: gpu.name ?? "GPU", value: utilization.formattedPercentValue)
                    ProgressBar(fraction: utilization / 100, tint: .orange).frame(height: 5)
                    Text(tr("采样方式：\(gpu.backend)", "Sampled via \(gpu.backend)"))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                Text(tr("这台服务器的平台没有实现 GPU 采样。",
                        "This server's platform does not implement GPU sampling."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var appsSection: some View {
        Section(tr("站点占用", "Per-site usage")) {
            let samples = (model.metrics?.apps ?? []).filter { $0.hasOwnProcess }
            if samples.isEmpty {
                Text(tr("没有带独立进程的站点。静态站点由内核直接托管，没有可测的资源占用。",
                        "No sites with their own process. Static sites are served by the kernel itself and have nothing to measure."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // 按 CPU 排序：用户打开"资源"页时想找的是**那个在吃 CPU 的**，
                // 而按名字或创建时间排都得让他自己扫一遍。
                ForEach(samples.sorted { $0.cpuPercent > $1.cpuPercent }) { sample in
                    HStack {
                        Text(name(of: sample.appId)).font(.callout).lineLimit(1)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(sample.cpuPercent.formattedPercentValue)
                                .font(.caption).monospacedDigit()
                            Text(sample.memoryBytes.formattedBytes)
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func name(of appID: String) -> String {
        model.apps.first { $0.id == appID }?.name ?? appID
    }
}

/// DNS：凭据 → 区域 → 记录，以及动态解析任务。
///
/// 写操作按角色门控，而**门控的依据来自服务端**（`/v1/remote/self` 里的
/// role），不是客户端自己判断的。
struct DNSView: View {
    @Bindable var model: AppModel

    @State private var selectedCredential: CredentialInfo?
    @State private var selectedZone: DNSZone?
    @State private var zones: [DNSZone] = []
    @State private var records: [DNSRecord] = []
    @State private var loading = false
    @State private var editing: DNSRecord?
    @State private var creating = false

    var body: some View {
        List {
            credentialsSection
            if let zone = selectedZone {
                recordsSection(zone)
            }
            ddnsSection
        }
        .refreshable { await model.refreshAll() }
        .sheet(isPresented: $creating) {
            RecordFormView(model: model, credential: selectedCredential, zone: selectedZone,
                           record: nil) { await reloadRecords() }
        }
        .sheet(item: $editing) { record in
            RecordFormView(model: model, credential: selectedCredential, zone: selectedZone,
                           record: record) { await reloadRecords() }
        }
    }

    @ViewBuilder private var credentialsSection: some View {
        Section(tr("服务商凭据", "Provider credentials")) {
            if model.credentials.isEmpty {
                Text(tr("还没有 DNS 凭据。凭据只能在 Phecda 上添加 —— 手机端刻意不提供录入 API Key 的入口。",
                        "No DNS credentials yet. They can only be added in Phecda — entering an API key on a phone is deliberately not supported."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.credentials) { credential in
                Button {
                    Task { await select(credential) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(credential.label).font(.callout)
                            Text(credential.provider).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedCredential?.id == credential.id {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            if let credential = selectedCredential, !zones.isEmpty {
                Picker(tr("区域", "Zone"), selection: $selectedZone) {
                    Text(tr("请选择", "Select")).tag(DNSZone?.none)
                    ForEach(zones) { zone in
                        Text(zone.name).tag(DNSZone?.some(zone))
                    }
                }
                .onChange(of: selectedZone) { _, _ in
                    Task { await reloadRecords() }
                }
            }
        }
    }

    @ViewBuilder private func recordsSection(_ zone: DNSZone) -> some View {
        Section {
            if loading {
                HStack { ProgressView().controlSize(.small); Text(tr("读取中…", "Loading…")) }
            } else if records.isEmpty {
                Text(tr("这个区域里没有记录。", "No records in this zone."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                Button {
                    guard model.canWrite else { return }
                    editing = record
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(record.type)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 4))
                            Text(record.name)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if let ttl = record.ttl {
                                Text("TTL \(ttl)").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Text(record.content)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    if model.canWrite {
                        Button(role: .destructive) {
                            delete(record)
                        } label: {
                            Label(tr("删除", "Delete"), systemImage: "trash")
                        }
                    }
                }
            }

            if model.canWrite {
                Button {
                    creating = true
                } label: {
                    Label(tr("新增记录", "Add record"), systemImage: "plus")
                }
            } else {
                Label(tr("这台设备是只读的，不能改动记录。", "This device is read-only."),
                      systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(tr("记录 · \(zone.name)", "Records · \(zone.name)"))
        }
    }

    @ViewBuilder private var ddnsSection: some View {
        Section(tr("动态解析", "Dynamic DNS")) {
            if model.ddnsTasks.isEmpty {
                Text(tr("没有动态解析任务。", "No dynamic DNS tasks."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.ddnsTasks) { task in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(task.label).font(.callout)
                        Spacer()
                        if model.canWrite {
                            Toggle("", isOn: Binding(
                                get: { task.enabled },
                                set: { newValue in toggle(task, newValue) }))
                                .labelsHidden()
                                .toggleStyle(.switch)
                        } else {
                            Text(task.enabled ? tr("已启用", "On") : tr("已停用", "Off"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let message = task.lastMessage, !message.isEmpty {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(task.lastStatus == "failed" ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let ipv4 = task.lastIpv4, !ipv4.isEmpty {
                        Text("IPv4 \(ipv4)").font(.caption2)
                            .foregroundStyle(.tertiary).monospaced()
                    }
                    if model.canWrite {
                        Button {
                            model.execute { try await model.currentKernel().runDdnsTask(task.id) }
                        } label: {
                            Label(tr("立即执行一次", "Run once now"), systemImage: "bolt")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 动作

    private func select(_ credential: CredentialInfo) async {
        selectedCredential = credential
        selectedZone = nil
        records = []
        zones = []
        guard let client = try? await model.currentKernel() else { return }
        zones = (try? await client.zones(credentialID: credential.id)) ?? []
    }

    private func reloadRecords() async {
        guard let credential = selectedCredential, let zone = selectedZone,
              let client = try? await model.currentKernel() else { return }
        loading = true
        records = (try? await client.records(credentialID: credential.id, zone: zone.id)) ?? []
        loading = false
    }

    private func delete(_ record: DNSRecord) {
        guard let credential = selectedCredential, let zone = selectedZone else { return }
        model.execute {
            try await model.currentKernel()
                .deleteRecord(credentialID: credential.id, zone: zone.id, recordID: record.id)
        }
    }

    private func toggle(_ task: DdnsTaskInfo, _ enabled: Bool) {
        // 走服务端的窄接口（enable/disable），而不是 `PATCH /v1/ddns-tasks/{id}` ——
        // 后者能改域名与取址来源，因此**不在远程面的白名单里**。
        model.execute {
            _ = try await model.currentKernel().setDdnsTask(task.id, enabled: enabled)
        }
    }
}
