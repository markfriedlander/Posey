import Foundation

struct MarkdownLibraryImporter {
    let databaseManager: DatabaseManager
    private let importer = MarkdownDocumentImporter()

    func importDocument(from url: URL) throws -> Document {
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

        return document
    }
}
