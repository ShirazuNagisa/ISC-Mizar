import SwiftUI
import MizarApp
import MizarKit
import MizarUI

/// watchOS 的应用入口。
///
/// # 手表上**没有**写操作，这是服务端保证的
///
/// 手表既没有摄像头也没有键盘，无法自己扫码，因此它的令牌是从配对过的
/// iPhone 派生出来的。让手表直接复用手机的令牌会绕开"手表只读"这条约束 ——
/// 而约束如果只写在客户端里，改一个字段就没了。
///
/// 因此手表用的是 `POST /v1/remote/self/derive` 签发的**角色不高于手机**
/// 的独立令牌：它在 Phecda 的设备列表里是一台可以单独吊销的设备，
/// 而服务端会拒绝任何越权的写请求。
@main
struct MizarWatchApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: model)
                .task {
                    // 同步会话要**先激活再连**：手表上的配置全部来自手机，
                    // 而它可能在激活完成之前就已经开始渲染了。
                    WatchSyncSession.shared.activate(model: model)
                    await model.enterForeground()
                }
        }
    }
}

/// 手表上的根：服务器列表 → 概览。
///
/// 刻意只有两屏：手表上翻三屏才看到 CPU 是一件很累的事，而用户抬手腕
/// 想知道的是"家里那台机器有事吗"。其余的一切都在手机上看。
struct WatchRootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.servers) { server in
                    NavigationLink {
                        WatchOverviewView(model: model, server: server)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(.headline)
                            Text(model.state(of: server.id).summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if model.servers.isEmpty {
                    Text("还没有服务端。请先在 iPhone 上添加。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Mizar")
        }
    }
}

/// 一台服务器的概览（只读）。
struct WatchOverviewView: View {
    @Bindable var model: AppModel
    let server: ServerRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                let state = model.state(of: server.id)
                if state.isOnline, let host = model.metrics?.host {
                    metric("CPU", host.cpuPercent.formattedPercentValue)
                    metric("内存", "\(host.memoryUsedBytes.formattedBytes)")
                    metric("网络", host.netRxBytesPerSec.formattedRate)
                    if let gpu = host.gpu, gpu.isSupported,
                       let value = gpu.utilizationPercent {
                        metric("GPU", value.formattedPercentValue)
                    }
                } else {
                    Text(state.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !model.apps.isEmpty {
                    Divider()
                    Text("站点").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.apps) { app in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(StateStyle.color(app.state))
                                .frame(width: 6, height: 6)
                            Text(app.name).font(.caption)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(server.name)
        .task {
            await model.select(server.id)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.callout, design: .rounded)).monospacedDigit()
        }
    }
}
