/// A JSON value: what travels between the erupt server and the node, what records hold and what the
/// annotation templates are made of. Parsed and written here, so integers stay integers and booleans stay
/// booleans on every platform.
public enum JSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public var isNull: Bool { self == .null }

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }

    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }

    public var array: [JSON]? { if case .array(let a) = self { return a } else { return nil } }

    public var object: [String: JSON]? { if case .object(let o) = self { return o } else { return nil } }

    /// The value as an integer, when it is an integral number.
    public var int: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d == d.rounded() && abs(d) < 9.2e18: return Int64(d)
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    /// The member `key` of an object; setting one on a non-object makes it an object.
    public subscript(key: String) -> JSON? {
        get { object?[key] }
        set {
            var o = object ?? [:]
            o[key] = newValue
            self = .object(o)
        }
    }

    public subscript(index: Int) -> JSON? {
        guard let a = array, a.indices.contains(index) else { return nil }
        return a[index]
    }

    /// Text of the value the way a user typed it: a string as is, anything else as its JSON.
    public var text: String {
        if case .string(let s) = self { return s }
        return serialized()
    }

    // numbers compare by value: 2 and 2.0 are the same number
    public static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)): return x == y
        case (.int(let x), .int(let y)): return x == y
        default:
            if let x = a.number, let y = b.number { return x == y }
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let b): hasher.combine(b)
        case .int, .double: hasher.combine(double)
        case .string(let s): hasher.combine(s)
        case .array(let a): hasher.combine(a)
        case .object(let o): hasher.combine(o)
        }
    }

    var number: Double? {
        switch self {
        case .int, .double: return double
        default: return nil
        }
    }
}

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }

    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSON: CustomStringConvertible {
    public var description: String { serialized() }
}

// MARK: - writing

extension JSON {
    /// Compact JSON text, object keys sorted.
    public func serialized() -> String {
        var out = ""
        write(to: &out)
        return out
    }

    func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += d.isFinite ? "\(d)" : "null"
        case .string(let s): JSON.quote(s, into: &out)
        case .array(let a):
            out += "["
            for (i, item) in a.enumerated() {
                if i > 0 { out += "," }
                item.write(to: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, key) in o.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                JSON.quote(key, into: &out)
                out += ":"
                o[key]!.write(to: &out)
            }
            out += "}"
        }
    }

    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

// MARK: - parsing

public struct JSONParseError: Error, CustomStringConvertible {
    public let offset: Int
    public var description: String { "malformed JSON at byte \(offset)" }
}

extension JSON {
    public static func parse(_ text: String) throws -> JSON { try parse(Array(text.utf8)) }

    public static func parse<Bytes: Collection>(_ bytes: Bytes) throws -> JSON where Bytes.Element == UInt8 {
        var p = Parser(bytes: Array(bytes))
        p.skipSpace()
        let value = try p.value(depth: 0)
        p.skipSpace()
        guard p.i == p.bytes.count else { throw JSONParseError(offset: p.i) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSpace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        func fail() -> JSONParseError { JSONParseError(offset: i) }

        mutating func literal(_ word: String, _ value: JSON) throws -> JSON {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw fail() }
            i += w.count
            return value
        }

        mutating func value(depth: Int) throws -> JSON {
            guard i < bytes.count, depth < 512 else { throw fail() }
            switch bytes[i] {
            case UInt8(ascii: "n"): return try literal("null", .null)
            case UInt8(ascii: "t"): return try literal("true", .bool(true))
            case UInt8(ascii: "f"): return try literal("false", .bool(false))
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "["):
                i += 1
                var items: [JSON] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while true {
                    skipSpace()
                    items.append(try value(depth: depth + 1))
                    skipSpace()
                    guard i < bytes.count else { throw fail() }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    throw fail()
                }
            case UInt8(ascii: "{"):
                i += 1
                var members: [String: JSON] = [:]
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                while true {
                    skipSpace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail() }
                    let key = try string()
                    skipSpace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail() }
                    i += 1
                    skipSpace()
                    members[key] = try value(depth: depth + 1)
                    skipSpace()
                    guard i < bytes.count else { throw fail() }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                    throw fail()
                }
            default: return try number()
            }
        }

        mutating func number() throws -> JSON {
            let start = i
            var integral = true
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            let digits = i
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
            guard i > digits else { throw fail() }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                integral = false
                i += 1
                let frac = i
                while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
                guard i > frac else { throw fail() }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                integral = false
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                let exp = i
                while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
                guard i > exp else { throw fail() }
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            if integral, let n = Int64(text) { return .int(n) }
            guard let d = Double(text) else { throw fail() }
            return .double(d)
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16)
            else { throw fail() }
            i += 4
            return v
        }

        mutating func string() throws -> String {
            i += 1
            var out = [UInt8]()
            while true {
                guard i < bytes.count else { throw fail() }
                let b = bytes[i]
                i += 1
                switch b {
                case UInt8(ascii: "\""): return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard i < bytes.count else { throw fail() }
                    let e = bytes[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800..<0xDC00).contains(code), i + 6 <= bytes.count, bytes[i] == UInt8(ascii: "\\"),
                            bytes[i + 1] == UInt8(ascii: "u")
                        {
                            i += 2
                            let low = try hex4()
                            guard (0xDC00..<0xE000).contains(low) else { throw fail() }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        out.append(contentsOf: Array(String(Unicode.Scalar(code) ?? "\u{FFFD}").utf8))
                    default: throw fail()
                    }
                case 0..<0x20: throw fail()
                default: out.append(b)
                }
            }
        }
    }
}

/// Deep-merges `override` onto `target`: objects merge member by member, anything else replaces.
func merge(_ target: inout JSON, _ override: JSON) {
    guard case .object(let o) = override, case .object(var t) = target else {
        target = override
        return
    }
    for (key, value) in o {
        if var existing = t[key], case .object = existing, case .object = value {
            merge(&existing, value)
            t[key] = existing
        } else {
            t[key] = value
        }
    }
    target = .object(t)
}
