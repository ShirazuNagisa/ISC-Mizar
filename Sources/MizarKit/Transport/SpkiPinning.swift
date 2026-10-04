import Foundation
import CryptoKit
import Security

/// 服务端证书的公钥固定（SPKI pinning）。
///
/// # 为什么固定的是公钥，而不是证书
///
/// 内核用的是**自签证书**，而自签证书会在地址变化时重签（换网段、加网卡、
/// 路由器换了 DHCP 段）。固定整张证书的话，重签之后指纹变了，每一台已配对
/// 的手机都会报"服务器身份已变化" —— 而服务器根本没换。
///
/// 内核重签时沿用同一把私钥，因此 SubjectPublicKeyInfo 的 SHA-256 不变。
/// 只有真的换了机器（换了密钥）它才变，而那时报"身份已变化"恰恰是对的。
///
/// # 为什么不能直接哈希 SecKeyCopyExternalRepresentation
///
/// 那个接口返回的是**裸公钥**（EC 是 `04||X||Y`，RSA 是 PKCS#1），
/// 而内核算的是 SubjectPublicKeyInfo（`AlgorithmIdentifier` + `BIT STRING`
/// 的两层包装）。两者的哈希完全不同 —— 而症状是"每一台手机都拒绝连接"，
/// 两边的日志都只说"指纹不匹配"。
///
/// 因此这里从证书 DER 里**按 X.509 的定义取出那段字段**，与 Go 的
/// `x509.Certificate.RawSubjectPublicKeyInfo` 逐字节一致。
public enum SpkiPinning {

    /// 计算证书公钥指纹的 base64url 形式（无填充）。
    ///
    /// 与内核 `remote.Certificate.SPKIBase64()` 的输出同构。
    /// 拿不到或解析失败时返回 nil —— 调用方必须把它当成**验证失败**，
    /// 而不是"没有指纹所以放行"。
    public static func fingerprint(of certificate: SecCertificate) -> String? {
        let der = SecCertificateCopyData(certificate) as Data
        guard let spki = subjectPublicKeyInfo(fromCertificateDER: der) else { return nil }
        let digest = SHA256.hash(data: spki)
        return base64URL(Data(digest))
    }

    /// 从证书 DER 中取出 SubjectPublicKeyInfo 的完整 TLV 字节。
    ///
    /// 路径（RFC 5280）：
    ///
    ///	Certificate       ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
    ///	TBSCertificate    ::= SEQUENCE { [0] version?, serialNumber, signature,
    ///	                                 issuer, validity, subject,
    ///	                                 subjectPublicKeyInfo, ... }
    ///
    /// 因此：进第 1 层取第一个子元素（tbsCertificate），进第 2 层跳过
    /// 前五个可选/必选字段，第六个就是我们要的。
    static func subjectPublicKeyInfo(fromCertificateDER der: Data) -> Data? {
        guard let certificate = DER.element(der, at: der.startIndex) else { return nil }
        guard let tbs = DER.children(of: certificate).first else { return nil }

        // version 是 [0] EXPLICIT 且**可选**（默认 v1），因此要先看第一个
        // 子元素是不是上下文标签 0。少这一步的话，v3 证书（全都是）会
        // 整体错位一个字段，取到 issuer 而不是公钥。
        var fields = DER.children(of: tbs)
        if let first = fields.first, first.tag == 0xA0 {
            fields.removeFirst()
        }
        // 跳过 serialNumber、signature、issuer、validity、subject。
        guard fields.count > 5 else { return nil }
        return fields[5].encoded
    }

    /// 把一串 base64url 指纹缩成可供人眼核对的短码，形如 `A1B2-C3D4`。
    ///
    /// 与内核 `remote.Certificate.FingerprintShort()` 的算法一致：取前
    /// 四个字节的十六进制，中间加连字符。
    ///
    /// 存在的理由只有一个：完整的指纹是 43 个 base64url 字符，没有人在
    /// 两块屏幕之间逐个比对 43 个字符。短码不承担密码学强度（真正的校验
    /// 是完整的 SPKI 比对），它承担的是"这件事**会**被真的做一遍"。
    public static func shortFingerprint(fromBase64URL spki: String) -> String {
        guard let data = base64URLDecode(spki), data.count >= 4 else { return spki }
        let hex = data.prefix(4).map { String(format: "%02X", $0) }.joined()
        return "\(hex.prefix(4))-\(hex.suffix(4))"
    }

    /// base64url（无填充）解码。
    public static func base64URLDecode(_ text: String) -> Data? {
        var normalized = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// 一个极小的 DER 解析器。
///
/// 只实现取"长度确定"的元素与遍历直接子元素 —— 证书里的每一个字段
/// 都是确定长度，不定长形式（0x80）在 X.509 里根本不允许出现。
enum DER {
    struct Element {
        let tag: UInt8
        /// 整个 TLV 的字节（含 tag 与长度）。
        ///
        /// 注意：它是 `Data` 的**切片**，而 `Data` 的切片保留原集合的索引
        /// 空间 —— 因此 `contentStart` / `contentEnd` 与 `encoded` 的索引
        /// 是同一套，可以直接混用。
        ///
        /// 这一点不能靠"看起来对"来维持：如果哪天把它改成
        /// `Data(encoded)`（复制一份），索引会从 0 重新开始，而
        /// `children(of:)` 会静默地取到错误的位置 —— 症状是
        /// "某些证书的指纹算错"，而那是最难查的一类。
        let encoded: Data
        /// 内容区间的起点。
        let contentStart: Data.Index
        let contentEnd: Data.Index
    }

    /// 读取 `data[index]` 处的一个 TLV 元素。
    static func element(_ data: Data, at index: Data.Index) -> Element? {
        guard index < data.endIndex else { return nil }
        let tag = data[index]
        var cursor = data.index(after: index)

        guard cursor < data.endIndex else { return nil }
        let first = data[cursor]
        cursor = data.index(after: cursor)

        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            // 不定长（0x80）与超过 4 字节的长度在证书里都不该出现：
            // 前者是 BER 的特性，而 X.509 要求 DER。
            guard count > 0, count <= 4, data.distance(from: cursor, to: data.endIndex) >= count else { return nil }
            for _ in 0..<count {
                length = (length << 8) | Int(data[cursor])
                cursor = data.index(after: cursor)
            }
        }

        guard length >= 0, data.distance(from: cursor, to: data.endIndex) >= length else { return nil }
        let end = data.index(cursor, offsetBy: length)
        return Element(tag: tag, encoded: data[index..<end], contentStart: cursor, contentEnd: end)
    }

    /// 一个元素的直接子元素。
    static func children(of element: Element) -> [Element] {
        // 只有构造类型（SEQUENCE / SET / 上下文标签）才有子元素。
        var out: [Element] = []
        var cursor = element.contentStart
        while cursor < element.contentEnd {
            guard let child = self.element(element.encoded, at: cursor) else { break }
            out.append(child)
            cursor = child.encoded.endIndex
        }
        return out
    }
}
