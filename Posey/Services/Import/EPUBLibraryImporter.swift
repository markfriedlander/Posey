import Foundation

// ========== BLOCK 01: EPUB LIBRARY IMPORTER - START ==========

struct EPUBLibraryImporter {
    let databaseManager: DatabaseManager
    let embeddingIndex: DocumentEmbeddingIndex?
    private let importer = EPUBDocumentImporter()

    init(databaseManager: DatabaseManager,
         embeddingIndex: DocumentEmbeddingIndex? = nil) {
        self.databaseManager = databaseManager
        self.embeddingIndex = embeddingIndex
    }

    func importDocument(from url: URL) throws -> Document {
        let parsed = try importer.loadDocument(from: url)
        let doc = try persistParsedDocument(
            title: parsed.title ?? url.deletingPathExtension().lastPathComponent,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            displayText: parsed.displayText,
            plainText: parsed.plainText
        )
        try saveImages(parsed.images, for: doc.id)
        try saveTOC(parsed.tocEntries, for: doc.id)
        return doc
    }

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "epub") throws -> Document {
        let parsed = try importer.loadDocument(fromData: rawData)
        let doc = try persistParsedDocument(
            title: parsed.title ?? title,
            fileName: fileName,
            fileType: fileType,
            displayText: parsed.displayText,
            plainText: parsed.plainText
        )
        try saveImages(parsed.images, for: doc.id)
        try saveTOC(parsed.tocEntries, for: doc.id)
        return doc
    }
}

// ========== BLOCK 01: EPUB LIBRARY IMPORTER - END ==========

// ========== BLOCK 02: EPUB LIBRARY IMPORTER - PERSISTENCE - START ==========

extension EPUBLibraryImporter {

    private func persistParsedDocument(
        title: String,
        fileName: String,
        fileType: String,
        displayText: String,
        plainText: String
    ) throws -> Document {
        let now = Date()
        let existing = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: plainText,
            displayText: displayText
        )

        let document = Document(
            id: existing?.id ?? UUID(),
            title: title,
            fileName: fileName,
            fileType: fileType,
            importedAt: existing?.importedAt ?? now,
            modifiedAt: now,
            displayText: displayText,
            plainText: plainText,
            characterCount: plainText.count
        )

        try databaseManager.upsertDocument(document)

        if existing == nil {
            try databaseManager.upsertReadingPosition(.initial(for: document.id))
        }

        // Ask Posey embedding index — best-effort.
        try? embeddingIndex?.indexIfNeeded(document)

        return document
    }

    /// Delete stale image records then insert the new set. Called after every
    /// import so reimports don't leave orphaned blobs under old image IDs.
    private func saveImages(_ images: [PageImageRecord], for documentID: UUID) throws {
        try databaseManager.deleteImages(for: documentID)
        for image in images {
            try databaseManager.insertImage(id: image.imageID, documentID: documentID, data: image.data)
        }
    }

    /// Persist TOC entries from a freshly parsed EPUB. Replaces any existing
    /// entries so reimports stay current.
    private func saveTOC(_ entries: [EPUBTOCEntry], for documentID: UUID) throws {
        let stored = entries.map {
            StoredTOCEntry(title: $0.title, plainTextOffset: $0.plainTextOffset, playOrder: $0.playOrder)
        }
        try databaseManager.insertTOCEntries(stored, for: documentID)
    }
}

// ========== BLOCK 02: EPUB LIBRARY IMPORTER - PERSISTENCE - END ==========
