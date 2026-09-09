import Darwin
import Foundation
import SQLite3

public enum OperationalStoreError: Error, Equatable, Sendable {
    case invalidLocation, unsafeFile, unsupportedSchema, invalidDatabase, invalidInput, scopeMismatch
    case missingRun, staleSequence
    case database(Int32)
}

/// Confined to its owning actor. Errors expose SQLite codes, never SQL or bound data.
final class SQLiteConnection {
    private let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(database: URL) throws {
        guard database.isFileURL, !database.path.utf8.contains(0),
              database.lastPathComponent == "operations.sqlite",
              let canonical = realpath(database.deletingLastPathComponent().path, nil) else {
            throw OperationalStoreError.invalidLocation
        }
        defer { free(canonical) }
        let parent = String(cString: canonical)
        let path = parent + "/operations.sqlite"
        // The caller authorizes the application-owned container; arbitrary relative paths are not accepted.
        for suffix in ["", "-wal", "-shm", "-journal"] {
            var metadata = stat()
            if lstat(path + suffix, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else { throw OperationalStoreError.unsafeFile }
            } else if errno != ENOENT { throw OperationalStoreError.invalidLocation }
        }
        // A new operational database is private from its first creation.
        let created = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if created >= 0 { Darwin.close(created) }
        else if errno != EEXIST { throw OperationalStoreError.invalidLocation }
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw OperationalStoreError.database(result)
        }
        handle = opened
        sqlite3_busy_timeout(handle, 250)
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 1_048_576)
        sqlite3_limit(handle, SQLITE_LIMIT_SQL_LENGTH, 65_536)
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        try statement(sql, values) { statement in
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE else { throw OperationalStoreError.database(code) }
        }
    }

    func query<T>(_ sql: String, _ values: [SQLValue] = [], map: (OpaquePointer) throws -> T) throws -> [T] {
        try statement(sql, values) { statement in
            var rows: [T] = []
            while true {
                try Task.checkCancellation()
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return rows }
                guard code == SQLITE_ROW else { throw OperationalStoreError.database(code) }
                rows.append(try map(statement))
            }
        }
    }

    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try operation()
            try Task.checkCancellation()
            try execute("COMMIT")
            return value
        } catch {
            // Rollback must run even when the caller is cancelled.
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    func integer(_ sql: String) throws -> Int {
        guard let result = try query(sql, map: { Int(sqlite3_column_int64($0, 0)) }).first else {
            throw OperationalStoreError.invalidDatabase
        }
        return result
    }

    private func statement<T>(_ sql: String, _ values: [SQLValue], body: (OpaquePointer) throws -> T) throws -> T {
        try Task.checkCancellation()
        var prepared: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        guard code == SQLITE_OK, let prepared else { throw OperationalStoreError.database(code) }
        defer { sqlite3_finalize(prepared) }
        guard sqlite3_bind_parameter_count(prepared) == values.count else { throw OperationalStoreError.invalidInput }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let bound: Int32
            switch value {
            case .text(let text):
                guard !text.utf8.contains(0), text.utf8.count <= 65_536 else { throw OperationalStoreError.invalidInput }
                bound = sqlite3_bind_text(prepared, position, text, -1, Self.transient)
            case .json(let text):
                // Only validated, encoded operational snapshots use this larger bound.
                guard !text.utf8.contains(0), text.utf8.count <= 131_072 else { throw OperationalStoreError.invalidInput }
                bound = sqlite3_bind_text(prepared, position, text, -1, Self.transient)
            case .integer(let number): bound = sqlite3_bind_int64(prepared, position, number)
            case .real(let number):
                guard number.isFinite else { throw OperationalStoreError.invalidInput }
                bound = sqlite3_bind_double(prepared, position, number)
            }
            guard bound == SQLITE_OK else { throw OperationalStoreError.database(bound) }
        }
        return try body(prepared)
    }

    static func text(_ statement: OpaquePointer, _ index: Int32, maximumBytes: Int = 65_536) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, index) else { throw OperationalStoreError.invalidDatabase }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard (1...131_072).contains(maximumBytes), count <= maximumBytes else { throw OperationalStoreError.invalidDatabase }
        let data = Data(bytes: bytes, count: count)
        guard let string = String(data: data, encoding: .utf8), !string.utf8.contains(0) else {
            throw OperationalStoreError.invalidDatabase
        }
        return string
    }
}

enum SQLValue {
    case text(String), json(String), integer(Int64), real(Double)
}
