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
        SELECT id, title, file_name, file_type, imported_at, modified_at, display_text, plain_text, character_count, playback_skip_until_offset, content_end_offset, skip_source
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
                playbackSkipUntilOffset: Int(sqlite3_column_int64(statement, 9)),
                contentEndOffset: Int(sqlite3_column_int64(statement, 10)),
                skipSource: sqliteString(statement, index: 11) ?? ""
            ))
        }
        return documents
    }

    func upsertDocument(_ document: Document) throws {
        let sql = """
        INSERT INTO documents (id, title, file_name, file_type, imported_at, modified_at, display_text, plain_text, character_count, playback_skip_until_offset, content_end_offset, skip_source)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            file_name = excluded.file_name,
            file_type = excluded.file_type,
            imported_at = excluded.imported_at,
            modified_at = excluded.modified_at,
            display_text = excluded.display_text,
            plain_text = excluded.plain_text,
            character_count = excluded.character_count,
            playback_skip_until_offset = excluded.playback_skip_until_offset,
            content_end_offset = excluded.content_end_offset,
            skip_source = excluded.skip_source;
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
        sqlite3_bind_int64(statement, 11, sqlite3_int64(document.contentEndOffset))
        try bind(document.skipSource, at: 12, for: statement)

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
        SELECT id, title, file_name, file_type, imported_at, modified_at, display_text, plain_text, character_count, playback_skip_until_offset, content_end_offset, skip_source
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
            playbackSkipUntilOffset: Int(sqlite3_column_int64(statement, 9)),
            contentEndOffset: Int(sqlite3_column_int64(statement, 10)),
            skipSource: sqliteString(statement, index: 11) ?? ""
        )
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

    /// Insert a single synthetic chunk (e.g., the metadata-prose
    /// chunk produced by `DocumentMetadataChunkSynthesizer`). Picks
    /// `chunk_index = max + 1` so the synthetic chunk lives AFTER
    /// the content chunks and doesn't disturb the front-matter
    /// query (`ORDER BY chunk_index ASC LIMIT N`) which always
    /// returns the document's actual opening chunks.
    ///
    /// Idempotent w.r.t. all synthetic chunks for the document: any
    /// existing chunk whose embedding_kind ends in ":syn-meta" is
    /// deleted before inserting, so re-extraction always leaves a
    /// single canonical synthetic chunk regardless of whether the
    /// embedder for synthetic chunks changes between runs.
    func insertSyntheticChunk(text: String,
                              embedding: [Double],
                              embeddingKind: String,
                              for documentID: UUID) throws {
        // Delete ALL prior synthetic chunks for this document (any
        // kind ending with ":syn-meta"). This handles the case where
        // an earlier extraction used a different base embedder.
        let deleteSQL = """
        DELETE FROM document_chunks
        WHERE document_id = ? AND embedding_kind LIKE '%:syn-meta';
        """
        let deleteStmt = try prepareStatement(sql: deleteSQL)
        try bind(documentID.uuidString, at: 1, for: deleteStmt)
        try step(deleteStmt)
        sqlite3_finalize(deleteStmt)

        // Find the next chunk index (max + 1; 0 if no chunks yet).
        let maxSQL = """
        SELECT COALESCE(MAX(chunk_index), -1) + 1
        FROM document_chunks
        WHERE document_id = ?;
        """
        let maxStmt = try prepareStatement(sql: maxSQL)
        try bind(documentID.uuidString, at: 1, for: maxStmt)
        var nextIndex = 0
        if sqlite3_step(maxStmt) == SQLITE_ROW {
            nextIndex = Int(sqlite3_column_int(maxStmt, 0))
        }
        sqlite3_finalize(maxStmt)

        // Insert.
        let insertSQL = """
        INSERT INTO document_chunks
            (document_id, chunk_index, start_offset, end_offset, text, embedding, embedding_kind)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        let insertStmt = try prepareStatement(sql: insertSQL)
        defer { sqlite3_finalize(insertStmt) }

        try bind(documentID.uuidString, at: 1, for: insertStmt)
        sqlite3_bind_int(insertStmt, 2, Int32(nextIndex))
        // Synthetic chunks have no offset in the source text.
        // Convention: start_offset = end_offset = -1 marks "synthetic;
        // not a slice of plainText." Downstream code that uses these
        // offsets to map back to the document (jump-to-passage) must
        // skip negatives — citation code already shouldn't be linking
        // synthetic chunks to a passage anyway.
        sqlite3_bind_int(insertStmt, 3, -1)
        sqlite3_bind_int(insertStmt, 4, -1)
        try bind(text, at: 5, for: insertStmt)

        // Embedding as Data blob — same encoding pattern as
        // replaceChunks (Doubles → little-endian bytes).
        let bytesPerDouble = MemoryLayout<Double>.size
        var embeddingData = Data(count: embedding.count * bytesPerDouble)
        embeddingData.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            for (i, value) in embedding.enumerated() {
                base.advanced(by: i * bytesPerDouble)
                    .storeBytes(of: value, as: Double.self)
            }
        }
        embeddingData.withUnsafeBytes { rawBuffer -> Void in
            sqlite3_bind_blob(
                insertStmt, 6, rawBuffer.baseAddress,
                Int32(rawBuffer.count), SQLITE_TRANSIENT)
        }

        try bind(embeddingKind, at: 7, for: insertStmt)
        try step(insertStmt)
    }

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
}

// ========== BLOCK 05B: DOCUMENT TOC - END ==========

// ========== BLOCK 05C: DOCUMENT CHUNKS (Ask Posey M2) - START ==========

/// One row of `document_chunks`: a slice of plainText with its
/// pre-computed embedding. Used by Ask Posey for RAG retrieval.
/// Created at import time for every supported format.
///
/// `nonisolated` because the project default is `MainActor` and this
/// value is consumed from `DocumentEmbeddingIndex` (nonisolated) and
/// from XCTest runners off the main actor. Without this annotation,
/// Swift 5 mode emits a forward-compat warning ("main actor-isolated
/// conformance of 'StoredDocumentChunk' to 'Equatable' cannot be used
/// in nonisolated context; this is an error in the Swift 6 language
/// mode"). The type has only `let` properties of `Sendable` types so
/// `nonisolated` is correct and safe.
nonisolated struct StoredDocumentChunk: Equatable, Sendable {
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
    /// 2026-05-22 Phase 2.2 Step 2 — PDF page provenance. First and
    /// last PDF page indices (0-based) that contributed this chunk's
    /// text. Default 0 / 0 for non-PDF chunks and for any chunk where
    /// the importer didn't supply page boundaries. The Phase 2.2
    /// Tier 2 runner uses this to find which chunks belong to a
    /// Vision-rescued page.
    let pageStart: Int
    let pageEnd: Int
    /// 2026-05-22 Phase 2.2 Step 2 — bumps on every enhancement-tier
    /// text update. 0 = original Tier 1 chunk. Read by the embedding
    /// indexer (when Phase 2.2 Step 7 lands) to know when re-embedding
    /// is required.
    let revision: Int
    /// 2026-05-22 Phase 2.2 Step 2 — which extractor produced the
    /// current text. `"tier1"` for PDFKit / non-PDF importers,
    /// `"tier2_vision"` after Vision rescue, `"tier3_afm_repair"`
    /// after AFM fusion correction. Diagnostic; surfaced via LIST_CHUNKS.
    let sourceTier: String

    /// Default-arg init so the wide set of existing call sites can
    /// continue to construct chunks without page provenance — the
    /// defaults are correct for non-PDF formats and for the Tier 1
    /// first-pass case. Phase 2.2 Step 4 wires PDF page boundaries
    /// through this init.
    init(
        chunkIndex: Int,
        startOffset: Int,
        endOffset: Int,
        text: String,
        embedding: [Double],
        embeddingKind: String,
        pageStart: Int = 0,
        pageEnd: Int = 0,
        revision: Int = 0,
        sourceTier: String = "tier1"
    ) {
        self.chunkIndex = chunkIndex
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.text = text
        self.embedding = embedding
        self.embeddingKind = embeddingKind
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.revision = revision
        self.sourceTier = sourceTier
    }
}

extension DatabaseManager {
    /// Replace any existing chunks for `documentID` with `chunks`. Wraps
    /// the replacement in a single SQL transaction so a partial failure
    /// can't leave the index in a half-rebuilt state.
    func replaceChunks(_ chunks: [StoredDocumentChunk], for documentID: UUID) throws {
        try execute("BEGIN TRANSACTION;")
        do {
            try execute("DELETE FROM document_chunks WHERE document_id = '\(documentID.uuidString)';")
            // 2026-05-22 Phase 2.2 Step 2 — bind page provenance +
            // revision + source_tier alongside the existing columns.
            // Defaults on the StoredDocumentChunk init make this
            // safe for non-PDF importers that don't supply page
            // boundaries.
            let insertSQL = """
            INSERT INTO document_chunks
                (document_id, chunk_index, start_offset, end_offset, text, embedding, embedding_kind,
                 page_start, page_end, revision, source_tier)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
                sqlite3_bind_int(statement, 8, Int32(chunk.pageStart))
                sqlite3_bind_int(statement, 9, Int32(chunk.pageEnd))
                sqlite3_bind_int(statement, 10, Int32(chunk.revision))
                try bind(chunk.sourceTier, at: 11, for: statement)
                try step(statement)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // NOTE: `frontMatterChunks(for:limit:)` below still projects only
    // the legacy columns because it deliberately discards the embedding
    // blob and reconstructs chunks for text use only. Phase 2.2 Step 2
    // didn't widen this path because its consumer (Ask Posey front-
    // matter injection) never reads page_start / page_end / revision /
    // source_tier. The chunk objects it returns carry the StoredDocumentChunk
    // defaults for those fields, which is correct for read-only text use.
    /// Return the document's first `limit` chunks (oldest by
    /// chunk_index). Used by the Ask Posey front-matter injection
    /// path: document-scoped invocations always include the title
    /// page so meta-questions ("who wrote this?", "what is this
    /// document about?") get reliable grounding even when the
    /// cosine retrieval misses the front matter.
    func frontMatterChunks(for documentID: UUID, limit: Int) throws -> [StoredDocumentChunk] {
        guard limit > 0 else { return [] }
        let sql = """
        SELECT chunk_index, start_offset, end_offset, text, embedding, embedding_kind
        FROM document_chunks
        WHERE document_id = ?
        ORDER BY chunk_index ASC
        LIMIT \(limit);
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        var chunks: [StoredDocumentChunk] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let chunkIndex = Int(sqlite3_column_int(statement, 0))
            let startOffset = Int(sqlite3_column_int(statement, 1))
            let endOffset = Int(sqlite3_column_int(statement, 2))
            guard let text = sqliteString(statement, index: 3) else { continue }
            // Skip the embedding blob deserialization here — front
            // matter is consumed for its TEXT, not for re-search.
            let kind = sqliteString(statement, index: 5) ?? "unknown"
            chunks.append(StoredDocumentChunk(
                chunkIndex: chunkIndex,
                startOffset: startOffset,
                endOffset: endOffset,
                text: text,
                embedding: [],
                embeddingKind: kind
            ))
        }
        return chunks
    }

    /// 2026-05-05 — Phase B chunk-enhancement queue access.
    ///
    /// One row per content chunk that needs a context note. Excludes
    /// synthetic chunks (chunk_kind ending `:syn-meta`) — those are
    /// already curated metadata and don't need contextual prepends.
    /// Excludes chunks already enhanced (ctx_status = 1) or attempted
    /// and failed (ctx_status = 2; we don't retry refusals).
    ///
    /// The scheduler walks results from this query in the order
    /// provided. The query orders by chunk_index ASC; the scheduler
    /// re-orders by user reading position before processing. Caller
    /// (BackgroundEnhancementScheduler) is responsible for skipping
    /// already-processed entries on its own pointer.
    struct ChunkEnhancementCandidate: Sendable {
        let chunkIndex: Int
        let startOffset: Int
        let endOffset: Int
        let text: String
        let embeddingKind: String
    }

    func unenhancedChunks(for documentID: UUID) throws -> [ChunkEnhancementCandidate] {
        let sql = """
        SELECT chunk_index, start_offset, end_offset, text, embedding_kind
        FROM document_chunks
        WHERE document_id = ?
          AND ctx_status = 0
          AND embedding_kind NOT LIKE '%:syn-meta'
        ORDER BY chunk_index ASC;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        var rows: [ChunkEnhancementCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let idx = Int(sqlite3_column_int(statement, 0))
            let start = Int(sqlite3_column_int(statement, 1))
            let end = Int(sqlite3_column_int(statement, 2))
            guard let text = sqliteString(statement, index: 3) else { continue }
            let kind = sqliteString(statement, index: 4) ?? "unknown"
            rows.append(.init(chunkIndex: idx, startOffset: start,
                              endOffset: end, text: text, embeddingKind: kind))
        }
        return rows
    }

    /// Counts of chunk enhancement progress for a document.
    /// Returns (enhanced, attempted-failed, pending). Pending excludes
    /// synthetic chunks. Used to drive the unified progress ring on
    /// the sparkle icon — the Phase B fraction is enhanced /
    /// (enhanced + pending).
    func chunkEnhancementCounts(for documentID: UUID) throws
        -> (enhanced: Int, failed: Int, pending: Int)
    {
        // Per the ChunkEnhancementSource split:
        //   ctx_status = 1 → AFM-enhanced
        //   ctx_status = 3 → fallback-enhanced
        // Both count as "enhanced" for unified-progress purposes;
        // the diagnostic surface can pull a finer breakdown via
        // chunkEnhancementCountsBySource(for:) below.
        let sql = """
        SELECT
            COALESCE(SUM(CASE WHEN ctx_status IN (1, 3) THEN 1 ELSE 0 END), 0) AS enhanced,
            COALESCE(SUM(CASE WHEN ctx_status = 2 THEN 1 ELSE 0 END), 0) AS failed,
            COALESCE(SUM(CASE WHEN ctx_status = 0 THEN 1 ELSE 0 END), 0) AS pending
        FROM document_chunks
        WHERE document_id = ?
          AND embedding_kind NOT LIKE '%:syn-meta';
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return (0, 0, 0)
        }
        return (
            enhanced: Int(sqlite3_column_int(statement, 0)),
            failed:   Int(sqlite3_column_int(statement, 1)),
            pending:  Int(sqlite3_column_int(statement, 2))
        )
    }

    /// Source-split enhancement counts. Used by the PHASE_B_STATUS
    /// API verb to surface AFM-vs-fallback honestly rather than
    /// hiding the split behind a single "enhanced" number.
    func chunkEnhancementCountsBySource(for documentID: UUID) throws
        -> (afm: Int, fallback: Int, failed: Int, pending: Int)
    {
        let sql = """
        SELECT
            COALESCE(SUM(CASE WHEN ctx_status = 1 THEN 1 ELSE 0 END), 0) AS afm,
            COALESCE(SUM(CASE WHEN ctx_status = 3 THEN 1 ELSE 0 END), 0) AS fallback,
            COALESCE(SUM(CASE WHEN ctx_status = 2 THEN 1 ELSE 0 END), 0) AS failed,
            COALESCE(SUM(CASE WHEN ctx_status = 0 THEN 1 ELSE 0 END), 0) AS pending
        FROM document_chunks
        WHERE document_id = ?
          AND embedding_kind NOT LIKE '%:syn-meta';
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return (0, 0, 0, 0)
        }
        return (
            afm:      Int(sqlite3_column_int(statement, 0)),
            fallback: Int(sqlite3_column_int(statement, 1)),
            failed:   Int(sqlite3_column_int(statement, 2)),
            pending:  Int(sqlite3_column_int(statement, 3))
        )
    }

    /// Source of an enhancement — distinguishes AFM-generated context
    /// notes from deterministic fallback notes. Both result in an
    /// "enhanced" chunk from the user's perspective, but we track
    /// the split so the diagnostic surface can report honestly.
    enum ChunkEnhancementSource: Sendable {
        case afm        // ctx_status = 1
        case fallback   // ctx_status = 3
    }

    /// Save the AFM-generated context note + refresh the embedding
    /// for a single chunk, atomically. ctx_status flips to 1 (AFM-
    /// enhanced) or 3 (fallback-enhanced) per `source`. If `embedding`
    /// is empty, only the note is stored and ctx_status stays at its
    /// current value — the scheduler can retry the embed later.
    func saveChunkEnhancement(documentID: UUID,
                              chunkIndex: Int,
                              contextNote: String,
                              embedding: [Double],
                              source: ChunkEnhancementSource = .afm) throws {
        let statusValue: Int
        switch source {
        case .afm:      statusValue = 1
        case .fallback: statusValue = 3
        }
        let sql = """
        UPDATE document_chunks
        SET context_note = ?,
            embedding = ?,
            ctx_status = \(statusValue)
        WHERE document_id = ? AND chunk_index = ?;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(contextNote, at: 1, for: statement)

        let bytesPerDouble = MemoryLayout<Double>.size
        var data = Data(count: embedding.count * bytesPerDouble)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            for (i, value) in embedding.enumerated() {
                base.advanced(by: i * bytesPerDouble)
                    .storeBytes(of: value, as: Double.self)
            }
        }
        data.withUnsafeBytes { rawBuffer -> Void in
            sqlite3_bind_blob(
                statement, 2, rawBuffer.baseAddress,
                Int32(rawBuffer.count), SQLITE_TRANSIENT)
        }
        try bind(documentID.uuidString, at: 3, for: statement)
        sqlite3_bind_int(statement, 4, Int32(chunkIndex))
        try step(statement)
    }

    /// Mark a chunk as failed-enhancement. Used after AFM refusal so
    /// the scheduler doesn't keep retrying the same chunk.
    func markChunkEnhancementFailed(documentID: UUID,
                                    chunkIndex: Int) throws {
        let sql = """
        UPDATE document_chunks
        SET ctx_status = 2
        WHERE document_id = ? AND chunk_index = ?;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        sqlite3_bind_int(statement, 2, Int32(chunkIndex))
        try step(statement)
    }

    /// Diagnostic-only: return chunks that have been enhancement-touched
    /// (ctx_status != 0) with their stored context note + text preview.
    /// Drives the LIST_ENHANCED_CHUNKS local-API verb so we can verify
    /// the scheduler's outputs from the Python harness.
    struct EnhancedChunkRecord: Sendable {
        let chunkIndex: Int
        let startOffset: Int
        let ctxStatus: Int
        let contextNote: String?
        let text: String
    }

    func enhancedChunkRecords(for documentID: UUID, limit: Int = 20) throws
        -> [EnhancedChunkRecord]
    {
        let sql = """
        SELECT chunk_index, start_offset, ctx_status, context_note, text
        FROM document_chunks
        WHERE document_id = ? AND ctx_status != 0
        ORDER BY chunk_index ASC
        LIMIT \(max(1, limit));
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        var rows: [EnhancedChunkRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let idx = Int(sqlite3_column_int(statement, 0))
            let off = Int(sqlite3_column_int(statement, 1))
            let status = Int(sqlite3_column_int(statement, 2))
            let note = sqliteString(statement, index: 3)
            let text = sqliteString(statement, index: 4) ?? ""
            rows.append(.init(chunkIndex: idx, startOffset: off,
                              ctxStatus: status, contextNote: note, text: text))
        }
        return rows
    }

    /// Reset all failed-enhancement chunks (ctx_status=2) back to
    /// pending (ctx_status=0). Used after iterating on the enhancer
    /// prompt: the previously-refused chunks become pending again
    /// and will be retried by the scheduler with the new prompt.
    /// Only resets ctx_status=2 — successful enhancements (1) keep
    /// their context note and embedding intact.
    func resetFailedChunks(for documentID: UUID) throws -> Int {
        let sql = """
        UPDATE document_chunks
        SET ctx_status = 0
        WHERE document_id = ? AND ctx_status = 2;
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        try step(statement)
        return Int(sqlite3_changes(database))
    }

    /// Documents in the library that have any pending chunks (not
    /// enhanced AND not yet attempted). Used by the scheduler to
    /// pick the next document for library-wide traversal.
    func documentsWithPendingChunks() throws -> [UUID] {
        let sql = """
        SELECT DISTINCT document_id
        FROM document_chunks
        WHERE ctx_status = 0
          AND embedding_kind NOT LIKE '%:syn-meta';
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        var ids: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let s = sqliteString(statement, index: 0),
               let u = UUID(uuidString: s) {
                ids.append(u)
            }
        }
        return ids
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
        // 2026-05-22 Phase 2.2 Step 2 — also project page_start /
        // page_end / revision / source_tier so the Tier 2 / Tier 3
        // runners can locate chunks by page and skip already-updated
        // ones. Old rows missing the columns get the table's
        // declared defaults (0 / 0 / 0 / 'tier1').
        let sql = """
        SELECT chunk_index, start_offset, end_offset, text, embedding, embedding_kind,
               page_start, page_end, revision, source_tier
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
            let pageStart  = Int(sqlite3_column_int(statement, 6))
            let pageEnd    = Int(sqlite3_column_int(statement, 7))
            let revision   = Int(sqlite3_column_int(statement, 8))
            let sourceTier = sqliteString(statement, index: 9) ?? "tier1"
            results.append(StoredDocumentChunk(
                chunkIndex: index,
                startOffset: start,
                endOffset: end,
                text: text,
                embedding: embedding,
                embeddingKind: kind,
                pageStart: pageStart,
                pageEnd: pageEnd,
                revision: revision,
                sourceTier: sourceTier
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

    // MARK: - Document entity index (Task 4 #6 B)

    /// Bulk-insert entity → chunk_index rows for a document. Caller
    /// is responsible for de-duping inputs if needed (we do an
    /// INSERT — duplicates would inflate hit counts but not break
    /// retrieval).
    func insertEntities(
        documentID: UUID,
        entries: [(entityLower: String, chunkIndex: Int)]
    ) throws {
        guard !entries.isEmpty else { return }
        let sql = """
        INSERT INTO document_entities (document_id, entity_lower, chunk_index)
        VALUES (?, ?, ?);
        """
        try execute("BEGIN TRANSACTION;")
        do {
            let statement = try prepareStatement(sql: sql)
            defer { sqlite3_finalize(statement) }
            for entry in entries {
                sqlite3_reset(statement)
                try bind(documentID.uuidString, at: 1, for: statement)
                try bind(entry.entityLower, at: 2, for: statement)
                sqlite3_bind_int(statement, 3, Int32(entry.chunkIndex))
                try step(statement)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Drop all entity rows for a document. Called before re-index
    /// so old entries don't accumulate.
    func deleteEntities(for documentID: UUID) throws {
        let sql = "DELETE FROM document_entities WHERE document_id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        try step(statement)
    }

    /// Look up the set of chunk indices that mention any of the
    /// given entity strings (case-insensitive). Empty input → empty
    /// result. Used by the entity-aware retrieval path: when the
    /// user's question contains a named entity, we prefer chunks
    /// that mention that entity over the cosine top-K.
    func chunkIndicesMentioningEntities(
        documentID: UUID,
        entitiesLower: [String]
    ) throws -> Set<Int> {
        guard !entitiesLower.isEmpty else { return [] }
        // Build a parameterized IN-list; each ? is one entity.
        let placeholders = Array(repeating: "?", count: entitiesLower.count).joined(separator: ",")
        let sql = """
        SELECT DISTINCT chunk_index
        FROM document_entities
        WHERE document_id = ? AND entity_lower IN (\(placeholders));
        """
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        for (i, entity) in entitiesLower.enumerated() {
            try bind(entity, at: Int32(2 + i), for: statement)
        }
        var results: Set<Int> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.insert(Int(sqlite3_column_int(statement, 0)))
        }
        return results
    }
}

// ========== BLOCK 05C: DOCUMENT CHUNKS (Ask Posey M2) - END ==========

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

extension DatabaseManager {
    /// Append a single turn to the persistent conversation log for
    /// `documentID`. Called both for user turns (immediately on send)
    /// and assistant turns (after streaming completes). Writing each
    /// side individually rather than as a paired transaction keeps the
    /// model honest about partial responses — if AFM crashes mid-
    /// stream, the user turn is still on disk and can be retried.
    func appendAskPoseyTurn(_ turn: StoredAskPoseyTurn) throws {
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

    /// Return non-summary conversation turns for a document, oldest-first.
    /// `limit == nil` returns every turn; positive `limit` caps to the
    /// most recent N rows (still returned oldest-first so the prompt
    /// builder can append them in chronological order).
    ///
    /// Summary rows are intentionally excluded — they live in the
    /// `conversationSummary` slot of the prompt, not the verbatim STM
    /// slot. Use `askPoseyLatestSummary(for:)` for those.
    func askPoseyTurns(for documentID: UUID, limit: Int? = nil) throws -> [StoredAskPoseyTurn] {
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
        // 2026-05-05 — Phase B per-chunk contextual retrieval state.
        // context_note: AFM-generated 1-2 sentence prepend describing
        //   the chunk's topic and document position. Stored separately
        //   from `text` so we can re-embed without recomputing the
        //   note (rare; embedder upgrades).
        // ctx_status: enhancement state machine.
        //   0 = not enhanced (default), 1 = enhanced (context_note +
        //   embedding refreshed), 2 = enhancement attempted and
        //   failed (e.g., AFM refused; don't keep retrying).
        try addColumnIfNeeded(table: "document_chunks", column: "context_note", definition: "TEXT")
        try addColumnIfNeeded(table: "document_chunks", column: "ctx_status", definition: "INTEGER NOT NULL DEFAULT 0")
        try execute("""
            CREATE INDEX IF NOT EXISTS idx_document_chunks_doc
            ON document_chunks(document_id, chunk_index);
            """)

        // ========== Task 4 #6 (B) — entity index ==========
        // Maps every named entity (NLTagger.nameType: person, place,
        // organization) found in any chunk to that chunk's index.
        // Lets retrieval skip cosine entirely when the user's
        // question contains a known entity — far more reliable for
        // identity / character / place questions than sentence
        // embedding similarity, especially on long fiction where
        // a chunk that establishes "Joe Malik is a journalist…"
        // doesn't lexically resemble "Who is Joe Malik?".
        try execute("""
            CREATE TABLE IF NOT EXISTS document_entities (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                document_id TEXT NOT NULL,
                entity_lower TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
            );
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS idx_document_entities_lookup
            ON document_entities(document_id, entity_lower);
            """)
        // ========== End Task 4 #6 (B) ==========
        // ========== End Ask Posey Milestone 1 schema additions ==========

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
        try addColumnIfNeeded(table: "documents", column: "content_boundaries", definition: "TEXT NOT NULL DEFAULT '[]'")
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

        // document_chunks — page provenance + revision tracking.
        // page_start / page_end mark which PDF pages contributed
        // this chunk's text. 0 = unknown / non-PDF (existing chunks
        // backfill to 0). Used by Tier 2 to locate the chunks that
        // belong to a rescued page.
        try addColumnIfNeeded(table: "document_chunks", column: "page_start", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfNeeded(table: "document_chunks", column: "page_end", definition: "INTEGER NOT NULL DEFAULT 0")
        // revision bumps every time a chunk's text is updated by
        // an enhancement tier. 0 = original Tier 1. Read by the
        // embedding indexer to know when to re-embed.
        try addColumnIfNeeded(table: "document_chunks", column: "revision", definition: "INTEGER NOT NULL DEFAULT 0")
        // source_tier records which extractor produced the current
        // text: 'tier1' (PDFKit / non-PDF importer), 'tier2_vision'
        // (Vision rescued the page), 'tier3_afm_repair' (AFM
        // corrected a fusion token). Diagnostic; surfaced via
        // LIST_CHUNKS for debugging.
        try addColumnIfNeeded(table: "document_chunks", column: "source_tier", definition: "TEXT NOT NULL DEFAULT 'tier1'")

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

    /// Read the content_boundaries array as `[Int]`. Returns empty
    /// array on missing column or malformed JSON.
    func contentBoundaries(for documentID: UUID) throws -> [Int] {
        let sql = "SELECT content_boundaries FROM documents WHERE id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let json = sqliteString(statement, index: 0),
              let data = json.data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([Int].self, from: data)) ?? []
    }

    /// Write the content_boundaries array. Called once at import
    /// time and updated incrementally by `rewritePageText` as Tier 2
    /// swaps shift downstream offsets.
    func setContentBoundaries(_ boundaries: [Int], for documentID: UUID) throws {
        let data = try JSONEncoder().encode(boundaries)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        let sql = "UPDATE documents SET content_boundaries = ? WHERE id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(json, at: 1, for: statement)
        try bind(documentID.uuidString, at: 2, for: statement)
        try step(statement)
    }

    /// Read plainText for a document. Used by the enhancement service
    /// to compute the current page range before rewriting it.
    func plainText(for documentID: UUID) throws -> String? {
        let sql = "SELECT plain_text FROM documents WHERE id = ?;"
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(documentID.uuidString, at: 1, for: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqliteString(statement, index: 0)
    }

    /// **Atomic per-page text rewrite.** The load-bearing operation for
    /// streaming chunk replacement.
    ///
    /// Given a `documentID`, a `pageIndex`, and `newPageText` produced
    /// by Tier 2 (Vision) — splice the new text into `documents.plainText`
    /// in place of the old page region, replace the affected chunks
    /// with freshly-segmented ones tagged `(pageStart: N, pageEnd: N,
    /// revision: $0.revision + 1, sourceTier: "tier2_vision")`, and
    /// shift the offsets of every downstream reference (later chunks,
    /// notes, bookmarks, reading positions, TOC entries) by the length
    /// delta. Wrapped in a single SQL transaction so a partial failure
    /// can never leave the index in a half-rewritten state.
    ///
    /// Re-segmentation is delegated via the `segmentAndEmbed` closure
    /// because chunk creation requires the embedder (owned by
    /// `DocumentEmbeddingIndex`). The closure receives the new page
    /// text and the chunk-index range it should fill, and returns
    /// fresh `StoredDocumentChunk`s with `chunkIndex` set to whatever
    /// scheme makes sense — this helper renumbers them globally before
    /// inserting.
    ///
    /// **NOTE on displayText:** Step 5 deliberately does NOT splice
    /// displayText. plainText is updated incrementally so RAG sees
    /// the corrected text; displayText is rebuilt by the enhancement
    /// service at end-of-Tier-2 from the corrected per-page text via
    /// a separate write. The reader observes plainText for TTS-pace
    /// material and displayText for visible rendering, so the gap
    /// during enhancement is bounded.
    func rewritePageText(
        documentID: UUID,
        pageIndex: Int,
        newPageText: String,
        sourceTier: String,
        segmentAndEmbed: (String) throws -> [StoredDocumentChunk]
    ) throws -> RewritePageResult {
        // ── Read current state ───────────────────────────────────
        let boundaries = try contentBoundaries(for: documentID)
        guard pageIndex >= 0, pageIndex < boundaries.count else {
            throw DatabaseError.prepareFailed("rewritePageText: pageIndex \(pageIndex) out of range")
        }
        guard let plainText = try plainText(for: documentID) else {
            throw DatabaseError.prepareFailed("rewritePageText: document \(documentID) has no plainText")
        }
        let pageStart = boundaries[pageIndex]
        let pageEnd: Int = (pageIndex + 1 < boundaries.count)
            ? boundaries[pageIndex + 1]
            : plainText.count
        guard pageStart <= plainText.count, pageEnd <= plainText.count, pageStart <= pageEnd else {
            throw DatabaseError.prepareFailed("rewritePageText: bad page bounds [\(pageStart),\(pageEnd)] for plainText length \(plainText.count)")
        }
        let lowerIdx = plainText.index(plainText.startIndex, offsetBy: pageStart)
        let upperIdx = plainText.index(plainText.startIndex, offsetBy: pageEnd)
        let oldPageText = String(plainText[lowerIdx..<upperIdx])
        let delta = newPageText.count - oldPageText.count

        // Existing chunks (full set) so we can determine which ones
        // overlap the page region by offset comparison.
        let allChunks = try chunks(for: documentID)
        let overlapping = allChunks.filter {
            $0.startOffset < pageEnd && $0.endOffset > pageStart
        }
        let downstream = allChunks.filter { $0.startOffset >= pageEnd }
        let upstream = allChunks.filter { $0.endOffset <= pageStart }

        // ── Generate the replacement chunks BEFORE we open the txn ─
        // Re-segmenting is potentially heavy (re-embedding). Do it
        // outside the transaction so the DB lock is held briefly.
        let baseRevision = (overlapping.map(\.revision).max() ?? 0) + 1
        let freshChunks = try segmentAndEmbed(newPageText)

        // Renumber + offset-correct the fresh chunks: they should
        // start at the page's startOffset and be sequentially indexed
        // beginning at the first overlapping chunk's index.
        let firstReplacedIndex = overlapping.first?.chunkIndex ?? upstream.count
        var newChunkRows: [StoredDocumentChunk] = []
        newChunkRows.reserveCapacity(freshChunks.count)
        var cursor = pageStart
        for (i, fc) in freshChunks.enumerated() {
            let chunkStart = cursor
            let chunkEnd = chunkStart + fc.text.count
            cursor = chunkEnd
            newChunkRows.append(StoredDocumentChunk(
                chunkIndex: firstReplacedIndex + i,
                startOffset: chunkStart,
                endOffset: chunkEnd,
                text: fc.text,
                embedding: fc.embedding,
                embeddingKind: fc.embeddingKind,
                pageStart: pageIndex,
                pageEnd: pageIndex,
                revision: baseRevision,
                sourceTier: sourceTier
            ))
        }

        // Downstream chunks get their indices renumbered + offsets
        // shifted by delta.
        let downstreamShifted: [StoredDocumentChunk] = downstream.enumerated().map { (offsetFromStart, c) in
            StoredDocumentChunk(
                chunkIndex: firstReplacedIndex + newChunkRows.count + offsetFromStart,
                startOffset: c.startOffset + delta,
                endOffset: c.endOffset + delta,
                text: c.text,
                embedding: c.embedding,
                embeddingKind: c.embeddingKind,
                pageStart: c.pageStart,
                pageEnd: c.pageEnd,
                revision: c.revision,
                sourceTier: c.sourceTier
            )
        }

        let assembledChunks = upstream + newChunkRows + downstreamShifted

        // ── Splice plainText ─────────────────────────────────────
        var newPlainText = plainText
        newPlainText.replaceSubrange(lowerIdx..<upperIdx, with: newPageText)

        // ── Adjust content_boundaries for subsequent pages ───────
        var newBoundaries = boundaries
        if delta != 0 && pageIndex + 1 < newBoundaries.count {
            for j in (pageIndex + 1)..<newBoundaries.count {
                newBoundaries[j] += delta
            }
        }

        // ── Atomic transaction: write everything together ────────
        try execute("BEGIN TRANSACTION;")
        do {
            // Replace all chunks for this document. `replaceChunks`
            // wraps DELETE + INSERTs in its own transaction
            // semantically; we're inside an outer BEGIN so the rows
            // either all land or all roll back together with the
            // documents + linked-table updates.
            try execute("DELETE FROM document_chunks WHERE document_id = '\(documentID.uuidString)';")
            let insertSQL = """
            INSERT INTO document_chunks
                (document_id, chunk_index, start_offset, end_offset, text, embedding, embedding_kind,
                 page_start, page_end, revision, source_tier)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            for chunk in assembledChunks {
                let statement = try prepareStatement(sql: insertSQL)
                defer { sqlite3_finalize(statement) }
                try bind(documentID.uuidString, at: 1, for: statement)
                sqlite3_bind_int(statement, 2, Int32(chunk.chunkIndex))
                sqlite3_bind_int(statement, 3, Int32(chunk.startOffset))
                sqlite3_bind_int(statement, 4, Int32(chunk.endOffset))
                try bind(chunk.text, at: 5, for: statement)
                let blob = chunk.embedding.withUnsafeBufferPointer { Data(buffer: $0) }
                let bytes = [UInt8](blob)
                if sqlite3_bind_blob(statement, 6, bytes, Int32(bytes.count), SQLITE_TRANSIENT) != SQLITE_OK {
                    throw DatabaseError.bindFailed(lastErrorMessage())
                }
                try bind(chunk.embeddingKind, at: 7, for: statement)
                sqlite3_bind_int(statement, 8, Int32(chunk.pageStart))
                sqlite3_bind_int(statement, 9, Int32(chunk.pageEnd))
                sqlite3_bind_int(statement, 10, Int32(chunk.revision))
                try bind(chunk.sourceTier, at: 11, for: statement)
                try step(statement)
            }

            // Write the new plainText + character_count + content_boundaries.
            let docSQL = """
            UPDATE documents SET
              plain_text = ?,
              character_count = ?,
              content_boundaries = ?
            WHERE id = ?;
            """
            let docStmt = try prepareStatement(sql: docSQL)
            defer { sqlite3_finalize(docStmt) }
            try bind(newPlainText, at: 1, for: docStmt)
            sqlite3_bind_int(docStmt, 2, Int32(newPlainText.count))
            let boundaryJSON = String(
                data: try JSONEncoder().encode(newBoundaries),
                encoding: .utf8
            ) ?? "[]"
            try bind(boundaryJSON, at: 3, for: docStmt)
            try bind(documentID.uuidString, at: 4, for: docStmt)
            try step(docStmt)

            // Shift linked-table offsets that fall AT OR AFTER pageEnd
            // (the splice point). Anything in the rewritten page
            // region is left alone — the user's notes/reading_position
            // inside that page may map to slightly different text now,
            // but the chunk-level mapping makes that survivable.
            // (Notes mid-page falling exactly on a fused token now
            // anchor to the corrected token; an acceptable improvement.)
            if delta != 0 {
                // reading_positions uses character_offset; notes
                // anchors a (start_offset, end_offset) range; toc uses
                // plain_text_offset. Shift any reference that lands at
                // or after the splice point.
                let shiftSQLs: [String] = [
                    "UPDATE reading_positions SET character_offset = character_offset + \(delta) WHERE document_id = ? AND character_offset >= \(pageEnd);",
                    "UPDATE notes SET start_offset = start_offset + \(delta), end_offset = end_offset + \(delta) WHERE document_id = ? AND start_offset >= \(pageEnd);",
                    "UPDATE document_toc SET plain_text_offset = plain_text_offset + \(delta) WHERE document_id = ? AND plain_text_offset >= \(pageEnd);"
                ]
                for sql in shiftSQLs {
                    let s = try prepareStatement(sql: sql)
                    defer { sqlite3_finalize(s) }
                    try bind(documentID.uuidString, at: 1, for: s)
                    try step(s)
                }
            }

            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }

        return RewritePageResult(
            oldPageText: oldPageText,
            newPageTextLength: newPageText.count,
            delta: delta,
            replacedChunkCount: overlapping.count,
            insertedChunkCount: newChunkRows.count
        )
    }

    /// Telemetry returned by `rewritePageText` for logging + caller
    /// state updates.
    struct RewritePageResult: Sendable {
        let oldPageText: String
        let newPageTextLength: Int
        let delta: Int
        let replacedChunkCount: Int
        let insertedChunkCount: Int
    }
}

// ========== BLOCK 08: PHASE 2.2 CONTENT BOUNDARIES + PAGE REWRITE - END ==========

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
