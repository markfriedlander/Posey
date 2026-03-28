import Foundation
import SQLite3

// ========== BLOCK 01: DATABASE ERRORS AND LIFECYCLE - START ==========

final class DatabaseManager {
    enum DatabaseError: LocalizedError {
        case openFailed
        case prepareFailed(String)
        case stepFailed(String)
        case bindFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed:
                return "Posey could not open its local database."
            case .prepareFailed(let message):
                return "Posey could not prepare a database statement: \(message)"
            case .stepFailed(let message):
                return "Posey could not execute a database statement: \(message)"
            case .bindFailed(let message):
                return "Posey could not bind a database value: \(message)"
            }
        }
    }

    private let databaseURL: URL
    private var database: OpaquePointer?

    convenience init(fileManager: FileManager = .default, resetIfExists: Bool = false) throws {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent("Posey", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("posey.sqlite")
        try self.init(databaseURL: databaseURL, fileManager: fileManager, resetIfExists: resetIfExists)
    }

    init(databaseURL: URL, fileManager: FileManager = .default, resetIfExists: Bool = false) throws {
        self.databaseURL = databaseURL
        try fileManager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if resetIfExists, fileManager.fileExists(atPath: databaseURL.path) {
            try fileManager.removeItem(at: databaseURL)
        }
        try open()
        try migrate()
    }

    deinit {
        sqlite3_close(database)
    }
}

// ========== BLOCK 01: DATABASE ERRORS AND LIFECYCLE - END ==========

// ========== BLOCK 02: DOCUMENTS - START ==========

extension DatabaseManager {
    func documents() throws -> [Document] {
        let sql = """
        SELECT id, title, file_name, file_type, imported_at, modified_at, display_text, plain_text, character_count
        FROM documents
        ORDER BY imported_at DESC;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }

        var documents: [Document] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqliteString(statement, index: 0),
                let id = UUID(uuidString: idText),
                let title = sqliteString(statement, index: 1),
                let fileName = sqliteString(statement, index: 2),
                let fileType = sqliteString(statement, index: 3),
                let plainText = sqliteString(statement, index: 7)
            else { continue }

            documents.append(Document(
                id: id,
                title: title,
                fileName: fileName,
                fileType: fileType,
                importedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                displayText: sqliteString(statement, index: 6) ?? plainText,
                plainText: plainText,
                characterCount: Int(sqlite3_column_int64(statement, 8))
            ))
        }
        return documents
    }

    func upsertDocument(_ document: Document) throws {
        let sql = """
        INSERT INTO documents (id, title, file_name, file_type, imported_at, modified_at, display_text, plain_text, character_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            file_name = excluded.file_name,
            file_type = excluded.file_type,
            imported_at = excluded.imported_at,
            modified_at = excluded.modified_at,
            display_text = excluded.display_text,
            plain_text = excluded.plain_text,
            character_count = excluded.character_count;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }

        try bind(document.id.uuidString, at: 1, for: statement)
        try bind(document.title, at: 2, for: statement)
        try bind(document.fileName, at: 3, for: statement)
        try bind(document.fileType, at: 4, for: statement)
        sqlite3_bind_double(statement, 5, document.importedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 6, document.modifiedAt.timeIntervalSince1970)
        try bind(document.displayText, at: 7, for: statement)
        try bind(document.plainText, at: 8, for: statement)
        sqlite3_bind_int64(statement, 9, sqlite3_int64(document.characterCount))

        try step(statement)
    }

    func deleteDocument(_ document: Document) throws {
        let sql = "DELETE FROM documents WHERE id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(document.id.uuidString, at: 1, for: statement)
        try step(statement)
    }

    func existingDocument(matchingFileName fileName: String, fileType: String, plainText: String, displayText: String? = nil) throws -> Document? {
        let sql = """
        SELECT id, title, file_name, file_type, imported_at, modified_at, display_text, plain_text, character_count
        FROM documents
        WHERE file_name = ? AND file_type = ? AND plain_text = ? AND display_text = ?
        LIMIT 1;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }

        try bind(fileName, at: 1, for: statement)
        try bind(fileType, at: 2, for: statement)
        try bind(plainText, at: 3, for: statement)
        try bind(displayText ?? plainText, at: 4, for: statement)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        guard
            let idText = sqliteString(statement, index: 0),
            let id = UUID(uuidString: idText),
            let title = sqliteString(statement, index: 1),
            let storedFileName = sqliteString(statement, index: 2),
            let storedFileType = sqliteString(statement, index: 3),
            let storedText = sqliteString(statement, index: 7)
        else { return nil }

        return Document(
            id: id,
            title: title,
            fileName: storedFileName,
            fileType: storedFileType,
            importedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            displayText: sqliteString(statement, index: 6) ?? storedText,
            plainText: storedText,
            characterCount: Int(sqlite3_column_int64(statement, 8))
        )
    }
}

// ========== BLOCK 02: DOCUMENTS - END ==========

// ========== BLOCK 03: READING POSITIONS - START ==========

extension DatabaseManager {
    func readingPosition(for documentID: UUID) throws -> ReadingPosition? {
        let sql = """
        SELECT document_id, updated_at, character_offset, sentence_index
        FROM reading_positions
        WHERE document_id = ?
        LIMIT 1;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }

        try bind(documentID.uuidString, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let idText = sqliteString(statement, index: 0), let id = UUID(uuidString: idText) else { return nil }

        return ReadingPosition(
            documentID: id,
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            characterOffset: Int(sqlite3_column_int64(statement, 2)),
            sentenceIndex: Int(sqlite3_column_int64(statement, 3))
        )
    }

    func upsertReadingPosition(_ position: ReadingPosition) throws {
        let sql = """
        INSERT INTO reading_positions (document_id, updated_at, character_offset, sentence_index)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(document_id) DO UPDATE SET
            updated_at = excluded.updated_at,
            character_offset = excluded.character_offset,
            sentence_index = excluded.sentence_index;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }

        try bind(position.documentID.uuidString, at: 1, for: statement)
        sqlite3_bind_double(statement, 2, position.updatedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, sqlite3_int64(position.characterOffset))
        sqlite3_bind_int64(statement, 4, sqlite3_int64(position.sentenceIndex))

        try step(statement)
    }
}

// ========== BLOCK 03: READING POSITIONS - END ==========

// ========== BLOCK 04: NOTES - START ==========

extension DatabaseManager {
    func notes(for documentID: UUID) throws -> [Note] {
        let sql = """
        SELECT id, document_id, created_at, updated_at, kind, start_offset, end_offset, body
        FROM notes
        WHERE document_id = ?
        ORDER BY created_at DESC;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }

        try bind(documentID.uuidString, at: 1, for: statement)

        var notes: [Note] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqliteString(statement, index: 0),
                let id = UUID(uuidString: idText),
                let documentIDText = sqliteString(statement, index: 1),
                let rowDocumentID = UUID(uuidString: documentIDText),
                let kindText = sqliteString(statement, index: 4),
                let kind = NoteKind(rawValue: kindText)
            else { continue }

            notes.append(Note(
                id: id,
                documentID: rowDocumentID,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                kind: kind,
                startOffset: Int(sqlite3_column_int64(statement, 5)),
                endOffset: Int(sqlite3_column_int64(statement, 6)),
                body: sqliteString(statement, index: 7)
            ))
        }
        return notes
    }

    func insertNote(_ note: Note) throws {
        let sql = """
        INSERT INTO notes (id, document_id, created_at, updated_at, kind, start_offset, end_offset, body)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }

        try bind(note.id.uuidString, at: 1, for: statement)
        try bind(note.documentID.uuidString, at: 2, for: statement)
        sqlite3_bind_double(statement, 3, note.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, note.updatedAt.timeIntervalSince1970)
        try bind(note.kind.rawValue, at: 5, for: statement)
        sqlite3_bind_int64(statement, 6, sqlite3_int64(note.startOffset))
        sqlite3_bind_int64(statement, 7, sqlite3_int64(note.endOffset))

        if let body = note.body {
            try bind(body, at: 8, for: statement)
        } else {
            sqlite3_bind_null(statement, 8)
        }

        try step(statement)
    }
}

// ========== BLOCK 04: NOTES - END ==========

// ========== BLOCK 05: DOCUMENT IMAGES - START ==========

extension DatabaseManager {
    /// Insert one image record. The image ID is embedded in the document's
    /// displayText visual-page markers and used to load the image at read time.
    func insertImage(id: String, documentID: UUID, data: Data) throws {
        let sql = """
        INSERT OR REPLACE INTO document_images (id, document_id, image_data)
        VALUES (?, ?, ?);
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }

        try bind(id, at: 1, for: statement)
        try bind(documentID.uuidString, at: 2, for: statement)

        let bytes = [UInt8](data)
        if sqlite3_bind_blob(statement, 3, bytes, Int32(bytes.count), SQLITE_TRANSIENT) != SQLITE_OK {
            throw DatabaseError.bindFailed(lastErrorMessage())
        }

        try step(statement)
    }

    /// Load image data by image ID. Returns nil if the record does not exist.
    func imageData(for imageID: String) throws -> Data? {
        let sql = "SELECT image_data FROM document_images WHERE id = ? LIMIT 1;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }

        try bind(imageID, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let ptr = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        return Data(bytes: ptr, count: count)
    }

    /// Delete all images for a document. Called before re-inserting on reimport
    /// so stale image IDs (embedded in the old displayText) don't linger.
    func deleteImages(for documentID: UUID) throws {
        let sql = "DELETE FROM document_images WHERE document_id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        try step(statement)
    }

    /// Returns all image IDs stored for a document, in insertion order.
    func imageIDs(for documentID: UUID) throws -> [String] {
        let sql = "SELECT id FROM document_images WHERE document_id = ? ORDER BY rowid;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(statement, 0) {
                ids.append(String(cString: cStr))
            }
        }
        return ids
    }
}

// ========== BLOCK 05: DOCUMENT IMAGES - END ==========

// ========== BLOCK 05B: DOCUMENT TOC - START ==========

/// One entry in a document's table of contents, as stored in the database.
struct StoredTOCEntry {
    let title: String
    let plainTextOffset: Int
    let playOrder: Int
}

extension DatabaseManager {
    func insertTOCEntries(_ entries: [StoredTOCEntry], for documentID: UUID) throws {
        try execute("DELETE FROM document_toc WHERE document_id = '\(documentID.uuidString)';")
        let sql = """
        INSERT INTO document_toc (document_id, play_order, title, plain_text_offset)
        VALUES (?, ?, ?, ?);
        """
        // Deduplicate on (title, plainTextOffset) so NCX sub-navPoints that reference
        // the same position don't insert redundant rows.
        var seen = Set<String>()
        for entry in entries {
            let key = "\(entry.title)|\(entry.plainTextOffset)"
            guard seen.insert(key).inserted else { continue }
            let statement = try prepareStatement(sql: sql)
            defer { sqlite3_finalize(statement) }
            try bind(documentID.uuidString, at: 1, for: statement)
            sqlite3_bind_int(statement, 2, Int32(entry.playOrder))
            try bind(entry.title, at: 3, for: statement)
            sqlite3_bind_int(statement, 4, Int32(entry.plainTextOffset))
            try step(statement)
        }
    }

    func tocEntries(for documentID: UUID) throws -> [StoredTOCEntry] {
        let sql = """
        SELECT title, plain_text_offset, play_order
        FROM document_toc
        WHERE document_id = ?
        ORDER BY play_order;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        var entries: [StoredTOCEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let title = sqliteString(statement, index: 0) else { continue }
            let offset = Int(sqlite3_column_int(statement, 1))
            let order  = Int(sqlite3_column_int(statement, 2))
            entries.append(StoredTOCEntry(title: title, plainTextOffset: offset, playOrder: order))
        }
        return entries
    }
}

// ========== BLOCK 05B: DOCUMENT TOC - END ==========

// ========== BLOCK 06: SCHEMA AND HELPERS - START ==========

extension DatabaseManager {
    private func open() throws {
        if sqlite3_open(databaseURL.path, &database) != SQLITE_OK {
            throw DatabaseError.openFailed
        }
        // Enable foreign key enforcement so ON DELETE CASCADE on document_images
        // and other tables fires correctly.
        sqlite3_exec(database, "PRAGMA foreign_keys = ON;", nil, nil, nil)
    }

    private func migrate() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS documents (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                file_name TEXT NOT NULL,
                file_type TEXT NOT NULL,
                imported_at REAL NOT NULL,
                modified_at REAL NOT NULL,
                display_text TEXT NOT NULL DEFAULT '',
                plain_text TEXT NOT NULL,
                character_count INTEGER NOT NULL
            );
            """)

        try addColumnIfNeeded(table: "documents", column: "display_text", definition: "TEXT NOT NULL DEFAULT ''")

        try execute("""
            CREATE TABLE IF NOT EXISTS reading_positions (
                document_id TEXT PRIMARY KEY NOT NULL,
                updated_at REAL NOT NULL,
                character_offset INTEGER NOT NULL,
                sentence_index INTEGER NOT NULL,
                FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
            );
            """)

        try execute("""
            CREATE TABLE IF NOT EXISTS notes (
                id TEXT PRIMARY KEY NOT NULL,
                document_id TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                kind TEXT NOT NULL,
                start_offset INTEGER NOT NULL,
                end_offset INTEGER NOT NULL,
                body TEXT,
                FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
            );
            """)

        try execute("""
            CREATE TABLE IF NOT EXISTS document_images (
                id TEXT PRIMARY KEY NOT NULL,
                document_id TEXT NOT NULL,
                image_data BLOB NOT NULL,
                FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
            );
            """)

        try execute("""
            CREATE TABLE IF NOT EXISTS document_toc (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                document_id TEXT NOT NULL,
                play_order INTEGER NOT NULL,
                title TEXT NOT NULL,
                plain_text_offset INTEGER NOT NULL,
                FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
            );
            """)
    }

    private func execute(_ sql: String) throws {
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try step(statement)
    }

    private func addColumnIfNeeded(table: String, column: String, definition: String) throws {
        let statement = try prepareStatement(sql: "PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if sqliteString(statement, index: 1) == column { return }
        }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    private func prepareStatement(sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &statement, nil) != SQLITE_OK {
            throw DatabaseError.prepareFailed(lastErrorMessage())
        }
        return statement
    }

    private func step(_ statement: OpaquePointer?) throws {
        if sqlite3_step(statement) != SQLITE_DONE {
            throw DatabaseError.stepFailed(lastErrorMessage())
        }
    }

    private func bind(_ value: String, at index: Int32, for statement: OpaquePointer?) throws {
        if sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) != SQLITE_OK {
            throw DatabaseError.bindFailed(lastErrorMessage())
        }
    }

    private func sqliteString(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func lastErrorMessage() -> String {
        guard let database else { return "Unknown database error" }
        return String(cString: sqlite3_errmsg(database))
    }
}

// ========== BLOCK 06: SCHEMA AND HELPERS - END ==========

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
