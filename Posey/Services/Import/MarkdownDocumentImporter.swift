import Foundation

struct MarkdownDocumentImporter {
    enum ImportError: LocalizedError, Equatable {
        case emptyDocument

        var errorDescription: String? {
            switch self {
            case .emptyDocument:
                return "The Markdown file is empty."
            }
        }
    }

    private let parser = MarkdownParser()

    func loadDocument(from url: URL) throws -> ParsedMarkdownDocument {
        let source = try String(contentsOf: url, encoding: .utf8)
        return try loadDocument(fromContents: source)
    }

    func loadDocument(fromContents source: String) throws -> ParsedMarkdownDocument {
        let parsed = parser.parse(markdown: source)
        guard parsed.plainText.isEmpty == false else {
            throw ImportError.emptyDocument
        }
        return parsed
    }
}
