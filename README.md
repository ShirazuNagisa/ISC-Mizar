# ISC Mizar

ISC Phecda 的移动端配套应用：在 iPhone、iPad 与 Apple Watch 上查看 Phecda
服务端的运行状态与资源占用（CPU / GPU / 内存 / 磁盘 / 网络），并远程配置
DNS 解析。

## 它连的是什么

Mizar 连的是**内核的远程管理面**，而不是 Phecda 本身。那条链路由内核提供，
在 Phecda 的「远程访问」页上开启：

* 独立监听（默认 8788）+ 自签证书，客户端固定**公钥指纹**；
* 扫码（或手输六位码）配对，换取按设备签发的长期令牌；
* 两级角色：`viewer` 只读、`operator` 还能改 DNS 记录、启停站点与续期证书；
* 权限由**服务端**判定 —— 手表用的是服务端派生的只读令牌，
  即使客户端被改也写不了任何东西。

安全模型见 ISC-Core 的 [`docs/REMOTE-ACCESS.md`](../ISC-Core/docs/REMOTE-ACCESS.md)
与决策 D38。

## 仓库结构

```
Sources/MizarKit/    传输、契约模型、配对、持久化 —— 只依赖 Foundation，
                     因此可以在 macOS 上用 `swift test` 完整验证
Sources/MizarUI/     跨 iOS / watchOS 的 SwiftUI 组件
Sources/MizarApp/    状态机 + 推送 + 手表同步（iOS 与 watchOS 共用，
                     因此不含任何屏幕）
Sources/MizarScreens/ iOS / iPadOS 的全部屏幕
App/                 Xcode 工程：两个很薄的应用壳（@main + Info.plist）
Tests/MizarKitTests/ Swift Testing
Scripts/             构建、测试与端到端验收
```

## 开发

```bash
swift test                 # 契约层与配对逻辑（macOS 上跑，不需要模拟器）
Scripts/test.sh            # 同上 + 格式与构建检查
Scripts/build-ios.sh       # xcodebuild 到 iOS 模拟器
Scripts/acceptance.sh      # 对着真实内核跑一遍配对（扫码 + 手输）→ 读数据 → 吊销
Scripts/acceptance-ios.sh  # 在模拟器上把真实应用连上真实内核（验证 TLS/ATS）
Scripts/build-watch.sh     # 构建 watchOS 应用
```

## 许可证

GPL-3.0，与 ISC-Core 和 ISC Phecda 一致。
