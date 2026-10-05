import SwiftUI
import MizarKit
import MizarApp
import MizarUI

/// 应用的根：服务器列表 → 某一台服务器的四个页签。
///
/// # 为什么服务器列表是根，而不是把服务器做成页签里的一个选择器
///
/// 多台服务端是这个应用的**第一等公民**（用户可能同时有家里的 Mac mini
/// 与云上的机器）。把服务器选择放在每个页签的导航栏里，会让"我现在看的
/// 是哪一台"变成一个需要每次确认的问题 —— 而看错服务器比看不到更危险：
/// 用户会以为家里的机器 CPU 爆了，实际上是云上那台。
///
/// iPad 横屏时 `NavigationSplitView` 自动把列表变成侧栏，iPhone 上则是
/// 压栈的列表 —— 一份代码两套形态。
public struct RootView: View {
    @Bindable var model: AppModel
    @State private var showingAddServer = false

    /// 应用的根视图由 Xcode 工程里的 `@main` 构造 —— 那在另一个模块里，
    /// 因此这个入口必须是 public。内部的各个屏幕不必：它们只在本模块内
    /// 互相引用，而把每一个都公开只会让"哪些是真正的对外接口"变得模糊。
    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            ServerListView(model: model, showingAddServer: $showingAddServer)
        } detail: {
            if let server = model.selectedServer {
                ServerDetailView(model: model, server: server)
            } else if !model.hasLoadedServers {
                // 服务端列表还在从磁盘里读：先画骨架。
                //
                // 少了这一条，冷启动的第一帧是"还没有服务端，去扫码添加"
                // —— 而用户明明有三台，那句话会让人以为配置丢了（甚至去
                // 重新配对，于是多出第二条记录）。
                ScrollView { SkeletonCards() }
            } else {
                EmptyHint(
                    symbol: "antenna.radiowaves.left.and.right",
                    title: tr("还没有服务端", "No servers yet"),
                    message: tr("在 Phecda 的「远程访问」页生成一个配对二维码，然后扫码添加。",
                                "Generate a pairing code in Phecda's Remote Access page, then scan it."),
                    action: (tr("添加服务端", "Add server"), { showingAddServer = true }))
            }
        }
        .sheet(isPresented: $showingAddServer) {
            AddServerView(model: model)
        }
        .overlay(alignment: .bottom) {
            if let message = model.errorMessage {
                BannerRow(text: message, tint: .orange) { model.errorMessage = nil }
            } else if let notice = model.notice {
                BannerRow(text: notice, tint: .accentColor) { model.notice = nil }
            }
        }
    }
}

/// 一台服务端的详情：四个页签。
///
/// 只有在前一台的数据被清空之后才会被构造（见 `AppModel.select`），
/// 因此这里不会出现"新服务器的标题配着旧服务器的指标"。
struct ServerDetailView: View {
    @Bindable var model: AppModel
    let server: ServerRecord

    var body: some View {
        let state = model.state(of: server.id)

        Group {
            // 状态的优先级：先看能不能连上，再看连上之后的数据。
            // 反过来会让一个连不上的服务器显示四个空页签，而用户
            // 完全不知道问题出在哪。
            switch state {
            case .needsPairing(let detail):
                EmptyHint(
                    symbol: "key.slash",
                    title: tr("这台服务器需要重新配对", "This server needs pairing again"),
                    message: detail,
                    action: (tr("重新配对", "Pair again"), { model.forget(server.id) }))
            case .identityChanged(let detail):
                EmptyHint(
                    symbol: "exclamationmark.shield",
                    title: tr("服务器身份已变化", "The server's identity changed"),
                    message: detail)
            case .unreachable(let detail):
                EmptyHint(
                    symbol: "wifi.exclamationmark",
                    title: tr("连不上这台服务器", "Cannot reach this server"),
                    message: detail,
                    // `retry()` 不阻塞：它把状态标成"连接中"就返回，
                    // 于是点下去的**当帧**就会画出四个页签的骨架 ——
                    // 而不是让用户对着一个按下去没反应的按钮等一轮超时。
                    action: (tr("重试", "Try again"), { model.retry() }))
            default:
                // `.connecting` / `.idle` 也走这里：连接中看到的是各页签的
                // 占位骨架，数据到了就地填入。空白或转圈都不是它该有的样子。
                TabsView(model: model, server: server)
            }
        }
        .navigationTitle(server.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RoleBadge(canWrite: model.canWrite)
            }
        }
    }
}

/// 角色徽标。
///
/// 它存在的理由不是装饰：`operator` 与 `viewer` 在界面上的差别是"按钮能
/// 不能点"，而一个被置灰的按钮如果不解释为什么，用户只会以为应用坏了。
struct RoleBadge: View {
    let canWrite: Bool

    var body: some View {
        Label(canWrite ? tr("可改 DNS", "Can edit DNS") : tr("只读监控", "Read-only"),
              systemImage: canWrite ? "pencil.and.list.clipboard" : "eye")
            .font(.caption)
            .foregroundStyle(canWrite ? Color.accentColor : Color.secondary)
    }
}

struct TabsView: View {
    @Bindable var model: AppModel
    let server: ServerRecord

    var body: some View {
        TabView {
            OverviewView(model: model)
                .tabItem { Label(tr("概览", "Overview"), systemImage: "gauge.with.dots.needle.50percent") }
            ServicesView(model: model)
                .tabItem { Label(tr("服务", "Services"), systemImage: "square.stack.3d.up") }
            ResourcesView(model: model)
                .tabItem { Label(tr("资源", "Resources"), systemImage: "chart.xyaxis.line") }
            DNSView(model: model)
                .tabItem { Label(tr("DNS", "DNS"), systemImage: "globe") }
        }
    }
}

/// 底部横幅。
///
/// 与 `EmptyHint` 一样，宽度与高度都要钉住（ISC-Core 的 D33）：一条拼接
/// 出来的长错误会让整个布局被撑开，而症状是"某个完全无关的区域变成空白"。
struct BannerRow: View {
    let text: String
    let tint: Color
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .frame(maxWidth: Theme.messageMaxWidth, alignment: .leading)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
