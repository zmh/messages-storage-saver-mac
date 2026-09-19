import Foundation
import SQLite3

public enum DBValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public var int64: Int64? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        case .text(let s): return Int64(s)
        default: return nil
        }
    }

    public var string: String? {
        if case .text(let s) = self { return s }
        return nil
    }
}

public struct Row {
    public let values: [String: DBValue]
    public subscript(_ name: String) -> DBValue { values[name] ?? .null }
    public func int(_ name: String) -> Int64? { self[name].int64 }
    public func text(_ name: String) -> String? { self[name].string }
}

public enum DatabaseError: Error, CustomStringConvertible {
    case open(path: String, message: String)
    case prepare(sql: String, message: String)
    case step(message: String)
    case schema(missing: [String])
    case notOpen

    public var description: String {
        switch self {
        case .open(let path, let message): return "cannot open \(path) read-only: \(message)"
        case .prepare(let sql, let message): return "cannot prepare query: \(message) [\(sql.prefix(80))]"
        case .step(let message): return "query failed: \(message)"
        case .schema(let missing): return "unexpected chat.db schema, missing: \(missing.joined(separator: ", "))"
        case .notOpen: return "database is not open"
        }
    }
}

/// Read-only pragmas that take a table/index name in parentheses.
private let argumentPragmas: Set<String> = [
    "table_info", "table_xinfo", "index_list", "index_info", "foreign_key_list",
]
/// Read-only pragmas that must not be assigned a value.
private let valuelessPragmas: Set<String> = [
    "user_version", "schema_version", "journal_mode", "data_version", "page_size", "page_count", "freelist_count",
]

/// The only entry point to chat.db. The connection is opened read-only via a
/// `mode=ro` URI, forced into `query_only`, and guarded by an SQLite authorizer
/// that denies every action except reading. There is no `execute` method:
/// callers can only run `query`.
public final class ReadOnlyDatabase {
    private var handle: OpaquePointer?
    public let path: String

    /// - Parameters:
    ///   - path: file path of the database.
    ///   - immutable: open with `immutable=1` (no locks, no WAL read). Only for
    ///     backup copies that are not being written by anyone.
    public init(path: String, immutable: Bool = false) throws {
        self.path = path
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var uri = "file:\(encoded)?mode=ro"
        if immutable { uri += "&immutable=1" }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(uri, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let db { sqlite3_close(db) }
            throw DatabaseError.open(path: path, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
        sqlite3_set_authorizer(db, { _, action, arg1, arg2, _, _ -> Int32 in
            switch action {
            case SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_RECURSIVE, SQLITE_TRANSACTION:
                return SQLITE_OK
            case SQLITE_PRAGMA:
                // arg1 = pragma name, arg2 = assigned value (nil when just reading).
                guard let arg1 else { return SQLITE_DENY }
                let name = String(cString: arg1).lowercased()
                if name == "query_only" { return (arg2 == nil || String(cString: arg2!) == "1") ? SQLITE_OK : SQLITE_DENY }
                if argumentPragmas.contains(name) { return SQLITE_OK }
                if arg2 == nil, valuelessPragmas.contains(name) { return SQLITE_OK }
                return SQLITE_DENY
            default:
                return SQLITE_DENY
            }
        }, nil)
        _ = try query("PRAGMA query_only = 1")
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    /// Runs a read-only statement and returns all rows.
    public func query(_ sql: String, _ bindings: [DBValue] = []) throws -> [Row] {
        guard let handle else { throw DatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepare(sql: sql, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .blob(let d): d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), transient) }
            }
        }
        let columnCount = Int(sqlite3_column_count(stmt))
        let names = (0..<columnCount).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var values: [String: DBValue] = [:]
                for c in 0..<columnCount {
                    let col = Int32(c)
                    switch sqlite3_column_type(stmt, col) {
                    case SQLITE_INTEGER: values[names[c]] = .int(sqlite3_column_int64(stmt, col))
                    case SQLITE_FLOAT: values[names[c]] = .double(sqlite3_column_double(stmt, col))
                    case SQLITE_TEXT: values[names[c]] = .text(String(cString: sqlite3_column_text(stmt, col)))
                    case SQLITE_BLOB:
                        let n = Int(sqlite3_column_bytes(stmt, col))
                        if let p = sqlite3_column_blob(stmt, col) { values[names[c]] = .blob(Data(bytes: p, count: n)) } else { values[names[c]] = .blob(Data()) }
                    default: values[names[c]] = .null
                    }
                }
                rows.append(Row(values: values))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DatabaseError.step(message: String(cString: sqlite3_errmsg(handle)))
            }
        }
        return rows
    }

    public func scalarInt(_ sql: String, _ bindings: [DBValue] = []) throws -> Int64 {
        let rows = try query(sql, bindings)
        guard let first = rows.first, let value = first.values.values.first?.int64 else { return 0 }
        return value
    }

    /// Columns the offload logic depends on. Anything missing means an
    /// unknown schema; the tool refuses rather than guesses.
    public static let requiredColumns: [String: [String]] = [
        "attachment": ["ROWID", "guid", "filename", "uti", "mime_type", "transfer_state", "total_bytes",
                       "is_sticker", "hide_attachment", "ck_sync_state", "ck_record_id"],
        "message": ["ROWID", "date", "is_audio_message"],
        "chat": ["ROWID", "chat_identifier", "display_name"],
        "message_attachment_join": ["message_id", "attachment_id"],
        "chat_message_join": ["chat_id", "message_id"],
        "sync_deleted_attachments": ["guid"],
        "sync_deleted_messages": ["guid"],
    ]

    public func verifySchema() throws {
        var missing: [String] = []
        for (table, columns) in Self.requiredColumns.sorted(by: { $0.key < $1.key }) {
            let present = Set(try query("PRAGMA table_info(\(table))").compactMap { $0.text("name") })
            if present.isEmpty { missing.append(table); continue }
            for c in columns where !present.contains(c) { missing.append("\(table).\(c)") }
        }
        if !missing.isEmpty { throw DatabaseError.schema(missing: missing) }
    }
}
