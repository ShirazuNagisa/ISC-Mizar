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
