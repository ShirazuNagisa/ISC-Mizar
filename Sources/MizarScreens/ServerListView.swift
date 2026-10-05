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
        // 选中走 `model.select` 而不是直接写 `model.selectedServerID`。
        //
        // # 为什么不能直接绑到属性上
        //
        // 直接写属性只改变了"选中项"这个事实，**没有任何东西会去连接
        // 那一台** —— 于是点一下服务端，右边出现的是上一台的数据与
        // 空白卡片，要等下一次进前台才可能填上。而 `select` 会立刻把
        // 状态标成"连接中"（界面当帧画出骨架）并在后台发起连接。
        //
        // 用 `List(selection:)` 而不是自己写点击手势：iPad 横屏的侧栏
        // 高亮、键盘上下键、VoiceOver 的"已选中"都靠它，自己实现会漏。
        List(selection: Binding(get: { model.selectedServerID },
                               set: { if let id = $0 { model.select(id) } })) {
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
    /// 粘贴进来的配对链接。
    @State private var link = ""
    @State private var busy = false
    @State private var failure: String?
    /// 手输路径的中间结果：等用户核对指纹。

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
            // **指纹确认弹窗已删除。**
            //
            // 它存在的前提是"六位码不携带任何身份信息，所以要人工比一比"。
            // 六位码已去掉，而二维码与配对链接里装着指纹 —— 核对是内建的，
            // 留着弹窗只会让人多做一步没有意义的事。
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
            Text(tr("这个平台没有摄像头，请改用下面的配对链接。",
                    "This platform has no camera; use the pairing link below instead."))
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
            // 先问"有没有链接"，有的话地址与配对码都不必填。
            //
            // 那个顺序是有意的：能一条链接解决的事，不该让人去手打
            // 一串 IP。而链接里装的不只是地址 —— 还有公钥指纹，
            // 也就是说手动路径本来要做的"两端核对指纹"那一步也省了。
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("方式一：粘贴配对链接", "Option 1: paste a pairing link"))
                    .font(.caption).foregroundStyle(.secondary)

                TextField(tr("isc-remote://pair?d=…", "isc-remote://pair?d=…"), text: $link)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif

                Button {
                    Task { await pairFromLink() }
                } label: {
                    Label(tr("用链接连接", "Connect with link"), systemImage: "link")
                }
                .buttonStyle(.glassProminent)
                .disabled(busy || link.trimmingCharacters(in: .whitespaces).isEmpty)

                Text(tr("链接在 Phecda 的配对弹窗上，点「复制配对链接」即可。五分钟内有效、用一次即失效。",
                        "The link is in Phecda's pairing sheet — tap “Copy pairing link”. Valid for five minutes, single use."))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 地址 + 六位码那条路已删除。
            //
            // 六位码只有约 10 亿种可能、靠按来源锁定兜底，而且携带不了
            // 任何身份信息（所以那时必须让用户人工比对公钥指纹）。
            // 二维码与配对链接里的密钥是 256 位，且自带指纹。
            //
            // 链接就是"没法扫码"时的替代 —— 传过去、粘一次即可。
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

    /// 用粘贴进来的配对链接连接。
    ///
    /// 走的是与扫码**完全相同**的那条路（`AppModel.pairFromLink` →
    /// `PairingService.pair(payloadText:)`）—— 链接与二维码里装的是
    /// 同一份载荷，只是载体不同。两条独立实现意味着两处会漂移，
    /// 而漂移的症状是"扫得进、粘不进"。
    private func pairFromLink() async {
        busy = true
        failure = nil
        await model.pairFromLink(link.trimmingCharacters(in: .whitespacesAndNewlines))
        // 成功与否由 model 决定；这里只负责把输入框收干净，
        // 免得那条已经用掉的链接还留在屏幕上被再点一次。
        if model.errorMessage == nil {
            link = ""
        } else {
            failure = model.errorMessage
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
/// 中间人在这里是可能的。核对多花五秒，而不核对的代价是：一次配对时的/// 单独包一层是因为 `UIPasteboard`（iOS）与 `NSPasteboard`（macOS）类型
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

