import Foundation

struct RTFLibraryImporter {
    let databaseManager: DatabaseManager
    let embeddingIndex: DocumentEmbeddingIndex?
    private let textLoader = RTFDocumentImporter()

    init(databaseManager: DatabaseManager,
         embeddingIndex: DocumentEmbeddingIndex? = nil) {
        self.databaseManager = databaseManager
        self.embeddingIndex = embeddingIndex
    }

    func importDocument(from url: URL) throws -> Document {
        let parsed = try textLoader.loadDocument(from: url)
        return try importNormalizedDocument(
            title: url.deletingPathExtension().lastPathComponent,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            plainText: parsed.plainText,
            headings: parsed.headings
        )
    }

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "rtf") throws -> Document {
        let parsed = try textLoader.loadDocument(fromData: rawData)
        return try importNormalizedDocument(
            title: title,
            fileName: fileName,
            fileType: fileType,
            plainText: parsed.plainText,
            headings: parsed.headings
        )
    }

    private func importNormalizedDocument(title: String,
                                          fileName: String,
                                          fileType: String,
                                          plainText: String,
                                          headings: [RTFDocumentImporter.RTFHeadingEntry]) throws -> Document {
        let now = Date()
        let existingDocument = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: plainText
        )

        let document = Document(
            id: existingDocument?.id ?? UUID(),
            title: title,
            fileName: fileName,
            fileType: fileType,
            importedAt: existingDocument?.importedAt ?? now,
            modifiedAt: now,
            displayText: plainText,
            plainText: plainText,
            characterCount: plainText.count
        )

        try databaseManager.upsertDocument(document)

        // 2026-05-06 — Persist heading-styled paragraphs as TOC entries
        // (parity item #1). Only insert if at least one heading was found.
        if !headings.isEmpty {
            let stored = headings.enumerated().map { (idx, h) in
                StoredTOCEntry(
                    title: h.title,
                    plainTextOffset: h.plainTextOffset,
                    playOrder: idx + 1,
                    level: h.level
                )
            }
            try databaseManager.insertTOCEntries(stored, for: document.id)
        }

        if existingDocument == nil {
            try databaseManager.upsertReadingPosition(.initial(for: document.id))
        }

        embeddingIndex?.enqueueIndexing(document)

        return document
    }
}
