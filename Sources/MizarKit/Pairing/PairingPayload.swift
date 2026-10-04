import Foundation

/// 二维码（或剪贴板链接）里携带的配对信息。
///
/// 结构由**内核**生成（见 ISC-Core 的 `internal/remote/service.go`），
/// 客户端只解析。这里刻意不做任何"猜"：版本不认就明确拒绝，
/// 而不是试着按旧格式读一半 —— 那种容错会让"扫了一个更高版本内核的码"
/// 表现成一堆莫名其妙的字段缺失。
public struct PairingPayload: Codable, Sendable, Equatable {

    /// payload 的类型标识。
    ///
    /// 相机里全是别的二维码，而扫错的表现是一个无法解释的解析错误。
    /// 这一条让"这不是 ISC 的码"变成一句可读的话。
    public static let payloadKind = "isc-remote"

    /// 当前认得的版本。
    public static let supportedVersion = 1

    public let v: Int
    public let kind: String
    /// 服务端显示名。
    public let name: String
    /// `https`（默认）或 `http`。
    public let scheme: String
    /// 候选地址（含端口），顺序即建议的尝试顺序。
    public let addresses: [String]
    /// 服务端证书公钥指纹（base64url，无填充）。
    public let spki: String
    /// 高熵配对密钥。
    public let secret: String
    /// 会话过期时间（Unix 秒）。
    public let exp: Int64

    /// 逐字段构造。
    ///
    /// 需要的场景只有两个：测试要造各种畸形/过期载荷，而验收工具要在
    /// 不改变其余字段的前提下把候选地址换成一条可达的 —— 两者都不该
    /// 通过"拼一段 JSON 再解析"来做。
    public init(v: Int = PairingPayload.supportedVersion,
                kind: String = PairingPayload.payloadKind,
                name: String, scheme: String, addresses: [String],
                spki: String, secret: String, exp: Int64) {
        self.v = v
        self.kind = kind
        self.name = name
        self.scheme = scheme
        self.addresses = addresses
        self.spki = spki
        self.secret = secret
        self.exp = exp
    }

    /// 换一组候选地址（其余字段不变）。
    public func withAddresses(_ addresses: [String]) -> PairingPayload {
        PairingPayload(v: v, kind: kind, name: name, scheme: scheme,
                       addresses: addresses, spki: spki, secret: secret, exp: exp)
    }

    /// 解析一段文本（扫码结果或粘贴进来的链接）。
    public static func parse(_ text: String) throws -> PairingPayload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 两种载体：内核生成的裸 JSON，以及可以复制粘贴的 `isc-remote://` 链接。
        if trimmed.hasPrefix("isc-remote:") {
            return try parse(link: trimmed)
        }
        guard trimmed.hasPrefix("{") else {
            throw PairingError.notAPairingCode
        }

        return try classify(Data(trimmed.utf8))
    }

    /// 先认类型与版本，再解完整结构。
    ///
    /// # 为什么不能直接解完整结构
    ///
    /// 解不出来的时候有两种完全不同的原因，而它们要让用户做的事相反：
    ///
    ///	这不是 ISC 的码	→ 重新扫一个
    ///	这是更新的版本	→ 更新应用
    ///
    /// 直接解完整结构的话，第二种会因为"新版字段与旧版对不上"而同样
    /// 失败，于是它被报成第一种 —— 用户会去反复重扫一个本来就没问题的码。
    /// 只解 `{v, kind}` 两个字段就没有这个问题：新版格式也一定带着它们。
    private static func classify(_ data: Data) throws -> PairingPayload {
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else {
            throw PairingError.unreadable
        }
        guard probe.kind == payloadKind else { throw PairingError.notAPairingCode }
        let version = probe.v ?? 0
        guard version <= supportedVersion else {
            throw PairingError.unsupportedVersion(version)
        }
        guard let payload = try? JSONDecoder().decode(Self.self, from: data) else {
            throw PairingError.unreadable
        }
        return payload
    }

    /// 解析 `isc-remote://pair?d=<base64url JSON>`。
    private static func parse(link: String) throws -> PairingPayload {
        guard let components = URLComponents(string: link),
              let encoded = components.queryItems?.first(where: { $0.name == "d" })?.value
        else { throw PairingError.notAPairingCode }

        guard let data = base64URLDecode(encoded) else { throw PairingError.unreadable }
        return try classify(data)
    }

    /// 只解"这是不是我们的码、版本认不认得"所需的最少字段。
    private struct Probe: Decodable {
        let v: Int?
        let kind: String?
    }

    /// 转成可复制粘贴的链接形式。
    public func link() throws -> String {
        let data = try JSONEncoder().encode(self)
        return "isc-remote://pair?d=" + SpkiPinning.base64URL(data)
    }

    /// 是否还能用。
    public func expired(now: Date = Date()) -> Bool {
        Date(timeIntervalSince1970: TimeInterval(exp)) <= now
    }

    /// 按候选顺序构造服务端基址。
    ///
    /// 顺序有意义：内核已经按"最可能连通的排前面"排好了（IPv4 私有地址、
    /// 其它 IPv4、IPv6、`<hostname>.local`），客户端不该重新排序 ——
    /// 那等于把内核知道而客户端不知道的信息丢掉。
    public func baseURLs() -> [URL] {
        addresses.compactMap { URL(string: "\(scheme)://\($0)") }
    }

    /// 解码 base64url（无填充）。
    ///
    /// 直接转给 `SpkiPinning`：那是唯一的实现，两边共用一份 ——
    /// "补填充"这件事写两遍就会有其中一遍在某天漏掉一个边界。
    static func base64URLDecode(_ text: String) -> Data? {
        SpkiPinning.base64URLDecode(text)
    }
}

/// 配对过程中的失败。
public enum PairingError: Error, LocalizedError, Sendable, Equatable {
    case notAPairingCode
    case unreadable
    case unsupportedVersion(Int)
    case expired
    case noReachableAddress
    case identityMismatch
    case identityNotConfirmed
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .notAPairingCode:
            "这不是一台 ISC Phecda 服务端的配对码。"
        case .unreadable:
            "配对码无法解析，请重新生成一个。"
        case .unsupportedVersion(let v):
            "这个配对码是更新版本（v\(v)）生成的，请先更新 ISC Mizar。"
        case .expired:
            "配对码已过期，请在 Phecda 上重新生成。"
        case .noReachableAddress:
            "试过服务端给出的全部地址都连不上。请确认手机与这台机器在同一网络，并且远程访问处于开启状态。"
        case .identityMismatch:
            "服务器身份与配对码里固定的不一致，连接已中止。"
        case .identityNotConfirmed:
            "没有核对指纹，配对未完成。"
        case .rejected(let detail):
            detail
        }
    }
}

/// 六位手输配对码的规范化。
///
/// 规则与内核逐字一致（Crockford base32）：
///
///   - 去掉空白与连字符 —— 用户照着屏幕念、再敲进另一个设备时常带分隔符；
///   - 转大写 —— 手机键盘默认可能是小写；
///   - `I`/`L` → `1`，`O` → `0`。字母表里没有这几个字符，因此这条映射
///     **不可能把一个合法的码改坏**，只可能救回一个读错的码。
///
/// 两边各实现一份是有意的：客户端先在本地规范化，用户才能立刻看到
/// "我输的是不是被理解了"，而不必等一次往返之后才发现少打一位。
/// 一致性由共享的字母表常量与测试钉住。
public enum PairingCode {
    static let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    public static let length = 6

    /// 规范化；含有字母表之外的字符或长度不对时返回 nil。
    public static func normalize(_ input: String) -> String? {
        var out = ""
        out.reserveCapacity(input.count)
        for scalar in input.unicodeScalars {
            switch scalar {
            case " ", "\t", "\n", "-", "_":
                continue
            case "I", "L", "i", "l":
                out.append("1")
            case "O", "o":
                out.append("0")
            default:
                let upper = String(scalar).uppercased()
                out.append(contentsOf: upper)
            }
        }
        guard out.count == length else { return nil }
        guard out.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return out
    }

    /// 供界面显示用的分组形式（`ABC123` → `ABC 123`）。
    public static func grouped(_ code: String) -> String {
        guard code.count == length else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<middle]) \(code[middle...])"
    }
}
