import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - SnippetRecord

/// A persisted snippet record in the local SQLite history.
public struct SnippetRecord: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let rawText: String
    public let cleanedText: String?
    public let mode: String
    public let detectedCommands: [String]
    public let targetAppName: String?
    public let insertionSuccess: Bool?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        rawText: String,
        cleanedText: String? = nil,
        mode: String = "Terminal",
        detectedCommands: [String] = [],
        targetAppName: String? = nil,
        insertionSuccess: Bool? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.mode = mode
        self.detectedCommands = detectedCommands
        self.targetAppName = targetAppName
        self.insertionSuccess = insertionSuccess
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The display text — cleaned if available, raw as fallback.
    public var displayText: String {
        cleanedText ?? rawText
    }

    public var preview: String {
        let trimmed = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 120 else { return trimmed }
        return "\(trimmed.prefix(120))…"
    }
}

// MARK: - SnippetStoreError

public enum SnippetStoreError: Error, LocalizedError {
    case sqliteUnavailable
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
    case closeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sqliteUnavailable:
            return "SQLite3 is not available on this system."
        case .openFailed(let msg):
            return "Failed to open database: \(msg)"
        case .prepareFailed(let msg):
            return "Failed to prepare statement: \(msg)"
        case .stepFailed(let msg):
            return "Failed to execute statement: \(msg)"
        case .bindFailed(let msg):
            return "Failed to bind parameter: \(msg)"
        case .closeFailed(let msg):
            return "Failed to close database: \(msg)"
        }
    }
}

// MARK: - SnippetStore

/// A SQLite-backed store for snippet history.
/// Thread-safe via a serial dispatch queue with a persistent connection.
public final class SnippetStore: Sendable {
    private let dbPath: String
    private let queue = DispatchQueue(label: "com.voicetotext.snippetstore", qos: .userInitiated)
    private nonisolated(unsafe) var db: OpaquePointer?

    public init(baseDirectoryURL: URL? = nil) {
        let dirURL: URL
        if let baseDirectoryURL {
            dirURL = baseDirectoryURL
        } else {
            dirURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent("VoiceToTextMac")
        }
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        self.dbPath = dirURL.appendingPathComponent("snippets.db").path
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Public API

    public func bootstrap() throws {
        try queue.sync {
            try openDBIfNeeded()

            let sql = """
            CREATE TABLE IF NOT EXISTS snippets (
                id TEXT PRIMARY KEY,
                raw_text TEXT NOT NULL,
                cleaned_text TEXT,
                mode TEXT NOT NULL DEFAULT 'Terminal',
                detected_commands TEXT DEFAULT '[]',
                target_app_name TEXT,
                insertion_success INTEGER,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_snippets_created_at ON snippets(created_at DESC);
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SnippetStoreError.prepareFailed(String(cString: sqlite3_errmsg(db!)))
            }
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw SnippetStoreError.stepFailed(String(cString: sqlite3_errmsg(db!)))
            }
        }
    }

    public func insert(_ record: SnippetRecord) throws {
        try queue.sync {
            try openDBIfNeeded()

            let sql = """
            INSERT INTO snippets (id, raw_text, cleaned_text, mode, detected_commands, target_app_name, insertion_success, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                raw_text = excluded.raw_text,
                cleaned_text = excluded.cleaned_text,
                mode = excluded.mode,
                detected_commands = excluded.detected_commands,
                target_app_name = excluded.target_app_name,
                insertion_success = excluded.insertion_success,
                updated_at = excluded.updated_at
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SnippetStoreError.prepareFailed(String(cString: sqlite3_errmsg(db!)))
            }
            defer { sqlite3_finalize(stmt) }

            let commandsJSON = try encodeCommands(record.detectedCommands)

            bindText(stmt, 1, record.id.uuidString)
            bindText(stmt, 2, record.rawText)
            bindTextOrNil(stmt, 3, record.cleanedText)
            bindText(stmt, 4, record.mode)
            bindText(stmt, 5, commandsJSON)
            bindTextOrNil(stmt, 6, record.targetAppName)
            bindIntOrNil(stmt, 7, record.insertionSuccess.map { $0 ? 1 : 0 })
            bindDouble(stmt, 8, record.createdAt.timeIntervalSince1970)
            bindDouble(stmt, 9, record.updatedAt.timeIntervalSince1970)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw SnippetStoreError.stepFailed(String(cString: sqlite3_errmsg(db!)))
            }
        }
    }

    public func loadRecent(limit: Int = 50) throws -> [SnippetRecord] {
        try queue.sync {
            try openDBIfNeeded()

            let sql = "SELECT id, raw_text, cleaned_text, mode, detected_commands, target_app_name, insertion_success, created_at, updated_at FROM snippets ORDER BY created_at DESC LIMIT ?"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SnippetStoreError.prepareFailed(String(cString: sqlite3_errmsg(db!)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(limit))

            var records: [SnippetRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let idStr = columnText(stmt, 0) ?? ""
                let rawText = columnText(stmt, 1) ?? ""
                let cleanedText = columnText(stmt, 2)
                let mode = columnText(stmt, 3) ?? "Terminal"
                let commands = decodeCommands(columnText(stmt, 4))
                let targetAppName = columnText(stmt, 5)
                let insertionSuccess = columnInt(stmt, 6).map { $0 != 0 }
                let createdAt = columnDouble(stmt, 7)
                let updatedAt = columnDouble(stmt, 8)

                records.append(SnippetRecord(
                    id: UUID(uuidString: idStr) ?? UUID(),
                    rawText: rawText,
                    cleanedText: cleanedText,
                    mode: mode,
                    detectedCommands: commands,
                    targetAppName: targetAppName,
                    insertionSuccess: insertionSuccess,
                    createdAt: Date(timeIntervalSince1970: createdAt),
                    updatedAt: Date(timeIntervalSince1970: updatedAt)
                ))
            }

            return records
        }
    }

    public func delete(id: UUID) throws {
        try queue.sync {
            try openDBIfNeeded()

            let sql = "DELETE FROM snippets WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SnippetStoreError.prepareFailed(String(cString: sqlite3_errmsg(db!)))
            }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, 1, id.uuidString)
            _ = sqlite3_step(stmt)
        }
    }

    public func clearAll() throws {
        try queue.sync {
            try openDBIfNeeded()

            let sql = "DELETE FROM snippets"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SnippetStoreError.prepareFailed(String(cString: sqlite3_errmsg(db!)))
            }
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw SnippetStoreError.stepFailed(String(cString: sqlite3_errmsg(db!)))
            }
        }
    }

    public func count() throws -> Int {
        try queue.sync {
            try openDBIfNeeded()

            let sql = "SELECT COUNT(*) FROM snippets"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SnippetStoreError.prepareFailed(String(cString: sqlite3_errmsg(db!)))
            }
            defer { sqlite3_finalize(stmt) }

            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int64(stmt, 0))
            }
            return 0
        }
    }

    // MARK: - Private Helpers

    private func openDBIfNeeded() throws {
        guard db == nil else { return }
        var newDb: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &newDb, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let newDb else {
            throw SnippetStoreError.openFailed("Could not open database at \(dbPath)")
        }
        self.db = newDb
    }

/// SQLITE_TRANSIENT tells SQLite to copy the string immediately.
/// Required because Swift String memory is managed and may be deallocated.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindTextOrNil(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindIntOrNil(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(stmt, index, Int32(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: TimeInterval) {
        sqlite3_bind_double(stmt, index, value)
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private func columnInt(_ stmt: OpaquePointer?, _ index: Int32) -> Int? {
        let colType = sqlite3_column_type(stmt, index)
        guard colType != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, index))
    }

    private func columnDouble(_ stmt: OpaquePointer?, _ index: Int32) -> TimeInterval {
        let colType = sqlite3_column_type(stmt, index)
        guard colType != SQLITE_NULL else { return 0 }
        return sqlite3_column_double(stmt, index)
    }

    private func encodeCommands(_ commands: [String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: commands)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func decodeCommands(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return arr
    }
}
