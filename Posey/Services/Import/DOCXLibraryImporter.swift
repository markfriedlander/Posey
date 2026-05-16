import Foundation

struct DOCXLibraryImporter {
    let databaseManager: DatabaseManager
    let embeddingIndex: DocumentEmbeddingIndex?
    private let textLoader = DOCXDocumentImporter()

    init(databaseManager: DatabaseManager,
         embeddingIndex: DocumentEmbeddingIndex? = nil) {
        self.databaseManager = databaseManager
        self.embeddingIndex = embeddingIndex
    }

    func importDocument(from url: URL) throws -> Document {
        // 2026-05-16 (B8) — Reject anything that isn't ZIP-shaped.
        try FormatPrecheck.checkDOCX(url: url)
        let parsed = try textLoader.loadDocument(from: url)
        return try importNormalizedDocument(
            title: url.deletingPathExtension().lastPathComponent,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            displayText: parsed.displayText,
            plainText: parsed.plainText,
            images: parsed.images,
            headings: parsed.headings
        )
    }

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "docx") throws -> Document {
        let parsed = try textLoader.loadDocument(fromData: rawData)
        return try importNormalizedDocument(
            title: title,
            fileName: fileName,
            fileType: fileType,
            displayText: parsed.displayText,
            plainText: parsed.plainText,
            images: parsed.images,
            headings: parsed.headings
        )
    }

    private func importNormalizedDocument(
        title: String,
        fileName: String,
        fileType: String,
        displayText: String,
        plainText: String,
        images: [PageImageRecord],
        headings: [DOCXDocumentImporter.DOCXHeadingEntry]
    ) throws -> Document {
        let now = Date()
        let existingDocument = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: plainText
        )

        // 2026-05-07 (parity #6 closure): TOC playback skip.
        // If the doc has a heading whose title is "Contents" or
        // "Table of Contents" (case-insensitive), set the playback
        // skip offset to the next heading after it. Mirrors PDF/EPUB
        // skip-on-playback behavior for DOCX. Without this, TTS reads
        // "Table of contents" out loud at the start of every doc that
        // has one.
        let tocSkipUntilOffset = TOCSkipDetector.skipOffset(
            for: headings.map { (title: $0.title, plainTextOffset: $0.plainTextOffset) },
            in: plainText
        )

        let document = Document(
            id: existingDocument?.id ?? UUID(),
            title: title,
            fileName: fileName,
            fileType: fileType,
            importedAt: existingDocument?.importedAt ?? now,
            modifiedAt: now,
            displayText: displayText,
            plainText: plainText,
            characterCount: plainText.count,
            playbackSkipUntilOffset: tocSkipUntilOffset
        )

        try databaseManager.upsertDocument(document)

        // Persist inline images. Drop any prior images first so
        // reimports don't accumulate orphans.
        try databaseManager.deleteImages(for: document.id)
        for image in images {
            try databaseManager.insertImage(id: image.imageID, documentID: document.id, data: image.data)
        }

        // 2026-05-06 — Persist heading-style paragraphs as TOC entries.
        // The extractor surfaced (level, title, plainTextOffset) for
        // every paragraph styled as Heading1-9 or Title. Only insert
        // if at least one heading was found.
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

        // Ask Posey embedding index — best-effort (logs on failure).
        embeddingIndex?.enqueueIndexing(document)

        return document
    }
}
