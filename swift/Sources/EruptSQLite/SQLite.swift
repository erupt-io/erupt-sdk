import CSQLite
import EruptSDK
import Foundation

/// A SQLExecutor on a SQLite file through the system libsqlite3; one connection, used by one thread at a time.
///
/// ```swift
/// let db = try SQLiteExecutor(path: "blog.db")
/// let repo = try SQLRepository(db, table: "article", autoCreate: true)
/// ```
public final class SQLiteExecutor: SQLExecutor {
    public let dialect = SQLDialect.sqlite
    private var db: OpaquePointer?
    private let lock = NSLock()

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(db)
            throw Failure(description: message)
        }
        sqlite3_busy_timeout(db, 5000)
    }

    deinit { sqlite3_close(db) }

    public func execute(_ sql: String, _ params: [JSON]) throws -> [[String: JSON]] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        // SQLITE_TRANSIENT: SQLite copies the value before the call returns
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in params.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .bool(let b): sqlite3_bind_int64(statement, index, b ? 1 : 0)
            case .int(let n): sqlite3_bind_int64(statement, index, n)
            case .double(let d): sqlite3_bind_double(statement, index, d)
            case .string(let s): sqlite3_bind_text(statement, index, s, -1, transient)
            case .array, .object: sqlite3_bind_text(statement, index, value.serialized(), -1, transient)
            }
        }
        var rows: [[String: JSON]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return rows
            case SQLITE_ROW:
                var row: [String: JSON] = [:]
                for col in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, col))
                    switch sqlite3_column_type(statement, col) {
                    case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(statement, col))
                    case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(statement, col))
                    case SQLITE_NULL: row[name] = .null
                    default: row[name] = .string(String(cString: sqlite3_column_text(statement, col)))
                    }
                }
                rows.append(row)
            default: throw failure()
            }
        }
    }

    private func failure() -> Failure { Failure(description: String(cString: sqlite3_errmsg(db))) }
}
