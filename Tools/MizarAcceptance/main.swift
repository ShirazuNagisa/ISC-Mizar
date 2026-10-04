import Foundation
import MizarKit

// 验收工具：对着**真实内核**跑一遍配对与连接。
//
// 单元测试用的是假传输，因此证明不了"真的能连上"。这个工具走完整条链路：
// 解析二维码 → 逐个候选地址试 HTTPS → 比对证书公钥指纹 → 换设备令牌 →
// 拉指标。自签证书的固定是这条链路上最可能出问题的一环（也是唯一一个
// 无法用单元测试证明的环节）。
//
// 用法：
//   MizarAcceptance pair-qr   <二维码原文> <状态目录> [可达地址]
//   MizarAcceptance pair-code <地址> <六位码> <状态目录>
//   MizarAcceptance status    <状态目录>
//   MizarAcceptance expect    <状态目录> <状态名>

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("用法：MizarAcceptance <pair|status|expect> ...\n".utf8))
    exit(2)
}

/// 把令牌写到状态目录。
///
/// 刻意不用 Keychain：验收工具会在无人值守的脚本里跑，而 Keychain 在
/// 那种环境下可能弹窗或直接失败 —— 那会让"验证"变成"看运气"。
struct FileTokenStore: TokenStore {
    let url: URL

    func token(for serverID: String) throws -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    func setToken(_ token: String?, for serverID: String) throws {
        if let token {
            try token.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func removeAll() throws {
        try? FileManager.default.removeItem(at: url)
    }
}

func fail(_ message: String) -> Never {
    print("❌ \(message)")
    exit(1)
}

func ok(_ message: String) {
    print("✅ \(message)")
}

/// 把一次配对的结果落到状态目录，并汇报基本信息。
func commit(_ outcome: PairingService.Outcome, into stateDirectory: URL) async throws {
    let store = FileTokenStore(url: stateDirectory.appendingPathComponent("token"))
    try store.setToken(outcome.token, for: outcome.record.id)
    let pool = ServerPool(directory: stateDirectory, tokens: store)
    let session = try await pool.add(outcome)
    print("角色：\(await session.snapshot().role)")
    print("设备：\(outcome.deviceId)")
    print("指纹：\(outcome.server.fingerprintShort ?? "?")")
}

switch arguments[1] {
case "pair-qr":
    // 扫码路径：指纹来自二维码，TLS 握手时就比对 —— 这是**强校验**，
    // 也是这个功能里唯一无法用单元测试证明的环节。
    guard arguments.count >= 4 else { fail("pair-qr 需要 <二维码原文> <状态目录> [可达地址]") }
    let stateDirectory = URL(fileURLWithPath: arguments[3])
    try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

    let parsed: PairingPayload
    do {
        parsed = try PairingPayload.parse(arguments[2])
    } catch {
        fail("二维码无法解析：\(error.localizedDescription)")
    }

    // 可选的可达地址覆盖：验收脚本在**同一台机器**上跑内核，而二维码里
    // 是局域网地址 —— 那依赖防火墙放行，会让验收多一个与代码无关的失败源。
    let payload = arguments.count >= 5 ? parsed.withAddresses([arguments[4]]) : parsed

    print("服务端：\(payload.name)")
    print("候选地址：\(payload.addresses.joined(separator: ", "))")

    do {
        let outcome = try await PairingService().pair(
            payload: payload, device: .init(name: "mizar-acceptance", platform: "macos"))
        // 响应里自报的指纹必须与二维码里的相同 —— 这是纵深防御，
        // 但更重要的是它证明"扫码路径真的用了二维码里的那个指纹"。
        guard outcome.record.spkiSHA256 == payload.spki else {
            fail("落库的指纹与二维码不一致：\(outcome.record.spkiSHA256) vs \(payload.spki)")
        }
        ok("配对成功，公钥指纹与二维码一致（TLS 层已比对）")
        try await commit(outcome, into: stateDirectory)
    } catch {
        fail("配对失败：\(error.localizedDescription)")
    }

case "pair-code":
    // 手输路径：没有二维码，因此指纹要从响应里取，再让用户核对。
    guard arguments.count >= 5 else { fail("pair-code 需要 <地址> <六位码> <状态目录>") }
    let stateDirectory = URL(fileURLWithPath: arguments[4])
    try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

    do {
        let pending = try await PairingService().probe(
            address: arguments[2], code: arguments[3],
            device: .init(name: "mizar-acceptance-code", platform: "macos"))
        guard !pending.fingerprintShort.isEmpty else { fail("响应里没有指纹，用户无从核对") }
        ok("探测成功，可核对指纹 \(pending.fingerprintShort)（这一段要由用户与 Phecda 核对）")
        try await commit(pending.outcome, into: stateDirectory)
    } catch {
        fail("探测失败：\(error.localizedDescription)")
    }

case "status":
    guard arguments.count >= 3 else { fail("status 需要 <状态目录>") }
    let stateDirectory = URL(fileURLWithPath: arguments[2])
    let store = FileTokenStore(url: stateDirectory.appendingPathComponent("token"))
    let pool = ServerPool(directory: stateDirectory, tokens: store)

    guard let record = await pool.records().first else { fail("状态目录里没有服务端") }

    do {
        // 先走一次**真链路**：建会话 → 候选地址逐个试 → 公钥指纹比对。
        let session = try await pool.session(for: record.id)
        let state = await session.connect()
        guard state == .online else { fail("连接状态是 \(state.summary)") }
        ok("已连接（\(await session.address ?? "?")）")

        let kernel = try await session.kernel()
        let metrics = try await kernel.metrics()
        let apps = try await kernel.apps()

        print("CPU：\(String(format: "%.1f", metrics.host.cpuPercent))%")
        print("内存：\(metrics.host.memoryUsedBytes) / \(metrics.host.memoryTotalBytes)")
        print("挂载点：\((metrics.host.disks ?? []).count) 个")
        if let gpu = metrics.host.gpu {
            print("GPU：\(gpu.name ?? "?") \(gpu.utilizationPercent.map { String(format: "%.0f%%", $0) } ?? "不支持")")
        }
        print("站点：\(apps.count) 个")
        print("角色：\(await session.role)")
        let selfInfo = try await kernel.remoteSelf()
        print("自述角色：\(selfInfo.role)")
        ok("真实链路验证通过")
    } catch {
        fail("连接失败：\(error.localizedDescription)")
    }

case "expect":
    guard arguments.count >= 4 else { fail("expect 需要 <状态目录> <状态名>") }
    let stateDirectory = URL(fileURLWithPath: arguments[2])
    let expected = arguments[3]
    let store = FileTokenStore(url: stateDirectory.appendingPathComponent("token"))
    let pool = ServerPool(directory: stateDirectory, tokens: store)

    guard let record = await pool.records().first else { fail("状态目录里没有服务端") }
    let session = try await pool.session(for: record.id)
    let state = await session.connect()

    let actual: String
    switch state {
    case .online: actual = "online"
    case .needsPairing: actual = "needsPairing"
    case .identityChanged: actual = "identityChanged"
    case .unreachable: actual = "unreachable"
    case .idle, .connecting: actual = "other"
    }

    if actual == expected {
        ok("状态是 \(actual)（期望 \(expected)）")
    } else {
        fail("状态是 \(actual)，期望 \(expected)")
    }

default:
    fail("未知子命令 \(arguments[1])")
}
