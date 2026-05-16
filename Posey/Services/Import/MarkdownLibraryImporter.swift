import Foundation

struct MarkdownLibraryImporter {
    let databaseManager: DatabaseManager
    let embeddingIndex: DocumentEmbeddingIndex?
    private let importer = MarkdownDocumentImporter()

    init(databaseManager: DatabaseManager,
         embeddingIndex: DocumentEmbeddingIndex? = nil) {
        self.databaseManager = databaseManager
        self.embeddingIndex = embeddingIndex
    }

    func importDocument(from url: URL) throws -> Document {
        // 2026-05-16 (B8) — Reject binary content at the door.
        try FormatPrecheck.checkTextLike(url: url, declaredType: "md")
        let parsed = try importer.loadDocument(from: url)
        return try importParsedDocument(
            title: url.deletingPathExtension().lastPathComponent,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            parsed: parsed
        )
    }

    func importDocument(title: String, fileName: String, rawText: String, fileType: String = "md") throws -> Document {
        let parsed = try importer.loadDocument(fromContents: rawText)
        return try importParsedDocument(
            title: title,
            fileName: fileName,
            fileType: fileType,
            parsed: parsed
        )
    }

    private func importParsedDocument(title: String, fileName: String, fileType: String, parsed: ParsedMarkdownDocument) throws -> Document {
        let now = Date()
        let existingDocument = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: parsed.plainText,
            displayText: parsed.displayText
        )

        let document = Document(
            id: existingDocument?.id ?? UUID(),
            title: title,
            fileName: fileName,
            fileType: fileType,
            importedAt: existingDocument?.importedAt ?? now,
            modifiedAt: now,
            displayText: parsed.displayText,
            plainText: parsed.plainText,
            characterCount: parsed.plainText.count
        )

        try databaseManager.upsertDocument(document)

        if existingDocument == nil {
            try databaseManager.upsertReadingPosition(.initial(for: document.id))
        }

        // 2026-05-06 — Build TOC from heading blocks. Markdown
        // headings are explicit (# / ## / ### lines); the parser
        // already classifies them as `.heading(level: N)` blocks.
        // Take all heading blocks and persist as TOC entries with
        // their plainText offset and parse order.
        let tocEntries: [StoredTOCEntry] = parsed.blocks.enumerated().compactMap { (idx, block) in
            guard case .heading(let level) = block.kind else { return nil }
            return StoredTOCEntry(
                title: block.text,
                plainTextOffset: block.startOffset,
                playOrder: idx + 1,
                level: level
            )
        }
        if !tocEntries.isEmpty {
            try databaseManager.insertTOCEntries(tocEntries, for: document.id)
        }

        // Ask Posey embedding index — best-effort (logs on failure).
        embeddingIndex?.enqueueIndexing(document)

        return document
    }
}
