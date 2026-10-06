import Foundation

/// 契约层的最小模型集合。
///
/// 与 Phecda 的 `KernelModels.swift` 是同一套约定：
///
///   * 可选性照着契约里的 `required` 走 —— 契约说必填的用非可选，
///     这样漏字段会在解码时报错，而不是悄悄变成一个空字符串显示给用户；
///   * **状态一律是 String，不是 enum** —— 内核多一个取值时，界面应该
///     显示它而不是解码失败；
///   * 只声明本应用真正用到的字段，不做全量镜像。

// MARK: - 远程面自身

/// `GET /v1/remote/self` 的响应。
public struct RemoteSelfInfo: Decodable, Sendable {
    public let role: String
    public let device: RemoteDeviceInfo
    public let server: PairingService.ServerInfo
    /// 可达性自检的探测计划。
    ///
    /// 它挂在这里而不是单独一个接口：手机本来就每次连接都取一次
    /// `/v1/remote/self`，因此不多一次往返，也意味着手机随时拿着
    /// **最新**的公网地址（地址会变）。
    public let `public`: PublicProbePlan?

    public var canWrite: Bool { role == "operator" }
}

/// 一次探测的回报（发给内核）。
public struct PublicCheckRequest: Encodable, Sendable {
    public var family: String
    public var reachable: Bool
    public var sameLan: Bool
    public var detail: String?

    public init(report: PublicCheckReport) {
        self.family = report.family
        self.reachable = report.reachable
        self.sameLan = report.sameLan
        self.detail = report.detail
    }
}

/// 公网访问的状态（内核侧）。
public struct PublicStatus: Decodable, Sendable {
    public let enabled: Bool
    public let ready: Bool
    public let host: String?
    public let records: [String: String]?
    public let lastCheck: PublicCheck?

    public struct PublicCheck: Decodable, Sendable {
        public let at: Date
        public let verdict: String
        public let family: String?
        public let detail: String?
    }

    /// 内核观测到的 AAAA / A 地址。
    public var ipv6: String? { records?["AAAA"] }
    public var ipv4: String? { records?["A"] }
}

public struct RemoteDeviceInfo: Decodable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let role: String
    public let notificationsEnabled: Bool
    public let osVersion: String?
    public let model: String?
}

// MARK: - 元信息与健康

public struct KernelHealth: Decodable, Sendable {
    public let status: String
    public let uptimeSeconds: Int64
    public let version: String?

    public var ok: Bool { status == "ok" }
}

public struct KernelMeta: Decodable, Sendable {
    public let version: String
    public let apiVersion: String
    public let commit: String?
    public let os: String?
    public let arch: String?
    public let startedAt: Date?
    public let capabilities: KernelCapabilities?
}

public struct KernelCapabilities: Decodable, Sendable {
    public let remote: ImplState?
    public let metricsGpu: ImplState?

    private enum CodingKeys: String, CodingKey {
        case remote
        case metricsGpu
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remote = try? container.decodeIfPresent(ImplState.self, forKey: .remote)
        metricsGpu = try? container.decodeIfPresent(ImplState.self, forKey: .metricsGpu)
    }
}

/// 某个平台后端的实现状态。
public struct ImplState: Decodable, Sendable {
    public let available: Bool
    public let backend: String
    public let note: String?

    /// `unsupported` 表示这个平台没有实现它。
    ///
    /// 界面据此显示"此平台不支持"，而不是显示一个假的 0 ——
    /// 这两者对用户的意义完全不同。
    public var isSupported: Bool { available && backend != "unsupported" }
}

// MARK: - 指标

public struct MetricsSnapshot: Decodable, Sendable {
    public let host: HostMetrics
    /// 内核自身 + 站点的合计占用。旧内核不发这个字段，因此可选。
    public let footprint: FootprintMetrics?
    public let apps: [AppMetrics]
    public let history: [HostMetrics]?
}

public struct HostMetrics: Decodable, Sendable {
    public let at: Date?
    public let cpuPercent: Double
    public let memoryUsedBytes: Int
    public let memoryTotalBytes: Int
    public let netRxBytesPerSec: Double
    public let netTxBytesPerSec: Double
    public let backend: String?
    /// 挂载点只在**当前快照**里有，历史点里没有（见契约里的说明）。
    public let disks: [DiskMetrics]?
    public let gpu: GpuMetrics?

    public var memoryFraction: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }

    public var metricsUnsupported: Bool { backend == "unsupported" }
}

public struct DiskMetrics: Decodable, Sendable, Identifiable {
    public let mountPoint: String
    public let fsType: String?
    public let totalBytes: Int
    public let usedBytes: Int
    public let freeBytes: Int

    public var id: String { mountPoint }

    /// 已用占比。
    ///
    /// 用 used/(used+free) 而不是 used/total：ext4 默认给 root 留 5%，
    /// 那部分既不算已用、也不算用户可用，摊进任何一边都会得到一个
    /// 与 `df` 对不上的数字。
    public var fraction: Double {
        let denom = usedBytes + freeBytes
        guard denom > 0 else { return 0 }
        return Double(usedBytes) / Double(denom)
    }
}

public struct GpuMetrics: Decodable, Sendable {
    public let backend: String
    public let name: String?
    public let utilizationPercent: Double?

    public var isSupported: Bool { backend != "unsupported" }
}

/// **内核自己 + 它托管的站点**的合计占用。
///
/// # 为什么手机端也要区分它和 HostMetrics
///
/// `HostMetrics` 是那台服务器整机的占用，这个是"上面跑的这套东西占了多少"。
/// 手机上看一眼就知道"服务器卡是不是因为这边的站点"，不必让用户自己去减。
///
/// # 三条读法上的边界（定义在 Core 的 D39）
///
///   - 含站点的**进程树**：预设里的 `npm start` 会再 fork 出 node；
///   - `memoryBytes` 是各进程 RSS 之和，是一个上界；
///   - `cpuPercent` 是各进程之和，**可能超过 100**（每个进程的 100% 指
///     "一个核跑满"），画进度条前必须钳到 0...1。
///
/// GPU 不在里面：macOS 没有按进程归因 GPU 的途径，看 `HostMetrics.gpu`。
public struct FootprintMetrics: Decodable, Sendable {
    public let at: Date?
    public let cpuPercent: Double
    public let memoryBytes: Int
    /// 仅在 `netBackend` 是后端名时才有值 —— 另外两种状态（不支持 /
    /// 没读到）下内核**不发**这两个字段，界面据此显示"—"而不是 0。
    public let netRxBytesPerSec: Double?
    public let netTxBytesPerSec: Double?
    /// 网络数字的来源，三态：后端名 / `unsupported` / `unavailable`。
    /// 三者必须分开显示：把"没读到"说成 0 会让用户以为它不占网络。
    public let netBackend: String
    /// 参与合计的进程数。
    public let processes: Int

    public var hasNetwork: Bool { netRxBytesPerSec != nil && netTxBytesPerSec != nil }

    /// 进度条用的占比。多核机器上 CPU 之和会超过 100%，不钳会画到框外。
    public var cpuFraction: Double { min(1, max(0, cpuPercent / 100)) }
}

public struct AppMetrics: Decodable, Sendable, Identifiable {
    public let appId: String
    public let pid: Int
    public let cpuPercent: Double
    public let memoryBytes: Int
    public let uptimeSeconds: Int64

    public var id: String { appId }

    /// 静态站点由内核自己托管，没有独立进程可测。
    public var hasOwnProcess: Bool { pid > 0 }
}

// MARK: - 站点与建议

public struct AppRecord: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let presetId: String
    public let kind: String
    public let sourcePath: String
    public let localPort: Int
    public let state: String
    public let health: String
    public let healthDetail: String?
    public let restartCount: Int?
    public let lastError: String?
    public let domains: [AppDomain]?
    public let createdAt: Date?
    public let updatedAt: Date?

    public var isRunning: Bool { state == "running" }
    public var isBusy: Bool {
        ["provisioning", "installing", "building", "starting", "stopping"].contains(state)
    }
    /// 空 kind 表示静态站点（由内核直接托管）。
    public var isStatic: Bool { kind.isEmpty }
    public var domainNames: [String] { (domains ?? []).map(\.name) }
}

public struct AppDomain: Decodable, Sendable, Identifiable {
    public let name: String
    public let routeReady: Bool?
    public let certExpiresAt: Date?
    public let certNeedsRenew: Bool?
    public let certError: String?

    public var id: String { name }
}

public struct AppList: Decodable, Sendable {
    public let items: [AppRecord]
}

public struct AppLogs: Decodable, Sendable {
    public let lines: [String]
}

public struct Advisory: Decodable, Sendable, Identifiable {
    public let id: String
    public let severity: String
    public let title: String
    public let detail: String?
}

public struct AdvisoryList: Decodable, Sendable {
    public let items: [Advisory]
}

// MARK: - 地址

public struct IPStatus: Decodable, Sendable {
    public let ipv4: [String]?
    public let ipv6: [String]?
    public let globalIpv6: [String]?
    public let interfaces: [InterfaceAddrs]?
}

public struct InterfaceAddrs: Decodable, Sendable, Identifiable {
    public let name: String
    public let ipv4: [String]?
    public let globalIpv6: [String]?
    public let isUp: Bool?

    public var id: String { name }
}

// MARK: - DNS

public struct CredentialInfo: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let provider: String
    public let label: String
    public let lastVerifyOk: Bool?
    public let lastVerifyError: String?

    /// 凭据的敏感字段在内核侧就已经是掩码了 —— 手机拿不到明文，
    /// 这是有意的：改 DNS 记录需要的是凭据 id，不是它的内容。
    public var verifyState: String {
        guard let ok = lastVerifyOk else { return "unverified" }
        return ok ? "ok" : "failed"
    }
}

public struct CredentialList: Decodable, Sendable {
    public let items: [CredentialInfo]
}

public struct DNSZone: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let status: String?
}

public struct DNSZoneList: Decodable, Sendable {
    public let items: [DNSZone]
}

public struct DNSRecord: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let type: String
    public let content: String
    public let ttl: Int?
    public let proxied: Bool?
    public let comment: String?
}

public struct DNSRecordList: Decodable, Sendable {
    public let items: [DNSRecord]
}

public struct DdnsTaskInfo: Decodable, Sendable, Identifiable {
    public let id: String
    public let credentialId: String
    public let label: String
    public let enabled: Bool
    public let lastRunAt: Date?
    public let lastStatus: String?
    public let lastMessage: String?
    public let lastIpv4: String?
    public let lastIpv6: String?
}

public struct DdnsTaskList: Decodable, Sendable {
    public let items: [DdnsTaskInfo]
}

// MARK: - 证书

public struct CertificateInfo: Decodable, Sendable, Identifiable {
    public let domains: [String]
    public let notAfter: Date?
    public let staging: Bool?
    public let error: String?

    public var id: String { domains.joined(separator: ",") }

    public var daysRemaining: Int? {
        guard let notAfter else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: notAfter).day
    }
}

public struct CertificateList: Decodable, Sendable {
    public let items: [CertificateInfo]
}

public struct ProxyStatus: Decodable, Sendable {
    public let running: Bool
    public let port: Int
    public let tls: Bool
    public let routes: Int
    public let error: String?
}
