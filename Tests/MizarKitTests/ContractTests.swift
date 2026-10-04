import Foundation
import CryptoKit
import Testing
@testable import MizarKit

/// 契约层与传输层的测试。
///
/// # 为什么这些断言值得写
///
/// 它们覆盖的都是"错了之后症状与原因隔得很远"的地方：信封解错会把一次
/// 成功显示成失败；问题响应的 code 取错会让界面把"需要重新配对"显示成
/// 一段英文错误；公钥指纹算错会让每一台手机都拒绝连接，而两边的日志
/// 都只说"指纹不匹配"。

// MARK: - JSON 与信封

@Test func jsonValueRoundTrips() throws {
    let source = #"{"a":1,"b":[true,"x",null],"c":{"d":2.5}}"#
    let value = try JSONValue.parse(source)

    #expect(value["a"].number == 1)
    #expect(value["b"].array.count == 3)
    #expect(value["b"].array[1].string == "x")
    #expect(value["c"]["d"].number == 2.5)
    // 缺失的键返回空值而不是抛错：契约新增字段时旧客户端不该崩。
    #expect(value["nope"].string == "")
    #expect(value["nope"].bool == false)
    #expect(value["nope"].array.isEmpty)

    let text = try value.text()
    #expect(try JSONValue.parse(text) == value)
}

@Test func jsonPathWalksDottedKeys() throws {
    let value = try JSONValue.parse(#"{"a":{"b":{"c":"deep"}}}"#)
    #expect(value.path("a.b.c").string == "deep")
    #expect(value.path("a.missing.c").string == "")
}

@Test func kernelReplyUnwrapsTheEnvelope() throws {
    let envelope = try JSONValue.parse(#"{"ok":true,"status":200,"body":{"id":"x"}}"#)
    let reply = try KernelReply(envelope)
    #expect(reply.status == 200)
    #expect(reply.body["id"].string == "x")
}

@Test func kernelReplyTurnsFailuresIntoErrors() throws {
    let envelope = try JSONValue.parse(#"{"ok":false,"code":"not_found","status":404,"error":"没有"}"#)
    do {
        _ = try KernelReply(envelope)
        Issue.record("失败的响应应当抛出")
    } catch let error as KernelError {
        #expect(error.code == "not_found")
        #expect(error.status == 404)
    }
}

@Test func pathComponentEscapesSeparators() {
    #expect(KernelClient.pathComponent("a/b?x=1") == "a%2Fb%3Fx%3D1")
    // base64url 与 UUID 里的 - 与 _ 保持不变：编码它们虽然仍然正确，
    // 但会让日志与错误信息里的 URL 难以辨认。
    #expect(KernelClient.pathComponent("a-b_c") == "a-b_c")
}

// MARK: - HTTP 归一化

@Test func httpSuccessBecomesAnEnvelope() throws {
    let body = Data(#"{"status":"ok"}"#.utf8)
    let reply = try HTTPTransport.normalize(status: 200, data: body)
    #expect(reply.status == 200)
    #expect(reply.body["status"].string == "ok")
}

@Test func httpNoContentBecomesNullBody() throws {
    let reply = try HTTPTransport.normalize(status: 204, data: Data())
    #expect(reply.status == 204)
    #expect(reply.body == .null)
}

@Test func httpProblemBecomesKernelError() throws {
    let problem = Data(#"{"type":"https://isc.invalid/problems/unauthorized","title":"未授权","status":401,"code":"unauthorized","detail":"这台设备已被吊销，请重新配对。"}"#.utf8)
    do {
        _ = try HTTPTransport.normalize(status: 401, data: problem)
        Issue.record("非 2xx 应当抛出")
    } catch let error as KernelError {
        #expect(error.code == "unauthorized")
        #expect(error.status == 401)
        // detail 优先于 title：它是内核针对这一次失败写的那句话。
        #expect(error.message == "这台设备已被吊销，请重新配对。")
        // 界面据此把整台服务器标成"需要重新配对"。
        #expect(error.needsPairing)
    }
}

@Test func httpProblemWithoutBodyStillFails() throws {
    do {
        _ = try HTTPTransport.normalize(status: 500, data: Data("<html>oops</html>".utf8))
        Issue.record("非 2xx 应当抛出")
    } catch let error as KernelError {
        // 没有 problem+json 时退化成 http_500，而不是一个空的 code ——
        // 上层的分支判断需要一个**非空**的字符串。
        #expect(error.code == "http_500")
        #expect(!error.needsPairing)
    }
}

@Test func urlErrorsMapToActionableCodes() {
    #expect(HTTPTransport.map(URLError(.cannotConnectToHost), pinFailure: nil).code == "unreachable")
    #expect(HTTPTransport.map(URLError(.timedOut), pinFailure: nil).code == "timeout")

    // 指纹不匹配时我们在挑战回调里主动取消了连接，因此错误码是笼统的
    // `.cancelled`。不看那个标记的话，用户会看到"已取消" ——
    // 而真实原因是服务端身份变了，两者该做的事完全相反。
    let mapped = HTTPTransport.map(URLError(.cancelled), pinFailure: "身份已变化")
    #expect(mapped.code == "identity_changed")
    #expect(mapped.message == "身份已变化")
}

// MARK: - 公钥指纹

/// 用 Go 的 `x509.Certificate.RawSubjectPublicKeyInfo` 生成的真实样本。
///
/// # 为什么是用真样本而不是自造的字节
///
/// 这里要证明的是"Swift 侧算出来的指纹与内核算出来的**逐字节一致**"。
/// 自造一个 DER 只能证明解析器与它自己一致 —— 而那正是这个缺陷会藏身的
/// 地方：两边各自自洽，合起来连不上。
///
/// 样本是一张 ECDSA P-256 自签证书，SAN 为 `fixture.local` 与
/// `192.168.1.10`，有效期 2026-01-01 至 2036-01-01。
private let fixtureCertBase64 = """
MIIBmTCCAT+gAwIBAgIQPB5LCd4mKg9zug54lXji6TAKBggqhkjOPQQDAjASMRAwDgYDVQQDEwdmaXh0dXJlMB4XDTI2MDEwMTAwMDAwMFoXDTM2MDEwMTAwMDAwMFowEjEQMA4GA1UEAxMHZml4dHVyZTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABKL0zC3LiA3un7Ih/bHyz/0AHhaBvBHf8CqoLyTSKTLPuvHjjyADXo7Cdd3Of/1Y6Gi22CB0v8UjM9TUFednzzqjdzB1MA4GA1UdDwEB/wQEAwIChDATBgNVHSUEDDAKBggrBgEFBQcDATAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBS3AMnue6X+pcrlsQD4/waBCPmPUzAeBgNVHREEFzAVgg1maXh0dXJlLmxvY2FshwTAqAEKMAoGCCqGSM49BAMCA0gAMEUCIQCoYKwqg4jiKhopjR+LfTSVxv0b910TFNLltzSfYsJVrAIgd5BKoSnkEsTYz3AwS3dSK25kqXC03kFsfRJR+b5+lMA=
"""

private let fixtureSPKIDERBase64 = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEovTMLcuIDe6fsiH9sfLP/QAeFoG8Ed/wKqgvJNIpMs+68eOPIANejsJ13c5//VjoaLbYIHS/xSMz1NQV52fPOg=="

/// Go 侧算出的 `sha256(RawSubjectPublicKeyInfo)` 的 base64url。
private let fixtureFingerprint = "4mevts4lq4WbR05Ng_uHwmpiJgHesktkdiB3m9br5LA"

@Test func spkiExtractionMatchesTheKernelsDefinition() throws {
    let der = try #require(Data(base64Encoded: fixtureCertBase64))
    let expectedSPKI = try #require(Data(base64Encoded: fixtureSPKIDERBase64))

    let extracted = try #require(SpkiPinning.subjectPublicKeyInfo(fromCertificateDER: der))
    #expect(extracted == expectedSPKI,
            "取出的 SubjectPublicKeyInfo 与 Go 的 RawSubjectPublicKeyInfo 不一致")
}

@Test func spkiFingerprintMatchesTheKernel() throws {
    let der = try #require(Data(base64Encoded: fixtureCertBase64))

    // 直接用 DER 走内部路径（SecCertificate 需要真实证书对象，
    // 而这里要钉的是**算法**，不是 Security 框架）。
    let spki = try #require(SpkiPinning.subjectPublicKeyInfo(fromCertificateDER: der))
    let fingerprint = SpkiPinning.base64URL(Data(SHA256.hash(data: spki)))

    #expect(fingerprint == fixtureFingerprint)
}

@Test func spkiExtractionRejectsGarbage() {
    #expect(SpkiPinning.subjectPublicKeyInfo(fromCertificateDER: Data()) == nil)
    #expect(SpkiPinning.subjectPublicKeyInfo(fromCertificateDER: Data([0x30, 0x02, 0x01, 0x00])) == nil)
    // 截断的长度声明必须被拒绝，而不是读出越界的内容。
    #expect(SpkiPinning.subjectPublicKeyInfo(fromCertificateDER: Data([0x30, 0x7F, 0x01])) == nil)
}

@Test func base64URLMatchesTheKernelsEncoding() {
    // 内核用的是 base64.RawURLEncoding：无填充，且 +/ 换成 -_。
    let data = Data([0xFB, 0xFF, 0xBF, 0x00])
    let encoded = SpkiPinning.base64URL(data)
    #expect(!encoded.contains("="))
    #expect(!encoded.contains("+"))
    #expect(!encoded.contains("/"))
}

// MARK: - 配对码

@Test func pairingCodeNormalizationMatchesTheKernel() {
    let cases: [(String, String?)] = [
        ("A2B3C4", "A2B3C4"),
        ("a2b3c4", "A2B3C4"),
        ("A2B3-C4", "A2B3C4"),
        ("A2B3 C4", "A2B3C4"),
        // 字母表里没有 I/L/O，因此这几条映射不可能把一个合法的码改坏。
        ("I2B3C4", "12B3C4"),
        ("L2B3C4", "12B3C4"),
        ("O2B3C4", "02B3C4"),
        ("A2B3C", nil),
        ("A2B3C4D", nil),
        ("A2B3C!", nil),
        ("", nil),
    ]
    for (input, expected) in cases {
        #expect(PairingCode.normalize(input) == expected, "输入 \(input)")
    }
}

@Test func pairingCodeGroupingIsOnlyForDisplay() {
    #expect(PairingCode.grouped("A2B3C4") == "A2B 3C4")
    // 长度不对时原样返回，而不是切出一个更奇怪的东西。
    #expect(PairingCode.grouped("ABC") == "ABC")
}

// MARK: - 配对载荷

private let validPayload = #"""
{"v":1,"kind":"isc-remote","name":"Mac mini","scheme":"https","addresses":["192.168.1.10:8788","Mac-mini.local:8788"],"spki":"TErcJ99SbmE1HNydX19qHAuNhRpsr5jH71UR2Zkw420","secret":"cSDEmeUwrYcoWLAvYCjHo1G9ALevbA1p_OaBXteclnw","exp":4102444800}
"""#

@Test func pairingPayloadParses() throws {
    let payload = try PairingPayload.parse(validPayload)
    #expect(payload.name == "Mac mini")
    #expect(payload.addresses.count == 2)
    #expect(!payload.expired())

    let urls = payload.baseURLs()
    #expect(urls.count == 2)
    #expect(urls[0].absoluteString == "https://192.168.1.10:8788")
    // IPv6 会带方括号，URL(string:) 必须能解析它。
    #expect(urls.allSatisfy { $0.scheme == "https" })
}

@Test func pairingPayloadRejectsForeignQRCodes() {
    // 相机里全是别的二维码，扫错必须是一句可读的话，而不是字段缺失。
    #expect(throws: PairingError.notAPairingCode) {
        try PairingPayload.parse("https://example.com")
    }
    #expect(throws: PairingError.notAPairingCode) {
        try PairingPayload.parse(#"{"v":1,"kind":"something-else"}"#)
    }
}

@Test func pairingPayloadRejectsNewerVersionsExplicitly() throws {
    let newer = validPayload.replacingOccurrences(of: #""v":1"#, with: #""v":2"#)
    do {
        _ = try PairingPayload.parse(newer)
        Issue.record("更高版本应当被明确拒绝")
    } catch let error as PairingError {
        // 提示必须与"扫错了"不同：用户该做的是更新应用。
        #expect(error == .unsupportedVersion(2))
        #expect(error.errorDescription?.contains("更新") == true)
    }
}

@Test func pairingPayloadRoundTripsThroughALink() throws {
    let payload = try PairingPayload.parse(validPayload)
    let link = try payload.link()
    #expect(link.hasPrefix("isc-remote://pair?d="))
    #expect(try PairingPayload.parse(link) == payload)
}

@Test func pairingPayloadDetectsExpiry() throws {
    let expired = validPayload.replacingOccurrences(of: "4102444800", with: "1000000000")
    let payload = try PairingPayload.parse(expired)
    #expect(payload.expired())
}
