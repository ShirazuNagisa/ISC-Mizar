import Foundation

/// 内核契约的**类型化**入口。
///
/// 与 ISC Phecda 的 `Sources/ISCCore/KernelAPI.swift` 是同一份代码，
/// 唯一的差别在 `KernelClient` 的构造（那边注入 C 调用，这边注入传输）。
/// 因此两个应用对同一个契约的解读不会有分歧 —— 而"两边各写一遍"正是
/// 契约最容易漂移的地方。
///
/// 这里只声明 Mizar 真正用得上的接口。远程面只有一份白名单，而这份
/// 文件与它一一对应：**界面能调的东西，服务端也允许**。

extension KernelClient {

    // MARK: - 通用入口

    /// 发一个请求并把响应体解码成 `T`。
    public func send<T: Decodable>(_ method: String, _ path: String,
                                   body: (some Encodable)? = Optional<Never>.none,
                                   as type: T.Type = T.self) async throws -> T {
        let reply = try await perform(method, path, body: body)
        guard let payload = try? reply.body.data() else {
            throw KernelError(code: "decoding", status: reply.status,
                              message: "内核返回了无法读取的响应体。")
        }
        do {
            return try JSONDecoder.mizar.decode(T.self, from: payload)
        } catch {
            throw KernelError(code: "decoding", status: reply.status,
                              message: "内核的响应与 \(path) 的预期形状不符：\(error)")
        }
    }

    @discardableResult
    public func sendIgnoringReply(_ method: String, _ path: String,
                                  body: (some Encodable)? = Optional<Never>.none) async throws -> Int {
        try await perform(method, path, body: body).status
    }

    private func perform(_ method: String, _ path: String,
                         body: (some Encodable)?) async throws -> KernelReply {
        guard let body else { return try await call(method, path) }
        let encoded = try JSONEncoder.mizar.encode(body)
        return try await callRaw(method, path, body: String(decoding: encoded, as: UTF8.self))
    }

    // MARK: - 元信息与健康

    public func health() async throws -> KernelHealth {
        try await send("GET", "/v1/health", body: Optional<Never>.none, as: KernelHealth.self)
    }

    public func meta() async throws -> KernelMeta {
        try await send("GET", "/v1/meta", body: Optional<Never>.none, as: KernelMeta.self)
    }

    // MARK: - 远程面自身

    public func remoteSelf() async throws -> RemoteSelfInfo {
        try await send("GET", "/v1/remote/self", body: Optional<Never>.none, as: RemoteSelfInfo.self)
    }

    /// 派生一台只读设备（给 Apple Watch）。
    ///
    /// 服务端会拒绝**高于自己**的角色，因此这里即便传了 `operator`
    /// 也不会越权 —— 约束在服务端，不在这一行。
    public func deriveDevice(role: String, label: String, device: PairingService.DeviceInfo) async throws -> DerivedDevice {
        try await send("POST", "/v1/remote/self/derive",
                       body: DeriveRequest(role: role, label: label, device: device),
                       as: DerivedDevice.self)
    }

    public struct DeriveRequest: Encodable, Sendable {
        public var role: String
        public var label: String
        public var device: PairingService.DeviceInfo
    }

    /// 派生出来的设备与它的令牌。
    public struct DerivedDevice: Decodable, Sendable {
        public let deviceId: String
        public let token: String
        public let role: String
    }

    public func registerPushToken(_ token: String, environment: String, topic: String?) async throws {
        try await sendIgnoringReply("POST", "/v1/remote/self/push-token",
                                    body: PushTokenRequest(token: token,
                                                           environment: environment,
                                                           topic: topic))
    }

    public func unregisterPushToken() async throws {
        try await sendIgnoringReply("DELETE", "/v1/remote/self/push-token")
    }

    public struct PushTokenRequest: Encodable, Sendable {
        public var token: String
        public var environment: String
        public var topic: String?
    }

    // MARK: - 指标与建议

    public func metrics() async throws -> MetricsSnapshot {
        try await send("GET", "/v1/metrics", body: Optional<Never>.none, as: MetricsSnapshot.self)
    }

    public func advisories() async throws -> [Advisory] {
        try await send("GET", "/v1/advisories", body: Optional<Never>.none, as: AdvisoryList.self).items
    }

    // MARK: - 站点

    public func apps() async throws -> [AppRecord] {
        try await send("GET", "/v1/apps", body: Optional<Never>.none, as: AppList.self).items
    }

    public func app(_ id: String) async throws -> AppRecord {
        try await send("GET", "/v1/apps/\(Self.pathComponent(id))", body: Optional<Never>.none, as: AppRecord.self)
    }

    public func appLogs(_ id: String, tail: Int = 200) async throws -> [String] {
        try await send("GET", "/v1/apps/\(Self.pathComponent(id))/logs?tail=\(tail)",
                       body: Optional<Never>.none, as: AppLogs.self).lines
    }

    public func startApp(_ id: String) async throws { try await appAction(id, "start") }
    public func stopApp(_ id: String) async throws { try await appAction(id, "stop") }
    public func restartApp(_ id: String) async throws { try await appAction(id, "restart") }

    private func appAction(_ id: String, _ action: String) async throws {
        try await sendIgnoringReply("POST", "/v1/apps/\(Self.pathComponent(id))/\(action)")
    }

    // MARK: - 地址

    public func currentIP() async throws -> IPStatus {
        try await send("GET", "/v1/ip/current", body: Optional<Never>.none, as: IPStatus.self)
    }

    // MARK: - DNS

    public func credentials() async throws -> [CredentialInfo] {
        try await send("GET", "/v1/credentials", body: Optional<Never>.none, as: CredentialList.self).items
    }

    public func zones(credentialID: String) async throws -> [DNSZone] {
        try await send("GET", "/v1/credentials/\(Self.pathComponent(credentialID))/zones",
                       body: Optional<Never>.none, as: DNSZoneList.self).items
    }

    public func records(credentialID: String, zone: String) async throws -> [DNSRecord] {
        try await send("GET", "/v1/credentials/\(Self.pathComponent(credentialID))/zones/\(Self.pathComponent(zone))/records",
                       body: Optional<Never>.none, as: DNSRecordList.self).items
    }

    public func createRecord(credentialID: String, zone: String,
                             name: String, type: String, content: String,
                             ttl: Int? = nil, proxied: Bool? = nil,
                             comment: String? = nil) async throws -> DNSRecord {
        try await send("POST", "/v1/credentials/\(Self.pathComponent(credentialID))/zones/\(Self.pathComponent(zone))/records",
                       body: DNSRecordRequest(name: name, type: type, content: content,
                                              ttl: ttl, proxied: proxied, comment: comment),
                       as: DNSRecord.self)
    }

    public func updateRecord(credentialID: String, zone: String, recordID: String,
                             name: String, type: String, content: String,
                             ttl: Int? = nil, proxied: Bool? = nil,
                             comment: String? = nil) async throws -> DNSRecord {
        // PUT 而不是删了重建：后者会让那条记录在 DNS 上消失一小会儿，
        // 而解析的缓存窗口远长于那段时间 —— 表现为"改个 TTL 导致站点断了几分钟"。
        try await send("PUT", "/v1/credentials/\(Self.pathComponent(credentialID))/zones/\(Self.pathComponent(zone))/records/\(Self.pathComponent(recordID))",
                       body: DNSRecordRequest(name: name, type: type, content: content,
                                              ttl: ttl, proxied: proxied, comment: comment),
                       as: DNSRecord.self)
    }

    public func deleteRecord(credentialID: String, zone: String, recordID: String) async throws {
        try await sendIgnoringReply("DELETE", "/v1/credentials/\(Self.pathComponent(credentialID))/zones/\(Self.pathComponent(zone))/records/\(Self.pathComponent(recordID))")
    }

    public struct DNSRecordRequest: Encodable, Sendable {
        public var name: String
        public var type: String
        public var content: String
        public var ttl: Int?
        public var proxied: Bool?
        public var comment: String?

        public init(name: String, type: String, content: String,
                    ttl: Int? = nil, proxied: Bool? = nil, comment: String? = nil) {
            self.name = name
            self.type = type
            self.content = content
            self.ttl = ttl
            self.proxied = proxied
            self.comment = comment
        }

        public init(from record: DNSRecord) {
            self.init(name: record.name, type: record.type, content: record.content,
                      ttl: record.ttl, proxied: record.proxied, comment: record.comment)
        }
    }

    // MARK: - 动态解析

    public func ddnsTasks() async throws -> [DdnsTaskInfo] {
        try await send("GET", "/v1/ddns-tasks", body: Optional<Never>.none, as: DdnsTaskList.self).items
    }

    public func runDdnsTask(_ id: String) async throws {
        try await sendIgnoringReply("POST", "/v1/ddns-tasks/\(Self.pathComponent(id))/run")
    }

    public func setDdnsTask(_ id: String, enabled: Bool) async throws -> DdnsTaskInfo {
        // 走服务端的窄接口而不是 `PATCH /v1/ddns-tasks/{id}`：后者能改域名
        // 与取址来源，权限面远大于"启停"，因此**不在远程面的白名单里**。
        // 客户端能不能只发一个字段不是安全边界，服务端允许什么才是。
        try await send("POST", "/v1/ddns-tasks/\(Self.pathComponent(id))/\(enabled ? "enable" : "disable")",
                       body: Optional<Never>.none, as: DdnsTaskInfo.self)
    }

    // MARK: - 证书与反代

    public func certificates() async throws -> [CertificateInfo] {
        try await send("GET", "/v1/certs", body: Optional<Never>.none, as: CertificateList.self).items
    }

    public func renewCertificates() async throws {
        try await sendIgnoringReply("POST", "/v1/certs/renew")
    }

    public func proxyStatus() async throws -> ProxyStatus {
        try await send("GET", "/v1/proxy/status", body: Optional<Never>.none, as: ProxyStatus.self)
    }

    // MARK: - 公网访问

    /// 回报一次可达性自检的结果。
    ///
    /// 内核据此决定要不要写 A 记录 —— **只有实测过 IPv4 可达才写**。
    /// 写一条连不上的 A 比不写更糟：客户端默认先试 IPv4，
    /// 于是它会先卡在一个永远连不上的地址上。
    @discardableResult
    public func reportPublicCheck(_ report: PublicCheckReport) async throws -> PublicStatus {
        try await send("POST", "/v1/remote/public/check",
                       body: PublicCheckRequest(report: report), as: PublicStatus.self)
    }
}
