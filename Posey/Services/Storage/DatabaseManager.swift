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
        SELECT id, title, file_name, file_type, imported_at, modified_at, display_text, plain_text, character_count, playback_skip_until_offset
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
                characterCount: Int(sqlite3_column_int64(statement, 8)),
                playbackSkipUntilOffset: Int(sqlite3_column_int64(statement, 9))
            ))
        }
        return documents
    }

    func upsertDocument(_ document: Document) throws {
        let sql = """
        INSERT INTO documents (id, title, file_name, file_type, imported_at, modified_at, display_text, plain_text, character_count, playback_skip_until_offset)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            file_name = excluded.file_name,
            file_type = excluded.file_type,
            imported_at = excluded.imported_at,
            modified_at = excluded.modified_at,
            display_text = excluded.display_text,
            plain_text = excluded.plain_text,
            character_count = excluded.character_count,
            playback_skip_until_offset = excluded.playback_skip_until_offset;
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
        sqlite3_bind_int64(statement, 10, sqlite3_int64(document.playbackSkipUntilOffset))

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
        SELECT id, title, file_name, file_type, imported_at, modified_at, display_text, plain_text, character_count, playback_skip_until_offset
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
            characterCount: Int(sqlite3_column_int64(statement, 8)),
            playbackSkipUntilOffset: Int(sqlite3_column_int64(statement, 9))
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

// ========== BLOCK 05C: DOCUMENT CHUNKS (Ask Posey M2) - START ==========

/// One row of `document_chunks`: a slice of plainText with its
/// pre-computed embedding. Used by Ask Posey for RAG retrieval.
/// Created at import time for every supported format.
struct StoredDocumentChunk: Equatable {
    let chunkIndex: Int
    let startOffset: Int
    let endOffset: Int
    let text: String
    let embedding: [Double]
    /// Identifies which embedding model produced `embedding`. Examples:
    /// `"en-sentence"`, `"fr-sentence"`, `"english-fallback"`,
    /// `"hash-fallback"`. Stored so future model upgrades can re-index
    /// only the rows that need it.
    let embeddingKind: String
}

extension DatabaseManager {
    /// Replace any existing chunks for `documentID` with `chunks`. Wraps
    /// the replacement in a single SQL transaction so a partial failure
    /// can't leave the index in a half-rebuilt state.
    func replaceChunks(_ chunks: [StoredDocumentChunk], for documentID: UUID) throws {
        try execute("BEGIN TRANSACTION;")
        do {
            try execute("DELETE FROM document_chunks WHERE document_id = '\(documentID.uuidString)';")
            let insertSQL = """
            INSERT INTO document_chunks
                (document_id, chunk_index, start_offset, end_offset, text, embedding, embedding_kind)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
            for chunk in chunks {
                let statement = try prepareStatement(sql: insertSQL)
                defer { sqlite3_finalize(statement) }
                try bind(documentID.uuidString, at: 1, for: statement)
                sqlite3_bind_int(statement, 2, Int32(chunk.chunkIndex))
                sqlite3_bind_int(statement, 3, Int32(chunk.startOffset))
                sqlite3_bind_int(statement, 4, Int32(chunk.endOffset))
                try bind(chunk.text, at: 5, for: statement)

                // Pack [Double] little-endian. The reader does the
                // reverse on retrieval; both sides assume the
                // current-machine endianness, which is fine for an
                // app-private SQLite file that never moves between
                // architectures.
                let blob = chunk.embedding.withUnsafeBufferPointer {
                    Data(buffer: $0)
                }
                let bytes = [UInt8](blob)
                if sqlite3_bind_blob(statement, 6, bytes, Int32(bytes.count), SQLITE_TRANSIENT) != SQLITE_OK {
                    throw DatabaseError.bindFailed(lastErrorMessage())
                }
                try bind(chunk.embeddingKind, at: 7, for: statement)
                try step(statement)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Number of indexed chunks for a document. Used by callers that
    /// need to decide whether to retro-index without paying for a full
    /// row read.
    func chunkCount(for documentID: UUID) throws -> Int {
        let sql = "SELECT COUNT(*) FROM document_chunks WHERE document_id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// Return all chunks for a document, in chunk-index order.
    func chunks(for documentID: UUID) throws -> [StoredDocumentChunk] {
        let sql = """
        SELECT chunk_index, start_offset, end_offset, text, embedding, embedding_kind
        FROM document_chunks
        WHERE document_id = ?
        ORDER BY chunk_index;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        var results: [StoredDocumentChunk] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let index   = Int(sqlite3_column_int(statement, 0))
            let start   = Int(sqlite3_column_int(statement, 1))
            let end     = Int(sqlite3_column_int(statement, 2))
            guard let text = sqliteString(statement, index: 3) else { continue }
            guard let blobPtr = sqlite3_column_blob(statement, 4) else { continue }
            let blobSize = Int(sqlite3_column_bytes(statement, 4))
            let embedding = Data(bytes: blobPtr, count: blobSize)
                .withUnsafeBytes { ptr -> [Double] in
                    Array(ptr.bindMemory(to: Double.self))
                }
            let kind = sqliteString(statement, index: 5) ?? "unknown"
            results.append(StoredDocumentChunk(
                chunkIndex: index,
                startOffset: start,
                endOffset: end,
                text: text,
                embedding: embedding,
                embeddingKind: kind
            ))
        }
        return results
    }

    /// Drop every chunk for a document. Called on re-import so stale
    /// embeddings don't linger when content changes. (The cascade
    /// delete handles document removal; this helper is for the
    /// re-import case where the document row stays but the chunks
    /// need to be rebuilt.)
    func deleteChunks(for documentID: UUID) throws {
        let sql = "DELETE FROM document_chunks WHERE document_id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        try step(statement)
    }
}

// ========== BLOCK 05C: DOCUMENT CHUNKS (Ask Posey M2) - END ==========

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
        // playback_skip_until_offset = character offset in plainText past which
        // the reader should auto-jump on first open. Used by the PDF TOC
        // detector to suppress reading the TOC aloud. 0 = no skip.
        try addColumnIfNeeded(table: "documents", column: "playback_skip_until_offset", definition: "INTEGER NOT NULL DEFAULT 0")

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

        // ========== Ask Posey Milestone 1 — schema additions ==========
        // Persistent per-document conversation history. Every Ask Posey
        // exchange (passage-scoped, document-scoped, or rolling summary)
        // lands here. ON DELETE CASCADE keeps the table clean when a
        // document is deleted from the library. See ask_posey_spec.md and
        // ARCHITECTURE.md "Ask Posey Architecture" for semantics.
        try execute("""
            CREATE TABLE IF NOT EXISTS ask_posey_conversations (
                id TEXT PRIMARY KEY NOT NULL,
                document_id TEXT NOT NULL,
                timestamp REAL NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                invocation TEXT NOT NULL,
                anchor_offset INTEGER,
                summary_of_turns_through INTEGER NOT NULL DEFAULT 0,
                is_summary INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
            );
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS idx_ask_posey_doc_ts
            ON ask_posey_conversations(document_id, timestamp);
            """)

        // Embedding index for Ask Posey RAG retrieval. One row per ~500-char
        // chunk with 50-char overlap, built at import time for every
        // supported format (TXT/MD/RTF/DOCX/HTML/EPUB/PDF) per the
        // format-parity standing policy. The `embedding` BLOB packs
        // [Double] little-endian; the embedding model used (English,
        // detected-language NLEmbedding, or hash fallback) is captured in
        // `embedding_kind` so Milestone 2 can validate retrieval and
        // re-index if a model is upgraded.
        try execute("""
            CREATE TABLE IF NOT EXISTS document_chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                document_id TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                start_offset INTEGER NOT NULL,
                end_offset INTEGER NOT NULL,
                text TEXT NOT NULL,
                embedding BLOB NOT NULL,
                embedding_kind TEXT NOT NULL DEFAULT 'unknown',
                FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
            );
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS idx_document_chunks_doc
            ON document_chunks(document_id, chunk_index);
            """)
        // ========== End Ask Posey Milestone 1 schema additions ==========
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
