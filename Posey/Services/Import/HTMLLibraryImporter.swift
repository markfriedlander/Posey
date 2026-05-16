import Foundation

struct HTMLLibraryImporter {
    let databaseManager: DatabaseManager
    let embeddingIndex: DocumentEmbeddingIndex?
    private let importer = HTMLDocumentImporter()

    init(databaseManager: DatabaseManager,
         embeddingIndex: DocumentEmbeddingIndex? = nil) {
        self.databaseManager = databaseManager
        self.embeddingIndex = embeddingIndex
    }

    func importDocument(from url: URL) throws -> Document {
        // 2026-05-16 (B8) — Reject binary content at the door.
        try FormatPrecheck.checkTextLike(url: url, declaredType: "html")
        // Task 8 #4 (2026-05-03): URL-based import resolves inline
        // <img> references against the file's containing directory.
        // The resulting document carries a separate displayText (with
        // [[POSEY_VISUAL_PAGE:0:uuid]] markers) and plainText (markers
        // stripped, suitable for TTS + embeddings).
        let parsed = try importer.loadDocument(from: url)
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

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "html") throws -> Document {
        // Data-based import (e.g. via local API upload): no
        // surrounding directory means we can't resolve relative
        // <img> paths. Falls back to plain-text-only extraction;
        // inline images carried as data: URIs would still need
        // additional code to surface — punted as a Mark-review
        // item if it ever matters. Documented in NEXT.md.
        let plainText = try importer.loadText(fromData: rawData)
        // 2026-05-06 (parity #3): heading extraction works on raw HTML
        // and is independent of the inline-image extraction path, so
        // it works on data-based import too.
        let headings = importer.extractHeadings(fromRawData: rawData)
        return try importNormalizedDocument(
            title: title,
            fileName: fileName,
            fileType: fileType,
            displayText: plainText,
            plainText: plainText,
            images: [],
            headings: headings
        )
    }

    private func importNormalizedDocument(
        title: String,
        fileName: String,
        fileType: String,
        displayText: String,
        plainText: String,
        images: [PageImageRecord],
        headings: [HTMLDocumentImporter.HTMLHeadingEntry]
    ) throws -> Document {
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
            displayText: displayText,
            plainText: plainText,
            characterCount: plainText.count
        )

        try databaseManager.upsertDocument(document)

        // Task 8 #4: persist inline images. Drop any prior images
        // first so reimports don't accumulate orphans.
        try databaseManager.deleteImages(for: document.id)
        for image in images {
            try databaseManager.insertImage(id: image.imageID, documentID: document.id, data: image.data)
        }

        // 2026-05-06 (parity #3): persist HTML headings as TOC entries
        // with their level. The plainText offset is found by sequential
        // search — each heading is matched left-to-right starting from
        // the cursor of the previous match so duplicates in the body
        // (e.g. "Introduction" appearing in both a heading and a later
        // paragraph) don't all collapse to the same offset.
        if !headings.isEmpty {
            let stored = resolveHeadingOffsets(headings, in: plainText)
            if !stored.isEmpty {
                try databaseManager.insertTOCEntries(stored, for: document.id)
            }
        }

        if existingDocument == nil {
            try databaseManager.upsertReadingPosition(.initial(for: document.id))
        }

        // Ask Posey embedding index — best-effort (logs on failure).
        embeddingIndex?.enqueueIndexing(document)

        return document
    }

    /// For each `HTMLHeadingEntry`, find its title in `plainText`
    /// starting from the running cursor. Skips a heading whose title
    /// can't be located. Returns `StoredTOCEntry` rows in document
    /// order with sequential `playOrder`.
    private func resolveHeadingOffsets(
        _ headings: [HTMLDocumentImporter.HTMLHeadingEntry],
        in plainText: String
    ) -> [StoredTOCEntry] {
        var out: [StoredTOCEntry] = []
        var cursor = plainText.startIndex
        var order = 0
        for h in headings {
            let needle = h.title
            guard !needle.isEmpty,
                  cursor <= plainText.endIndex,
                  let range = plainText.range(of: needle, range: cursor..<plainText.endIndex) else {
                continue
            }
            let offset = plainText.distance(from: plainText.startIndex, to: range.lowerBound)
            order += 1
            out.append(StoredTOCEntry(
                title: needle,
                plainTextOffset: offset,
                playOrder: order,
                level: h.level
            ))
            cursor = range.upperBound
        }
        return out
    }
}
