import SwiftUI
import MizarKit
import MizarApp
import MizarUI

/// 新增/修改一条 DNS 记录。
///
/// # 字段顺序是照着"最常改的那个排最前"
///
/// 手机上改记录最常见的是"换个 IP"（内容），其次是 TTL。类型与名字很少动，
/// 因此它们在后。表单顺序在这里不是审美问题：一个要滚动才能看到"内容"
/// 字段的表单，在手机上每次都要多花两三秒。
struct RecordFormView: View {
    @Bindable var model: AppModel
    let credential: CredentialInfo?
    let zone: DNSZone?
    let record: DNSRecord?
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var type = "A"
    @State private var name = ""
    @State private var content = ""
    @State private var ttlText = ""
    @State private var proxied = false
    @State private var comment = ""
    @State private var busy = false
    @State private var failure: String?

    private static let types = ["A", "AAAA", "CNAME", "TXT", "MX", "NS", "SRV", "CAA"]

    private var isEditing: Bool { record != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(tr("内容（例如 1.2.3.4）", "Content (e.g. 1.2.3.4)"), text: $content)
                        .font(.system(.callout, design: .monospaced))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                } header: {
                    Text(tr("内容", "Content"))
                }

                Section {
                    Picker(tr("类型", "Type"), selection: $type) {
                        ForEach(Self.types, id: \.self) { Text($0).tag($0) }
                    }
                    TextField(tr("名称（@ 表示根）", "Name (@ for the zone root)"), text: $name)
                        .font(.system(.callout, design: .monospaced))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }

                Section {
                    TextField(tr("TTL（秒，留空用服务商默认）", "TTL (seconds, blank for provider default)"),
                              text: $ttlText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    if supportsProxy {
                        Toggle(tr("经由 Cloudflare 代理", "Proxy through Cloudflare"), isOn: $proxied)
                    }
                    TextField(tr("备注（可选）", "Comment (optional)"), text: $comment)
                }

                if let failure {
                    Section {
                        Text(failure).font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle(isEditing ? tr("修改记录", "Edit record") : tr("新增记录", "Add record"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("取消", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("保存", "Save")) { Task { await save() } }
                        .disabled(busy || content.isEmpty || name.isEmpty)
                }
                if busy { ToolbarItem(placement: .status) { ProgressView().controlSize(.small) } }
            }
            .onAppear(perform: load)
        }
    }

    /// 代理开关只在 A/AAAA/CNAME 上有意义。
    ///
    /// 显示一个对当前类型无效的开关，用户会打开它然后奇怪为什么没生效。
    private var supportsProxy: Bool {
        ["A", "AAAA", "CNAME"].contains(type)
    }

    private func load() {
        guard let record else { return }
        type = record.type
        name = record.name
        content = record.content
        ttlText = record.ttl.map(String.init) ?? ""
        proxied = record.proxied ?? false
        comment = record.comment ?? ""
    }

    private func save() async {
        guard let credential, let zone else {
            failure = tr("没有选中区域。", "No zone selected.")
            return
        }
        busy = true
        failure = nil

        let ttl = Int(ttlText.trimmingCharacters(in: .whitespaces))
        if !ttlText.isEmpty, ttl == nil {
            failure = tr("TTL 必须是整数秒。", "TTL must be a whole number of seconds.")
            busy = false
            return
        }

        do {
            let client = try await model.currentKernel()
            if let record {
                _ = try await client.updateRecord(
                    credentialID: credential.id, zone: zone.id, recordID: record.id,
                    name: name, type: type, content: content,
                    ttl: ttl, proxied: supportsProxy ? proxied : nil,
                    comment: comment.isEmpty ? nil : comment)
            } else {
                _ = try await client.createRecord(
                    credentialID: credential.id, zone: zone.id,
                    name: name, type: type, content: content,
                    ttl: ttl, proxied: supportsProxy ? proxied : nil,
                    comment: comment.isEmpty ? nil : comment)
            }
            await onSaved()
            dismiss()
        } catch let error as KernelError {
            failure = error.message
        } catch {
            failure = error.localizedDescription
        }
        busy = false
    }
}

/// 设置。
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// 用来在用户从系统设置返回时刷新权限状态。
    @Environment(\.scenePhase) private var scenePhase

    @State private var showForgetAll = false

    var body: some View {
        NavigationStack {
            List {
                if let server = model.selectedServer {
                    Section(tr("当前服务端", "Current server")) {
                        InfoRow(label: tr("名称", "Name"), value: server.name)
                        InfoRow(label: tr("角色", "Role"),
                                value: server.canWrite ? tr("可改 DNS", "Can edit DNS") : tr("只读监控", "Read-only"))
                        InfoRow(label: tr("公钥指纹", "Key fingerprint"),
                                value: fingerprintShort(server.spkiSHA256), monospaced: true)
                        if let seen = server.lastSeenAt {
                            InfoRow(label: tr("最后连接", "Last connected"),
                                    value: seen.formatted(date: .abbreviated, time: .shortened))
                        }
                        // 指纹给用户自己核对 —— Phecda 上也显示同一串。
                        Text(tr("这一串应当与 Phecda 的「远程访问」页显示的一致。不一致说明你连的不是那台机器。",
                                "This should match what Phecda's Remote Access page shows. If it does not, you are not talking to that machine."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Section(tr("地址", "Addresses")) {
                        ForEach(server.orderedAddresses(), id: \.self) { address in
                            HStack {
                                Text(address)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer()
                                if server.lastGoodAddress == address {
                                    Text(tr("上次可用", "Last used"))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                Section(tr("通知", "Notifications")) {
                    // 两件事要分开说清楚：**这台手机**有没有被系统允许收通知，
                    // 与**这台服务端**有没有配好推送。只显示其中一半的话，
                    // "我明明开了"会变成一个查不下去的状态。
                    switch pushState {
                    case .notDetermined:
                        Button {
                            // 只发这一条。应用壳收到之后会申请授权，并在
                            // 拿到权限时向 APNs 注册。
                            //
                            // 以前这里**同时**又调了一次
                            // `model.push.requestAuthorization()`：那次调用
                            // 不会让结果更早回来，只会让"到底谁负责注册"
                            // 有两个地方可看 —— 而漏掉注册的症状是
                            // "权限给了但收不到通知"。
                            NotificationCenter.default.post(name: .mizarRequestPushRegistration, object: nil)
                        } label: {
                            Label(tr("允许接收通知", "Allow notifications"), systemImage: "bell")
                        }

                    case .denied:
                        // 被拒之后画的是**另一条出路**，不是一个再点一次的
                        // "允许"：系统只会问一次，`requestAuthorization` 在
                        // 已经决定过之后不显示任何界面。以前这里画的就是
                        // 那个"允许"按钮 —— 它按下去什么都不会发生，而
                        // 用户会一直点它。
                        #if os(iOS)
                        Button {
                            PermissionCenter(push: model.push).openSettings()
                        } label: {
                            Label(tr("去系统设置开启通知", "Turn on notifications in Settings"),
                                  systemImage: "gear")
                        }
                        #endif
                        Text(tr("系统只会问一次，现在再点「允许」也不会弹框。",
                                "The system only asks once; tapping Allow again would not show a prompt."))
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)

                    case .granted, .notRequestable:
                        EmptyView()
                    }

                    if !apnsConfigured {
                        Label(tr("这台服务端还没有配置推送凭据。请在 Phecda 的「远程访问」页填入 APNs 密钥 —— 在那之前，你只能在打开应用时看到状态变化。",
                                 "This server has no push credentials yet. Fill in the APNs key on Phecda's Remote Access page — until then you only see changes when the app is open."),
                              systemImage: "bell.slash")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if pushState == .granted {
                        Label(tr("就绪。站点失败、证书失败、解析失败时会推送到这台设备。",
                                 "Ready. Failures of sites, certificates and DNS updates are pushed to this device."),
                              systemImage: "bell.badge")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // 上报给内核的 APNs 环境。
                    //
                    // 它平时不用露面，但**收不到通知**时它是第一个该被核对
                    // 的东西：开发版装到真机上拿到的是沙箱令牌，而内核必须
                    // 往沙箱发。两边对不上时 Apple 回的是 BadDeviceToken
                    // —— 那个错误看起来像"令牌失效"，与真正的原因（环境
                    // 不匹配）毫无相似之处。
                    //
                    // 只在服务端配了推送时显示：在那之前这一行是纯粹的噪音
                    // （没有推送可发，也就无所谓发去哪个环境）。
                    //
                    // 做成一行可读的值而不是一个开关：它由签名时的
                    // `aps-environment` 决定，用户改不了（见 PushEnvironment）。
                    if apnsConfigured {
                        LabeledContent(tr("推送环境", "Push environment"),
                                       value: PushCoordinator.environment)
                            .font(.caption)
                    }

                    if let error = model.push.lastRegistrationError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // 可达性自检的入口。
                    //
                    // # 为什么是手机来测
                    //
                    // 内核测不了自己的入站可达性：本机发起的连接走的是
                    // 内部路径（同网段二层、跨网段 NAT 环回），与真实
                    // 客户端的路径不同。而手机就在真实客户端要走的网络上。
                    //
                    // # 手机自己在家里的 Wi-Fi 上时测不准
                    //
                    // 那时连公网地址**也会成功**，因为那个连接根本没出
                    // 局域网。探测本身会先试局域网地址，通了就报"不作数"——
                    // 因此下面这句话是必须说的，否则用户会得到一个
                    // 看起来通过、其实什么都没证明的结果。
                    if model.currentServerInfo?.public?.hasTargets == true {
                        Button {
                            Task { await model.checkReachability() }
                        } label: {
                            Label(model.probing
                                  ? tr("正在测试…", "Testing…")
                                  : tr("测试公网可达性", "Test public reachability"),
                                  systemImage: "network")
                        }
                        .disabled(model.probing)

                        if let report = model.reachability {
                            Label(report.detail ?? "",
                                  systemImage: report.reachable ? "checkmark.seal.fill"
                                             : (report.sameLan ? "questionmark.circle" : "exclamationmark.triangle"))
                                .font(.caption)
                                .foregroundStyle(report.reachable ? Color.green
                                                 : (report.sameLan ? Color.secondary : Color.orange))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(tr("最准的测法：手机关掉 Wi-Fi、用蜂窝数据再点这个按钮。在同一个 Wi-Fi 下测出来的结果不作数。",
                                    "Most accurate: turn off Wi-Fi on the phone, use cellular data, then tap this. A result measured on the same Wi-Fi does not count."))
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // Apple Watch 的同步入口。
                    //
                    // 手表没有摄像头也没有键盘，因此它**从不自己配对** ——
                    // 配置全部来自这台手机。同步过去的是一台派生的
                    // **只读**设备（它在 Phecda 里可以单独吊销），
                    // 而不是手机自己的凭据。
                    Button {
                        NotificationCenter.default.post(name: .mizarRequestWatchSync, object: nil)
                    } label: {
                        Label(tr("同步到 Apple Watch", "Sync to Apple Watch"), systemImage: "applewatch")
                    }
                    Text(tr("手表拿到的是这台手机派生出来的一台独立只读设备，可以在 Phecda 的设备列表里单独吊销。",
                            "The watch gets its own read-only device derived from this phone; it can be revoked separately from Phecda's device list."))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    // 后台刷新的定位是**兜底**：系统决定它什么时候跑，
                    // 因此不能承诺"多久检查一次"。
                    Text(tr("应用不在前台时，系统也会偶尔在后台刷新一次状态（时机由系统决定，不保证频率）。",
                            "While the app is in the background the system may occasionally refresh in the background (timing is up to the system, frequency not guaranteed)."))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section(tr("关于", "About")) {
                    // 用常量而不是 `Bundle.main`：界面层在 `swift test` 与
                    // 验收工具里也会被编译，而那里没有应用包 —— 读 Bundle
                    // 会安静地显示成 `—`，恰好是最需要这个数字的一刻。
                    InfoRow(label: tr("应用版本", "App version"), value: MizarVersion.display)
                    InfoRow(label: tr("服务端内核", "Server kernel"),
                            value: model.currentServerInfo?.server.version ?? "—")
                    if let server = model.selectedServer {
                        InfoRow(label: tr("公钥指纹", "Key fingerprint"),
                                value: PairingCode.grouped(server.spkiSHA256.prefix(8).description))
                    }
                }

                Section {
                    Button(role: .destructive) { showForgetAll = true } label: {
                        Label(tr("移除全部服务端", "Remove all servers"), systemImage: "trash")
                    }
                }
            }
            .navigationTitle(tr("设置", "Settings"))
            .task {
                pushState = PermissionOnboarding.state(
                    forAuthorization: await model.push.authorizationStatus())
            }
            // 从系统设置回来时重新读一次。
            //
            // 少了这一条，用户在设置里把通知打开、切回来，看到的仍然是
            // 那个"去系统设置开启通知"的按钮 —— 他会以为刚才那一下没生效，
            // 于是再去一次。权限的真相在系统那里，而系统不会通知我们。
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    pushState = PermissionOnboarding.state(
                        forAuthorization: await model.push.authorizationStatus())
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("完成", "Done")) { dismiss() }
                }
            }
            .confirmationDialog(tr("移除全部服务端？", "Remove all servers?"),
                                isPresented: $showForgetAll) {
                Button(tr("移除全部", "Remove all"), role: .destructive) {
                    for server in model.servers { model.forget(server.id) }
                    dismiss()
                }
                Button(tr("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(tr("这只会清掉这台手机上的记录与令牌，所有服务端本身不受影响。",
                        "This only clears the records and tokens on this phone. The servers themselves are unaffected."))
            }
        }
    }

    /// 系统是否允许本应用显示通知。
    ///
    /// 与"服务端配没配推送"是**两件事**，而用户看到的现象只有一个
    /// （"我没收到通知"）。只显示其中一半，排查就无从下手。
    ///
    /// 存的是三态而不是一个 `Bool`：被拒（`.denied`）与还没问过
    /// （`.notDetermined`）在界面上必须是**两种**东西 —— 前者只能去
    /// 系统设置，后者才值得画一个"允许"按钮。合成一个布尔的话，
    /// 被拒的用户会看到一个按下去永远没反应的按钮。
    @State private var pushState: PermissionStepState = .notDetermined

    /// 服务端是否配了 APNs 凭据。
    ///
    /// 它来自 `GET /v1/remote/self` 的 `server.apns_topic`（没配就是空）——
    /// 而不是客户端自己记的一个开关。
    private var apnsConfigured: Bool {
        guard let topic = model.currentServerInfo?.server.apnsTopic else { return false }
        return !topic.isEmpty
    }

    /// 指纹的短形式：与 Phecda 上显示的那一串同源。
    private func fingerprintShort(_ spki: String) -> String {
        SpkiPinning.shortFingerprint(fromBase64URL: spki)
    }
}
