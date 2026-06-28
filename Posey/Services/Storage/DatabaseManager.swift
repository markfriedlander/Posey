import Foundation
import SQLite3

// ========== BLOCK 01: DATABASE ERRORS AND LIFECYCLE - START ==========

/// Threading invariant: every `DatabaseManager` call routes through the
/// canonical main thread. The underlying SQLite handle is single-threaded
/// and serialized by the call sites; this type is marked `@unchecked Sendable`
/// so it can be captured into `@Sendable` closures that hop *to* main
/// (the indexing pipeline hands off accumulated chunks to main for persistence).
final class DatabaseManager: @unchecked Sendable {
    enum DatabaseError: LocalizedError {
        case openFailed
        case prepareFailed(String)
        case stepFailed(String)
        case bindFailed(String)
        /// SQLite reported `SQLITE_CONSTRAINT_FOREIGNKEY` (extended code 787).
        /// Surfaced as a distinct case so callers can treat the "document
        /// was deleted under us" race as benign (silent no-op) instead of
        /// presenting a scary alert. Race window: reader writes a reading
        /// position while RESET_ALL / DELETE_DOCUMENT cascade-deletes the
        /// document row on main; the FK on reading_positions.document_id
        /// then rejects the upsert.
        case foreignKeyViolation(String)

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
            case .foreignKeyViolation(let message):
                return "Posey could not satisfy a database relationship: \(message)"
            }
        }
    }

    private let databaseURL: URL
    private var database: OpaquePointer?

    /// Serializes ALL access to the single SQLite connection. The class
    /// header used to claim access was "serialized by the call sites" —
    /// it was not: `UnitEmbeddingService.fillEmbeddings` (background) and
    /// the import/persist path touched the one connection concurrently,
    /// which libsqlite3 traps as "illegal multi-threaded access to
    /// database connection" (caught on the Mac, 2026-05-29). Every public
    /// method now takes this lock for its whole body, so a multi-statement
    /// transaction can't interleave with another thread's access.
    /// **Recursive** because composite public methods call other public
    /// methods on the same thread (e.g. persistParsedDocument); a plain
    /// lock or serial-queue `.sync` would deadlock on that reentrancy.
    private let dbLock = NSRecursiveLock()

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
        dbLock.lock(); defer { dbLock.unlock() }
        // **Step 10 — derived plainText / displayText.** The columns
        // `display_text` and `plain_text` no longer exist; both fields
        // on Document are populated by joining prose-bearing units
        // (the same algorithm the persister used when it still wrote
        // the columns). One small SELECT + N derivations; on a typical
        // library that's <100ms even for tens of docs.
        let sql = """
        SELECT id, title, file_name, file_type, imported_at, modified_at, character_count, playback_skip_until_offset, content_end_offset, skip_source, content_hash, edition_label
        FROM documents
        ORDER BY imported_at DESC;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }

        var rows: [(id: UUID, title: String, fileName: String, fileType: String, importedAt: Date, modifiedAt: Date, characterCount: Int, playbackSkipUntilOffset: Int, contentEndOffset: Int, skipSource: String, contentHash: String?, editionLabel: String?)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqliteString(statement, index: 0),
                let id = UUID(uuidString: idText),
                let title = sqliteString(statement, index: 1),
                let fileName = sqliteString(statement, index: 2),
                let fileType = sqliteString(statement, index: 3)
            else { continue }
            rows.append((
                id: id,
                title: title,
                fileName: fileName,
                fileType: fileType,
                importedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                characterCount: Int(sqlite3_column_int64(statement, 6)),
                playbackSkipUntilOffset: Int(sqlite3_column_int64(statement, 7)),
                contentEndOffset: Int(sqlite3_column_int64(statement, 8)),
                skipSource: sqliteString(statement, index: 9) ?? "",
                contentHash: sqliteString(statement, index: 10),
                editionLabel: sqliteString(statement, index: 11)
            ))
        }

        // Now derive plainText per row (the SELECT statement above is
        // finalized — safe to issue per-doc unit queries).
        var documents: [Document] = []
        documents.reserveCapacity(rows.count)
        for row in rows {
            let derived = (try? plainText(for: row.id)) ?? ""
            documents.append(Document(
                id: row.id,
                title: row.title,
                fileName: row.fileName,
                fileType: row.fileType,
                importedAt: row.importedAt,
                modifiedAt: row.modifiedAt,
                displayText: derived,
                plainText: derived,
                characterCount: row.characterCount,
                playbackSkipUntilOffset: row.playbackSkipUntilOffset,
                contentEndOffset: row.contentEndOffset,
                skipSource: row.skipSource,
                contentHash: row.contentHash,
                editionLabel: row.editionLabel
            ))
        }
        return documents
    }

    func upsertDocument(_ document: Document) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        // **Step 10 — plain_text / display_text columns dropped.**
        // INSERT omits them; the doc's plainText/displayText fields
        // are derived from units at row-read time. Persistence of the
        // text lives entirely in `document_units` now.
        // **Bundle 2b (2026-05-26)** — content_hash added.
        let sql = """
        INSERT INTO documents (id, title, file_name, file_type, imported_at, modified_at, character_count, playback_skip_until_offset, content_end_offset, skip_source, content_hash, edition_label)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            file_name = excluded.file_name,
            file_type = excluded.file_type,
            imported_at = excluded.imported_at,
            modified_at = excluded.modified_at,
            character_count = excluded.character_count,
            playback_skip_until_offset = excluded.playback_skip_until_offset,
            content_end_offset = excluded.content_end_offset,
            skip_source = excluded.skip_source,
            content_hash = excluded.content_hash,
            edition_label = excluded.edition_label;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }

        try bind(document.id.uuidString, at: 1, for: statement)
        try bind(document.title, at: 2, for: statement)
        try bind(document.fileName, at: 3, for: statement)
        try bind(document.fileType, at: 4, for: statement)
        sqlite3_bind_double(statement, 5, document.importedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 6, document.modifiedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 7, sqlite3_int64(document.characterCount))
        sqlite3_bind_int64(statement, 8, sqlite3_int64(document.playbackSkipUntilOffset))
        sqlite3_bind_int64(statement, 9, sqlite3_int64(document.contentEndOffset))
        try bind(document.skipSource, at: 10, for: statement)
        if let hash = document.contentHash, !hash.isEmpty {
            try bind(hash, at: 11, for: statement)
        } else {
            sqlite3_bind_null(statement, 11)
        }
        if let edition = document.editionLabel, !edition.isEmpty {
            try bind(edition, at: 12, for: statement)
        } else {
            sqlite3_bind_null(statement, 12)
        }

        try step(statement)
    }

    func deleteDocument(_ document: Document) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = "DELETE FROM documents WHERE id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(document.id.uuidString, at: 1, for: statement)
        try step(statement)
    }

    /// Returns true iff a row exists in `documents` with the given id.
    /// Used as a precheck before writes that would otherwise hit a FK
    /// violation if the document was concurrently deleted (RESET_ALL,
    /// DELETE_DOCUMENT antenna verb, swipe-to-delete).
    func documentExists(_ id: UUID) throws -> Bool {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = "SELECT 1 FROM documents WHERE id = ? LIMIT 1;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, for: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func existingDocument(matchingFileName fileName: String, fileType: String, plainText: String, displayText: String? = nil, contentHash: String? = nil) throws -> Document? {
        dbLock.lock(); defer { dbLock.unlock() }
        // **Bundle 2b (2026-05-26)** — content-hash-based dedup.
        // When the caller supplied a hash, prefer it: SHA-256 of raw
        // source bytes is the only signal that survives Tier 2 / Tier
        // 3 enhancement rewriting plainText post-import. Fall back to
        // the character_count + derived-plainText path for legacy
        // docs imported before the hash column existed.
        if let hash = contentHash, !hash.isEmpty {
            let hashSQL = """
            SELECT id, title, file_name, file_type, imported_at, modified_at, character_count, playback_skip_until_offset, content_end_offset, skip_source, content_hash, edition_label
            FROM documents
            WHERE file_name = ? AND file_type = ? AND content_hash = ?
            LIMIT 1;
            """
            let hStmt = try prepareStatement(sql: hashSQL)
            defer { sqlite3_finalize(hStmt) }
            try bind(fileName, at: 1, for: hStmt)
            try bind(fileType, at: 2, for: hStmt)
            try bind(hash, at: 3, for: hStmt)
            if sqlite3_step(hStmt) == SQLITE_ROW,
               let idText = sqliteString(hStmt, index: 0),
               let id = UUID(uuidString: idText),
               let title = sqliteString(hStmt, index: 1),
               let storedFileName = sqliteString(hStmt, index: 2),
               let storedFileType = sqliteString(hStmt, index: 3) {
                let derived = (try? self.plainText(for: id)) ?? ""
                return Document(
                    id: id,
                    title: title,
                    fileName: storedFileName,
                    fileType: storedFileType,
                    importedAt: Date(timeIntervalSince1970: sqlite3_column_double(hStmt, 4)),
                    modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(hStmt, 5)),
                    displayText: derived,
                    plainText: derived,
                    characterCount: Int(sqlite3_column_int64(hStmt, 6)),
                    playbackSkipUntilOffset: Int(sqlite3_column_int64(hStmt, 7)),
                    contentEndOffset: Int(sqlite3_column_int64(hStmt, 8)),
                    skipSource: sqliteString(hStmt, index: 9) ?? "",
                    contentHash: sqliteString(hStmt, index: 10),
                    editionLabel: sqliteString(hStmt, index: 11)
                )
            }
            // Hash didn't match anything — incoming is a new doc.
            // Don't fall through to the plainText path; that would
            // match a different doc with same name + char count.
            return nil
        }

        // Legacy path — file_name + file_type + character_count
        // candidate set, confirmed by plainText comparison.
        let sql = """
        SELECT id, title, file_name, file_type, imported_at, modified_at, character_count, playback_skip_until_offset, content_end_offset, skip_source
        FROM documents
        WHERE file_name = ? AND file_type = ? AND character_count = ?;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }

        try bind(fileName, at: 1, for: statement)
        try bind(fileType, at: 2, for: statement)
        sqlite3_bind_int64(statement, 3, sqlite3_int64(plainText.count))

        // Collect all id candidates first (single-statement lifecycle).
        var candidateIDs: [(id: UUID, row: (String, String, String, Date, Date, Int, Int, Int, String))] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqliteString(statement, index: 0),
                let id = UUID(uuidString: idText),
                let title = sqliteString(statement, index: 1),
                let storedFileName = sqliteString(statement, index: 2),
                let storedFileType = sqliteString(statement, index: 3)
            else { continue }
            candidateIDs.append((
                id: id,
                row: (
                    title, storedFileName, storedFileType,
                    Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    Int(sqlite3_column_int64(statement, 6)),
                    Int(sqlite3_column_int64(statement, 7)),
                    Int(sqlite3_column_int64(statement, 8)),
                    sqliteString(statement, index: 9) ?? ""
                )
            ))
        }

        // Confirm via derived plainText. First exact match wins.
        for candidate in candidateIDs {
            let derived = (try? self.plainText(for: candidate.id)) ?? ""
            guard derived == plainText else { continue }
            let (title, sFile, sType, imported, modified, chars, skipOff, endOff, source) = candidate.row
            return Document(
                id: candidate.id,
                title: title,
                fileName: sFile,
                fileType: sType,
                importedAt: imported,
                modifiedAt: modified,
                displayText: derived,
                plainText: derived,
                characterCount: chars,
                playbackSkipUntilOffset: skipOff,
                contentEndOffset: endOff,
                skipSource: source,
                contentHash: nil,
                editionLabel: nil
            )
        }
        _ = displayText  // dedup is plainText-only post-Step-10
        return nil
    }
}

// ========== BLOCK 02: DOCUMENTS - END ==========

// ========== BLOCK 02b: DOCUMENT METADATA - START ==========

/// Stored representation of AFM-extracted document metadata. Mirrors
/// `DocumentMetadata` (the domain type) but lives in the storage
/// layer so the database extension can avoid importing the
/// AskPosey module. Conversion happens at the call boundary.
nonisolated struct StoredDocumentMetadata: Sendable, Equatable {
    let title: String?
    let authors: [String]
    let year: String?
    let documentType: String?
    let summary: String?
    let extractedAt: Date
    let detectedNonEnglish: Bool
}

extension DatabaseManager {

    /// Read the stored metadata for a document. Returns nil when no
    /// extraction has been run yet (`metadata_extracted_at = 0`).
    /// Empty strings come back as nil so callers don't have to
    /// distinguish "" from missing.
    func documentMetadata(for documentID: UUID) throws -> StoredDocumentMetadata? {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        SELECT
            metadata_title,
            metadata_authors,
            metadata_year,
            metadata_document_type,
            metadata_summary,
            metadata_extracted_at,
            metadata_detected_non_english
        FROM documents
        WHERE id = ?
        LIMIT 1;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let extractedAtRaw = sqlite3_column_double(statement, 5)
        guard extractedAtRaw > 0 else { return nil }

        let title    = sqliteString(statement, index: 0)?.nilIfEmpty
        let authorsRaw = sqliteString(statement, index: 1) ?? "[]"
        let year     = sqliteString(statement, index: 2)?.nilIfEmpty
        let docType  = sqliteString(statement, index: 3)?.nilIfEmpty
        let summary  = sqliteString(statement, index: 4)?.nilIfEmpty
        let nonEng   = sqlite3_column_int(statement, 6) != 0

        let authors: [String]
        if let data = authorsRaw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            authors = decoded
        } else {
            authors = []
        }

        return StoredDocumentMetadata(
            title: title,
            authors: authors,
            year: year,
            documentType: docType,
            summary: summary,
            extractedAt: Date(timeIntervalSince1970: extractedAtRaw),
            detectedNonEnglish: nonEng
        )
    }

    /// Persist extracted metadata for a document. Overwrites any
    /// prior extraction — use `documentMetadata(for:)` first if the
    /// caller wants to skip when already present.
    func saveDocumentMetadata(_ metadata: StoredDocumentMetadata,
                              for documentID: UUID) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        UPDATE documents
        SET metadata_title = ?,
            metadata_authors = ?,
            metadata_year = ?,
            metadata_document_type = ?,
            metadata_summary = ?,
            metadata_extracted_at = ?,
            metadata_detected_non_english = ?
        WHERE id = ?;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }

        try bindOrNull(metadata.title, at: 1, for: statement)

        let authorsJSON: String
        if let data = try? JSONEncoder().encode(metadata.authors),
           let json = String(data: data, encoding: .utf8) {
            authorsJSON = json
        } else {
            authorsJSON = "[]"
        }
        try bind(authorsJSON, at: 2, for: statement)

        try bindOrNull(metadata.year, at: 3, for: statement)
        try bindOrNull(metadata.documentType, at: 4, for: statement)
        try bindOrNull(metadata.summary, at: 5, for: statement)

        sqlite3_bind_double(statement, 6, metadata.extractedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 7, metadata.detectedNonEnglish ? 1 : 0)

        try bind(documentID.uuidString, at: 8, for: statement)
        try step(statement)
    }

    // 2026-05-23 — Step 8f: `insertSyntheticChunk` removed alongside
    // the synthetic-metadata-chunk feature. The `documents` metadata
    // columns (title / authors / year / summary / detected_non_english)
    // still exist and `documentMetadata(for:)` above still reads them
    // — but nothing writes anymore (the previous writer was
    // `DocumentMetadataService`, deleted in 8f). Existing extracted
    // rows remain readable; new imports never populate them.

    /// Helper: bind a String? as either text or NULL.
    fileprivate func bindOrNull(_ value: String?, at index: Int32,
                                for statement: OpaquePointer?) throws {
        if let value {
            try bind(value, at: index, for: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let self else { return nil }
        return self.isEmpty ? nil : self
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// ========== BLOCK 02b: DOCUMENT METADATA - END ==========

// ========== BLOCK 03: READING POSITIONS - START ==========

extension DatabaseManager {
    func readingPosition(for documentID: UUID) throws -> ReadingPosition? {
        dbLock.lock(); defer { dbLock.unlock() }
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
        dbLock.lock(); defer { dbLock.unlock() }
        // furthest_character_offset tracks the MAX-ever offset (spoiler line),
        // distinct from character_offset (current). On insert it starts at the
        // current offset; on conflict it only ever grows — max(existing, new) —
        // so scrolling BACK never lowers the spoiler line. See the schema note
        // and ASK_POSEY_V1_RELEASE_PLAN.md § 🔒 (Layer 0).
        let sql = """
        INSERT INTO reading_positions (document_id, updated_at, character_offset, sentence_index, furthest_character_offset)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(document_id) DO UPDATE SET
            updated_at = excluded.updated_at,
            character_offset = excluded.character_offset,
            sentence_index = excluded.sentence_index,
            furthest_character_offset = MAX(furthest_character_offset, excluded.character_offset);
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }

        try bind(position.documentID.uuidString, at: 1, for: statement)
        sqlite3_bind_double(statement, 2, position.updatedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, sqlite3_int64(position.characterOffset))
        sqlite3_bind_int64(statement, 4, sqlite3_int64(position.sentenceIndex))
        sqlite3_bind_int64(statement, 5, sqlite3_int64(position.characterOffset))

        try step(statement)
    }

    /// TEST/diagnostic only — FORCE the reading position (both current and
    /// furthest) to an exact offset, overriding the normal max()-only growth of
    /// furthest. The spoiler firewall's furthest offset is otherwise sticky-high
    /// (by design, so a re-reader isn't deflected), which makes the "early line"
    /// A/B probes impossible to set up without this. Driven by the antenna
    /// SET_READING_POSITION verb; never called from the reading UI.
    func forceReadingPosition(_ offset: Int, for documentID: UUID) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        INSERT INTO reading_positions (document_id, updated_at, character_offset, sentence_index, furthest_character_offset)
        VALUES (?, ?, ?, 0, ?)
        ON CONFLICT(document_id) DO UPDATE SET
            updated_at = excluded.updated_at,
            character_offset = excluded.character_offset,
            furthest_character_offset = excluded.furthest_character_offset;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, sqlite3_int64(offset))
        sqlite3_bind_int64(statement, 4, sqlite3_int64(offset))
        try step(statement)
    }

    /// The reader's furthest-ever character offset for a document — the spoiler
    /// line. Used by the spoiler firewall's prompt (Layer 1) and catcher
    /// (Layer 2). Falls back to the current offset / 0 when no row exists yet.
    func furthestReadOffset(for documentID: UUID) throws -> Int {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        SELECT MAX(furthest_character_offset, character_offset)
        FROM reading_positions WHERE document_id = ? LIMIT 1;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

// ========== BLOCK 03: READING POSITIONS - END ==========

// ========== BLOCK 03b: SPOILER PROTECTION - START ==========

extension DatabaseManager {
    /// Per-document spoiler-firewall toggle. DEFAULT ON for every document
    /// (the catcher no-ops on non-narrative content, so default-on is cheap).
    /// Read by the prompt builder (Layer 1) and the catcher (Layer 2); flipped
    /// from the chat quick toggle and Preferences → Ask Posey. § 🔒.
    func spoilerProtectionEnabled(for documentID: UUID) throws -> Bool {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = "SELECT spoiler_protection FROM documents WHERE id = ? LIMIT 1;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return true }
        return sqlite3_column_int64(statement, 0) != 0
    }

    func setSpoilerProtection(_ enabled: Bool, for documentID: UUID) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = "UPDATE documents SET spoiler_protection = ? WHERE id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, enabled ? 1 : 0)
        try bind(documentID.uuidString, at: 2, for: statement)
        try step(statement)
    }
}

// ========== BLOCK 03b: SPOILER PROTECTION - END ==========

// ========== BLOCK 04: NOTES - START ==========

extension DatabaseManager {
    func notes(for documentID: UUID) throws -> [Note] {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        SELECT id, document_id, created_at, updated_at, kind, start_offset, end_offset, body,
               anchor_text, context_before, context_after
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
                body: sqliteString(statement, index: 7),
                anchorText: sqliteString(statement, index: 8),
                contextBefore: sqliteString(statement, index: 9),
                contextAfter: sqliteString(statement, index: 10)
            ))
        }
        return notes
    }

    func insertNote(_ note: Note) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        INSERT INTO notes (id, document_id, created_at, updated_at, kind, start_offset, end_offset, body,
                           anchor_text, context_before, context_after)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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

        if let body = note.body { try bind(body, at: 8, for: statement) }
        else { sqlite3_bind_null(statement, 8) }
        if let t = note.anchorText { try bind(t, at: 9, for: statement) } else { sqlite3_bind_null(statement, 9) }
        if let c = note.contextBefore { try bind(c, at: 10, for: statement) } else { sqlite3_bind_null(statement, 10) }
        if let c = note.contextAfter { try bind(c, at: 11, for: statement) } else { sqlite3_bind_null(statement, 11) }

        try step(statement)
    }

    /// Update a note's body (and bump `updated_at`). Used by the inline-annotation
    /// editor: a note is created on selection, its body edited afterward.
    func updateNote(id: UUID, body: String?, updatedAt: Date = Date()) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = "UPDATE notes SET body = ?, updated_at = ? WHERE id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        if let body { try bind(body, at: 1, for: statement) } else { sqlite3_bind_null(statement, 1) }
        sqlite3_bind_double(statement, 2, updatedAt.timeIntervalSince1970)
        try bind(id.uuidString, at: 3, for: statement)
        try step(statement)
    }

    /// Re-anchor a note: overwrite its offsets + durable anchor (substring + context).
    /// Used when the reader re-confirms an unsure note's location, or when the
    /// enhancement pipeline precisely re-anchors a note whose text it just rewrote.
    func updateNoteAnchor(id: UUID, startOffset: Int, endOffset: Int,
                          anchorText: String?, contextBefore: String?, contextAfter: String?,
                          updatedAt: Date = Date()) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        UPDATE notes SET start_offset = ?, end_offset = ?, anchor_text = ?,
                         context_before = ?, context_after = ?, updated_at = ? WHERE id = ?;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sqlite3_int64(startOffset))
        sqlite3_bind_int64(statement, 2, sqlite3_int64(endOffset))
        if let t = anchorText { try bind(t, at: 3, for: statement) } else { sqlite3_bind_null(statement, 3) }
        if let c = contextBefore { try bind(c, at: 4, for: statement) } else { sqlite3_bind_null(statement, 4) }
        if let c = contextAfter { try bind(c, at: 5, for: statement) } else { sqlite3_bind_null(statement, 5) }
        sqlite3_bind_double(statement, 6, updatedAt.timeIntervalSince1970)
        try bind(id.uuidString, at: 7, for: statement)
        try step(statement)
    }

    /// Delete a note/bookmark by id.
    func deleteNote(id: UUID) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = "DELETE FROM notes WHERE id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, for: statement)
        try step(statement)
    }

    /// TEST SUPPORT (E2 R8): overwrite a unit's text + bump its revision, simulating
    /// the enhancement pipeline mutating text after an annotation was anchored. Reached
    /// only via the DEBUG-only antenna verb `SIMULATE_ANCHOR_DRIFT`; not used in normal
    /// flows. Lets the annotation re-find / flag path be exercised on a real device.
    func debugSetUnitText(unitID: UUID, text: String) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = "UPDATE document_units SET text = ?, revision = revision + 1 WHERE id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(text, at: 1, for: statement)
        try bind(unitID.uuidString, at: 2, for: statement)
        try step(statement)
    }
}

// ========== BLOCK 04: NOTES - END ==========

// ========== BLOCK 05: DOCUMENT IMAGES - START ==========

extension DatabaseManager {
    /// Insert one image record. The image ID is embedded in the document's
    /// displayText visual-page markers and used to load the image at read time.
    func insertImage(id: String, documentID: UUID, data: Data) throws {
        dbLock.lock(); defer { dbLock.unlock() }
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
        dbLock.lock(); defer { dbLock.unlock() }
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
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = "DELETE FROM document_images WHERE document_id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        try step(statement)
    }

    /// Returns all image IDs stored for a document, in insertion order.
    func imageIDs(for documentID: UUID) throws -> [String] {
        dbLock.lock(); defer { dbLock.unlock() }
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
    /// Heading level (1 = top, 6 = deepest). Used by the reader to
    /// pick the right typographic weight for the heading row. Importers
    /// that lack a real signal pass 1.
    let level: Int

    init(title: String, plainTextOffset: Int, playOrder: Int, level: Int = 1) {
        self.title = title
        self.plainTextOffset = plainTextOffset
        self.playOrder = playOrder
        self.level = max(1, min(6, level))
    }

    /// Task 8 (2026-05-03): composite identifier for SwiftUI `ForEach`
    /// when `playOrder` alone isn't unique (some synthesized EPUBs
    /// produce two entries with `playOrder = 0`, which crashed the
    /// TOC sheet). Combines all three fields so duplicates can't
    /// collide.
    var compositeID: String { "\(playOrder)|\(plainTextOffset)|\(title)" }
}

extension DatabaseManager {
    func insertTOCEntries(_ entries: [StoredTOCEntry], for documentID: UUID) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        try execute("DELETE FROM document_toc WHERE document_id = '\(documentID.uuidString)';")
        let sql = """
        INSERT INTO document_toc (document_id, play_order, title, plain_text_offset, level)
        VALUES (?, ?, ?, ?, ?);
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
            sqlite3_bind_int(statement, 5, Int32(entry.level))
            try step(statement)
        }
    }

    func tocEntries(for documentID: UUID) throws -> [StoredTOCEntry] {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        SELECT title, plain_text_offset, play_order, level
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
            let level  = Int(sqlite3_column_int(statement, 3))
            entries.append(StoredTOCEntry(
                title: title,
                plainTextOffset: offset,
                playOrder: order,
                level: level == 0 ? 1 : level
            ))
        }
        return entries
    }

    /// The document's `playback_skip_until_offset`. This is the reliable
    /// "Tier-1 found a skip region" signal — unlike `skip_unit_id`, which the
    /// importer sets to the first unit even when the offset is 0 (because
    /// `ContentUnitBuilder.firstUnit(atOrAfterPlainTextOffset: 0)` returns
    /// `units.first`). Used by the Bug F re-detect gate.
    func playbackSkipOffset(for documentID: UUID) throws -> Int {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = "SELECT playback_skip_until_offset FROM documents WHERE id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }
}

// ========== BLOCK 05B: DOCUMENT TOC - END ==========

// ========== BLOCK 05C: DOCUMENT CHUNKS — REMOVED IN STEP 8F ==========

// ========== BLOCK 05D: ASK POSEY CONVERSATIONS (M5) - START ==========

/// One row of `ask_posey_conversations`: a single message in a
/// per-document conversation thread. Conversations are persistent —
/// closing the Ask Posey sheet does not discard them; opening it again
/// for the same document continues the thread.
///
/// `nonisolated` because callers include both the MainActor-isolated
/// view model and (via the prompt builder) test code that runs off the
/// main actor. The type holds only `Sendable` value-typed properties.
nonisolated struct StoredAskPoseyTurn: Equatable, Sendable, Identifiable {
    /// The unique row identifier. Stable across the lifetime of the
    /// row — used as the SwiftUI `Identifiable` key when surfacing
    /// historical turns in the sheet.
    let id: String
    let documentID: UUID
    let timestamp: Date
    /// `"user"` or `"assistant"`. Modeled as a string rather than an
    /// enum because the SQL column is `TEXT`; the view model translates
    /// to/from `AskPoseyMessage.Role` at the boundary.
    let role: String
    let content: String
    /// `"passage"` (M5), `"document"` (M6), or `"annotation"` (later).
    /// Recorded per turn so retrievers in M6+ can prefer matching
    /// invocation kinds when budget is tight.
    let invocation: String
    /// Character offset of the anchor passage at the moment the turn
    /// was created. `nil` when the invocation didn't capture an anchor
    /// (M6 document-scope) or the row is a summary.
    let anchorOffset: Int?
    /// `AskPoseyIntent` raw value when this turn is a user message.
    /// `nil` for assistant turns and pre-M5 legacy rows.
    let intent: String?
    /// JSON-encoded array of chunk references actually injected into
    /// the prompt that produced this assistant turn. Empty in M5
    /// (`"[]"`); M6 fills it; M7 surfaces it as a "Sources" strip.
    let chunksInjectedJSON: String
    /// Verbatim prompt body the model saw on this turn. Optional
    /// because user turns and pre-M5 rows don't carry one. Used by
    /// the local-API tuning loop to inspect what was actually injected.
    let fullPromptForLogging: String?
    /// Watermark — when `is_summary == 1`, this row is a summary that
    /// covers turns up to and including this user-turn count. Lets the
    /// prompt builder pick the right summary without rebuilding it
    /// when conversation lengths cross the STM boundary.
    let summaryOfTurnsThrough: Int
    /// `true` when this row is a generated summary rather than a real
    /// user/assistant message. Summary rows are surfaced to the prompt
    /// builder's `conversationSummary` slot, never to the verbatim
    /// `conversationHistory` slot.
    let isSummary: Bool
}

/// A passage an Ask Posey conversation CITED (a retrieved chunk injected into one of its
/// assistant turns). An anchor (a passage the USER asked about) and a citation (a passage
/// the MODEL pulled in to answer) are the same kind of thing — a pointer from a document
/// spot to the doc's one conversation (Mark, 2026-06-26). `turnStorageID` is the id of the
/// ANSWER turn that cited the passage, so tapping the glyph lands the reader on the
/// contextually relevant turn — the answer where the passage was actually used.
struct AskPoseyCitedPassage {
    let offset: Int
    let turnStorageID: String
    /// A short fingerprint of the cited passage's text, so the reader's one placement
    /// system (`AnchorRefinder`) can re-find the glyph's spot by its WORDS after an
    /// OCR/AFM rewrite — not just trust `offset`. `offset` is already the durable
    /// unit-anchor resolution (a strong starting hint + fallback); the fingerprint adds
    /// content verification on top, so a cited glyph is at least as durable as the
    /// anchor it points to.
    let anchorText: String
}

extension DatabaseManager {
    /// Append a single turn to the persistent conversation log for
    /// `documentID`. Called both for user turns (immediately on send)
    /// and assistant turns (after streaming completes). Writing each
    /// side individually rather than as a paired transaction keeps the
    /// model honest about partial responses — if AFM crashes mid-
    /// stream, the user turn is still on disk and can be retried.
    func appendAskPoseyTurn(_ turn: StoredAskPoseyTurn) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        INSERT INTO ask_posey_conversations (
            id, document_id, timestamp, role, content, invocation,
            anchor_offset, summary_of_turns_through, is_summary,
            intent, chunks_injected, full_prompt_for_logging
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(turn.id, at: 1, for: statement)
        try bind(turn.documentID.uuidString, at: 2, for: statement)
        sqlite3_bind_double(statement, 3, turn.timestamp.timeIntervalSince1970)
        try bind(turn.role, at: 4, for: statement)
        try bind(turn.content, at: 5, for: statement)
        try bind(turn.invocation, at: 6, for: statement)
        if let offset = turn.anchorOffset {
            sqlite3_bind_int(statement, 7, Int32(offset))
        } else {
            sqlite3_bind_null(statement, 7)
        }
        sqlite3_bind_int(statement, 8, Int32(turn.summaryOfTurnsThrough))
        sqlite3_bind_int(statement, 9, turn.isSummary ? 1 : 0)
        if let intent = turn.intent {
            try bind(intent, at: 10, for: statement)
        } else {
            sqlite3_bind_null(statement, 10)
        }
        try bind(turn.chunksInjectedJSON, at: 11, for: statement)
        if let prompt = turn.fullPromptForLogging {
            try bind(prompt, at: 12, for: statement)
        } else {
            sqlite3_bind_null(statement, 12)
        }
        try step(statement)
    }

    /// Store a turn's semantic embedding (conversation-memory fix — see
    /// `AskPoseyTurnEmbedder`). `id` is the turn's row id; `kind` records which
    /// backend produced the vector so a later embedder swap can tell stale rows
    /// apart. The `embedding`/`embedding_kind` columns already exist on
    /// `ask_posey_conversations` (added in the schema for exactly this).
    func updateAskPoseyTurnEmbedding(id: String, embedding: [Double], kind: String) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = "UPDATE ask_posey_conversations SET embedding = ?, embedding_kind = ? WHERE id = ?;"
        let stmt = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(stmt) }
        let blob = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
        _ = blob.withUnsafeBytes {
            sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(blob.count), SQLITE_TRANSIENT)
        }
        try bind(kind, at: 2, for: stmt)
        try bind(id, at: 3, for: stmt)
        try step(stmt)
    }

    /// Diagnostic: per-document turn-embedding coverage (total user/assistant
    /// turns vs. how many carry an embedding for `backend`). Powers
    /// `ASK_POSEY_TURN_STATS` so embed-at-save is verifiable end-to-end.
    func askPoseyTurnEmbeddingStats(documentID: UUID, backend: EmbeddingBackend) throws -> (totalTurns: Int, embedded: Int) {
        dbLock.lock(); defer { dbLock.unlock() }
        let totalSQL = """
            SELECT COUNT(*) FROM ask_posey_conversations
            WHERE document_id = ? AND is_summary = 0 AND role IN ('user','assistant');
            """
        let embeddedSQL = """
            SELECT COUNT(*) FROM ask_posey_conversations
            WHERE document_id = ? AND is_summary = 0 AND role IN ('user','assistant')
              AND embedding IS NOT NULL AND embedding_kind = ?;
            """
        var total = 0, embedded = 0
        let t = try prepareStatement(sql: totalSQL)
        defer { sqlite3_finalize(t) }
        sqlite3_bind_text(t, 1, documentID.uuidString, -1, SQLITE_TRANSIENT)
        if sqlite3_step(t) == SQLITE_ROW { total = Int(sqlite3_column_int(t, 0)) }
        let e = try prepareStatement(sql: embeddedSQL)
        defer { sqlite3_finalize(e) }
        sqlite3_bind_text(e, 1, documentID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(e, 2, backend.rawValue, -1, SQLITE_TRANSIENT)
        if sqlite3_step(e) == SQLITE_ROW { embedded = Int(sqlite3_column_int(e, 0)) }
        return (total, embedded)
    }

    /// One semantically/lexically recalled past turn (conversation-memory
    /// fix, Part B). Carries enough to render + attribute it in the prompt.
    struct RecalledTurn: Sendable, Equatable {
        let id: String
        let role: String          // "user" | "assistant"
        let content: String
        let timestamp: Date
        let rrfScore: Double
    }

    /// Hybrid conversation-turn recall for `documentID`: cosine over stored
    /// turn embeddings + BM25 over `ask_posey_conversations_fts`, fused by RRF
    /// (k=60, same as Hal). Returns the top `limit` OLDER turns relevant to the
    /// query, EXCLUDING the verbatim-STM turns in `excludeTurnIDs` (Hal's real
    /// dedup is turn-ID exclusion, not the dead cosine constant — HISTORY
    /// 2026-06-20). Separate from doc-RAG by design (Posey is document-primary).
    ///
    /// `queryVector` empty (model not loaded) → semantic skipped, BM25 carries
    /// (Hal's graceful degradation). Only turns embedded under `backend` are
    /// semantic-eligible (same-space comparison); all turns are BM25-eligible.
    /// Returned newest-last (chronological) so the prompt reads in order.
    func retrieveConversationTurns(
        documentID: UUID,
        queryVector: [Double],
        queryText: String,
        excludeMostRecent: Int,
        backend: EmbeddingBackend,
        limit: Int = 4
    ) throws -> [RecalledTurn] {
        dbLock.lock(); defer { dbLock.unlock() }

        // The verbatim STM window = the most-recent K user/assistant turns;
        // those are already in the prompt verbatim, so exclude them by ID (Hal's
        // real dedup is turn exclusion, by recency here since our in-memory
        // messages don't carry the stored row id). K = the caller's verbatim depth.
        var excludeTurnIDs = Set<String>()
        if excludeMostRecent > 0 {
            let exSQL = """
                SELECT id FROM ask_posey_conversations
                WHERE document_id = ? AND is_summary = 0 AND role IN ('user','assistant')
                ORDER BY timestamp DESC LIMIT ?;
                """
            let exStmt = try prepareStatement(sql: exSQL)
            defer { sqlite3_finalize(exStmt) }
            sqlite3_bind_text(exStmt, 1, documentID.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(exStmt, 2, Int32(excludeMostRecent))
            while sqlite3_step(exStmt) == SQLITE_ROW {
                if let idC = sqlite3_column_text(exStmt, 0) { excludeTurnIDs.insert(String(cString: idC)) }
            }
        }

        struct Cand { let id: String; let role: String; let content: String; let ts: Date }
        var cands: [String: Cand] = [:]
        var semanticRank: [String: Int] = [:]
        var bm25Rank: [String: Int] = [:]

        // --- Semantic pass: cosine over eligible turn embeddings ---
        if !queryVector.isEmpty {
            let sql = """
                SELECT id, role, content, timestamp, embedding FROM ask_posey_conversations
                WHERE document_id = ? AND is_summary = 0 AND role IN ('user','assistant')
                  AND embedding IS NOT NULL AND embedding_kind = ?;
                """
            let stmt = try prepareStatement(sql: sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, documentID.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, backend.rawValue, -1, SQLITE_TRANSIENT)
            var scored: [(String, Double)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idC = sqlite3_column_text(stmt, 0) else { continue }
                let id = String(cString: idC)
                if excludeTurnIDs.contains(id) { continue }   // dedup vs verbatim STM
                let role = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let content = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                guard sqlite3_column_type(stmt, 4) != SQLITE_NULL,
                      let blob = sqlite3_column_blob(stmt, 4) else { continue }
                let n = Int(sqlite3_column_bytes(stmt, 4)) / MemoryLayout<Double>.size
                let vec = Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Double.self), count: n))
                cands[id] = Cand(id: id, role: role, content: content, ts: ts)
                scored.append((id, EmbeddingProvider.cosine(queryVector, vec)))
            }
            for (i, pair) in scored.sorted(by: { $0.1 > $1.1 }).enumerated() {
                semanticRank[pair.0] = i + 1
            }
        }

        // --- BM25 pass: FTS5 over the turns mirror ---
        let terms = queryText
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"" }
        if !terms.isEmpty {
            let match = terms.joined(separator: " ")
            let sql = """
                SELECT c.id, c.role, c.content, c.timestamp, bm25(ask_posey_conversations_fts) AS score
                FROM ask_posey_conversations_fts
                JOIN ask_posey_conversations c ON c.rowid = ask_posey_conversations_fts.rowid
                WHERE ask_posey_conversations_fts MATCH ?
                  AND c.document_id = ? AND c.is_summary = 0 AND c.role IN ('user','assistant')
                ORDER BY score LIMIT 25;
                """
            if let stmt = try? prepareStatement(sql: sql) {
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, documentID.uuidString, -1, SQLITE_TRANSIENT)
                var rank = 0
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let idC = sqlite3_column_text(stmt, 0) else { continue }
                    let id = String(cString: idC)
                    if excludeTurnIDs.contains(id) { continue }
                    if cands[id] == nil {
                        let role = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                        let content = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                        let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                        cands[id] = Cand(id: id, role: role, content: content, ts: ts)
                    }
                    rank += 1
                    bm25Rank[id] = rank
                }
            }
        }

        // --- RRF fusion (k=60), then top-N, then chronological order ---
        let k = 60.0
        let fused: [RecalledTurn] = cands.values.map { c in
            var rrf = 0.0
            if let r = semanticRank[c.id] { rrf += 1.0 / (k + Double(r)) }
            if let r = bm25Rank[c.id]    { rrf += 1.0 / (k + Double(r)) }
            return RecalledTurn(id: c.id, role: c.role, content: c.content, timestamp: c.ts, rrfScore: rrf)
        }
        let top = fused.sorted { $0.rrfScore > $1.rrfScore }.prefix(limit)
        return top.sorted { $0.timestamp < $1.timestamp }   // chronological for the prompt
    }

    /// Return non-summary conversation turns for a document, oldest-first.
    /// `limit == nil` returns every turn; positive `limit` caps to the
    /// most recent N rows (still returned oldest-first so the prompt
    /// builder can append them in chronological order).
    ///
    /// Summary rows are intentionally excluded — they live in the
    /// `conversationSummary` slot of the prompt, not the verbatim STM
    /// slot. Use `askPoseyLatestSummary(for:)` for those.
    func askPoseyTurns(for documentID: UUID, limit: Int? = nil) throws -> [StoredAskPoseyTurn] {
        dbLock.lock(); defer { dbLock.unlock() }
        let baseSQL = """
        SELECT id, document_id, timestamp, role, content, invocation,
               anchor_offset, summary_of_turns_through, is_summary,
               intent, chunks_injected, full_prompt_for_logging
        FROM ask_posey_conversations
        WHERE document_id = ? AND is_summary = 0
        """
        let sql: String
        if let limit, limit > 0 {
            // Inner query takes the most recent N by timestamp DESC,
            // outer query reverses to ASC for the prompt builder.
            sql = """
            SELECT * FROM (
                \(baseSQL)
                ORDER BY timestamp DESC
                LIMIT \(limit)
            ) ORDER BY timestamp ASC;
            """
        } else {
            sql = "\(baseSQL) ORDER BY timestamp ASC;"
        }

        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)

        var turns: [StoredAskPoseyTurn] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let turn = decodeAskPoseyTurn(statement: statement) else { continue }
            turns.append(turn)
        }
        return turns
    }

    /// Most recent summary row covering older turns for `documentID`,
    /// or `nil` if no summary exists yet. M6 writes these; M5 always
    /// returns nil.
    func askPoseyLatestSummary(for documentID: UUID) throws -> StoredAskPoseyTurn? {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        SELECT id, document_id, timestamp, role, content, invocation,
               anchor_offset, summary_of_turns_through, is_summary,
               intent, chunks_injected, full_prompt_for_logging
        FROM ask_posey_conversations
        WHERE document_id = ? AND is_summary = 1
        ORDER BY summary_of_turns_through DESC
        LIMIT 1;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        if sqlite3_step(statement) == SQLITE_ROW {
            return decodeAskPoseyTurn(statement: statement)
        }
        return nil
    }

    /// Count of non-summary turns for a document. Used by the view
    /// model's "should we fetch history at all" early exit so a
    /// fresh-document open doesn't hit SELECT before any turns exist.
    func askPoseyTurnCount(for documentID: UUID) throws -> Int {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        SELECT COUNT(*) FROM ask_posey_conversations
        WHERE document_id = ? AND is_summary = 0;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// Wipe every row (real turns + summary rows) from
    /// `ask_posey_conversations` for `documentID`. Used by the
    /// `CLEAR_ASK_POSEY_CONVERSATION` API command (Three Hats QA
    /// pass) so a test harness can run fresh-context Q&A without
    /// previous wrong answers biasing the model. Returns the row
    /// count that was deleted.
    func clearAskPoseyConversation(for documentID: UUID) throws -> Int {
        dbLock.lock(); defer { dbLock.unlock() }
        // First, count what's there so we can return a useful response.
        var count = 0
        let countSQL = "SELECT COUNT(*) FROM ask_posey_conversations WHERE document_id = ?;"
        let countStmt = try prepareStatement(sql: countSQL)
        try bind(documentID.uuidString, at: 1, for: countStmt)
        if sqlite3_step(countStmt) == SQLITE_ROW {
            count = Int(sqlite3_column_int(countStmt, 0))
        }
        sqlite3_finalize(countStmt)

        let deleteSQL = "DELETE FROM ask_posey_conversations WHERE document_id = ?;"
        let stmt = try prepareStatement(sql: deleteSQL)
        defer { sqlite3_finalize(stmt) }
        try bind(documentID.uuidString, at: 1, for: stmt)
        try step(stmt)
        return count
    }

    /// Return only the user/assistant rows for `documentID`, oldest-first.
    /// Anchor marker rows (`role = 'anchor'`) and summary rows are
    /// filtered out. Used by the prompt builder so anchor markers
    /// don't pollute the verbatim STM budget — the anchor passage
    /// already lives in its own ANCHOR PASSAGE prompt section.
    func askPoseyConversationTurns(for documentID: UUID, limit: Int? = nil) throws -> [StoredAskPoseyTurn] {
        dbLock.lock(); defer { dbLock.unlock() }
        let baseSQL = """
        SELECT id, document_id, timestamp, role, content, invocation,
               anchor_offset, summary_of_turns_through, is_summary,
               intent, chunks_injected, full_prompt_for_logging
        FROM ask_posey_conversations
        WHERE document_id = ? AND is_summary = 0
              AND role IN ('user', 'assistant')
        """
        let sql: String
        if let limit, limit > 0 {
            sql = """
            SELECT * FROM (
                \(baseSQL)
                ORDER BY timestamp DESC
                LIMIT \(limit)
            ) ORDER BY timestamp ASC;
            """
        } else {
            sql = "\(baseSQL) ORDER BY timestamp ASC;"
        }

        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)

        var turns: [StoredAskPoseyTurn] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let turn = decodeAskPoseyTurn(statement: statement) else { continue }
            turns.append(turn)
        }
        return turns
    }

    /// Return only anchor marker rows for `documentID`, newest-first.
    /// Powers the unified Saved Annotations list in the Notes sheet —
    /// each anchor row becomes a "conversation" entry, tappable to
    /// re-open Ask Posey scrolled to that point in the thread.
    func askPoseyAnchorRows(for documentID: UUID) throws -> [StoredAskPoseyTurn] {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        SELECT id, document_id, timestamp, role, content, invocation,
               anchor_offset, summary_of_turns_through, is_summary,
               intent, chunks_injected, full_prompt_for_logging
        FROM ask_posey_conversations
        WHERE document_id = ? AND is_summary = 0 AND role = 'anchor'
        ORDER BY timestamp DESC;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)

        var rows: [StoredAskPoseyTurn] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let row = decodeAskPoseyTurn(statement: statement) else { continue }
            rows.append(row)
        }
        return rows
    }

    /// Every passage CITED by an Ask Posey conversation for `documentID`, each tagged with
    /// the ANSWER turn that cited it. For each assistant turn, decodes the injected chunks
    /// and emits one entry per cited chunk offset, owned by that turn's storage id — so the
    /// reader glyph reopens the conversation at the answer where the passage was used.
    /// Powers the conversation glyphs alongside anchors — see `AskPoseyCitedPassage`.
    func askPoseyCitedPassages(for documentID: UUID) throws -> [AskPoseyCitedPassage] {
        // Resolve each cited chunk's DURABLE unit-anchor (startUnitID + intra offset)
        // to a CURRENT plainText offset, so a glyph lands on the right passage even
        // after Tier-2/3 reprocessing shifted global offsets. Build the unit → start-
        // offset map the same way `plain_text` is joined (prose units, "\n\n"-joined).
        // `units(for:)` takes the lock itself, so do it BEFORE acquiring the lock here.
        let prose = (try units(for: documentID))
            .filter { $0.kind.carriesProseText }
            .sorted { $0.sequence < $1.sequence }
        var unitStart: [UUID: Int] = [:]
        var unitLen: [UUID: Int] = [:]
        var unitText: [UUID: String] = [:]
        var cursor = 0
        for (idx, u) in prose.enumerated() {
            unitStart[u.id] = cursor
            unitLen[u.id] = u.text.count
            unitText[u.id] = u.text
            cursor += u.text.count + (idx < prose.count - 1 ? 2 : 0)
        }

        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        SELECT id, document_id, timestamp, role, content, invocation,
               anchor_offset, summary_of_turns_through, is_summary,
               intent, chunks_injected, full_prompt_for_logging
        FROM ask_posey_conversations
        WHERE document_id = ? AND is_summary = 0 AND role = 'assistant'
        ORDER BY timestamp ASC;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)

        var passages: [AskPoseyCitedPassage] = []
        var seen = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let row = decodeAskPoseyTurn(statement: statement),
                  let data = row.chunksInjectedJSON.data(using: .utf8),
                  let chunks = try? JSONDecoder().decode([RetrievedChunk].self, from: data),
                  !chunks.isEmpty else { continue }
            // SAME selection as the conversation SOURCES strip
            // (`RetrievedChunk.topSources`): the top 3 most-relevant passages
            // above the floor. This is what makes the round-trip whole — a margin
            // bubble appears for exactly the passages the conversation shows as
            // numbered sources, no more (Mark, 2026-06-26). Previously this emitted
            // a bubble for EVERY injected chunk, so the book had bubbles the
            // conversation had no chip for.
            for chunk in RetrievedChunk.topSources(from: chunks) {
                // Only chunks that carry a durable unit-anchor can be placed. Rows
                // persisted before this field (and anchor-less results) are skipped —
                // their location was not recorded, so we honestly show no glyph rather
                // than guess. New conversations record it going forward.
                guard let uid = chunk.startUnitID, let base = unitStart[uid] else { continue }
                let intra = max(0, min(chunk.startIntraOffset ?? 0, unitLen[uid] ?? 0))
                let offset = base + intra
                // One glyph per (turn, passage): a turn can cite the same spot via
                // overlapping chunks.
                guard seen.insert("\(row.id)#\(offset)").inserted else { continue }
                // Fingerprint the document text AT the anchor offset — NOT chunk.text.
                // `chunk.text` is the neighbor-EXPANDED (stitched) passage, which can
                // begin hundreds of chars before the stored anchor; fingerprinting it
                // would relocate the glyph to the stitched start (and away from the
                // chip, which jumps to the anchor). The unit text from `intra` is exactly
                // what sits at `offset`, so the glyph stays put at baseline and re-finds
                // by content after a rewrite. (Caught by RESOLVE_GLYPHS, 2026-06-26.)
                let atAnchor = String((unitText[uid] ?? "").dropFirst(intra))
                passages.append(AskPoseyCitedPassage(offset: offset, turnStorageID: row.id,
                                                     anchorText: AnchorRefinder.fingerprint(atAnchor)))
            }
        }
        return passages
    }

    /// Current plainText offset of a unit-anchored position (unit + intra offset).
    /// Inverse of `unitID(plainTextOffset:)`; computed against the document's CURRENT
    /// units so it reflects any Tier-2/3 reprocessing. nil if `unitID` isn't a
    /// prose-bearing unit in the doc. Resolves a cited passage / glyph to a live
    /// reader offset at display time.
    func plainTextOffset(forUnitID unitID: UUID, intraOffset: Int, in documentID: UUID) throws -> Int? {
        let prose = (try units(for: documentID))
            .filter { $0.kind.carriesProseText }
            .sorted { $0.sequence < $1.sequence }
        var cursor = 0
        for (idx, u) in prose.enumerated() {
            if u.id == unitID {
                return cursor + max(0, min(intraOffset, u.text.count))
            }
            cursor += u.text.count + (idx < prose.count - 1 ? 2 : 0)
        }
        return nil
    }

    /// Decode the columns selected by `askPoseyTurns` / `askPoseyLatestSummary`
    /// into the value type. The two queries share the same SELECT list
    /// so they can share this decoder.
    private func decodeAskPoseyTurn(statement: OpaquePointer?) -> StoredAskPoseyTurn? {
        guard
            let id = sqliteString(statement, index: 0),
            let docIDString = sqliteString(statement, index: 1),
            let docID = UUID(uuidString: docIDString),
            let role = sqliteString(statement, index: 3),
            let content = sqliteString(statement, index: 4),
            let invocation = sqliteString(statement, index: 5)
        else { return nil }
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        let anchorOffset: Int? = sqlite3_column_type(statement, 6) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int(statement, 6))
        let summaryThrough = Int(sqlite3_column_int(statement, 7))
        let isSummary = sqlite3_column_int(statement, 8) != 0
        let intent = sqliteString(statement, index: 9)
        let chunksInjected = sqliteString(statement, index: 10) ?? "[]"
        let fullPrompt = sqliteString(statement, index: 11)
        return StoredAskPoseyTurn(
            id: id,
            documentID: docID,
            timestamp: timestamp,
            role: role,
            content: content,
            invocation: invocation,
            anchorOffset: anchorOffset,
            intent: intent,
            chunksInjectedJSON: chunksInjected,
            fullPromptForLogging: fullPrompt,
            summaryOfTurnsThrough: summaryThrough,
            isSummary: isSummary
        )
    }
}

// ========== BLOCK 05D: ASK POSEY CONVERSATIONS (M5) - END ==========

// ========== BLOCK 06: SCHEMA AND HELPERS - START ==========

extension DatabaseManager {
    private func open() throws {
        // Serialized threading mode (SQLITE_OPEN_FULLMUTEX): SQLite's own
        // per-connection mutex permits this single connection to be used
        // from different threads. Belt-and-suspenders with `dbLock` (which
        // guarantees no *overlapping* access and keeps transactions
        // atomic); together they fix the "illegal multi-threaded access"
        // trap the Mac surfaced 2026-05-29.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(databaseURL.path, &database, flags, nil) != SQLITE_OK {
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
                character_count INTEGER NOT NULL
            );
            """)

        // **Step 10 — drop the derived plain_text / display_text
        // columns.** Both are computed from `document_units` on demand
        // via `plainText(for:)` / `displayText(for:)`. The legacy
        // columns lingered for backward compat during the rebuild;
        // with chunks-on-units (Step 8) + unified renderer (Step 9)
        // shipped, nothing reads the columns anymore. SQLite 3.35+
        // supports DROP COLUMN (every iOS 16+ device ships ≥ 3.39).
        // Safe no-op on fresh DBs where the columns never existed.
        try dropColumnIfPresent(table: "documents", column: "plain_text")
        try dropColumnIfPresent(table: "documents", column: "display_text")
        // 2026-05-27 — drop legacy `content_boundaries` column. Was
        // populated at import time and read by PDFEnhancementService
        // for page-range arithmetic. Now derived on-the-fly from
        // pageBreak units by `contentBoundaries(for:)`. Safe no-op
        // on fresh installs.
        try dropColumnIfPresent(table: "documents", column: "content_boundaries")
        // **Bundle 2b (2026-05-26)** — content-hash dedup. SHA-256 of
        // the raw source-file bytes, hex-encoded. Nullable so existing
        // rows imported before this migration don't get nuked; new
        // imports always populate it. existingDocument prefers a hash
        // match when both candidate and incoming have non-empty hashes;
        // falls back to plainText comparison otherwise.
        try addColumnIfNeeded(table: "documents", column: "content_hash",
                              definition: "TEXT")
        // **Bundle 2 follow-up (2026-05-26)** — edition label
        // (e.g. "Illustrated by Robinson") surfaced on the library
        // card when two cards share a title. Nullable for back-
        // compat; only EPUB writes it today.
        try addColumnIfNeeded(table: "documents", column: "edition_label",
                              definition: "TEXT")
        // (`content_boundaries` is dropped above; PDFEnhancementService
        // now reads through the derived `contentBoundaries(for:)`
        // function which walks pageBreak units. 2026-05-27.)
        // playback_skip_until_offset = character offset in plainText past which
        // the reader should auto-jump on first open. Used by the PDF TOC
        // detector, the EPUB front-matter detector, and (2026-05-21) the
        // Gutenberg boundary detector. 0 = no skip.
        try addColumnIfNeeded(table: "documents", column: "playback_skip_until_offset", definition: "INTEGER NOT NULL DEFAULT 0")
        // content_end_offset = character offset in plainText at which the
        // reader should treat the document as ended (e.g. before the
        // Gutenberg license trailer). 0 = no end boundary recorded;
        // playback runs to the end of plainText. Added 2026-05-21 with
        // the front-matter/content-boundary work.
        try addColumnIfNeeded(table: "documents", column: "content_end_offset", definition: "INTEGER NOT NULL DEFAULT 0")
        // skip_source = classification of how playback_skip_until_offset
        // was determined. "" / "gutenberg" / "heuristic" / "user_keep" /
        // "user_dismiss". Drives the smart-skip prompt: silent for
        // Gutenberg, one-time prompt for heuristic. See Document.skipSource
        // for the full enum. Added 2026-05-21.
        try addColumnIfNeeded(table: "documents", column: "skip_source", definition: "TEXT NOT NULL DEFAULT ''")

        // 2026-05-05 — Document metadata (title/authors/year/type/summary)
        // extracted via AFM @Generable call at index time. Stored as
        // structured columns (not JSON blob) so future library-wide
        // queries — "show me all law review articles by this author" —
        // can run as plain SQL. Authors is JSON because it's an array;
        // everything else is a single value.
        // metadata_extracted_at = unix timestamp; 0 means not yet extracted.
        try addColumnIfNeeded(table: "documents", column: "metadata_title", definition: "TEXT")
        try addColumnIfNeeded(table: "documents", column: "metadata_authors", definition: "TEXT NOT NULL DEFAULT '[]'")
        try addColumnIfNeeded(table: "documents", column: "metadata_year", definition: "TEXT")
        try addColumnIfNeeded(table: "documents", column: "metadata_document_type", definition: "TEXT")
        try addColumnIfNeeded(table: "documents", column: "metadata_summary", definition: "TEXT")
        try addColumnIfNeeded(table: "documents", column: "metadata_extracted_at", definition: "REAL NOT NULL DEFAULT 0")
        try addColumnIfNeeded(table: "documents", column: "metadata_detected_non_english", definition: "INTEGER NOT NULL DEFAULT 0")

        // 2026-06-17 — Spoiler firewall (Layer 0). Per-document toggle, DEFAULT
        // ON for every document (Mark: err on caution; the catcher no-ops on
        // non-narrative content anyway, so default-on is cheap for RFPs/docs).
        // User-disableable from two places: the Ask Posey chat quick toggle and
        // Preferences → Ask Posey. See ASK_POSEY_V1_RELEASE_PLAN.md § 🔒.
        try addColumnIfNeeded(table: "documents", column: "spoiler_protection", definition: "INTEGER NOT NULL DEFAULT 1")

        try execute("""
            CREATE TABLE IF NOT EXISTS reading_positions (
                document_id TEXT PRIMARY KEY NOT NULL,
                updated_at REAL NOT NULL,
                character_offset INTEGER NOT NULL,
                sentence_index INTEGER NOT NULL,
                FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
            );
            """)

        // 2026-06-17 — Spoiler firewall (Layer 0). The reader's MAX-ever
        // character offset, distinct from `character_offset` (current/last).
        // A re-reader who scrolls BACK must not be falsely deflected on content
        // they've already passed ("but I read that!"), so the spoiler line is
        // the furthest point ever reached, updated to max(existing, new) on each
        // upsert. Back-fills from the current offset for pre-migration rows.
        try addColumnIfNeeded(table: "reading_positions", column: "furthest_character_offset", definition: "INTEGER NOT NULL DEFAULT 0")
        try execute("UPDATE reading_positions SET furthest_character_offset = character_offset WHERE furthest_character_offset < character_offset;")

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

        // E2 R8 — durable annotation anchor (legal-grade). Bare offsets silently point
        // at the wrong characters if a unit's text is later mutated (enhancement
        // pipeline bumps revision + rewrites text) or re-imported. Store the anchored
        // substring + a small left/right context window so an anchor can be RE-FOUND
        // when offsets drift, and FLAGGED as unanchorable rather than mis-highlighting
        // if the text truly changed. Nullable + additive (legacy/bookmark rows = NULL,
        // treated as offset-only). No migration — just three ADD COLUMNs.
        try addColumnIfNeeded(table: "notes", column: "anchor_text", definition: "TEXT")
        try addColumnIfNeeded(table: "notes", column: "context_before", definition: "TEXT")
        try addColumnIfNeeded(table: "notes", column: "context_after", definition: "TEXT")

        try execute("""
            CREATE TABLE IF NOT EXISTS document_images (
                id TEXT PRIMARY KEY NOT NULL,
                document_id TEXT NOT NULL,
                image_data BLOB NOT NULL,
                FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
            );
            """)

        // 2026-05-06 (parity #3 — heading styling): document_toc gained
        // a `level` column. Per Mark's call, no data-preservation
        // migration; if an existing DB has the table without `level`,
        // drop it and let the user re-import to repopulate. The check
        // is one PRAGMA + an optional DROP — runs once per app launch
        // and short-circuits cleanly when the schema is already current.
        var hasLevelColumn = true
        let pragmaSQL = "PRAGMA table_info(document_toc);"
        if let pragma = try? prepareStatement(sql: pragmaSQL) {
            defer { sqlite3_finalize(pragma) }
            var foundTable = false
            var foundLevel = false
            while sqlite3_step(pragma) == SQLITE_ROW {
                foundTable = true
                if let name = sqliteString(pragma, index: 1), name == "level" {
                    foundLevel = true
                }
            }
            hasLevelColumn = !foundTable || foundLevel
        }
        if !hasLevelColumn {
            try execute("DROP TABLE IF EXISTS document_toc;")
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS document_toc (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                document_id TEXT NOT NULL,
                play_order INTEGER NOT NULL,
                title TEXT NOT NULL,
                plain_text_offset INTEGER NOT NULL,
                level INTEGER NOT NULL DEFAULT 1,
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

        // ========== Ask Posey Milestone 5 — column additions ==========
        // Five columns added to support the M5 prose response loop and the
        // observability the prompt builder needs:
        //
        // - intent: classified AskPoseyIntent ('immediate' | 'search' |
        //   'general'), nullable for legacy rows. Persisted per turn so
        //   we can audit how the classifier routed real questions.
        //
        // - chunks_injected: JSON array of chunk references (id, offset,
        //   relevance score) actually injected into the prompt for this
        //   assistant turn. M5 writes '[]' (no RAG yet); M6 fills it; M7
        //   surfaces it as the "Sources" strip below assistant bubbles.
        //
        // - full_prompt_for_logging: the rendered prompt body the model
        //   saw on this turn. Large but invaluable for the local-API
        //   tuning loop Mark called for ("watch what gets injected, what
        //   gets dropped, where answers fall short"). Nullable so
        //   pre-M5 turns don't need backfill.
        //
        // - embedding / embedding_kind: per-turn semantic embedding for
        //   M6+ "retrieve relevant older turns when budget is tight"
        //   path. Mirrors the document_chunks pattern. Nullable in M5;
        //   M6 backfills + populates new turns at write time.
        try addColumnIfNeeded(table: "ask_posey_conversations", column: "intent", definition: "TEXT")
        try addColumnIfNeeded(table: "ask_posey_conversations", column: "chunks_injected", definition: "TEXT NOT NULL DEFAULT '[]'")
        try addColumnIfNeeded(table: "ask_posey_conversations", column: "full_prompt_for_logging", definition: "TEXT")
        try addColumnIfNeeded(table: "ask_posey_conversations", column: "embedding", definition: "BLOB")
        try addColumnIfNeeded(table: "ask_posey_conversations", column: "embedding_kind", definition: "TEXT NOT NULL DEFAULT 'unknown'")
        // ========== End Ask Posey Milestone 5 column additions ==========

        // 2026-06-20 — CONVERSATION-MEMORY FIX, Part B. FTS5 mirror over
        // ask_posey_conversations.content so the conversation-recall pass can
        // run BM25 alongside the semantic (embedding) pass and RRF-fuse them —
        // Hal's own measure was dense ~78% vs hybrid ~91% recall@10, and Posey
        // already owns this external-content pattern (see unit_embedding_chunks_fts).
        // Same contentless external-content shape + the standard three sync
        // triggers from the SQLite docs. The search joins back to the base table
        // to filter is_summary=0 AND role IN ('user','assistant').
        try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS ask_posey_conversations_fts USING fts5(
                content,
                document_id UNINDEXED,
                content='ask_posey_conversations',
                content_rowid='rowid'
            );
            """)
        try execute("""
            CREATE TRIGGER IF NOT EXISTS ask_posey_conversations_ai
            AFTER INSERT ON ask_posey_conversations BEGIN
                INSERT INTO ask_posey_conversations_fts(rowid, content, document_id)
                VALUES (new.rowid, new.content, new.document_id);
            END;
            """)
        try execute("""
            CREATE TRIGGER IF NOT EXISTS ask_posey_conversations_ad
            AFTER DELETE ON ask_posey_conversations BEGIN
                INSERT INTO ask_posey_conversations_fts(ask_posey_conversations_fts, rowid, content, document_id)
                VALUES ('delete', old.rowid, old.content, old.document_id);
            END;
            """)
        try execute("""
            CREATE TRIGGER IF NOT EXISTS ask_posey_conversations_au
            AFTER UPDATE ON ask_posey_conversations BEGIN
                INSERT INTO ask_posey_conversations_fts(ask_posey_conversations_fts, rowid, content, document_id)
                VALUES ('delete', old.rowid, old.content, old.document_id);
                INSERT INTO ask_posey_conversations_fts(rowid, content, document_id)
                VALUES (new.rowid, new.content, new.document_id);
            END;
            """)
        // NOTE: no one-time 'rebuild' to backfill pre-existing turns. The
        // triggers index every turn inserted from now on, and any conversation
        // that predates this table is disposable test data — we clear
        // conversations before each chat test and each A/B arm anyway, and there
        // is no production user history to preserve (single-dev app). If a real
        // pre-update history ever needed recall, a one-time rebuild + embed
        // backfill would do it — not needed now (Mark, 2026-06-20).

        // Embedding index for Ask Posey RAG retrieval. One row per ~500-char
        // chunk with 50-char overlap, built at import time for every
        // supported format (TXT/MD/RTF/DOCX/HTML/EPUB/PDF) per the
        // format-parity standing policy. The `embedding` BLOB packs
        // [Double] little-endian; the embedding model used (English,
        // detected-language NLEmbedding, or hash fallback) is captured in
        // `embedding_kind` so Milestone 2 can validate retrieval and
        // re-index if a model is upgraded.
        // 2026-05-23 — Step 8f: drop the legacy document_chunks and
        // document_entities tables. Retrieval now flows entirely
        // through unit_embedding_chunks (semantic) +
        // unit_embedding_chunks_fts (BM25). DROP IF EXISTS handles
        // pre-8f installs cleanly; the CREATE TABLE / index lines
        // these statements replace are gone for good.
        try execute("DROP TABLE IF EXISTS document_entities;")
        try execute("DROP TABLE IF EXISTS document_chunks;")

        // ========== 2026-05-22 Phase 2.2 — Background enhancement schema ==========
        // Streaming chunk replacement architecture for PDF Tier 2
        // (Vision) and Tier 3 (AFM fusion repair) post-extraction
        // enhancement. See DECISIONS.md 2026-05-22 late-evening
        // entry. All columns additive + nullable / defaulted so
        // pre-Phase-2.2 databases migrate cleanly.

        // documents — enhancement state machine + resume markers.
        //
        // enhancement_status state machine:
        //   'na'       — no enhancement applicable (non-PDF, or PDF
        //                with zero flagged pages and zero suspect
        //                tokens)
        //   'pending'  — enqueued but not yet started
        //   'tier2'    — Tier 2 (Vision) currently running
        //   'tier3'    — Tier 3 (AFM fusion repair) currently running
        //   'complete' — both tiers finished
        //   'failed'   — enhancement aborted; see enhancement_error
        try addColumnIfNeeded(table: "documents", column: "enhancement_status", definition: "TEXT NOT NULL DEFAULT 'na'")
        // 2026-05-22 Phase 2.2 Step 5 — universal content boundaries.
        // JSON array of plainText character offsets where each
        // meaningful division begins. Format-specific:
        //   - PDF:   page boundaries (every page start)
        //   - EPUB:  chapter boundaries
        //   - DOCX:  section boundaries
        //   - HTML:  heading boundaries (if any) or empty
        //   - MD:    heading boundaries (if any) or empty
        //   - RTF:   heading boundaries (if any) or empty
        //   - TXT:   heading boundaries (if any) or empty
        // The enhancement service uses these at runtime to compute
        // which chunks overlap a given page/section being processed
        // by Tier 2 / Tier 3 — one mechanism, all seven formats.
        // content_boundaries column removed 2026-05-27 — derived on-the-fly
        // from pageBreak units by `contentBoundaries(for:)`. Drop migration
        // is in the earlier dropColumnIfPresent block.
        // tier2_pages_done — JSON array of page indices Vision has
        // already processed for this document. Lets us resume a
        // partial run after relaunch without re-doing completed
        // pages. Empty array = nothing done yet.
        try addColumnIfNeeded(table: "documents", column: "tier2_pages_done", definition: "TEXT NOT NULL DEFAULT '[]'")
        // tier3_tokens_done — count of suspect tokens AFM has
        // already corrected (or attempted). Diagnostic / telemetry;
        // the authoritative idempotency record is the
        // `document_afm_corrections` table below.
        try addColumnIfNeeded(table: "documents", column: "tier3_tokens_done", definition: "INTEGER NOT NULL DEFAULT 0")
        // enhancement_error — last failure reason when
        // enhancement_status = 'failed'. NULL otherwise.
        try addColumnIfNeeded(table: "documents", column: "enhancement_error", definition: "TEXT")

        // 2026-05-23 — Step 8f: per-row provenance columns on
        // document_chunks (page_start / page_end / revision /
        // source_tier) gone with the table itself.

        // document_afm_corrections — Tier 3 idempotency table.
        // One row per (document, original-token, corrected-token)
        // triple. Tier 3 startup queries this table to skip tokens
        // already corrected for the document. Survives mid-pass
        // app kills + relaunches without reprocessing.
        try execute("""
            CREATE TABLE IF NOT EXISTS document_afm_corrections (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                document_id TEXT NOT NULL,
                original TEXT NOT NULL,
                corrected TEXT NOT NULL,
                applied_at REAL NOT NULL,
                FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
            );
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS idx_document_afm_corrections_doc
            ON document_afm_corrections(document_id);
            """)
        try execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS uq_document_afm_corrections_orig
            ON document_afm_corrections(document_id, original);
            """)
        // ========== End Phase 2.2 schema additions ==========

        // ========== 2026-05-23 Architecture rebuild — units schema ==========
        // The new single-source-of-truth content model. See
        // `docs-internal/architecture-rebuild-proposal.md`.
        //
        // Old `documents.plain_text` / `display_text` columns + the
        // `document_chunks` table remain in the schema during the
        // per-format rollout so the project compiles while one
        // format at a time switches over. The cleanup pass at the
        // end of the rebuild drops the old columns and the chunks
        // table.

        // document_units — the new authoritative content store. Every
        // importer emits an ordered list of these; the reader, TTS,
        // search, and Ask Posey RAG all derive their views from this
        // table. See `ContentUnit.swift` for the type and the field
        // conventions.
        try execute("""
            CREATE TABLE IF NOT EXISTS document_units (
                id TEXT PRIMARY KEY,
                document_id TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                kind TEXT NOT NULL,
                text TEXT NOT NULL DEFAULT '',
                metadata_json TEXT NOT NULL DEFAULT '{}',
                revision INTEGER NOT NULL DEFAULT 1,
                source_tier TEXT NOT NULL DEFAULT 'importer',
                FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
            );
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS idx_document_units_doc_seq
            ON document_units(document_id, sequence);
            """)

        // document_sentences — pre-computed sentence segmentation per
        // unit, produced by `SentenceIndexer` at import time. The
        // playback service reads these directly with no NLTokenizer
        // pass on the open path. `(unit_sequence, sentence_index)`
        // gives the global playback order.
        try execute("""
            CREATE TABLE IF NOT EXISTS document_sentences (
                id TEXT PRIMARY KEY,
                document_id TEXT NOT NULL,
                unit_id TEXT NOT NULL,
                unit_sequence INTEGER NOT NULL,
                sentence_index INTEGER NOT NULL,
                intra_start INTEGER NOT NULL,
                intra_end INTEGER NOT NULL,
                text TEXT NOT NULL,
                FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE,
                FOREIGN KEY(unit_id) REFERENCES document_units(id) ON DELETE CASCADE
            );
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS idx_document_sentences_playback
            ON document_sentences(document_id, unit_sequence, sentence_index);
            """)

        // unit_embedding_chunks — derived cache for RAG retrieval.
        // The unit-aware chunker reads units in order and emits
        // overlap-windowed retrieval slices anchored to
        // (start_unit_id, start_intra_offset, end_unit_id,
        // end_intra_offset). Rebuilt when units change (Tier 2
        // page swap, Tier 3 token correction).
        //
        // 2026-05-23 — Step 8a (Hal-based Ask Posey rebuild).
        // The earlier interim schema had `embedding BLOB NOT NULL`
        // and an `embedding_kind` column. The new architecture's
        // invariant is "one active embedding backend at a time,
        // every row is either in that backend's space or NULL
        // pending a migration re-embed." Per-row kind has no
        // meaning under this invariant, and NULL is required so
        // `EmbedderMigrationCoordinator` can wipe-and-refill.
        //
        // **Idempotent migration.** First version of this migration
        // unconditionally DROPped the table on every launch — that
        // wiped chunk data on every app update / install. The fix:
        // detect the legacy shape (presence of the `embedding_kind`
        // column) and migrate only when needed. If the table
        // already exists in the new shape, leave it alone. If it
        // doesn't exist yet (fresh install), CREATE IF NOT EXISTS
        // handles that path.
        let chunksTableHasLegacyKind: Bool = {
            do {
                let stmt = try prepareStatement(sql: "PRAGMA table_info(unit_embedding_chunks);")
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let cName = sqlite3_column_text(stmt, 1) {
                        let name = String(cString: cName)
                        if name == "embedding_kind" { return true }
                    }
                }
            } catch { return false }
            return false
        }()
        if chunksTableHasLegacyKind {
            try execute("DROP TABLE unit_embedding_chunks;")
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS unit_embedding_chunks (
                id TEXT PRIMARY KEY,
                document_id TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                start_unit_id TEXT NOT NULL,
                start_intra_offset INTEGER NOT NULL,
                end_unit_id TEXT NOT NULL,
                end_intra_offset INTEGER NOT NULL,
                text TEXT NOT NULL,
                embedding BLOB,
                FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE,
                FOREIGN KEY(start_unit_id) REFERENCES document_units(id) ON DELETE CASCADE,
                FOREIGN KEY(end_unit_id) REFERENCES document_units(id) ON DELETE CASCADE
            );
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS idx_unit_embedding_chunks_doc
            ON unit_embedding_chunks(document_id, chunk_index);
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS idx_unit_embedding_chunks_null
            ON unit_embedding_chunks(document_id) WHERE embedding IS NULL;
            """)

        // 2026-06-17 — PER-BACKEND VECTOR COLUMNS (embedder-swap final design).
        // Each backend owns a permanent BLOB column so BOTH vector sets coexist:
        //   embedding_nl     — NLContextual, 512-dim
        //   embedding_nomic  — Nomic Embed Text v1.5, 768-dim
        // A swap fills the TARGET column (NULL rows only) while the other stays
        // intact (Rule 1, no destructive NULL-all); the active-backend flag
        // (`EmbeddingBackend.defaultsKey`) tells the retriever which column to
        // read. Keep-both payoff: removing a backend is a free revert — flip the
        // flag back, no re-embed (Rule: keep both sets).
        //
        // The legacy single `embedding` column held whatever backend was active
        // when written. ONE-TIME, NON-DESTRUCTIVE copy: move that data into the
        // active backend's column. Idempotent + clobber-safe by construction —
        // copies only where the legacy cell is non-NULL AND the target cell is
        // still NULL, so re-running on later launches matches nothing and a
        // freshly-written active-column vector is never overwritten by stale
        // legacy data. (On a phone already migrated to Nomic, this lands the
        // completed Nomic set in embedding_nomic and leaves embedding_nl empty —
        // the prior destructive swap already discarded the NL vectors; keep-both
        // applies to future swaps, not retroactively.)
        try addColumnIfNeeded(table: "unit_embedding_chunks", column: "embedding_nl", definition: "BLOB")
        try addColumnIfNeeded(table: "unit_embedding_chunks", column: "embedding_nomic", definition: "BLOB")
        // 2026-06-19 — 3rd backend: mxbai-embed-large (BERT-large, 1024-dim),
        // loaded via swift-embeddings' Bert path (gate-verified). Same keep-both
        // per-backend-column design: coexists with nl/nomic, filled by the
        // backfill worker, read when active.
        try addColumnIfNeeded(table: "unit_embedding_chunks", column: "embedding_mxbai", definition: "BLOB")
        let activeVectorColumn = EmbeddingBackend.current().vectorColumn
        try execute("""
            UPDATE unit_embedding_chunks
            SET \(activeVectorColumn) = embedding
            WHERE embedding IS NOT NULL AND \(activeVectorColumn) IS NULL;
            """)

        // FTS5 mirror over unit_embedding_chunks.text — gives BM25
        // and lexical search "for free" on the same rows that hold
        // semantic embeddings. Contentless external-content shape:
        // the FTS table doesn't store the text itself, it indexes
        // the base table's `text` column by rowid. Three triggers
        // (AFTER INSERT/DELETE/UPDATE) keep the mirror in sync;
        // they're the standard external-content FTS5 pattern from
        // the SQLite docs.
        //
        // 2026-05-23 — Step 8b (Hal-based Ask Posey rebuild).
        // BM25 retrieval rides on this; the RRF hybrid retriever
        // in 8c reads here.
        try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS unit_embedding_chunks_fts USING fts5(
                text,
                document_id UNINDEXED,
                content='unit_embedding_chunks',
                content_rowid='rowid'
            );
            """)
        try execute("""
            CREATE TRIGGER IF NOT EXISTS unit_embedding_chunks_ai
            AFTER INSERT ON unit_embedding_chunks BEGIN
                INSERT INTO unit_embedding_chunks_fts(rowid, text, document_id)
                VALUES (new.rowid, new.text, new.document_id);
            END;
            """)
        try execute("""
            CREATE TRIGGER IF NOT EXISTS unit_embedding_chunks_ad
            AFTER DELETE ON unit_embedding_chunks BEGIN
                INSERT INTO unit_embedding_chunks_fts(unit_embedding_chunks_fts, rowid, text, document_id)
                VALUES ('delete', old.rowid, old.text, old.document_id);
            END;
            """)
        try execute("""
            CREATE TRIGGER IF NOT EXISTS unit_embedding_chunks_au
            AFTER UPDATE ON unit_embedding_chunks BEGIN
                INSERT INTO unit_embedding_chunks_fts(unit_embedding_chunks_fts, rowid, text, document_id)
                VALUES ('delete', old.rowid, old.text, old.document_id);
                INSERT INTO unit_embedding_chunks_fts(rowid, text, document_id)
                VALUES (new.rowid, new.text, new.document_id);
            END;
            """)

        // smart-skip + content-end references move from plainText
        // offsets to unit ids. Old offset columns (playback_skip_until_offset,
        // content_end_offset) stay during the rollout; new code reads
        // these unit-id columns when available, falls back to the
        // offset columns when not.
        try addColumnIfNeeded(table: "documents", column: "skip_unit_id", definition: "TEXT")
        try addColumnIfNeeded(table: "documents", column: "content_end_unit_id", definition: "TEXT")
        // ========== End architecture rebuild — units schema ==========
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

    /// **Step 10 helper.** Drop a column from a table if it still
    /// exists. Wraps SQLite 3.35+ `ALTER TABLE ... DROP COLUMN`
    /// (every iOS 16+ device ships ≥ 3.39, so available everywhere
    /// Posey supports). No-op if the column was already dropped.
    private func dropColumnIfPresent(table: String, column: String) throws {
        let statement = try prepareStatement(sql: "PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        var found = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if sqliteString(statement, index: 1) == column { found = true; break }
        }
        if found {
            try execute("ALTER TABLE \(table) DROP COLUMN \(column);")
        }
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
            // Distinguish FK violations so callers can treat the
            // "doc was deleted under us" race as benign rather than
            // surfacing a confusing alert.
            // SQLITE_CONSTRAINT_FOREIGNKEY = 787 = SQLITE_CONSTRAINT (19)
            // | (3 << 8). The compound macro isn't bridged into Swift;
            // hardcode the literal.
            let extended = sqlite3_extended_errcode(database)
            if extended == 787 {
                throw DatabaseError.foreignKeyViolation(lastErrorMessage())
            }
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

// ========== BLOCK 07: PHASE 2.2 ENHANCEMENT STATE HELPERS - START ==========

/// Helpers for reading + writing the Phase 2.2 enhancement state
/// columns added to `documents` in Step 1. All run on the main-actor-
/// isolated DatabaseManager; the background `PDFEnhancementService`
/// actor hops to MainActor to call these.
extension DatabaseManager {

    /// One status row per pending / in-flight document. Used by
    /// `PDFEnhancementService.bootstrap()` on app launch to resume
    /// orphaned enhancement jobs.
    struct EnhancementStatusRow: Sendable {
        let documentID: UUID
        let status: String
        let tier2PagesDoneJSON: String
        let tier3TokensDone: Int
        let error: String?
    }

    /// Read the enhancement_status state for a single document.
    /// Returns nil when the document doesn't exist (caller should
    /// treat as 'na' and skip).
    func enhancementStatus(for documentID: UUID) throws -> EnhancementStatusRow? {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        SELECT enhancement_status, tier2_pages_done, tier3_tokens_done, enhancement_error
        FROM documents
        WHERE id = ?;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let status = sqliteString(statement, index: 0) ?? "na"
        let pagesDone = sqliteString(statement, index: 1) ?? "[]"
        let tokensDone = Int(sqlite3_column_int(statement, 2))
        let error = sqliteString(statement, index: 3)
        return EnhancementStatusRow(
            documentID: documentID,
            status: status,
            tier2PagesDoneJSON: pagesDone,
            tier3TokensDone: tokensDone,
            error: error
        )
    }

    /// Documents currently in any enhancement state matching one of
    /// `statuses`. Used by bootstrap to find orphaned jobs.
    func documentsByEnhancementStatus(_ statuses: [String]) throws -> [EnhancementStatusRow] {
        dbLock.lock(); defer { dbLock.unlock() }
        guard !statuses.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: statuses.count).joined(separator: ", ")
        let sql = """
        SELECT id, enhancement_status, tier2_pages_done, tier3_tokens_done, enhancement_error
        FROM documents
        WHERE enhancement_status IN (\(placeholders));
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        for (i, s) in statuses.enumerated() {
            try bind(s, at: Int32(i + 1), for: statement)
        }
        var rows: [EnhancementStatusRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idStr = sqliteString(statement, index: 0),
                  let id = UUID(uuidString: idStr) else { continue }
            let status = sqliteString(statement, index: 1) ?? "na"
            let pagesDone = sqliteString(statement, index: 2) ?? "[]"
            let tokensDone = Int(sqlite3_column_int(statement, 3))
            let error = sqliteString(statement, index: 4)
            rows.append(EnhancementStatusRow(
                documentID: id,
                status: status,
                tier2PagesDoneJSON: pagesDone,
                tier3TokensDone: tokensDone,
                error: error
            ))
        }
        return rows
    }

    /// Update enhancement_status (and optionally tier2_pages_done /
    /// tier3_tokens_done / enhancement_error) for a document.
    func updateEnhancementState(
        documentID: UUID,
        status: String,
        tier2PagesDoneJSON: String? = nil,
        tier3TokensDone: Int? = nil,
        error: String? = nil
    ) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        var sets: [String] = ["enhancement_status = ?"]
        if tier2PagesDoneJSON != nil { sets.append("tier2_pages_done = ?") }
        if tier3TokensDone != nil { sets.append("tier3_tokens_done = ?") }
        // enhancement_error is always written (including to NULL) when
        // status is updated, so a failure → recovery cycle clears the
        // prior error message.
        sets.append("enhancement_error = ?")
        let sql = "UPDATE documents SET \(sets.joined(separator: ", ")) WHERE id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        var idx: Int32 = 1
        try bind(status, at: idx, for: statement); idx += 1
        if let json = tier2PagesDoneJSON {
            try bind(json, at: idx, for: statement); idx += 1
        }
        if let tokens = tier3TokensDone {
            sqlite3_bind_int(statement, idx, Int32(tokens)); idx += 1
        }
        if let e = error {
            try bind(e, at: idx, for: statement)
        } else {
            sqlite3_bind_null(statement, idx)
        }
        idx += 1
        try bind(documentID.uuidString, at: idx, for: statement)
        try step(statement)
    }
}

// ========== BLOCK 07: PHASE 2.2 ENHANCEMENT STATE HELPERS - END ==========

// ========== BLOCK 08: PHASE 2.2 CONTENT BOUNDARIES + PAGE REWRITE - START ==========

/// Step 5 — content_boundaries read/write + the atomic per-page
/// text-rewrite transaction used by the Tier 2 Vision background
/// runner to splice new page text into a document and shift
/// downstream offsets across every linked table.
extension DatabaseManager {

    /// Derive the content_boundaries array on-the-fly from pageBreak
    /// units. Mirrors the legacy `documents.content_boundaries` column
    /// shape (which was dropped 2026-05-27): one entry per page that
    /// has prose text; the value is the plainText offset where that
    /// page's first prose unit begins.
    ///
    /// **Important alignment note (legacy invariant preserved):** the
    /// array is indexed by the *sequence of pages-with-text*, NOT by
    /// PDF page number. A pure-visual page (image-only) doesn't get an
    /// entry. This matches the original importer's `readableTextPages`-
    /// based derivation. PDFEnhancementService uses `page.pageIndex`
    /// (a PDF page number) to index into this array, which is correct
    /// for documents where every PDF page has text (the common case)
    /// but mis-aligns for documents with interleaved visual-only
    /// pages. That latent issue predates this change; preserving the
    /// exact contract avoids regression while the column is removed.
    func contentBoundaries(for documentID: UUID) throws -> [Int] {
        dbLock.lock(); defer { dbLock.unlock() }
        let units = try self.units(for: documentID)
        guard !units.isEmpty else { return [] }
        var boundaries: [Int] = []
        var runningOffset = 0
        var emittedProse = false
        var awaitingPageStart = false
        let sepLen = 2  // "\n\n" between consecutive prose units
        for unit in units {
            switch unit.kind {
            case .pageBreak:
                awaitingPageStart = true
            case .prose, .heading, .blockquote, .listItem, .code, .table:
                if awaitingPageStart {
                    if emittedProse { runningOffset += sepLen }
                    boundaries.append(runningOffset)
                    awaitingPageStart = false
                } else if emittedProse {
                    runningOffset += sepLen
                } else if boundaries.isEmpty {
                    // Fallback: prose with no preceding pageBreak.
                    // Treat as page 0 starting at offset 0.
                    boundaries.append(0)
                }
                runningOffset += unit.text.count
                emittedProse = true
            case .image, .horizontalRule:
                // Don't contribute to plainText offset; if the only
                // content on a page was an image, the page gets no
                // boundary entry (legacy contract).
                awaitingPageStart = false
            }
        }
        return boundaries
    }

    /// **Step 10 — derived from units.** Read plainText for a document
    /// by joining prose-bearing units the same way the persister did
    /// when it still wrote the `plain_text` column. Used by the
    /// enhancement service to compute the current page range before
    /// rewriting it; by ReaderView / LibraryView for legacy fallback
    /// paths during the column-drop migration.
    ///
    /// Returns `nil` only when the document has no rows (caller's
    /// distinct from empty-doc case where the result is `""`).
    func plainText(for documentID: UUID) throws -> String? {
        dbLock.lock(); defer { dbLock.unlock() }
        // Confirm document exists first so a nil return means "doc
        // gone" rather than "doc with zero units" (which is a valid
        // empty state).
        guard try documentExists(documentID) else { return nil }
        let units = try units(for: documentID)
        return units
            .filter { $0.kind.carriesProseText }
            .map(\.text)
            .joined(separator: "\n\n")
    }

}

// ========== BLOCK 08: PHASE 2.2 CONTENT BOUNDARIES + PAGE REWRITE - END ==========

// ========== BLOCK 09: PHASE 2.2 TIER 3 FUSION REPAIR HELPERS - START ==========

extension DatabaseManager {

    /// Read every original token already corrected (or attempted-and-
    /// kept-unchanged) for a document. Tier 3 startup queries this to
    /// skip tokens it's already processed.
    func existingAFMCorrections(for documentID: UUID) throws -> Set<String> {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = "SELECT original FROM document_afm_corrections WHERE document_id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        var out = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let s = sqliteString(statement, index: 0) {
                out.insert(s)
            }
        }
        return out
    }

    /// Record an AFM verdict for a token. UNIQUE constraint on
    /// (document_id, original) — if the token's already recorded
    /// the insert is a no-op (`ON CONFLICT DO NOTHING`).
    func recordAFMCorrection(
        documentID: UUID,
        original: String,
        corrected: String
    ) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        INSERT INTO document_afm_corrections (document_id, original, corrected, applied_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(document_id, original) DO NOTHING;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        try bind(original, at: 2, for: statement)
        try bind(corrected, at: 3, for: statement)
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        try step(statement)
    }

    /// 2026-06-09 (#3 Tier-3 verify) — read the recorded AFM fusion
    /// verdicts for a document, newest first. Diagnostic surface for the
    /// antenna's `LIST_AFM_CORRECTIONS` verb. Rows where `corrected ==
    /// original` are AFM "kept" verdicts (recorded only for idempotency);
    /// rows where they DIFFER are real applied fusion corrections — the
    /// signal that proves Tier-3 actually fired, not just ran.
    func afmCorrections(for documentID: UUID) throws -> [(original: String, corrected: String)] {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = "SELECT original, corrected FROM document_afm_corrections WHERE document_id = ? ORDER BY applied_at DESC;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        var out: [(original: String, corrected: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let o = sqliteString(statement, index: 0) ?? ""
            let c = sqliteString(statement, index: 1) ?? ""
            out.append((original: o, corrected: c))
        }
        return out
    }

}

// ========== BLOCK 09: PHASE 2.2 TIER 3 FUSION REPAIR HELPERS - END ==========

// ========== BLOCK 10: CONTENT UNITS + SENTENCES (REBUILD) - START ==========
//
// Persistence layer for the rebuild's content-units source of truth.
// See `docs-internal/architecture-rebuild-proposal.md` and
// `Posey/Domain/Models/ContentUnit.swift` for the data model.
//
// These helpers live alongside the legacy plainText / displayText /
// document_chunks paths during the per-format rollout. As each format
// flips to units, its old paths get retired.

extension DatabaseManager {

    // MARK: Units — read

    /// Fetch every content unit for a document, ordered by sequence.
    /// One indexed SELECT; sub-second even on Moby-sized documents
    /// because there's no per-row computation.
    func units(for documentID: UUID) throws -> [ContentUnit] {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        SELECT id, sequence, kind, text, metadata_json, revision, source_tier
        FROM document_units
        WHERE document_id = ?
        ORDER BY sequence ASC;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        var out: [ContentUnit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idStr = sqliteString(statement, index: 0),
                  let id = UUID(uuidString: idStr),
                  let kindRaw = sqliteString(statement, index: 2),
                  let kind = ContentUnitKind(rawValue: kindRaw),
                  let text = sqliteString(statement, index: 3),
                  let metaJSON = sqliteString(statement, index: 4),
                  let sourceTier = sqliteString(statement, index: 6) else {
                continue
            }
            let metadata: ContentUnitMetadata = {
                guard let data = metaJSON.data(using: .utf8),
                      let m = try? JSONDecoder().decode(ContentUnitMetadata.self, from: data) else {
                    return .empty
                }
                return m
            }()
            out.append(ContentUnit(
                id: id,
                documentID: documentID,
                sequence: Int(sqlite3_column_int64(statement, 1)),
                kind: kind,
                text: text,
                metadata: metadata,
                revision: Int(sqlite3_column_int64(statement, 5)),
                sourceTier: sourceTier
            ))
        }
        return out
    }

    /// **8f follow-up #12 — unit-aware page lock.**
    ///
    /// Return the set of `document_units.id`s that belong to the
    /// PDF page identified by `pageNumber` (the value carried on
    /// the `pageBreak` unit's metadata). A page's content is every
    /// prose-bearing unit between its page-break marker and the
    /// next page-break (or end of doc). The break unit itself is
    /// excluded — it carries no text and locking it is meaningless.
    ///
    /// Returns an empty set if no break unit matches `pageNumber`
    /// (e.g. non-PDF document, or page-break missing) so callers
    /// can treat the page as not-locked without a special case.
    /// Used by `PDFEnhancementService.pageIsLockedForUpdate` to
    /// decide whether a Tier 2 page rewrite would yank text out
    /// from under the user's eyes.
    func unitIDsForPage(documentID: UUID,
                        pageNumber: Int) throws -> Set<UUID> {
        dbLock.lock(); defer { dbLock.unlock() }
        let allUnits = try units(for: documentID)
        guard let breakIdx = allUnits.firstIndex(where: {
            $0.kind == .pageBreak && $0.metadata.pageNumber == pageNumber
        }) else {
            return []
        }
        var endIdx = allUnits.count
        for i in (breakIdx + 1)..<allUnits.count {
            if allUnits[i].kind == .pageBreak {
                endIdx = i
                break
            }
        }
        var out: Set<UUID> = []
        for i in (breakIdx + 1)..<endIdx {
            out.insert(allUnits[i].id)
        }
        return out
    }

    /// **8f follow-up #12 — unit-aware page lock.**
    ///
    /// Map a character offset in the document's derived plainText
    /// back to the unit it falls inside. Returns nil if the offset
    /// is negative, past end-of-doc, or falls in a gap between
    /// prose units (which shouldn't happen given the persister's
    /// invariants, but is defensive).
    ///
    /// Implementation: walks units in sequence order accumulating
    /// the joined-prose text length the way the persister builds
    /// `plain_text`: units that carry prose contribute their text
    /// plus the `"\n\n"` separator that joins adjacent prose units
    /// (matching `units.filter { $0.kind.carriesProseText }.map(\.text)
    /// .joined(separator: "\n\n")`). Linear in unit count — fine
    /// for the call frequency (once per active-sentence change).
    func unitID(documentID: UUID,
                plainTextOffset offset: Int) throws -> UUID? {
        dbLock.lock(); defer { dbLock.unlock() }
        guard offset >= 0 else { return nil }
        let allUnits = try units(for: documentID)
        var cursor = 0
        let prose = allUnits.filter { $0.kind.carriesProseText }
        for (idx, unit) in prose.enumerated() {
            let textLen = unit.text.count
            // Range covered by this unit: [cursor, cursor + textLen).
            if offset >= cursor && offset < cursor + textLen {
                return unit.id
            }
            cursor += textLen
            // Inter-unit separator "\n\n" between consecutive prose
            // units — match the joining the persister does. Skip the
            // bump after the final unit.
            if idx < prose.count - 1 {
                cursor += 2
            }
        }
        // Offset equal to total length is end-of-doc — return the
        // last prose unit so the lock still fires for a reader
        // sitting at the very end.
        if let last = prose.last, offset == cursor {
            return last.id
        }
        return nil
    }

    /// Fetch a single unit by id. Returns nil if not found (or
    /// document was deleted out from under it).
    func unit(withID id: UUID) throws -> ContentUnit? {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        SELECT id, document_id, sequence, kind, text, metadata_json, revision, source_tier
        FROM document_units
        WHERE id = ?;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let docIDStr = sqliteString(statement, index: 1),
              let docID = UUID(uuidString: docIDStr),
              let kindRaw = sqliteString(statement, index: 3),
              let kind = ContentUnitKind(rawValue: kindRaw),
              let text = sqliteString(statement, index: 4),
              let metaJSON = sqliteString(statement, index: 5),
              let sourceTier = sqliteString(statement, index: 7) else {
            return nil
        }
        let metadata: ContentUnitMetadata = {
            guard let data = metaJSON.data(using: .utf8),
                  let m = try? JSONDecoder().decode(ContentUnitMetadata.self, from: data) else {
                return .empty
            }
            return m
        }()
        return ContentUnit(
            id: id,
            documentID: docID,
            sequence: Int(sqlite3_column_int64(statement, 2)),
            kind: kind,
            text: text,
            metadata: metadata,
            revision: Int(sqlite3_column_int64(statement, 6)),
            sourceTier: sourceTier
        )
    }

    // MARK: Units — write

    /// Replace the entire unit list for a document. Atomic — the
    /// transaction either succeeds wholesale or rolls back. Used by
    /// importers at import time. For incremental edits (Tier 2 page
    /// swap, Tier 3 token correction) see `replaceUnitsForPage(...)`
    /// and `replaceTokenInUnits(...)`.
    func replaceAllUnits(_ units: [ContentUnit], for documentID: UUID) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        try execute("BEGIN TRANSACTION;")
        do {
            try execute("DELETE FROM document_units WHERE document_id = '\(documentID.uuidString)';")
            for unit in units {
                try insertUnit(unit)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Insert one unit. Assumes the caller is inside a transaction.
    private func insertUnit(_ unit: ContentUnit) throws {
        let metaJSON: String = {
            guard let data = try? JSONEncoder().encode(unit.metadata),
                  let s = String(data: data, encoding: .utf8) else {
                return "{}"
            }
            return s
        }()
        let sql = """
        INSERT INTO document_units
            (id, document_id, sequence, kind, text, metadata_json, revision, source_tier)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(unit.id.uuidString, at: 1, for: statement)
        try bind(unit.documentID.uuidString, at: 2, for: statement)
        sqlite3_bind_int64(statement, 3, sqlite3_int64(unit.sequence))
        try bind(unit.kind.rawValue, at: 4, for: statement)
        try bind(unit.text, at: 5, for: statement)
        try bind(metaJSON, at: 6, for: statement)
        sqlite3_bind_int64(statement, 7, sqlite3_int64(unit.revision))
        try bind(unit.sourceTier, at: 8, for: statement)
        try step(statement)
    }

    /// Count of units for a document. Cheap; uses the
    /// `(document_id, sequence)` index.
    func unitCount(for documentID: UUID) throws -> Int {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = "SELECT COUNT(*) FROM document_units WHERE document_id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: Sentences — read

    /// Fetch every sentence for a document, ordered by
    /// `(unit_sequence, sentence_index)` — the natural playback order.
    /// This is what `SpeechPlaybackService` consumes at open time.
    /// One indexed SELECT; no NLTokenizer pass.
    func sentences(for documentID: UUID) throws -> [Sentence] {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        SELECT id, unit_id, unit_sequence, sentence_index, intra_start, intra_end, text
        FROM document_sentences
        WHERE document_id = ?
        ORDER BY unit_sequence ASC, sentence_index ASC;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        var out: [Sentence] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idStr = sqliteString(statement, index: 0),
                  let id = UUID(uuidString: idStr),
                  let unitIDStr = sqliteString(statement, index: 1),
                  let unitID = UUID(uuidString: unitIDStr),
                  let text = sqliteString(statement, index: 6) else {
                continue
            }
            out.append(Sentence(
                id: id,
                documentID: documentID,
                unitID: unitID,
                unitSequence: Int(sqlite3_column_int64(statement, 2)),
                sentenceIndex: Int(sqlite3_column_int64(statement, 3)),
                intraStart: Int(sqlite3_column_int64(statement, 4)),
                intraEnd: Int(sqlite3_column_int64(statement, 5)),
                text: text
            ))
        }
        return out
    }

    // MARK: Sentences — write

    private func insertSentence(_ sentence: Sentence) throws {
        let sql = """
        INSERT INTO document_sentences
            (id, document_id, unit_id, unit_sequence, sentence_index, intra_start, intra_end, text)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(sentence.id.uuidString, at: 1, for: statement)
        try bind(sentence.documentID.uuidString, at: 2, for: statement)
        try bind(sentence.unitID.uuidString, at: 3, for: statement)
        sqlite3_bind_int64(statement, 4, sqlite3_int64(sentence.unitSequence))
        sqlite3_bind_int64(statement, 5, sqlite3_int64(sentence.sentenceIndex))
        sqlite3_bind_int64(statement, 6, sqlite3_int64(sentence.intraStart))
        sqlite3_bind_int64(statement, 7, sqlite3_int64(sentence.intraEnd))
        try bind(sentence.text, at: 8, for: statement)
        try step(statement)
    }

    /// Sentence count for a document — diagnostic / library badge.
    func sentenceCount(for documentID: UUID) throws -> Int {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = "SELECT COUNT(*) FROM document_sentences WHERE document_id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: One-shot persistence of an importer result

    /// Persist everything from a `ParsedDocument` in a single
    /// transaction: the document header, every unit, every sentence,
    /// TOC entries, and the skip references. Used by the unit-aware
    /// importers as the one call after they finish parsing.
    ///
    /// During the per-format rollout, this also populates the legacy
    /// `plain_text` / `display_text` / `character_count` columns by
    /// joining unit text — so any consumer that hasn't switched to
    /// units yet still sees a coherent document.

    /// Diagnostic only (logs, never throws or mutates): warn when a document
    /// advertises a table of contents in its opening yet produced no navigable
    /// structure — the silent-detector-failure class that hid the GEB run-on-TOC
    /// bug. Surfaces in LOGS so the next such failure is visible immediately
    /// instead of waiting for a reader to notice missing chapter navigation.
    ///
    /// STEP 3 — category + edge cases. Category: ANY document whose opening
    /// advertises a TOC (a standalone "Contents"/"Table of Contents" line) but
    /// whose detectors produced zero TOC entries AND zero heading units.
    ///   • Inline "the contents of this book…" must NOT trip it: the regex
    ///     anchors to a standalone line (`^\s*contents\s*$`). Verified — inline
    ///     mentions don't match.
    ///   • Partial structure (headings but no TOC, or TOC but no headings) is a
    ///     working detector, not a silent failure: the guard requires BOTH zero.
    ///   • Diagnostic only — a false positive costs one log line, never behavior,
    ///     so the bar to warn is deliberately low. Verified: 0 false fires across
    ///     the 8-doc real corpus (all of which DO have structure).
    ///   • KNOWN LIMITATION: English anchors only. A non-English book ("Inhalt",
    ///     "Sommaire", "Índice", "目次") won't be caught. Extend the alternation
    ///     if the corpus grows non-English — but keep the standalone-line anchor.
    private static func warnIfStructureSilentlyFailed(_ parsed: ParsedDocument) {
        let headingCount = parsed.units.filter { $0.kind == .heading }.count
        guard parsed.toc.isEmpty, headingCount == 0 else { return }
        // Scan the opening (first ~8000 chars of prose-bearing text) for a
        // standalone "Contents" / "Table of Contents" line.
        var opening = ""
        for unit in parsed.units where unit.kind.carriesProseText {
            opening += unit.text
            opening += "\n"
            if opening.count > 8000 { break }
        }
        let hasTOCAnchor: Bool = {
            guard let re = try? NSRegularExpression(
                pattern: #"(?im)^\s*(table of contents|contents)\s*$"#) else { return false }
            return re.firstMatch(in: opening, range: NSRange(opening.startIndex..., in: opening)) != nil
        }()
        guard hasTOCAnchor else { return }
        dbgLog("SILENT-STRUCTURE-FAILURE: '%@' (%@) advertises a Contents page but produced 0 TOC entries and 0 heading units — a structure detector likely failed silently.",
               parsed.title as NSString, parsed.fileType as NSString)
    }

    func persistParsedDocument(_ parsed: ParsedDocument) throws {
        // 2026-05-31 (ingestion audit) — silent-failure signaling. The GEB TOC
        // bug hid for a long time because a detector returned nothing and the
        // import moved on with no signal. Surface that whole class at the one
        // shared persist path: a document whose opening clearly advertises a
        // table of contents but that produced ZERO toc entries AND zero heading
        // units almost certainly had a detector fail silently. Log it so it's
        // visible in LOGS instead of hiding until a reader notices.
        Self.warnIfStructureSilentlyFailed(parsed)
        dbLock.lock(); defer { dbLock.unlock() }
        try execute("BEGIN TRANSACTION;")
        do {
            // **Step 10 — derived plainText / displayText.** The
            // legacy `plain_text` / `display_text` columns are gone;
            // both forms derive from joining prose-bearing units on
            // demand via `plainText(for:)`. Persister no longer
            // writes them. `character_count` is still stored — it's
            // the easiest indexable predicate for the dedup query.
            let proseUnits = parsed.units.filter { $0.kind.carriesProseText }
            let characterCount = proseUnits
                .map(\.text)
                .joined(separator: "\n\n")
                .count
            let now = Date()

            // Insert / update document header.
            // **Bundle 2b (2026-05-26)** — content_hash threaded.
            let docSQL = """
            INSERT INTO documents (
                id, title, file_name, file_type, imported_at, modified_at,
                character_count,
                playback_skip_until_offset, content_end_offset, skip_source,
                skip_unit_id, content_end_unit_id, content_hash, edition_label
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                file_name = excluded.file_name,
                file_type = excluded.file_type,
                modified_at = excluded.modified_at,
                character_count = excluded.character_count,
                playback_skip_until_offset = excluded.playback_skip_until_offset,
                content_end_offset = excluded.content_end_offset,
                skip_source = excluded.skip_source,
                skip_unit_id = excluded.skip_unit_id,
                content_end_unit_id = excluded.content_end_unit_id,
                content_hash = excluded.content_hash,
                edition_label = excluded.edition_label;
            """
            let docStmt = try prepareStatement(sql: docSQL)
            defer { sqlite3_finalize(docStmt) }
            try bind(parsed.id.uuidString, at: 1, for: docStmt)
            try bind(parsed.title, at: 2, for: docStmt)
            try bind(parsed.fileName, at: 3, for: docStmt)
            try bind(parsed.fileType, at: 4, for: docStmt)
            sqlite3_bind_double(docStmt, 5, now.timeIntervalSince1970)
            sqlite3_bind_double(docStmt, 6, now.timeIntervalSince1970)
            sqlite3_bind_int64(docStmt, 7, sqlite3_int64(characterCount))
            // **Bundle 2d (2026-05-26)** — the skip and end offsets
            // were always being written as 0 literal. Now bound
            // from ParsedDocument so the reader's skip-at-open path
            // sees the real value for TXT / Gutenberg / etc.
            sqlite3_bind_int64(docStmt, 8, sqlite3_int64(parsed.playbackSkipUntilOffset))
            sqlite3_bind_int64(docStmt, 9, sqlite3_int64(parsed.contentEndOffset))
            try bind(parsed.skipSource, at: 10, for: docStmt)
            if let s = parsed.skipUnitID {
                try bind(s.uuidString, at: 11, for: docStmt)
            } else {
                sqlite3_bind_null(docStmt, 11)
            }
            if let e = parsed.contentEndUnitID {
                try bind(e.uuidString, at: 12, for: docStmt)
            } else {
                sqlite3_bind_null(docStmt, 12)
            }
            if let h = parsed.contentHash, !h.isEmpty {
                try bind(h, at: 13, for: docStmt)
            } else {
                sqlite3_bind_null(docStmt, 13)
            }
            if let edition = parsed.editionLabel, !edition.isEmpty {
                try bind(edition, at: 14, for: docStmt)
            } else {
                sqlite3_bind_null(docStmt, 14)
            }
            try step(docStmt)

            // Replace units + sentences for this document.
            try execute("DELETE FROM document_units WHERE document_id = '\(parsed.id.uuidString)';")
            for unit in parsed.units {
                try insertUnit(unit)
            }
            try execute("DELETE FROM document_sentences WHERE document_id = '\(parsed.id.uuidString)';")
            for sentence in parsed.sentences {
                try insertSentence(sentence)
            }

            // TOC. Re-anchor each entry's offset to the true position of its
            // heading unit before persisting (2026-06-01) — importers store TOC
            // offsets in their own detector coordinate, which drifts from the
            // units coordinate the reader navigates in (DOCX displayText vs
            // plainText; PDF outline vs units). A no-op for formats already
            // unit-aligned (TXT/HTML/EPUB/RTF); exact-fix for DOCX/PDF. See
            // ContentUnitBuilder.reanchorTOCToHeadingUnits. (2026-06-02: the DOCX
            // case was traced to a non-robust importer offset — see that file's
            // note; the re-anchor is the canonical fix and was verified to make
            // all 7 formats' TOC nav land exactly on the heading.)
            let reanchoredTOC = ContentUnitBuilder.reanchorTOCToHeadingUnits(parsed.toc, units: parsed.units)
            try execute("DELETE FROM document_toc WHERE document_id = '\(parsed.id.uuidString)';")
            // 2026-06-11 — dedupe on (title, offset), as insertTOCEntries and
            // persistParsedDocumentIncrementally already do; this loop did not.
            // reanchorTOCToHeadingUnits can map two same-title TOC entries (e.g.
            // a section title that also appears as in-body text → resolved twice
            // by resolveHeadingOffsets) onto the SAME heading unit's offset,
            // producing identical (title, offset) rows. mdn_http-caching listed
            // 'Validation' twice (both @10104, the dup out-of-order). A TOC must
            // never list one location twice.
            var seenTOCKeys = Set<String>()
            for entry in reanchoredTOC {
                let key = "\(entry.title)|\(entry.plainTextOffset)"
                guard seenTOCKeys.insert(key).inserted else { continue }
                try insertTOCEntry(entry, for: parsed.id)
            }

            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Helper for `persistParsedDocument`'s TOC insert. The existing
    /// `insertTOCEntries` does a DELETE + bulk INSERT outside a
    /// transaction; we want each insert inline within our wrapping
    /// transaction.
    private func insertTOCEntry(_ entry: StoredTOCEntry, for documentID: UUID) throws {
        let sql = """
        INSERT INTO document_toc (document_id, play_order, title, plain_text_offset, level)
        VALUES (?, ?, ?, ?, ?);
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        sqlite3_bind_int64(statement, 2, sqlite3_int64(entry.playOrder))
        try bind(entry.title, at: 3, for: statement)
        sqlite3_bind_int64(statement, 4, sqlite3_int64(entry.plainTextOffset))
        sqlite3_bind_int64(statement, 5, sqlite3_int64(entry.level))
        try step(statement)
    }

    // MARK: Skip + content-end unit references

    /// Read the skip / content-end unit references for a document.
    /// During the per-format rollout, these may be nil for documents
    /// imported through the legacy plainText path.
    func unitSkipReferences(for documentID: UUID) throws -> (skipUnitID: UUID?, contentEndUnitID: UUID?) {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = "SELECT skip_unit_id, content_end_unit_id FROM documents WHERE id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return (nil, nil) }
        let skipStr = sqliteString(statement, index: 0)
        let endStr = sqliteString(statement, index: 1)
        return (
            skipStr.flatMap(UUID.init(uuidString:)),
            endStr.flatMap(UUID.init(uuidString:))
        )
    }

    /// Write the skip / content-end unit references. Set to nil to
    /// clear (e.g., user picked "Start from Beginning").
    func setUnitSkipReferences(
        skipUnitID: UUID?,
        contentEndUnitID: UUID?,
        for documentID: UUID
    ) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
        UPDATE documents
        SET skip_unit_id = ?, content_end_unit_id = ?
        WHERE id = ?;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        if let skipUnitID {
            try bind(skipUnitID.uuidString, at: 1, for: statement)
        } else {
            sqlite3_bind_null(statement, 1)
        }
        if let contentEndUnitID {
            try bind(contentEndUnitID.uuidString, at: 2, for: statement)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        try bind(documentID.uuidString, at: 3, for: statement)
        try step(statement)
    }

    // MARK: Enhancement — structure re-detection (Bug F)

    /// One promoted heading produced by an end-of-enhancement structure
    /// re-detect. Only `kind` + `metadata` change — the unit's `text`,
    /// `sequence`, and `id` are preserved, so sentences, intra-offsets, and
    /// the derived plain_text/display_text all stay valid and need no refresh.
    struct HeadingPromotion: Sendable {
        let unitID: UUID
        let level: Int
        let titleLength: Int?
    }

    /// Apply the result of an end-of-enhancement structure re-detect (Bug F)
    /// in ONE atomic transaction:
    ///
    ///   1. Replace `document_toc` with the freshly-detected entries.
    ///   2. Flip each promoted prose unit to a `.heading` unit (kind +
    ///      heading metadata only; text untouched).
    ///   3. Set the skip unit reference + the legacy skip offset/source.
    ///
    /// **Why one transaction.** This runs on the background enhancement actor
    /// after Tier-2/Tier-3. A crash between separate writes would leave a
    /// document with a TOC but no headings (or a skip with no TOC). Doing it
    /// atomically means the document either gains its full recovered structure
    /// or stays exactly as it was — never a half state. (And `enhancement_status`
    /// is already `complete` by the time bootstrap runs, so there is no resume
    /// pass to repair a partial write.)
    ///
    /// **Why no sentence/plain_text refresh.** Heading promotion changes only
    /// `kind` + `metadata_json`. `document_sentences` rows reference the unit
    /// by id and store intra-unit offsets into the unchanged `text`; the
    /// derived `plain_text`/`display_text` join unit *text*, which is also
    /// unchanged. So none of them need rewriting — unlike `replaceUnitsForPage`
    /// / `replaceTokenInUnits`, which mutate text and therefore must.
    func applyRedetectedStructure(
        documentID: UUID,
        tocEntries: [StoredTOCEntry],
        promotions: [HeadingPromotion],
        skipUnitID: UUID?,
        skipOffset: Int,
        skipSource: String
    ) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        try execute("BEGIN TRANSACTION;")
        do {
            // 1 — replace TOC. Dedup on (title, offset) like insertTOCEntries.
            try execute("DELETE FROM document_toc WHERE document_id = '\(documentID.uuidString)';")
            let tocSQL = """
            INSERT INTO document_toc (document_id, play_order, title, plain_text_offset, level)
            VALUES (?, ?, ?, ?, ?);
            """
            var seen = Set<String>()
            for entry in tocEntries {
                let key = "\(entry.title)|\(entry.plainTextOffset)"
                guard seen.insert(key).inserted else { continue }
                let stmt = try prepareStatement(sql: tocSQL)
                defer { sqlite3_finalize(stmt) }
                try bind(documentID.uuidString, at: 1, for: stmt)
                sqlite3_bind_int(stmt, 2, Int32(entry.playOrder))
                try bind(entry.title, at: 3, for: stmt)
                sqlite3_bind_int(stmt, 4, Int32(entry.plainTextOffset))
                sqlite3_bind_int(stmt, 5, Int32(entry.level))
                try step(stmt)
            }

            // 2 — promote prose units to headings (kind + metadata only).
            let promoteSQL = """
            UPDATE document_units
            SET kind = ?, metadata_json = ?, revision = revision + 1, source_tier = ?
            WHERE id = ?;
            """
            for promotion in promotions {
                let metadata = ContentUnitMetadata(
                    headingLevel: promotion.level,
                    titleLength: promotion.titleLength
                )
                let metaJSON: String = {
                    guard let data = try? JSONEncoder().encode(metadata),
                          let s = String(data: data, encoding: .utf8) else { return "{}" }
                    return s
                }()
                let stmt = try prepareStatement(sql: promoteSQL)
                defer { sqlite3_finalize(stmt) }
                try bind(ContentUnitKind.heading.rawValue, at: 1, for: stmt)
                try bind(metaJSON, at: 2, for: stmt)
                try bind("redetect_structure", at: 3, for: stmt)
                try bind(promotion.unitID.uuidString, at: 4, for: stmt)
                try step(stmt)
            }

            // 3 — skip references (unit id + legacy offset/source).
            let skipSQL = """
            UPDATE documents
            SET skip_unit_id = ?, playback_skip_until_offset = ?, skip_source = ?
            WHERE id = ?;
            """
            let skipStmt = try prepareStatement(sql: skipSQL)
            defer { sqlite3_finalize(skipStmt) }
            if let skipUnitID {
                try bind(skipUnitID.uuidString, at: 1, for: skipStmt)
            } else {
                sqlite3_bind_null(skipStmt, 1)
            }
            sqlite3_bind_int(skipStmt, 2, Int32(skipOffset))
            try bind(skipSource, at: 3, for: skipStmt)
            try bind(documentID.uuidString, at: 4, for: skipStmt)
            try step(skipStmt)

            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: Enhancement — unit-based replacements

    /// Replace the content units of one page (identified by
    /// `metadata.pageNumber` on a `pageBreak` unit) with new prose
    /// units derived from Vision OCR output. Atomic. The new
    /// sentences for the inserted units are regenerated and
    /// inserted in the same transaction.
    ///
    /// Used by `PDFEnhancementService.runTier2` after the reconciler
    /// returns `.visionWon` for a flagged page.
    func replaceUnitsForPage(
        documentID: UUID,
        pageNumber: Int,
        newPageText: String,
        sourceTier: String
    ) throws -> ReplacePageUnitsResult {
        dbLock.lock(); defer { dbLock.unlock() }
        try execute("BEGIN TRANSACTION;")
        do {
            // Find the page_break unit for this page, and the
            // page_break for the next page (or end of doc).
            let existingUnits = try units(for: documentID)
            guard let breakIdx = existingUnits.firstIndex(where: {
                $0.kind == .pageBreak && $0.metadata.pageNumber == pageNumber
            }) else {
                try execute("ROLLBACK;")
                throw DatabaseError.prepareFailed(
                    "replaceUnitsForPage: no pageBreak found for page \(pageNumber)"
                )
            }
            // The page's content is everything from breakIdx+1 up to
            // (but not including) the next pageBreak.
            var endIdx = existingUnits.count
            for i in (breakIdx + 1)..<existingUnits.count {
                if existingUnits[i].kind == .pageBreak {
                    endIdx = i
                    break
                }
            }
            let breakUnit = existingUnits[breakIdx]
            let pageContentUnits = Array(existingUnits[(breakIdx + 1)..<endIdx])

            // Sequence numbers for the new content. We insert after
            // the page break unit's sequence, before the next
            // existing unit (or open-ended at the end). Use sequence
            // strides of 1 starting at breakUnit.sequence + 1; this
            // preserves "page N's content" semantics regardless of
            // how many new units we produce.
            let baseSeq = breakUnit.sequence + 1
            let paragraphs = newPageText
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let newUnits: [ContentUnit] = paragraphs.enumerated().map { (i, text) in
                ContentUnit(
                    documentID: documentID,
                    sequence: baseSeq + i,
                    kind: .prose,
                    text: text,
                    sourceTier: sourceTier
                )
            }

            // Delete old content units + their sentences.
            for unit in pageContentUnits {
                try execute("DELETE FROM document_sentences WHERE unit_id = '\(unit.id.uuidString)';")
                try execute("DELETE FROM document_units WHERE id = '\(unit.id.uuidString)';")
            }
            // Insert new content units.
            for unit in newUnits {
                try insertUnit(unit)
            }
            // Insert sentences for the new units.
            for unit in newUnits {
                let sentences = SentenceIndexer.sentences(for: unit)
                for s in sentences { try insertSentence(s) }
            }

            // Refresh the stored `character_count` to match the
            // rewritten units. The legacy `plain_text` / `display_text`
            // columns were dropped at Step 10 (migrate(), :1135-1136) —
            // both text forms now derive from `document_units` on demand
            // via `plainText(for:)` / `displayText(for:)`, so writing
            // them here threw "no such column" and rolled the whole
            // Tier-2 page rewrite back. `character_count` is the one
            // header column still stored; recompute it with the SAME
            // prose-only `\n\n`-join semantics as persistParsedDocument
            // (:2449-2453) so the reading-time / progress meter stay
            // accurate after the rewrite.
            let refreshedUnits = try units(for: documentID)
            let characterCount = refreshedUnits
                .filter { $0.kind.carriesProseText }
                .map(\.text)
                .joined(separator: "\n\n")
                .count
            let updateStmt = try prepareStatement(
                sql: "UPDATE documents SET character_count = ? WHERE id = ?;")
            defer { sqlite3_finalize(updateStmt) }
            sqlite3_bind_int64(updateStmt, 1, sqlite3_int64(characterCount))
            try bind(documentID.uuidString, at: 2, for: updateStmt)
            try step(updateStmt)

            try execute("COMMIT;")
            return ReplacePageUnitsResult(
                removedUnitCount: pageContentUnits.count,
                insertedUnitCount: newUnits.count
            )
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    struct ReplacePageUnitsResult: Sendable {
        let removedUnitCount: Int
        let insertedUnitCount: Int
    }

    /// Replace every occurrence of `original` with `corrected` in
    /// every prose-bearing unit's text. Atomic. Each modified unit
    /// gets its `revision` bumped, `source_tier` updated, and its
    /// sentences regenerated. Used by `PDFEnhancementService.runTier3`
    /// for AFM fusion-token swaps.
    ///
    /// Word-boundary regex; case-sensitive (matching the prior
    /// pre-units token-replace behavior).
    func replaceTokenInUnits(
        documentID: UUID,
        original: String,
        corrected: String,
        sourceTier: String
    ) throws -> ReplaceTokenInUnitsResult {
        dbLock.lock(); defer { dbLock.unlock() }
        let escapedOriginal = NSRegularExpression.escapedPattern(for: original)
        let pattern = "\\b" + escapedOriginal + "\\b"
        let regex = try NSRegularExpression(pattern: pattern)

        try execute("BEGIN TRANSACTION;")
        do {
            let existing = try units(for: documentID)
            var unitsTouched = 0
            var totalOccurrences = 0
            for unit in existing where unit.kind.carriesProseText {
                let text = unit.text
                let range = NSRange(text.startIndex..., in: text)
                let matches = regex.matches(in: text, range: range)
                if matches.isEmpty { continue }
                let newText = regex.stringByReplacingMatches(
                    in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: corrected)
                )
                // Update unit text + bump revision + tier.
                let updateSQL = """
                UPDATE document_units
                SET text = ?, revision = revision + 1, source_tier = ?
                WHERE id = ?;
                """
                let updateStmt = try prepareStatement(sql: updateSQL)
                defer { sqlite3_finalize(updateStmt) }
                try bind(newText, at: 1, for: updateStmt)
                try bind(sourceTier, at: 2, for: updateStmt)
                try bind(unit.id.uuidString, at: 3, for: updateStmt)
                try step(updateStmt)

                // Replace sentences for this unit.
                try execute("DELETE FROM document_sentences WHERE unit_id = '\(unit.id.uuidString)';")
                let mutatedUnit = ContentUnit(
                    id: unit.id, documentID: unit.documentID, sequence: unit.sequence,
                    kind: unit.kind, text: newText, metadata: unit.metadata,
                    revision: unit.revision + 1, sourceTier: sourceTier
                )
                let newSentences = SentenceIndexer.sentences(for: mutatedUnit)
                for s in newSentences { try insertSentence(s) }

                unitsTouched += 1
                totalOccurrences += matches.count
            }

            // Refresh the stored `character_count` to match the
            // corrected units. The legacy `plain_text` / `display_text`
            // columns were dropped at Step 10 (migrate(), :1135-1136) —
            // writing them here threw "no such column", rolling back the
            // whole Tier-3 transaction (the unit-text update AND the
            // sentence regeneration done earlier), so every AFM token
            // correction was silently lost. Recompute `character_count`
            // with the SAME prose-only `\n\n`-join semantics as
            // persistParsedDocument (:2449-2453).
            if unitsTouched > 0 {
                let refreshedUnits = try units(for: documentID)
                let characterCount = refreshedUnits
                    .filter { $0.kind.carriesProseText }
                    .map(\.text)
                    .joined(separator: "\n\n")
                    .count
                let updateStmt = try prepareStatement(
                    sql: "UPDATE documents SET character_count = ? WHERE id = ?;")
                defer { sqlite3_finalize(updateStmt) }
                sqlite3_bind_int64(updateStmt, 1, sqlite3_int64(characterCount))
                try bind(documentID.uuidString, at: 2, for: updateStmt)
                try step(updateStmt)
            }

            // Keep annotations CONFIDENT through this fix (precise re-anchor). Apply the
            // SAME word-boundary token swap to each note's stored anchored substring +
            // surrounding context for this document. A note whose highlighted phrase (or
            // its context) contained the fused token now re-finds itself EXACTLY against
            // the corrected text — staying a solid/confident highlight instead of
            // degrading to an "unsure" placement the reader must re-confirm. Offsets are
            // left as-is; the reader's re-find relocates by the corrected text. Runs in
            // the SAME transaction as the unit edits, so text + annotations stay
            // consistent atomically. (dbLock is recursive; notes(for:) re-enters safely.)
            if totalOccurrences > 0 {
                let template = NSRegularExpression.escapedTemplate(for: corrected)
                func swapToken(_ s: String?) -> String? {
                    guard let s, !s.isEmpty else { return s }
                    let rng = NSRange(s.startIndex..., in: s)
                    guard regex.firstMatch(in: s, range: rng) != nil else { return s }
                    return regex.stringByReplacingMatches(in: s, range: rng, withTemplate: template)
                }
                for note in try notes(for: documentID) {
                    let na = swapToken(note.anchorText)
                    let nb = swapToken(note.contextBefore)
                    let nc = swapToken(note.contextAfter)
                    guard na != note.anchorText || nb != note.contextBefore || nc != note.contextAfter else { continue }
                    let nStmt = try prepareStatement(sql: """
                        UPDATE notes SET anchor_text = ?, context_before = ?, context_after = ?, updated_at = ?
                        WHERE id = ?;
                        """)
                    defer { sqlite3_finalize(nStmt) }
                    if let na { try bind(na, at: 1, for: nStmt) } else { sqlite3_bind_null(nStmt, 1) }
                    if let nb { try bind(nb, at: 2, for: nStmt) } else { sqlite3_bind_null(nStmt, 2) }
                    if let nc { try bind(nc, at: 3, for: nStmt) } else { sqlite3_bind_null(nStmt, 3) }
                    sqlite3_bind_double(nStmt, 4, Date().timeIntervalSince1970)
                    try bind(note.id.uuidString, at: 5, for: nStmt)
                    try step(nStmt)
                }
            }

            try execute("COMMIT;")
            return ReplaceTokenInUnitsResult(
                unitsTouched: unitsTouched,
                totalOccurrences: totalOccurrences
            )
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    struct ReplaceTokenInUnitsResult: Sendable {
        let unitsTouched: Int
        let totalOccurrences: Int
    }
}

// ========== BLOCK 10: CONTENT UNITS + SENTENCES (REBUILD) - END ==========


// ========== BLOCK 11: UNIT EMBEDDING CHUNKS (REBUILD STEP 8) - START ==========

/// One row of `unit_embedding_chunks`: a retrieval slice anchored to
/// content-unit coordinates. The `embedding` may be NULL while a
/// backend migration is in flight (rows get NULL'd at swap time and
/// re-embedded incrementally by `EmbedderMigrationCoordinator`).
struct StoredUnitEmbeddingChunk: Sendable, Equatable {
    let id: UUID
    let documentID: UUID
    let chunkIndex: Int
    let startUnitID: UUID
    let startIntraOffset: Int
    let endUnitID: UUID
    let endIntraOffset: Int
    let text: String
    /// Non-nil iff a vector currently exists for this row under the
    /// active embedding backend's space. Nil during migration.
    let embedding: [Double]?
}

extension DatabaseManager {

    /// Replace every chunk for `documentID` with the supplied set.
    /// Atomic: deletes old then inserts new in a single transaction.
    ///
    /// **Race guard:** `UnitEmbeddingService.enqueueIndexing` snapshots
    /// units on main, releases the actor to chunk off-main, then comes
    /// back to main to write. RESET_ALL / DELETE_DOCUMENT can cascade-
    /// delete the document (and its units) during the off-main window,
    /// after which the start_unit_id / end_unit_id FKs reject every
    /// insert. We re-check document existence inside the transaction
    /// and return silently if the doc is gone — DELETE already swept
    /// any stragglers via cascade, so the table is in the right state.
    /// `chunk_index` at or above this value marks a RAPTOR summary node
    /// (a verified abstractive summary) rather than a leaf chunk. Summary
    /// nodes live in the same `unit_embedding_chunks` pool as leaves so the
    /// hybrid retriever fuses across abstraction levels (RAPTOR's "collapsed
    /// tree"); the sentinel range distinguishes them without a schema change.
    static let raptorSummaryIndexBase = 1_000_000

    /// Atomically replace a document's RAPTOR summary nodes (leaf chunks —
    /// `chunk_index < raptorSummaryIndexBase` — are left untouched). Delete
    /// the old summary rows, insert the new. FTS5 triggers keep the BM25
    /// mirror in sync, so summaries are immediately retrievable by both
    /// semantic and lexical passes.
    func replaceSummaryNodes(_ chunks: [StoredUnitEmbeddingChunk],
                             for documentID: UUID) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let del = try prepareStatement(
                sql: "DELETE FROM unit_embedding_chunks WHERE document_id = ? AND chunk_index >= ?;"
            )
            defer { sqlite3_finalize(del) }
            sqlite3_bind_text(del, 1, documentID.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(del, 2, Int32(Self.raptorSummaryIndexBase))
            try step(del)

            if !chunks.isEmpty {
                // Vectors land in the WRITE backend's column (swap target during
                // a swap, else active). The legacy `embedding` column is frozen.
                let writeCol = EmbeddingBackend.writeBackend().vectorColumn
                let sql = """
                    INSERT OR REPLACE INTO unit_embedding_chunks
                        (id, document_id, chunk_index, start_unit_id, start_intra_offset,
                         end_unit_id, end_intra_offset, text, \(writeCol))
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """
                let ins = try prepareStatement(sql: sql)
                defer { sqlite3_finalize(ins) }
                for chunk in chunks {
                    sqlite3_reset(ins); sqlite3_clear_bindings(ins)
                    sqlite3_bind_text(ins, 1, chunk.id.uuidString, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(ins, 2, chunk.documentID.uuidString, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(ins, 3, Int32(chunk.chunkIndex))
                    sqlite3_bind_text(ins, 4, chunk.startUnitID.uuidString, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(ins, 5, Int32(chunk.startIntraOffset))
                    sqlite3_bind_text(ins, 6, chunk.endUnitID.uuidString, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(ins, 7, Int32(chunk.endIntraOffset))
                    sqlite3_bind_text(ins, 8, chunk.text, -1, SQLITE_TRANSIENT)
                    if let emb = chunk.embedding {
                        var bytes = emb
                        sqlite3_bind_blob(ins, 9, &bytes, Int32(bytes.count * MemoryLayout<Double>.size), SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(ins, 9)
                    }
                    try step(ins)
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func replaceAllUnitEmbeddingChunks(_ chunks: [StoredUnitEmbeddingChunk],
                                       for documentID: UUID) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            if try !documentExists(documentID) {
                try execute("ROLLBACK;")
                return
            }
            let deleteStmt = try prepareStatement(
                sql: "DELETE FROM unit_embedding_chunks WHERE document_id = ?;"
            )
            defer { sqlite3_finalize(deleteStmt) }
            sqlite3_bind_text(deleteStmt, 1, documentID.uuidString, -1, SQLITE_TRANSIENT)
            try step(deleteStmt)

            if !chunks.isEmpty {
                // Vectors land in the WRITE backend's column (swap target during
                // a swap, else active). The legacy `embedding` column is frozen.
                let writeCol = EmbeddingBackend.writeBackend().vectorColumn
                let insertSQL = """
                    INSERT INTO unit_embedding_chunks
                        (id, document_id, chunk_index,
                         start_unit_id, start_intra_offset,
                         end_unit_id, end_intra_offset,
                         text, \(writeCol))
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """
                let insertStmt = try prepareStatement(sql: insertSQL)
                defer { sqlite3_finalize(insertStmt) }
                for chunk in chunks {
                    sqlite3_reset(insertStmt)
                    sqlite3_clear_bindings(insertStmt)
                    sqlite3_bind_text(insertStmt, 1, chunk.id.uuidString, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(insertStmt, 2, chunk.documentID.uuidString, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(insertStmt, 3, Int32(chunk.chunkIndex))
                    sqlite3_bind_text(insertStmt, 4, chunk.startUnitID.uuidString, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(insertStmt, 5, Int32(chunk.startIntraOffset))
                    sqlite3_bind_text(insertStmt, 6, chunk.endUnitID.uuidString, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(insertStmt, 7, Int32(chunk.endIntraOffset))
                    sqlite3_bind_text(insertStmt, 8, chunk.text, -1, SQLITE_TRANSIENT)
                    if let emb = chunk.embedding {
                        var bytes = emb
                        let byteCount = bytes.count * MemoryLayout<Double>.size
                        sqlite3_bind_blob(insertStmt, 9, &bytes, Int32(byteCount), SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(insertStmt, 9)
                    }
                    try step(insertStmt)
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Update just the embedding for a single chunk. Used by the
    /// migration coordinator's re-embed loop. Passing nil for
    /// `embedding` clears the vector (e.g. on switch + wipe).
    func updateUnitEmbeddingChunkEmbedding(
        id: UUID,
        embedding: [Double]?,
        backend: EmbeddingBackend = EmbeddingBackend.writeBackend()
    ) throws {
        dbLock.lock(); defer { dbLock.unlock() }
        // Writes the WRITE backend's column (swap target during a swap, else
        // active). The coordinator passes the target explicitly; normal indexing
        // (`UnitEmbeddingService`) takes the default = active backend.
        let sql = "UPDATE unit_embedding_chunks SET \(backend.vectorColumn) = ? WHERE id = ?;"
        let stmt = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(stmt) }
        if let emb = embedding {
            var bytes = emb
            let byteCount = bytes.count * MemoryLayout<Double>.size
            sqlite3_bind_blob(stmt, 1, &bytes, Int32(byteCount), SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, SQLITE_TRANSIENT)
        try step(stmt)
    }

    /// DEPRECATED (2026-06-17 — per-backend columns). Operated on the legacy
    /// single `embedding` column, which is now frozen and unused. The
    /// non-destructive swap design never wipes a backend's column, so nothing
    /// calls this anymore. Kept only so any out-of-tree reference still
    /// compiles; do not use.
    @available(*, deprecated, message: "Per-backend columns make wipe-on-swap obsolete; the legacy `embedding` column is frozen.")
    func nullAllUnitEmbeddingChunkEmbeddings() throws {
        dbLock.lock(); defer { dbLock.unlock() }
        try execute("UPDATE unit_embedding_chunks SET embedding = NULL;")
    }

    /// Fetch IDs (and text) of every chunk currently lacking an
    /// embedding, optionally scoped to a single document. Ordered
    /// by `(document_id, chunk_index)` so the migration UI can
    /// report meaningful progress.
    struct UnitEmbeddingChunkNeedingEmbedding: Sendable {
        let id: UUID
        let text: String
    }
    func unitEmbeddingChunksNeedingEmbedding(
        for documentID: UUID? = nil,
        limit: Int? = nil,
        backend: EmbeddingBackend = EmbeddingBackend.writeBackend()
    ) throws -> [UnitEmbeddingChunkNeedingEmbedding] {
        dbLock.lock(); defer { dbLock.unlock() }
        // Rows still NULL in the WRITE backend's column — the ones a (re)embed
        // pass must fill. Default = active backend (normal indexing); the swap
        // coordinator passes its target.
        var sql = "SELECT id, text FROM unit_embedding_chunks WHERE \(backend.vectorColumn) IS NULL"
        if documentID != nil { sql += " AND document_id = ?" }
        sql += " ORDER BY document_id, chunk_index"
        if let limit = limit { sql += " LIMIT \(limit)" }
        sql += ";"
        let stmt = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(stmt) }
        if let documentID = documentID {
            sqlite3_bind_text(stmt, 1, documentID.uuidString, -1, SQLITE_TRANSIENT)
        }
        var rows: [UnitEmbeddingChunkNeedingEmbedding] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idCStr = sqlite3_column_text(stmt, 0),
                let id = UUID(uuidString: String(cString: idCStr)),
                let textCStr = sqlite3_column_text(stmt, 1)
            else { continue }
            rows.append(.init(id: id, text: String(cString: textCStr)))
        }
        return rows
    }

    /// Count of unit_embedding_chunks rows currently lacking an
    /// embedding. Used by the migration UI to report progress as
    /// `(total - needing) / total`.
    func unitEmbeddingChunkNullCount(
        backend: EmbeddingBackend = EmbeddingBackend.writeBackend()
    ) throws -> Int {
        dbLock.lock(); defer { dbLock.unlock() }
        let stmt = try prepareStatement(
            sql: "SELECT COUNT(*) FROM unit_embedding_chunks WHERE \(backend.vectorColumn) IS NULL;"
        )
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Health report for a backend's STORED vectors — read-only spot-check
    /// that the bytes on disk are real embeddings (right dimension, all-finite,
    /// non-degenerate norm), not just "non-NULL." Used to prove the backfill
    /// wrote good vectors, not garbage (Mark, 2026-06-20: "make sure we're not
    /// wasting time"). Reusable as a pre-flight before the A/B/C — a backend
    /// with dim-mismatches or NaN rows can't be fairly compared.
    struct EmbeddingValidationReport: Sendable, Equatable {
        let backend: String
        let expectedDim: Int
        let sampled: Int        // rows actually inspected (capped at sampleLimit)
        let dimMismatch: Int    // rows whose decoded length != expectedDim
        let nonFinite: Int      // rows containing any NaN/Inf
        let zeroNorm: Int       // rows whose L2 norm ~ 0 (degenerate/all-zero)
        let minNorm: Double
        let maxNorm: Double
        var healthy: Bool { sampled > 0 && dimMismatch == 0 && nonFinite == 0 && zeroNorm == 0 }
    }

    /// Sample up to `sampleLimit` non-NULL vectors from `backend`'s column and
    /// report their health. `ORDER BY RANDOM()` spreads the sample across the
    /// corpus (not just the first N rows) — a few hundred is cheap even on a
    /// 20k-row table. Column name is from the fixed `EmbeddingBackend` enum.
    func validateStoredEmbeddings(
        backend: EmbeddingBackend,
        sampleLimit: Int = 200
    ) throws -> EmbeddingValidationReport {
        dbLock.lock(); defer { dbLock.unlock() }
        let col = backend.vectorColumn
        let stmt = try prepareStatement(
            sql: "SELECT \(col) FROM unit_embedding_chunks WHERE \(col) IS NOT NULL ORDER BY RANDOM() LIMIT ?;"
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(sampleLimit))
        let expected = backend.dimension
        var sampled = 0, dimMismatch = 0, nonFinite = 0, zeroNorm = 0
        var minNorm = Double.greatestFiniteMagnitude, maxNorm = 0.0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard sqlite3_column_type(stmt, 0) != SQLITE_NULL,
                  let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let byteCount = Int(sqlite3_column_bytes(stmt, 0))
            let n = byteCount / MemoryLayout<Double>.size
            let vec = UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Double.self), count: n)
            sampled += 1
            if n != expected { dimMismatch += 1 }
            var sumsq = 0.0
            var bad = false
            for x in vec where !x.isFinite { bad = true; break }
            if bad { nonFinite += 1; continue }
            for x in vec { sumsq += x * x }
            let norm = sumsq.squareRoot()
            if norm < 1e-6 { zeroNorm += 1 }
            minNorm = Swift.min(minNorm, norm)
            maxNorm = Swift.max(maxNorm, norm)
        }
        return EmbeddingValidationReport(
            backend: backend.rawValue,
            expectedDim: expected,
            sampled: sampled,
            dimMismatch: dimMismatch,
            nonFinite: nonFinite,
            zeroNorm: zeroNorm,
            minNorm: sampled == 0 ? 0 : (minNorm == .greatestFiniteMagnitude ? 0 : minNorm),
            maxNorm: maxNorm
        )
    }

    /// Count of EMBEDDED leaf chunks for `documentID` — the rows the
    /// RAPTOR builder clusters over. Leaves are `chunk_index <
    /// raptorSummaryIndexBase`; an embedded leaf has a non-NULL vector.
    /// Used by `RaptorTreeService` to decide whether a document has
    /// enough indexed material to bother building a summary tree.
    func embeddedLeafChunkCount(for documentID: UUID) throws -> Int {
        dbLock.lock(); defer { dbLock.unlock() }
        // Active backend's column — RAPTOR clusters over the vectors the
        // retriever actually reads.
        let activeVectorColumn = EmbeddingBackend.current().vectorColumn
        let stmt = try prepareStatement(sql: """
            SELECT COUNT(*) FROM unit_embedding_chunks
            WHERE document_id = ? AND \(activeVectorColumn) IS NOT NULL AND chunk_index < ?;
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, documentID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(Self.raptorSummaryIndexBase))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // ========== EMBEDDING COVERAGE (per-backend backfill visibility) ==========
    // 2026-06-19 (Mark) — to support the embedder A/B/C phase we need to see,
    // and then fill, each backend's column independently. A document imported
    // while Nomic was active has `embedding_nomic` filled but `embedding_nl`
    // NULL (and vice-versa); the A/B/C retrieval harness needs ALL backends'
    // columns populated. These helpers report and (via the backfill worker)
    // close those gaps. Enum-driven over `EmbeddingBackend.allCases`, so adding
    // a 3rd backend (mxbai) picks them up automatically — no edit here.

    /// Total + filled chunk counts for a single backend's column across the
    /// whole corpus. `filled` counts rows where the backend's vector column is
    /// NON-NULL; `total` is every chunk row (leaves + RAPTOR summary nodes —
    /// the backfill fills both, matching the migration coordinator's loop).
    struct EmbeddingBackendCoverage: Sendable {
        let backend: EmbeddingBackend
        let filled: Int
        let total: Int
        var missing: Int { total - filled }
        var isComplete: Bool { missing == 0 }
    }

    /// Corpus-wide coverage for every backend in `EmbeddingBackend.allCases`,
    /// in declaration order. One COUNT query per backend; cheap. Drives the
    /// `EMBEDDING_COVERAGE` antenna verb and the backfill worker's "what's
    /// missing" decision.
    func embeddingCoverage() throws -> [EmbeddingBackendCoverage] {
        dbLock.lock(); defer { dbLock.unlock() }
        // Total rows once.
        let totalStmt = try prepareStatement(sql: "SELECT COUNT(*) FROM unit_embedding_chunks;")
        var total = 0
        if sqlite3_step(totalStmt) == SQLITE_ROW { total = Int(sqlite3_column_int(totalStmt, 0)) }
        sqlite3_finalize(totalStmt)

        var out: [EmbeddingBackendCoverage] = []
        for backend in EmbeddingBackend.allCases {
            // Column name is from the fixed enum (never user input) → safe to
            // interpolate.
            let stmt = try prepareStatement(
                sql: "SELECT COUNT(*) FROM unit_embedding_chunks WHERE \(backend.vectorColumn) IS NOT NULL;"
            )
            var filled = 0
            if sqlite3_step(stmt) == SQLITE_ROW { filled = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
            out.append(.init(backend: backend, filled: filled, total: total))
        }
        return out
    }

    /// Total on-disk bytes of the SQLite store: main file + WAL + SHM. Drives the
    /// dev embedding-status board's Storage section (the real disk cost of chunk
    /// text + every embedder's vectors + RAPTOR summaries). Embedding BLOBs
    /// dominate it — per backend, embedded-chunk-count × dimension × 4 (Float32).
    /// Cheap (three file-attribute reads); safe to poll on the board's timer.
    func databaseFileBytes() -> Int64 {
        let fm = FileManager.default
        let base = databaseURL.path
        return [base, base + "-wal", base + "-shm"].reduce(Int64(0)) { sum, path in
            sum + (((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// 2026-06-19 — SMALL-TO-BIG retrieval. Fetch the LEAF chunks of a document
    /// whose `chunk_index` falls in `[fromIndex, toIndex]`, ordered by index.
    /// Used to expand a retrieved (small, precise) chunk to its neighbors so the
    /// model sees the surrounding passage instead of a 400-char sliver — context
    /// without sacrificing the precision small chunks give retrieval. Leaf-only
    /// (`< raptorSummaryIndexBase`): RAPTOR summary nodes aren't contiguous prose
    /// and must never be stitched into a neighbor window.
    func unitEmbeddingChunkTexts(
        documentID: UUID, fromIndex: Int, toIndex: Int
    ) throws -> [(chunkIndex: Int, text: String)] {
        dbLock.lock(); defer { dbLock.unlock() }
        let stmt = try prepareStatement(sql: """
            SELECT chunk_index, text FROM unit_embedding_chunks
            WHERE document_id = ? AND chunk_index >= ? AND chunk_index <= ?
              AND chunk_index < ?
            ORDER BY chunk_index;
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, documentID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(max(0, fromIndex)))
        sqlite3_bind_int(stmt, 3, Int32(toIndex))
        sqlite3_bind_int(stmt, 4, Int32(Self.raptorSummaryIndexBase))
        var rows: [(chunkIndex: Int, text: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idx = Int(sqlite3_column_int(stmt, 0))
            guard let c = sqlite3_column_text(stmt, 1) else { continue }
            rows.append((chunkIndex: idx, text: String(cString: c)))
        }
        return rows
    }

    /// Total stored chunk rows for a document (leaves + any RAPTOR summary
    /// nodes), regardless of embedding state. The resume path uses this to
    /// distinguish "chunks already built → resume the fill" from "no chunks yet
    /// → build them": > 0 means a prior pass already chunked this document, so a
    /// re-enqueue should fill the remaining NULL rows rather than re-chunk from
    /// scratch (which would discard already-embedded vectors and restart a large
    /// doc forever). (2026-06-19)
    func unitEmbeddingChunkCount(for documentID: UUID) throws -> Int {
        dbLock.lock(); defer { dbLock.unlock() }
        let stmt = try prepareStatement(
            sql: "SELECT COUNT(*) FROM unit_embedding_chunks WHERE document_id = ?;"
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, documentID.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Document IDs that have at least one chunk still NULL in the ACTIVE
    /// backend's column — i.e. documents whose embedding was interrupted
    /// (jetsam / thermal kill / force-quit / backgrounded) and never finished.
    /// The launch resume sweep re-enqueues these through the normal indexing
    /// queue so they complete (and then build their RAPTOR tree). DISTINCT, in
    /// document order. Reads the ACTIVE backend's column specifically — the
    /// reader's column — so this is "what's not ready to answer well", not the
    /// inactive-backend A/B/C gap (that's the backfill worker's job).
    /// (2026-06-19 — Mark caught a doc stalled at 5% showing as "ready".)
    func documentIDsNeedingActiveEmbedding() throws -> [UUID] {
        dbLock.lock(); defer { dbLock.unlock() }
        let activeColumn = EmbeddingBackend.current().vectorColumn
        let stmt = try prepareStatement(sql: """
            SELECT DISTINCT document_id FROM unit_embedding_chunks
            WHERE \(activeColumn) IS NULL
            ORDER BY document_id;
            """)
        defer { sqlite3_finalize(stmt) }
        var ids: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: c)) else { continue }
            ids.append(id)
        }
        return ids
    }

    /// Per-document, per-backend coverage in ONE grouped query. The
    /// `filledByColumn` dict is keyed by each backend's `vectorColumn` name and
    /// holds that document's non-NULL count. Lets the coverage verb show, at a
    /// glance, which specific documents still need a given backend.
    struct DocumentEmbeddingCoverage: Sendable {
        let documentID: UUID
        let total: Int
        let filledByColumn: [String: Int]
    }
    func embeddingCoverageByDocument() throws -> [DocumentEmbeddingCoverage] {
        dbLock.lock(); defer { dbLock.unlock() }
        // Build "SUM(CASE WHEN <col> IS NOT NULL THEN 1 ELSE 0 END)" per backend
        // (columns from the fixed enum → safe to interpolate). One pass, grouped.
        let columns = EmbeddingBackend.allCases.map { $0.vectorColumn }
        let sums = columns
            .map { "SUM(CASE WHEN \($0) IS NOT NULL THEN 1 ELSE 0 END)" }
            .joined(separator: ", ")
        let sql = """
            SELECT document_id, COUNT(*)\(sums.isEmpty ? "" : ", " + sums)
            FROM unit_embedding_chunks
            GROUP BY document_id;
            """
        let stmt = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(stmt) }
        var rows: [DocumentEmbeddingCoverage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idCStr = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idCStr)) else { continue }
            let total = Int(sqlite3_column_int(stmt, 1))
            var filled: [String: Int] = [:]
            for (offset, col) in columns.enumerated() {
                filled[col] = Int(sqlite3_column_int(stmt, Int32(2 + offset)))
            }
            rows.append(.init(documentID: id, total: total, filledByColumn: filled))
        }
        return rows
    }

    /// Count of stored RAPTOR summary nodes for `documentID` (`chunk_index
    /// >= raptorSummaryIndexBase`). `RaptorTreeService.bootstrap` uses this
    /// to skip documents that already have a tree (avoids rebuilding on
    /// every launch) and to find pre-feature documents that need one.
    func raptorSummaryNodeCount(for documentID: UUID) throws -> Int {
        dbLock.lock(); defer { dbLock.unlock() }
        let stmt = try prepareStatement(sql: """
            SELECT COUNT(*) FROM unit_embedding_chunks
            WHERE document_id = ? AND chunk_index >= ?;
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, documentID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(Self.raptorSummaryIndexBase))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Fetch every chunk row for `documentID` (including embedding,
    /// possibly nil). Used by the semantic-pass side of the RRF
    /// hybrid retriever — Swift-side cosine over every row's vector.
    func unitEmbeddingChunks(for documentID: UUID) throws -> [StoredUnitEmbeddingChunk] {
        dbLock.lock(); defer { dbLock.unlock() }
        // Read the ACTIVE backend's column (`current()`), never `writeBackend()`:
        // during a swap the active column is the complete one; the target column
        // is half-built and Ask Posey is locked anyway. `.embedding` on the
        // returned struct therefore always carries the active backend's vector,
        // so every downstream consumer (HybridRetriever, RAPTOR) is correct with
        // no change. Column name is from the fixed `EmbeddingBackend` enum.
        let activeVectorColumn = EmbeddingBackend.current().vectorColumn
        let sql = """
            SELECT id, chunk_index,
                   start_unit_id, start_intra_offset,
                   end_unit_id, end_intra_offset,
                   text, \(activeVectorColumn)
            FROM unit_embedding_chunks
            WHERE document_id = ?
            ORDER BY chunk_index;
            """
        let stmt = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, documentID.uuidString, -1, SQLITE_TRANSIENT)
        var rows: [StoredUnitEmbeddingChunk] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idCStr = sqlite3_column_text(stmt, 0),
                let id = UUID(uuidString: String(cString: idCStr)),
                let startUCStr = sqlite3_column_text(stmt, 2),
                let startU = UUID(uuidString: String(cString: startUCStr)),
                let endUCStr = sqlite3_column_text(stmt, 4),
                let endU = UUID(uuidString: String(cString: endUCStr)),
                let textCStr = sqlite3_column_text(stmt, 6)
            else { continue }
            var embedding: [Double]? = nil
            if sqlite3_column_type(stmt, 7) != SQLITE_NULL,
               let blob = sqlite3_column_blob(stmt, 7) {
                let byteCount = Int(sqlite3_column_bytes(stmt, 7))
                let doubleCount = byteCount / MemoryLayout<Double>.size
                let buffer = blob.assumingMemoryBound(to: Double.self)
                embedding = Array(UnsafeBufferPointer(start: buffer, count: doubleCount))
            }
            rows.append(StoredUnitEmbeddingChunk(
                id: id,
                documentID: documentID,
                chunkIndex: Int(sqlite3_column_int(stmt, 1)),
                startUnitID: startU,
                startIntraOffset: Int(sqlite3_column_int(stmt, 3)),
                endUnitID: endU,
                endIntraOffset: Int(sqlite3_column_int(stmt, 5)),
                text: String(cString: textCStr),
                embedding: embedding
            ))
        }
        return rows
    }

    /// One BM25 search result: the chunk's rowid (which the caller
    /// joins back to `id` via `unitEmbeddingChunkByRowID`) and the
    /// raw BM25 score from FTS5 (lower is better; we negate at
    /// query time for SQL ordering convenience).
    struct UnitEmbeddingChunkBM25Hit: Sendable, Equatable {
        let chunkID: UUID
        let chunkIndex: Int
        /// FTS5 `bm25()` value, untouched. SQLite returns this as
        /// "lower is better" (typical BM25 form negated by FTS5).
        /// Most code wants the SQL `-bm25()` ordering — we expose
        /// the raw value so callers can pick a sign convention.
        let rawBM25: Double
    }

    /// BM25 search over `unit_embedding_chunks_fts` scoped to one
    /// document. `matchExpression` is passed directly to FTS5's
    /// `MATCH` operator — callers are responsible for sanitizing
    /// user input (FTS5 query syntax has its own operators that
    /// can throw if a stray quote appears in a question).
    func bm25Search(
        documentID: UUID,
        matchExpression: String,
        limit: Int
    ) throws -> [UnitEmbeddingChunkBM25Hit] {
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
            SELECT c.id, c.chunk_index, bm25(unit_embedding_chunks_fts) AS score
            FROM unit_embedding_chunks_fts
            JOIN unit_embedding_chunks c ON c.rowid = unit_embedding_chunks_fts.rowid
            WHERE unit_embedding_chunks_fts MATCH ?
              AND c.document_id = ?
            ORDER BY score
            LIMIT ?;
            """
        let stmt = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, matchExpression, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, documentID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var hits: [UnitEmbeddingChunkBM25Hit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idCStr = sqlite3_column_text(stmt, 0),
                let id = UUID(uuidString: String(cString: idCStr))
            else { continue }
            hits.append(UnitEmbeddingChunkBM25Hit(
                chunkID: id,
                chunkIndex: Int(sqlite3_column_int(stmt, 1)),
                rawBM25: sqlite3_column_double(stmt, 2)
            ))
        }
        return hits
    }

    /// One matching chunk for the answer-key authoring tool: the chunk index
    /// plus its ACTUAL stored text (what retrieval searches). Used by
    /// `SEARCH_CHUNKS` so defining-passage quotes for PDFs/CBA are pulled from
    /// Posey's own extracted text, not a divergent raw-file extraction.
    struct UnitEmbeddingChunkTextHit: Sendable, Equatable {
        let chunkIndex: Int
        let text: String
        let rawBM25: Double
    }

    /// BM25 search returning chunk TEXT for `documentID`. `query` is plain
    /// words from the caller; each whitespace token is wrapped in double quotes
    /// so FTS5 treats it as a literal term (no operator injection / no throw on
    /// a stray apostrophe). Read-only.
    func searchUnitEmbeddingChunkTexts(
        documentID: UUID,
        query: String,
        limit: Int = 5
    ) throws -> [UnitEmbeddingChunkTextHit] {
        let terms = query
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"" }
        guard !terms.isEmpty else { return [] }
        let matchExpression = terms.joined(separator: " ")
        dbLock.lock(); defer { dbLock.unlock() }
        let sql = """
            SELECT c.chunk_index, c.text, bm25(unit_embedding_chunks_fts) AS score
            FROM unit_embedding_chunks_fts
            JOIN unit_embedding_chunks c ON c.rowid = unit_embedding_chunks_fts.rowid
            WHERE unit_embedding_chunks_fts MATCH ?
              AND c.document_id = ?
            ORDER BY score
            LIMIT ?;
            """
        let stmt = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, matchExpression, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, documentID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var hits: [UnitEmbeddingChunkTextHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let textCStr = sqlite3_column_text(stmt, 1) else { continue }
            hits.append(UnitEmbeddingChunkTextHit(
                chunkIndex: Int(sqlite3_column_int(stmt, 0)),
                text: String(cString: textCStr),
                rawBM25: sqlite3_column_double(stmt, 2)
            ))
        }
        return hits
    }
}

// ========== BLOCK 11: UNIT EMBEDDING CHUNKS (REBUILD STEP 8) - END ==========

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
