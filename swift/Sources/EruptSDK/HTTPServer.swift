import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#else
    import Darwin
#endif

/// One request as a node sees it, whatever server received it.
public struct NodeRequest {
    public let method: String
    /// The raw (still percent-encoded) path below the node's mount point, e.g. `/erupt-api/build/Article`.
    public let path: String
    /// The raw query string, without `?`.
    public let query: String
    public let body: [UInt8]
    private let headers: [String: String]

    /// `headers` are matched case-insensitively.
    public init(method: String, path: String, query: String = "", headers: [String: String], body: [UInt8] = []) {
        self.method = method.uppercased()
        self.path = path
        self.query = query
        self.body = body
        var lower: [String: String] = [:]
        for (k, v) in headers { lower[k.lowercased()] = lower[k.lowercased()].map { "\($0), \(v)" } ?? v }
        self.headers = lower
    }

    /// From a request target: `/erupt-api/build/Article?_=1`.
    public init(method: String, target: String, headers: [String: String], body: [UInt8] = []) {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        self.init(method: method, path: String(parts[0]), query: parts.count > 1 ? String(parts[1]) : "", headers: headers, body: body)
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// What the node answers.
public struct NodeResponse {
    public let status: Int
    public let contentType: String
    public let body: [UInt8]
}

/// A small threaded HTTP/1.1 server (keep-alive, chunked request bodies) on POSIX sockets: enough for the
/// server-to-server traffic of a node, so the SDK needs no web framework. To serve a node from Vapor or
/// Hummingbird, route its paths to `Node.handle` instead.
public final class HTTPServer {
    static let maxBody = 32 << 20
    static let maxLine = 16 << 10
    static let maxHeaders = 100
    static let reasons = [
        100: "Continue", 200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 413: "Payload Too Large",
        500: "Internal Server Error",
    ]

    private let fd: Int32
    private let handler: (NodeRequest) -> NodeResponse
    private let closed = NSLock()
    private var isClosed = false
    /// The port listened on; the one picked by the system when 0 was asked for.
    public let port: Int

    public init(host: String = "0.0.0.0", port: Int, handler: @escaping (NodeRequest) -> NodeResponse) throws {
        signal(SIGPIPE, SIG_IGN)
        #if os(Linux)
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
            let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw POSIXFailure("socket") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            _ = systemClose(fd)
            throw POSIXFailure("illegal IPv4 address \(host)")
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 128) == 0 else {
            let failure = POSIXFailure("listen on \(host):\(port)")
            _ = systemClose(fd)
            throw failure
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.fd = fd
        self.port = Int(UInt16(bigEndian: actual.sin_port))
        self.handler = handler
    }

    /// Accepts on a thread of its own until closed; one thread per connection.
    public func start() {
        let thread = Thread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return  // closed
                }
                Thread.detachNewThread { [self] in connection(client) }
            }
        }
        thread.start()
    }

    public func close() {
        closed.lock()
        defer { closed.unlock() }
        if isClosed { return }
        isClosed = true
        shutdown(fd, Int32(SHUT_RDWR))
        _ = systemClose(fd)
    }

    private struct BadRequest: Error {
        let status: Int
    }

    private func connection(_ client: Int32) {
        var timeout = timeval(tv_sec: 30, tv_usec: 0)  // idle keep-alive connections are dropped
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if !os(Linux)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let conn = Connection(fd: client)
        defer { _ = systemClose(client) }
        do {
            while let (request, version) = try read(conn) {
                let response = handler(request)
                let connection = (request.header("connection") ?? "").lowercased()
                let keepAlive = version == "HTTP/1.1" ? !connection.contains("close") : connection.contains("keep-alive")
                var head = "HTTP/1.1 \(response.status) \(Self.reasons[response.status] ?? "Status")\r\n"
                head += "content-type: \(response.contentType)\r\ncontent-length: \(response.body.count)\r\n"
                head += "connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
                guard conn.write(Array(head.utf8) + response.body), keepAlive else { return }
            }
        } catch let e as BadRequest {
            _ = conn.write(Array("HTTP/1.1 \(e.status) \(Self.reasons[e.status] ?? "")\r\ncontent-length: 0\r\nconnection: close\r\n\r\n".utf8))
        } catch {
            // the peer went away
        }
    }

    private func read(_ conn: Connection) throws -> (NodeRequest, String)? {
        guard let line = try conn.line() else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { throw BadRequest(status: 400) }
        var headers: [String: String] = [:]
        for _ in 0...Self.maxHeaders {
            guard let header = try conn.line() else { throw BadRequest(status: 400) }
            if header.isEmpty {
                if (headers["expect"] ?? "").lowercased() == "100-continue" {
                    _ = conn.write(Array("HTTP/1.1 100 Continue\r\n\r\n".utf8))
                }
                let body = try readBody(conn, headers)
                return (NodeRequest(method: parts[0], target: parts[1], headers: headers, body: body), parts[2])
            }
            guard let colon = header.firstIndex(of: ":") else { throw BadRequest(status: 400) }
            let name = String(header[..<colon]).trimmingSpaces.lowercased()
            let value = String(header[header.index(after: colon)...]).trimmingSpaces
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        throw BadRequest(status: 400)
    }

    private func readBody(_ conn: Connection, _ headers: [String: String]) throws -> [UInt8] {
        if (headers["transfer-encoding"] ?? "").lowercased().contains("chunked") {
            var body: [UInt8] = []
            while true {
                guard let line = try conn.line(), let size = Int(line.split(separator: ";").first.map(String.init)?.trimmingSpaces ?? "", radix: 16)
                else { throw BadRequest(status: 400) }
                if size == 0 { break }
                guard body.count + size <= Self.maxBody else { throw BadRequest(status: 413) }
                body += try conn.bytes(size)
                _ = try conn.bytes(2)
            }
            while let trailer = try conn.line(), !trailer.isEmpty {}
            return body
        }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { throw BadRequest(status: 400) }
        guard length <= Self.maxBody else { throw BadRequest(status: 413) }
        return try conn.bytes(length)
    }

    /// Buffered reads and full writes on a socket.
    private final class Connection {
        let fd: Int32
        var buffer: [UInt8] = []
        var start = 0

        init(fd: Int32) { self.fd = fd }

        /// Reads more; false at the end of the stream (or a timeout).
        func fill() -> Bool {
            if start > 0 {
                buffer.removeFirst(start)
                start = 0
            }
            var chunk = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let n = recv(fd, &chunk, chunk.count, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                buffer += chunk[0..<n]
                return true
            }
        }

        /// A CRLF-terminated line without its terminator; nil at the end of the stream.
        func line() throws -> String? {
            while true {
                if let i = buffer[start...].firstIndex(of: 0x0A) {
                    let end = i > start && buffer[i - 1] == 0x0D ? i - 1 : i
                    let text = String(decoding: buffer[start..<end], as: UTF8.self)
                    start = i + 1
                    return text
                }
                guard buffer.count - start <= HTTPServer.maxLine else { throw BadRequest(status: 400) }
                guard fill() else { return nil }
            }
        }

        func bytes(_ n: Int) throws -> [UInt8] {
            while buffer.count - start < n {
                guard fill() else { throw BadRequest(status: 400) }
            }
            let out = Array(buffer[start..<start + n])
            start += n
            return out
        }

        func write(_ data: [UInt8]) -> Bool {
            var sent = 0
            while sent < data.count {
                #if os(Linux)
                    let n = data[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
                #else
                    let n = data[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
                #endif
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }
    }
}

struct POSIXFailure: Error, CustomStringConvertible {
    let description: String
    init(_ what: String) { description = "\(what): \(String(cString: strerror(errno)))" }
}

func systemClose(_ fd: Int32) -> Int32 {
    #if canImport(Glibc)
        return Glibc.close(fd)
    #elseif canImport(Musl)
        return Musl.close(fd)
    #else
        return Darwin.close(fd)
    #endif
}
