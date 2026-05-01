import Foundation

// ========== BLOCK 01: PDF LIBRARY IMPORTER - START ==========

struct PDFLibraryImporter {
    let databaseManager: DatabaseManager
    let embeddingIndex: DocumentEmbeddingIndex?
    private let importer = PDFDocumentImporter()

    init(databaseManager: DatabaseManager,
         embeddingIndex: DocumentEmbeddingIndex? = nil) {
        self.databaseManager = databaseManager
        self.embeddingIndex = embeddingIndex
    }

    /// Full synchronous import — parse and persist in one call.
    /// Used for formats where OCR is not needed (fast path).
    func importDocument(from url: URL) throws -> Document {
        let parsed = try importer.loadDocument(from: url)
        return try persistParsedDocument(parsed, from: url)
    }

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "pdf") throws -> Document {
        let parsed = try importer.loadDocument(fromData: rawData)
        let doc = try persistDocument(
            title: parsed.title ?? title,
            fileName: fileName,
            fileType: fileType,
            displayText: parsed.displayText,
            plainText: parsed.plainText,
            playbackSkipUntilOffset: parsed.tocSkipUntilOffset
        )
        try saveImages(parsed.images, for: doc.id)
        try saveTOCEntries(parsed.tocEntries, for: doc.id)
        return doc
    }

    /// Persist an already-parsed document. Called on the main thread after
    /// async PDF parsing completes. DatabaseManager must stay on main thread.
    func persistParsedDocument(_ parsed: ParsedPDFDocument, from url: URL) throws -> Document {
        // Strip duplicate file extensions (e.g. "report.pdf.pdf" → "report.pdf")
        // so the title fallback and stored fileName are clean.
        let rawFilename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let withoutExt = (rawFilename as NSString).deletingPathExtension
        let fileName = (withoutExt as NSString).pathExtension.lowercased() == ext ? withoutExt : rawFilename
        let titleFallback = (fileName as NSString).deletingPathExtension

        let doc = try persistDocument(
            title: parsed.title ?? titleFallback,
            fileName: fileName,
            fileType: ext,
            displayText: parsed.displayText,
            plainText: parsed.plainText,
            playbackSkipUntilOffset: parsed.tocSkipUntilOffset
        )
        try saveImages(parsed.images, for: doc.id)
        try saveTOCEntries(parsed.tocEntries, for: doc.id)
        return doc
    }
}

// ========== BLOCK 01: PDF LIBRARY IMPORTER - END ==========

// ========== BLOCK 02: PDF LIBRARY IMPORTER - PERSISTENCE - START ==========

extension PDFLibraryImporter {
    private func persistDocument(
        title: String,
        fileName: String,
        fileType: String,
        displayText: String,
        plainText: String,
        playbackSkipUntilOffset: Int = 0
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
            characterCount: plainText.count,
            playbackSkipUntilOffset: playbackSkipUntilOffset
        )

        try databaseManager.upsertDocument(document)

        if existing == nil {
            try databaseManager.upsertReadingPosition(.initial(for: document.id))
        }

        // Ask Posey embedding index — best-effort (logs on failure).
        // PDFs can be very long and the embedding step is synchronous;
        // if it ever becomes a perceptible UI freeze on the largest
        // documents we'll move it to a background Task. Tracked in
        // NEXT.md.
        embeddingIndex?.tryIndex(document)

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

    /// Persist TOC entries via the existing `document_toc` table. The
    /// shared insert path deduplicates and rewrites on every import.
    private func saveTOCEntries(_ entries: [PDFTOCEntry], for documentID: UUID) throws {
        let stored = entries.map {
            StoredTOCEntry(title: $0.title, plainTextOffset: $0.plainTextOffset, playOrder: $0.playOrder)
        }
        try databaseManager.insertTOCEntries(stored, for: documentID)
    }
}

// ========== BLOCK 02: PDF LIBRARY IMPORTER - PERSISTENCE - END ==========
