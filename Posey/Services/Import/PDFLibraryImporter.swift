import Foundation

// ========== BLOCK 01: PDF LIBRARY IMPORTER - START ==========

struct PDFLibraryImporter {
    let databaseManager: DatabaseManager
    private let importer = PDFDocumentImporter()

    /// Full synchronous import — parse and persist in one call.
    /// Used for formats where OCR is not needed (fast path).
    func importDocument(from url: URL) throws -> Document {
        let parsed = try importer.loadDocument(from: url)
        return try persistParsedDocument(parsed, from: url)
    }

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "pdf") throws -> Document {
        let parsed = try importer.loadDocument(fromData: rawData)
        return try persistDocument(
            title: parsed.title ?? title,
            fileName: fileName,
            fileType: fileType,
            displayText: parsed.displayText,
            plainText: parsed.plainText
        )
    }

    /// Persist an already-parsed document. Called on the main thread after
    /// async PDF parsing completes. DatabaseManager must stay on main thread.
    func persistParsedDocument(_ parsed: ParsedPDFDocument, from url: URL) throws -> Document {
        try persistDocument(
            title: parsed.title ?? url.deletingPathExtension().lastPathComponent,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            displayText: parsed.displayText,
            plainText: parsed.plainText
        )
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

        return document
    }
}

// ========== BLOCK 02: PDF LIBRARY IMPORTER - PERSISTENCE - END ==========
