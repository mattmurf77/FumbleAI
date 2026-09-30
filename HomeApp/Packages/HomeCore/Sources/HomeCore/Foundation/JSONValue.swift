import Foundation

/// A JSON value, used for free-form template attributes (`thing.attributes_json`). LLD §4.
public enum JSONValue: Hashable, Sendable, Codable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }

    /// Human-readable text for search indexing and display ("16x25x1", "11", "Yes").
    public var displayText: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "Yes" : "No"
        case .array(let a): return a.map(\.displayText).joined(separator: ", ")
        case .object(let o): return o.keys.sorted().map { "\($0): \(o[$0]!.displayText)" }.joined(separator: ", ")
        case .null: return ""
        }
    }

    public var description: String { displayText }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(floatLiteral v: Double) { self = .number(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
}

/// Shared deterministic JSON coding for JSON columns (sorted keys → stable text, clean diffs). LLD §4.
public enum HomeJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
    public static func decoder() -> JSONDecoder { JSONDecoder() }

    public static func encodeString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder().encode(value), as: UTF8.self)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        try decoder().decode(type, from: Data(string.utf8))
    }
}
