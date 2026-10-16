/// A business error shown to the user as a failed result message, e.g. thrown from an operation handler.
public struct EruptFailure: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A declaration that cannot work: thrown when a model is declared or registered.
public struct DeclarationError: Error, CustomStringConvertible {
    public let message: String
    init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Values in records. Dates travel as text: a DATE as `2026-01-05`, a DATE_TIME as `2026-01-05T10:30:00.000`
/// (local wall clock time), which also sorts and compares correctly as text.
public enum Values {
    /// A DATE_TIME from `2026-01-05`, `2026-01-05 10:30`, `2026-01-05T10:30:00.123Z` and the like.
    public static func dateTime(_ value: JSON) throws -> String {
        let p = try parts(value)
        return String(format4: p.y) + "-" + pad(p.mo) + "-" + pad(p.d) + "T" + pad(p.h) + ":" + pad(p.mi) + ":"
            + pad(p.s) + "." + p.ms
    }

    /// A DATE from the same inputs; a time of day is dropped.
    public static func date(_ value: JSON) throws -> String {
        let p = try parts(value)
        return String(format4: p.y) + "-" + pad(p.mo) + "-" + pad(p.d)
    }

    /// A number as an integer when it is integral, a double otherwise.
    public static func number(_ value: JSON) throws -> JSON {
        var n = value
        if case .string(let s) = value {
            let t = s.trimmingSpaces
            if let i = Int64(t) {
                n = .int(i)
            } else if let d = Double(t), !t.isEmpty, t.allSatisfy({ "0123456789+-.eE".contains($0) }) {
                n = .double(d)
            } else {
                n = .null
            }
        }
        switch n {
        case .int: return n
        case .double(let d) where d.isFinite: return n.int.map(JSON.int) ?? n
        default: throw EruptFailure("illegal number '\(value.text)'")
        }
    }

    private static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : String(n) }

    private static func parts(_ value: JSON) throws -> (y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int, ms: String) {
        let illegal = EruptFailure("illegal date '\(value.text)'")
        guard case .string(let raw) = value else { throw illegal }
        var c = Array(raw.trimmingSpaces.utf8)
        if c.last == UInt8(ascii: "Z") { c.removeLast() }
        var i = 0
        func digits(_ n: Int) throws -> Int {
            guard i + n <= c.count, c[i..<i + n].allSatisfy({ (0x30...0x39).contains($0) }) else { throw illegal }
            defer { i += n }
            return Int(String(decoding: c[i..<i + n], as: UTF8.self))!
        }
        func expect(_ ch: Character) throws {
            guard i < c.count, c[i] == ch.asciiValue! else { throw illegal }
            i += 1
        }
        let y = try digits(4)
        try expect("-")
        let mo = try digits(2)
        try expect("-")
        let d = try digits(2)
        var (h, mi, s, ms) = (0, 0, 0, "000")
        if i < c.count {
            guard c[i] == UInt8(ascii: "T") || c[i] == UInt8(ascii: " ") else { throw illegal }
            i += 1
            h = try digits(2)
            try expect(":")
            mi = try digits(2)
            if i < c.count {
                try expect(":")
                s = try digits(2)
                if i < c.count {
                    try expect(".")
                    let start = i
                    while i < c.count, (0x30...0x39).contains(c[i]) { i += 1 }
                    guard i > start, i - start <= 9 else { throw illegal }
                    ms = String((String(decoding: c[start..<i], as: UTF8.self) + "00").prefix(3))
                }
            }
        }
        let days = [31, y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard i == c.count, (1...12).contains(mo), d >= 1, d <= days[mo - 1], h < 24, mi < 60, s < 60 else { throw illegal }
        return (y, mo, d, h, mi, s, ms)
    }
}

extension String {
    fileprivate init(format4 n: Int) {
        let s = String(n)
        self = String(repeating: "0", count: Swift.max(0, 4 - s.count)) + s
    }
}
