import Foundation

struct TXTLibraryImporter {
    let databaseManager: DatabaseManager
    let embeddingIndex: DocumentEmbeddingIndex?
    private let textLoader = TXTDocumentImporter()

    /// Memberwise init with a default for `embeddingIndex` so existing
    /// call sites (and tests) compile unchanged. New callers pass the
    /// index in to enable Ask Posey RAG retrieval at import time.
    init(databaseManager: DatabaseManager,
         embeddingIndex: DocumentEmbeddingIndex? = nil) {
        self.databaseManager = databaseManager
        self.embeddingIndex = embeddingIndex
    }

    func importDocument(from url: URL) throws -> Document {
        let plainText = try textLoader.loadText(from: url)
        return try importNormalizedDocument(
            title: url.deletingPathExtension().lastPathComponent,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            plainText: plainText
        )
    }

    func importDocument(title: String, fileName: String, rawText: String, fileType: String = "txt") throws -> Document {
        let plainText = try textLoader.loadText(fromContents: rawText)
        return try importNormalizedDocument(
            title: title,
            fileName: fileName,
            fileType: fileType,
            plainText: plainText
        )
    }

    private func importNormalizedDocument(title: String, fileName: String, fileType: String, plainText: String) throws -> Document {
        let now = Date()
        let existingDocument = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: plainText
        )

        // 2026-05-21 — Layered content-start detection (same shape as
        // HTML and EPUB importers):
        //   1. Gutenberg `*** START` marker → skip license preamble
        //   2. In-prose TOC region → skip the Contents listing too
        let boundaries = GutenbergBoundaryDetector.detect(in: plainText)
        let gutenbergStart = boundaries.contentStartOffset ?? 0
        // 2026-05-22 — Multi-edition Gutenberg catalog page (illustrated
        // Alice shape). Skip past it before the in-prose TOC detector.
        let postCatalog = GutenbergCatalogDetector.endOfCatalogRegion(in: plainText, after: gutenbergStart) ?? gutenbergStart
        let postTOC = InProseTOCDetector.endOfTOCRegion(in: plainText, after: postCatalog) ?? postCatalog
        let skip = max(postCatalog, postTOC)
        // 2026-05-21 skip-source classification (locked rule).
        let skipSource: String
        if gutenbergStart > 0 {
            skipSource = "gutenberg"
        } else if skip > 0 {
            skipSource = "heuristic"
        } else {
            skipSource = ""
        }

        let document = Document(
            id: existingDocument?.id ?? UUID(),
            title: title,
            fileName: fileName,
            fileType: fileType,
            importedAt: existingDocument?.importedAt ?? now,
            modifiedAt: now,
            displayText: plainText,
            plainText: plainText,
            characterCount: plainText.count,
            playbackSkipUntilOffset: skip,
            contentEndOffset: boundaries.contentEndOffset ?? 0,
            skipSource: skipSource
        )

        try databaseManager.upsertDocument(document)

        if existingDocument == nil {
            try databaseManager.upsertReadingPosition(.initial(for: document.id))
        }

        // Best-effort: build the Ask Posey embedding index. Failure
        // here must NOT fail the import — the document is still
        // perfectly readable without RAG; the index will be retro-built
        // on first Ask Posey invocation if it's missing.
        embeddingIndex?.enqueueIndexing(document)

        return document
    }
}
