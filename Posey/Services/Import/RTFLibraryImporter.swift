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
        let plainText = try textLoader.loadText(from: url)
        return try importNormalizedDocument(
            title: url.deletingPathExtension().lastPathComponent,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            plainText: plainText
        )
    }

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "rtf") throws -> Document {
        let plainText = try textLoader.loadText(fromData: rawData)
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

        // Ask Posey embedding index — best-effort (logs on failure).
        embeddingIndex?.tryIndex(document)

        return document
    }
}
