import Foundation

/// 契约层的动态 JSON 值与回复封装。
///
/// 这一组类型**逐字来自 ISC Phecda**（`Sources/ISCCore/JSONValue.swift`）。
/// 两个仓库各自持有一份是有意的：Mizar 与 Phecda 是独立的两个应用，
/// 共享一个 SwiftPM 包会把"改哪个仓库"变成一个需要跨仓库协调的问题，
/// 而它们对内核契约的依赖面（这里 60 行）远小于协调成本。
///
/// 同步方式：内核契约变了，两边的**契约测试**都会红（两边都用真实内核的
/// 响应载荷固化了断言），因此不会出现一边悄悄漂移的情况。

/// 任意 JSON 值。
///
/// 用它而不是给每个响应都写一个 Codable 类型，是因为有些位置（事件载荷、
/// 建议动作的 body）的形状由内核在运行时决定：给它们硬造类型只会让
/// "内核多了一个字段"变成一次解码失败。
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue { object[key] ?? .null }
    public var object: [String: JSONValue] { if case .object(let v) = self { v } else { [:] } }
    public var array: [JSONValue] { if case .array(let v) = self { v } else { [] } }
    public var string: String { if case .string(let v) = self { v } else { "" } }
    public var bool: Bool { if case .bool(let v) = self { v } else { false } }
    public var number: Double { if case .number(let v) = self { v } else { 0 } }
    public var id: String { self["id"].string }
    public var items: [JSONValue] { if case .array = self { array } else { self["items"].array } }

    public func data() throws -> Data { try JSONEncoder().encode(self) }

    public func text(pretty: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(Self.self, from: Data(text.utf8))
    }

    /// 按 `key.path` 取值，任一段缺失就返回空值。
    public func path(_ dotted: String) -> JSONValue {
        dotted.split(separator: ".").reduce(self) { $0[String($1)] }
    }
}

/// 一次失败。
///
/// `code` 是内核给的**机器可读**字符串（`not_found`、`conflict`、
/// `unauthorized`…），而这里另外定义了客户端自己产生的几个：
///
///	unreachable        连不上（网络、端口、对端没在监听）
///	identity_changed   服务端证书的公钥与固定的不一致（**绝不静默接受**）
///	timeout            超时
///	decoding           响应不是预期的形状
///	outdated_kernel    内核没有远程访问能力（契约版本对不上）
///
/// 文案会随语言变，因此**分支判断必须看 code**。
public struct KernelError: Error, LocalizedError, Sendable {
    public let code: String
    public let status: Int
    public let message: String

    public init(code: String, status: Int = 0, message: String) {
        self.code = code
        self.status = status
        self.message = message
    }

    public var errorDescription: String? { message }

    /// 这台服务器需要重新配对。
    ///
    /// 把 401 的三种来源收在一处：令牌无效、设备被吊销、令牌格式不对。
    /// 界面据此把整台服务器标成"需要重新配对"，而不是给用户看一段
    /// 英文错误 —— 那三种在用户眼里是同一件事。
    public var needsPairing: Bool { status == 401 || code == "unauthorized" }
}

/// 一次调用的回复。
///
/// 形状与 libisc 的 `isc_call` 信封一致（`{ok, status, body}`）。
/// 服务端的 HTTP 接口并不产出这个信封 —— 它是**传输层**归一化出来的：
/// 这样契约层（`KernelAPI`）在 Phecda 与 Mizar 两边完全一样，
/// 而"HTTP 怎么变成信封"只有一处实现。
public struct KernelReply: Sendable {
    public let body: JSONValue
    public let status: Int

    public init(_ envelope: JSONValue) throws {
        guard envelope["ok"].bool else {
            throw KernelError(
                code: envelope["code"].string,
                status: Int(envelope["status"].number),
                message: envelope["error"].string.isEmpty ? "Invalid kernel reply" : envelope["error"].string)
        }
        status = Int(envelope["status"].number)
        body = envelope.object["body"] ?? envelope
    }

    /// 直接由 HTTP 响应构造。
    public init(status: Int, body: JSONValue) {
        self.status = status
        self.body = body
    }
}
