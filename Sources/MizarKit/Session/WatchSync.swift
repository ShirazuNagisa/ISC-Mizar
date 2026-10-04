import Foundation
import MizarKit

/// 手表从手机同步过去的一台服务端。
///
/// # 为什么连令牌一起同步
///
/// 手表没有摄像头也没有键盘，无法自己扫码或输入六位码。它唯一的
/// 接入方式就是手机把**已经建立好的**连接交给它。
///
/// 交出去的令牌是**派生的只读令牌**，不是手机自己的那一份：
///
///   - 它在 Phecda 的设备列表里是一台独立设备，可以单独吊销；
///   - 它的角色不高于父设备（服务端强制），因此手表即使被改也写不了；
///   - 吊销手机会级联吊销它。
///
/// 把手机自己的令牌复制一份给手表会让这三条**一条都不成立** ——
/// 而那时的症状是"手表看起来只是能看"，实际上它握着完整的写权限。
public struct SyncedServer: Codable, Sendable, Equatable {
    public var record: ServerRecord
    public var token: String

    public init(record: ServerRecord, token: String) {
        self.record = record
        self.token = token
    }
}

/// 一次同步的完整载荷。
public struct WatchSyncPayload: Codable, Sendable, Equatable {
    /// 当前版本。
    ///
    /// 手表与手机是**两个可以独立更新**的应用（手表上的那个往往晚几天
    /// 才更新完）。版本号让"新手机 + 旧手表"这种情况表现成一句
    /// "请更新手表上的 Mizar"，而不是一堆解不出来的字段。
    public static let currentVersion = 1

    public var version: Int
    public var generatedAt: Date
    public var servers: [SyncedServer]

    public init(servers: [SyncedServer], generatedAt: Date = Date()) {
        self.version = Self.currentVersion
        self.generatedAt = generatedAt
        self.servers = servers
    }

    /// 编码成可以交给 `WCSession` 的字节。
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// 从字节解出载荷。
    ///
    /// 版本更高时抛 `unsupportedVersion` —— 与配对码同一个道理：
    /// 让用户做的事（更新手表上的应用）与"数据坏了"完全不同。
    public static func decode(_ data: Data) throws -> WatchSyncPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // 先只解版本，再解完整结构：更高版本的字段可能对不上，
        // 而直接解完整结构会把"请更新应用"报成"数据无法解析"。
        struct Probe: Decodable { let version: Int? }
        if let probe = try? decoder.decode(Probe.self, from: data),
           let version = probe.version, version > currentVersion {
            throw WatchSyncError.unsupportedVersion(version)
        }
        return try decoder.decode(WatchSyncPayload.self, from: data)
    }

    /// 手表侧应用这份载荷时看到的摘要（供界面显示"从手机同步了 N 台"）。
    public var summary: String { "\(servers.count)" }
}

public enum WatchSyncError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedVersion(Int)
    case empty
    case noDerivedAccess(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "这台手机上的 Mizar 更新（v\(version)），请把 Apple Watch 上的也更新到最新版本。"
        case .empty:
            "手机上还没有可以同步的服务端。"
        case .noDerivedAccess(let name):
            "无法为「\(name)」派生只读访问权：请先在手机上打开一次它。"
        }
    }
}


extension Notification.Name {
    /// 请求立刻把手上的配置同步给手表。
    ///
    /// 由界面发出、由应用壳处理 —— 与推送注册同一个模式：包里的代码
    /// 在 macOS 上也要能编译，而 `WCSession` 只有 iOS 与 watchOS 有。
    public static let mizarRequestWatchSync = Notification.Name("app.isc.mizar.request-watch-sync")
}
