/// Erupt-Signature (erupt-cloud/PROTOCOL.md §4.3): an HMAC-SHA256 the server puts on every forward, keyed by
/// the node's access token, so the token need not travel and the signed headers cannot be forged.
public enum Signature {
    public static let windowSeconds: Int64 = 300
    static let unsignedPayload = "UNSIGNED-PAYLOAD"

    /// `body` is the raw bytes, or nil for a multipart upload the server re-encodes (not covered).
    public static func sign(
        accessToken: String, method: String, pathAndQuery: String, timestamp: Int64, enforced: String?,
        user: String?, body: [UInt8]?
    ) -> String {
        let canonical = [
            method.uppercased(), pathAndQuery, String(timestamp), enforced ?? "", hex(SHA256.hash(Array((user ?? "").utf8))),
            body.map { hex(SHA256.hash($0)) } ?? unsignedPayload,
        ].joined(separator: "\n")
        return hex(SHA256.hmac(key: Array(accessToken.utf8), message: Array(canonical.utf8)))
    }

    public static func verify(
        accessToken: String, method: String, pathAndQuery: String, timestamp: String?, enforced: String?,
        user: String?, body: [UInt8]?, signature: String?, now: Int64
    ) -> Bool {
        guard let ts = Int64((timestamp ?? "").trimmingSpaces), abs(now - ts) <= windowSeconds else { return false }
        let expected = sign(
            accessToken: accessToken, method: method, pathAndQuery: pathAndQuery, timestamp: ts, enforced: enforced,
            user: user, body: body)
        return constantTimeEquals(expected, (signature ?? "").trimmingSpaces)
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in x.indices { diff |= x[i] ^ y[i] }
    return diff == 0
}

/// SHA-256 and HMAC-SHA256 (FIPS 180-4, RFC 2104), so the SDK needs neither CryptoKit (Apple only) nor
/// swift-crypto.
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var data = message
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        let bits = UInt64(message.count) * 8
        for i in (0..<8).reversed() { data.append(UInt8(truncatingIfNeeded: bits >> (UInt64(i) * 8))) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(data[j]) << 24 | UInt32(data[j + 1]) << 16 | UInt32(data[j + 2]) << 8 | UInt32(data[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let t1 = hh &+ (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
                let t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            for (i, v) in [a, b, c, d, e, f, g, hh].enumerated() { h[i] = h[i] &+ v }
        }
        return h.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - $0 * 8)) } }
    }

    static func hmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var k = key.count > 64 ? hash(key) : key
        k += [UInt8](repeating: 0, count: 64 - k.count)
        return hash(k.map { $0 ^ 0x5c } + hash(k.map { $0 ^ 0x36 } + message))
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
}

extension String {
    var trimmingSpaces: String {
        var s = Substring(self)
        while let c = s.first, c.isWhitespace { s.removeFirst() }
        while let c = s.last, c.isWhitespace { s.removeLast() }
        return String(s)
    }
}
