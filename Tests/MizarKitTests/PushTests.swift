import Foundation
import Testing
@testable import MizarKit
@testable import MizarApp

/// 推送的深链与令牌处理。
///
/// 放在独立的文件里而不是并进契约测试：它测的是**应用层**的东西
/// （通知点开之后去哪儿），而契约测试测的是与内核的边界。

// MARK: - 推送深链

@MainActor
@Test func pushRouteParsesAStructuredTarget() {
    let route = PushRoute(userInfo: [
        "route": ["kind": "app", "id": "app-1"],
        "server": ["name": "Mac-mini"],
    ])
    #expect(route?.kind == "app")
    #expect(route?.id == "app-1")
    #expect(route?.serverName == "Mac-mini")
}

/// 认不出的载荷**返回 nil 而不是崩** —— 内核将来会加新的 kind，
/// 而旧版本的客户端不该因此挂掉。
@MainActor
@Test func pushRouteRejectsUnknownShapes() {
    #expect(PushRoute(userInfo: [:]) == nil)
    #expect(PushRoute(userInfo: ["route": "not-a-dict"]) == nil)
    #expect(PushRoute(userInfo: ["route": ["id": "x"]]) == nil, "缺少 kind")
    #expect(PushRoute(userInfo: ["route": ["kind": ""]]) == nil, "kind 为空")
}

/// 没有服务器名时也要能解析：那条通知来自只有一台服务端的用户，
/// 而"切到哪一台"在那时是一个不需要回答的问题。
@MainActor
@Test func pushRouteWorksWithoutAServerName() {
    let route = PushRoute(userInfo: ["route": ["kind": "cert", "id": "example.com"]])
    #expect(route?.kind == "cert")
    #expect(route?.serverName == nil)
}

/// APNs 给的字节要转成小写十六进制。
///
/// 直接 `String(data:encoding:)` 会得到一堆乱码，而它在服务端看起来
/// 只是一个"格式不对的令牌"。
@Test func deviceTokenBecomesLowercaseHex() {
    let data = Data([0x0A, 0xFF, 0x00, 0x1B])
    #expect(PushCoordinator.hexToken(from: data) == "0aff001b")
    #expect(PushCoordinator.hexToken(from: Data()) == "")
}

// MARK: - APNs 环境

/// 造一份形状与 `embedded.mobileprovision` 相同的描述文件。
///
/// 真的那一份是 CMS/PKCS#7 签名块：前面一段二进制 DER，中间嵌着一份 XML
/// plist。这里刻意保留那两个特征 —— 二进制前缀会让 `.utf8` 解码失败，
/// 而"解码失败"与"没找到那个键"在调用方看来是同一件事（都返回 nil），
/// 于是这个测试就没在测东西了。
private func fakeProfile(apsEnvironment: String?, binaryPrefix: Bool = true) -> Data {
    var data = Data()
    if binaryPrefix {
        // 故意放进不合法的 UTF-8 字节。
        data.append(contentsOf: [0x30, 0x82, 0x0A, 0x1C, 0x06, 0x09, 0x2A, 0x86, 0x48, 0xFF, 0xFE])
    }
    var xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
    <key>AppIDName</key><string>ISC Mizar</string>
    <key>Entitlements</key><dict>
    <key>application-identifier</key><string>5Q2A46685M.app.isc.mizar</string>
    """
    if let apsEnvironment {
        xml += "\n<key>aps-environment</key>\n<string>\(apsEnvironment)</string>\n"
    }
    xml += """
    <key>get-task-allow</key><true/>
    </dict>
    </dict></plist>
    """
    data.append(Data(xml.utf8))
    return data
}

/// 描述文件里写的是 `development` / `production`，而契约用的是
/// `sandbox` / `production`。这一处转换是两边唯一的接缝。
@Test func pushEnvironmentReadsDevelopmentFromTheProfile() {
    #expect(PushEnvironment.environment(inProfile: fakeProfile(apsEnvironment: "development"))
            == PushEnvironment.sandbox)
    #expect(PushEnvironment.environment(inProfile: fakeProfile(apsEnvironment: "production"))
            == PushEnvironment.production)
}

/// 二进制前缀不能让读取失败。
///
/// 描述文件里的签名字段不是文本，`.utf8` 解码会在那里返回 nil —— 而症状
/// 是"读不出环境，于是退回 `#if DEBUG`"，一个**只在真机上出现**的偏差。
@Test func pushEnvironmentSurvivesBinaryBytes() {
    let withBinary = fakeProfile(apsEnvironment: "development", binaryPrefix: true)
    let without = fakeProfile(apsEnvironment: "development", binaryPrefix: false)
    #expect(PushEnvironment.environment(inProfile: withBinary) == PushEnvironment.sandbox)
    #expect(PushEnvironment.environment(inProfile: without) == PushEnvironment.sandbox)
}

/// 描述文件**优先于**编译配置。
///
/// 这一条是这次改动的全部理由：用 Release 配置直接装到真机上调试时，
/// 编译出来的是 Release（`#if DEBUG` 会说 production），而签名用的是
/// development 描述文件（令牌属于沙箱）。信错了会让 Apple 回
/// `BadDeviceToken`，而内核把它理解成"令牌失效"，于是把这台设备的令牌
/// 清掉 —— 用户看到的是"通知收不到，而且每次都要重新登记"。
@Test func provisioningProfileWinsOverTheBuildConfiguration() {
    #expect(PushEnvironment.current(profile: fakeProfile(apsEnvironment: "production"),
                                    builtForDebugging: true) == PushEnvironment.production)
    #expect(PushEnvironment.current(profile: fakeProfile(apsEnvironment: "development"),
                                    builtForDebugging: false) == PushEnvironment.sandbox)
}

/// 读不到描述文件时（模拟器上没有）才退回编译配置。
@Test func pushEnvironmentFallsBackToTheBuildConfiguration() {
    #expect(PushEnvironment.current(profile: nil, builtForDebugging: true) == PushEnvironment.sandbox)
    #expect(PushEnvironment.current(profile: nil, builtForDebugging: false) == PushEnvironment.production)
}

/// 认不出的值不能被当成合法环境。
///
/// 返回一个 `"<development>"` 之类的串会让内核原样存下来，然后拿它去
/// 挑接入点 —— 那比"不知道"更难查。读不出来时返回 nil，由调用方兜底。
@Test func pushEnvironmentRejectsUnknownValues() {
    #expect(PushEnvironment.environment(inProfile: fakeProfile(apsEnvironment: "development-ish"))
            == nil)
    #expect(PushEnvironment.environment(inProfile: fakeProfile(apsEnvironment: nil)) == nil)
    #expect(PushEnvironment.environment(inProfile: Data()) == nil)
    #expect(PushEnvironment.environment(inProfile: Data([0x00, 0x01, 0x02])) == nil)
    // 有 key 但没有值：描述文件被截断的样子。
    #expect(PushEnvironment.environment(
        inProfile: Data("<key>aps-environment</key>".utf8)) == nil)
}

/// 注册失败必须能被记下来。
///
/// 以前那句话在应用壳里被直接丢掉了，于是设置页显示"就绪"而用户一条
/// 通知都收不到 —— 唯一能解释它的文本恰好被扔了。
@MainActor
@Test func registrationFailureIsRecorded() {
    let coordinator = PushCoordinator()
    #expect(coordinator.lastRegistrationError == nil)
    coordinator.recordRegistrationFailure("no valid 'aps-environment' entitlement")
    #expect(coordinator.lastRegistrationError == "no valid 'aps-environment' entitlement")
}
