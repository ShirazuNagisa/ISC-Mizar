import SwiftUI
import MizarKit
import MizarApp
import MizarUI

/// 服务端列表。
struct ServerListView: View {
    @Bindable var model: AppModel
    @Binding var showingAddServer: Bool
    @State private var pendingForget: ServerRecord?

    var body: some View {
        List(selection: $model.selectedServerID) {
            ForEach(model.servers) { server in
                row(server)
                    .tag(server.id)
                    .swipeActions {
                        Button(role: .destructive) { pendingForget = server } label: {
                            Label(tr("移除", "Remove"), systemImage: "trash")
                        }
                    }
            }
        }
        .navigationTitle(tr("服务端", "Servers"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAddServer = true } label: {
                    Label(tr("添加", "Add"), systemImage: "plus")
                }
            }
        }
        .refreshable { await model.loadServers() }
        .task { await model.loadServers() }
        .confirmationDialog(
            tr("移除这台服务端？", "Remove this server?"),
            isPresented: Binding(get: { pendingForget != nil },
                                 set: { if !$0 { pendingForget = nil } }),
            presenting: pendingForget
        ) { server in
            Button(tr("移除", "Remove"), role: .destructive) { model.forget(server.id) }
            Button(tr("取消", "Cancel"), role: .cancel) { pendingForget = nil }
        } message: { server in
            // 说清楚**不会**发生什么：用户最担心的通常是"我是不是要把
            // Phecda 那边也重新配一遍"。
            Text(tr("只会从这台手机上删掉「\(server.name)」的访问记录与令牌。服务端本身不受影响，随时可以重新扫码添加。",
                    "This only removes the access record and token for \(server.name) from this phone. The server itself is unaffected; you can scan it again any time."))
        }
    }

    private func row(_ server: ServerRecord) -> some View {
        let state = model.state(of: server.id)
        return HStack(spacing: 10) {
            Circle()
                .fill(color(for: state))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.callout).fontWeight(.medium)
                Text(subtitle(server, state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if server.canWrite {
                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(tr("这台设备有写权限", "This device can write"))
            }
        }
        .padding(.vertical, 2)
    }

    /// 状态点的颜色。
    ///
    /// "需要重新配对"与"连不上"必须是两种颜色：它们的下一步动作完全不同
    /// （一个要去重新扫码，一个要去检查网络与 Phecda），而如果都画成红的，
    /// 用户只会去反复下拉刷新。
    private func color(for state: SessionState) -> Color {
        switch state {
        case .online: .green
        case .connecting, .idle: .secondary
        case .needsPairing: .orange
        case .identityChanged: .purple
        case .unreachable: .red
        }
    }

    private func subtitle(_ server: ServerRecord, _ state: SessionState) -> String {
        switch state {
        case .online:
            if let seen = server.lastSeenAt {
                tr("已连接 · \(seen.formatted(date: .omitted, time: .shortened))",
                   "Connected · \(seen.formatted(date: .omitted, time: .shortened))")
            } else {
                tr("已连接", "Connected")
            }
        case .idle, .connecting:
            server.addresses.first ?? ""
        default:
            state.summary
        }
    }
}

/// 添加一台服务端：扫码，或者手输六位码。
struct AddServerView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case scan, manual
        var id: String { rawValue }
        var title: String {
            self == .scan ? tr("扫码", "Scan") : tr("手动输入", "Enter code")
        }
    }

    @State private var mode: Mode = .scan
    @State private var deviceName = ""
    @State private var address = ""
    @State private var code = ""
    @State private var busy = false
    @State private var failure: String?
    /// 手输路径的中间结果：等用户核对指纹。
    @State private var pending: PairingService.PendingManualPairing?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                TextField(tr("这台设备的名称（可选）", "A name for this device (optional)"),
                          text: $deviceName)
                    .textFieldStyle(.roundedBorder)

                if mode == .scan {
                    scanSection
                } else {
                    manualSection
                }

                if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(20)
            .navigationTitle(tr("添加服务端", "Add server"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("取消", "Cancel")) { dismiss() }
                }
                if busy { ToolbarItem(placement: .status) { ProgressView().controlSize(.small) } }
            }
            .sheet(item: $pending) { pendingPairing in
                FingerprintConfirmView(pending: pendingPairing) {
                    Task { await commit(pendingPairing) }
                } onCancel: {
                    // 用户说指纹不对：**丢弃令牌**，并明确告诉他配对码
                    // 可能已经泄露。静默丢弃会让他在 Phecda 上留着一个
                    // 仍然有效的会话，而那个会话正是攻击者可用的东西。
                    self.pending = nil
                    failure = tr("已取消。请在 Phecda 上取消那个配对会话并重新生成一个 —— 这一次的配对码可能已经被别人看到。",
                                 "Cancelled. Cancel that pairing session in Phecda and generate a new one — this code may have been seen by someone else.")
                }
            }
        }
    }

    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if os(iOS)
            QRScannerView { text in
                Task { await pairWithPayload(text) }
            }
            .frame(height: 260)
            .clipShape(.rect(cornerRadius: 12))
            Text(tr("对准 Phecda 上的配对二维码。", "Point at the pairing code in Phecda."))
                .font(.caption).foregroundStyle(.secondary)
            #else
            Text(tr("这个平台没有摄像头，请改用「手动输入」。",
                    "This platform has no camera; use “Enter code” instead."))
                .font(.callout).foregroundStyle(.secondary)
            #endif

            // 剪贴板与二维码走的是同一条路径：pairing payload 是同一段文本。
            Button {
                let text = Pasteboard.string ?? ""
                Task { await pairWithPayload(text) }
            } label: {
                Label(tr("从剪贴板粘贴配对内容", "Paste pairing code from clipboard"),
                      systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.glass)
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(tr("地址，例如 192.168.1.10:8788", "Address, e.g. 192.168.1.10:8788"),
                      text: $address)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

            TextField(tr("六位配对码", "Six-character code"), text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title3, design: .monospaced))
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                #endif

            Text(tr("配对码显示在 Phecda 的二维码下方。字母 O 与数字 0、字母 I/L 与数字 1 会按同一种理解，输入哪个都行。",
                    "The code is shown below the QR code in Phecda. O/0 and I/L/1 are treated the same, so either is fine."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await probeManual() }
            } label: {
                Label(tr("连接", "Connect"), systemImage: "arrow.right.circle")
            }
            .buttonStyle(.glassProminent)
            .disabled(busy || address.isEmpty || code.isEmpty)
        }
    }

    // MARK: - 动作

    private func pairWithPayload(_ text: String) async {
        guard !text.isEmpty else {
            failure = tr("剪贴板里没有可用的配对内容。", "Nothing to paste.")
            return
        }
        busy = true
        failure = nil
        do {
            _ = try await model.pair(payloadText: text, deviceName: deviceName)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
        busy = false
    }

    private func probeManual() async {
        busy = true
        failure = nil
        do {
            pending = try await model.probeManual(address: address, code: code, deviceName: deviceName)
        } catch {
            failure = error.localizedDescription
        }
        busy = false
    }

    private func commit(_ pending: PairingService.PendingManualPairing) async {
        busy = true
        do {
            _ = try await model.commitManual(pending)
            self.pending = nil
            dismiss()
        } catch {
            failure = error.localizedDescription
            self.pending = nil
        }
        busy = false
    }
}

/// 手输路径的指纹核对。
///
/// # 这一步不能省
///
/// 扫码路径的指纹来自二维码 —— 那是密码学意义上建立起来的信任。
/// 手输路径没有二维码，客户端只能**先连上去**再把指纹拿回来，因此
/// 中间人在这里是可能的。核对多花五秒，而不核对的代价是：一次配对时的
/// 中间人可以长期篡改返回的一切（包括 DNS 记录），而用户不会有任何察觉。
struct FingerprintConfirmView: View {
    let pending: PairingService.PendingManualPairing
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)

            Text(tr("核对指纹", "Compare the fingerprint"))
                .font(.title3.weight(.semibold))

            Text(pending.serverName)
                .font(.callout).foregroundStyle(.secondary)

            Text(pending.fingerprintShort)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)

            Text(tr("这一串必须与 Phecda 上「远程访问」页显示的公钥指纹完全一致。不一致就点「不一致」—— 那说明你连上的不是那台机器。",
                    "This must match the key fingerprint shown on Phecda's Remote Access page exactly. If it does not, tap “Does not match” — it means you are not talking to that machine."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Theme.messageMaxWidth)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(tr("不一致", "Does not match"), role: .destructive, action: onCancel)
                Button(tr("一致，完成配对", "Matches, finish pairing"), action: onConfirm)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
    }
}

/// 剪贴板。
///
/// 单独包一层是因为 `UIPasteboard`（iOS）与 `NSPasteboard`（macOS）类型
/// 不同，而这个应用要在两个平台上编译。
enum Pasteboard {
    static var string: String? {
        #if os(iOS)
        UIPasteboard.general.string
        #elseif os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        nil
        #endif
    }
}
