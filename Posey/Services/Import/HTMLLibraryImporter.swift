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
            images: parsed.images
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
        return try importNormalizedDocument(
            title: title,
            fileName: fileName,
            fileType: fileType,
            displayText: plainText,
            plainText: plainText,
            images: []
        )
    }

    private func importNormalizedDocument(
        title: String,
        fileName: String,
        fileType: String,
        displayText: String,
        plainText: String,
        images: [PageImageRecord]
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

        if existingDocument == nil {
            try databaseManager.upsertReadingPosition(.initial(for: document.id))
        }

        // Ask Posey embedding index — best-effort (logs on failure).
        embeddingIndex?.enqueueIndexing(document)

        return document
    }
}
