import Foundation

/// Mizar 自身的版本。
///
/// # 为什么是一个常量，而不是读 Info.plist
///
/// 这个字符串要出现在三个地方，而它们**都不一定**有应用包：
///
///   - 应用里的「关于」（有 Info.plist）；
///   - `swift test`（没有，`Bundle.main` 是测试运行器）；
///   - `MizarAcceptance` 那个命令行工具（没有，它是可执行文件）。
///
/// 读 `Bundle.main` 在前两种情况下会安静地拿到 `nil`，于是"应用版本"那一行
/// 显示成 `—` —— 而那恰好是排查问题时最需要它的一刻。因此这里是唯一的事实
/// 来源，Info.plist 里的 `CFBundleShortVersionString` 与它对齐，由
/// `Scripts/test.sh` 断言两者一致。
///
/// # 它还会被发到服务端
///
/// 配对时随设备信息一起上报，落在内核的 `remote_devices.app_version`。
/// 那让 Phecda 的设备列表能显示"这台手机上的 Mizar 是哪个版本" ——
/// 当契约出现不兼容时，那是第一个要看的字段。
public enum MizarVersion {

    /// 语义化版本号，不带 `v` 前缀（与 Info.plist 对齐）。
    public static let current = "0.2.0"

    /// 展示用的形式。
    public static var display: String { "v\(current)" }

    /// 上报给服务端的值。
    public static var reported: String { current }
}
