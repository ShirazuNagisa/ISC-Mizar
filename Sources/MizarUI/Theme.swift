import SwiftUI
import MizarKit

/// 双语取词。
///
/// 与 ISC-Phecda 的 `tr(_:_:)` 同构：中文在前（它是源语言），英文在后。
/// 组件层自带一份而不是从 app target 传入：`MizarUI` 要同时编译到
/// iOS 与 watchOS，把一个函数当参数层层传递只会让每个视图多一个属性。
///
/// 用内联双语而不是 String Catalog：这两个应用的文案量都在几百条量级，
/// 而 catalog 的键与内核的 i18n 键会立刻分叉成两套命名体系。
public func tr(_ zh: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
}

/// 内核与 CLI 用的语言代码。
public var kernelLanguage: String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-CN" : "en"
}

/// Mizar 的界面常量。
///
/// 与 Phecda 一样，这里**不做设计令牌系统**：两个应用的视觉语言来自
/// 系统组件（Liquid Glass / 语义色 / SF Symbols），而这里只放那些
/// 被多处引用、且"写歪了会真的坏掉"的常量。
public enum Theme {
    /// 正文的最大宽度。
    ///
    /// 来自 ISC-Core 的 D33：弹性列里的文本必须**同时**钉住宽度与高度。
    /// 一个不可断行的长 URL（DNS 记录、地址列表）会把自己的理想宽度与
    /// 理想高度一起向上传播，把整个分栏布局撑坏 —— 而症状是
    /// "侧栏莫名其妙变成空白"，与 DNS 毫无关系。
    public static let messageMaxWidth: CGFloat = 460
    public static let messageMaxLines = 8

    /// 指标卡的圆角。
    public static let cardRadius: CGFloat = 14
    public static let rowRadius: CGFloat = 10
}

/// 把内核的状态字符串映射成颜色、文案与图标。
///
/// 认不出的取值**原样显示**而不是隐藏：内核多一个状态时，用户应该看到
/// 那个新状态本身，而不是一个空白或者一个假的默认值。
public enum StateStyle {
    public static func color(_ state: String) -> Color {
        switch state {
        case "running", "healthy", "ok", "success": .green
        case "starting", "provisioning", "installing", "building", "stopping": .orange
        case "failed", "unhealthy", "degraded": .red
        case "stopped", "draft": .secondary
        default: .secondary
        }
    }

    /// 状态文案。
    ///
    /// 认不出的取值**原样返回**：内核多一个状态时，用户应该看到那个新状态
    /// 本身，而不是一个空白或者一个假的默认值。
    public static func label(_ state: String) -> String {
        switch state {
        case "running": tr("运行中", "Running")
        case "stopped": tr("已停止", "Stopped")
        case "starting": tr("启动中", "Starting")
        case "stopping": tr("停止中", "Stopping")
        case "building": tr("构建中", "Building")
        case "installing": tr("安装中", "Installing")
        case "provisioning": tr("准备中", "Preparing")
        case "failed": tr("失败", "Failed")
        case "draft": tr("草稿", "Draft")
        case "healthy": tr("健康", "Healthy")
        case "unhealthy": tr("不健康", "Unhealthy")
        default: state
        }
    }

    public static func healthSymbol(_ health: String) -> String {
        switch health {
        case "healthy": "checkmark.circle.fill"
        case "unhealthy": "xmark.circle.fill"
        case "starting": "clock.fill"
        default: "questionmark.circle"
        }
    }
}

/// 一个状态徽标：圆点 + 文案 + 健康图标。
public struct StatePill: View {
    public let state: String
    public let health: String

    public init(state: String, health: String) {
        self.state = state
        self.health = health
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle().fill(StateStyle.color(state)).frame(width: 7, height: 7)
            Text(StateStyle.label(state)).font(.caption)
            if !health.isEmpty && health != "unknown" {
                Image(systemName: StateStyle.healthSymbol(health))
                    .font(.caption2)
                    .foregroundStyle(StateStyle.color(health))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.25), in: .capsule)
    }
}
