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

        if existingDocument == nil {
            try databaseManager.upsertReadingPosition(.initial(for: document.id))
        }

        // Best-effort: build the Ask Posey embedding index. Failure
        // here must NOT fail the import — the document is still
        // perfectly readable without RAG; the index will be retro-built
        // on first Ask Posey invocation if it's missing.
        embeddingIndex?.tryIndex(document)

        return document
    }
}
