import Foundation

struct PDFLibraryImporter {
    let databaseManager: DatabaseManager
    private let importer = PDFDocumentImporter()

    func importDocument(from url: URL) throws -> Document {
        let parsed = try importer.loadDocument(from: url)
        return try importParsedDocument(
            title: parsed.title ?? url.deletingPathExtension().lastPathComponent,
            fileName: url.lastPathComponent,
            fileType: url.pathExtension.lowercased(),
            displayText: parsed.displayText,
            plainText: parsed.plainText
        )
    }

    func importDocument(title: String, fileName: String, rawData: Data, fileType: String = "pdf") throws -> Document {
        let parsed = try importer.loadDocument(fromData: rawData)
        return try importParsedDocument(
            title: parsed.title ?? title,
            fileName: fileName,
            fileType: fileType,
            displayText: parsed.displayText,
            plainText: parsed.plainText
        )
    }

    private func importParsedDocument(title: String, fileName: String, fileType: String, displayText: String, plainText: String) throws -> Document {
        let now = Date()
        let existingDocument = try databaseManager.existingDocument(
            matchingFileName: fileName,
            fileType: fileType,
            plainText: plainText,
            displayText: displayText
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

        if existingDocument == nil {
            try databaseManager.upsertReadingPosition(.initial(for: document.id))
        }

        return document
    }
}
