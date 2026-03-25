import Foundation
import PDFKit

struct ParsedPDFDocument {
    let title: String?
    let displayText: String
    let plainText: String
}

struct PDFDocumentImporter {
    private static let visualPageMarkerPrefix = "[[POSEY_VISUAL_PAGE:"
    private static let visualPageMarkerSuffix = "]]"

    enum ImportError: LocalizedError, Equatable {
        case unreadableDocument
        case emptyDocument
        case scannedDocument

        var errorDescription: String? {
            switch self {
            case .unreadableDocument:
                return "Posey could not read that PDF file."
            case .emptyDocument:
                return "The PDF file is empty."
            case .scannedDocument:
                return "This PDF appears to be scanned or image-only. Posey can read text-based PDFs in this pass, but OCR support is not implemented yet."
            }
        }
    }

    func loadDocument(from url: URL) throws -> ParsedPDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw ImportError.unreadableDocument
        }

        return try loadDocument(from: document)
    }

    func loadDocument(fromData data: Data) throws -> ParsedPDFDocument {
        guard let document = PDFDocument(data: data) else {
            throw ImportError.unreadableDocument
        }

        return try loadDocument(from: document)
    }

    private func loadDocument(from document: PDFDocument) throws -> ParsedPDFDocument {
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw ImportError.emptyDocument
        }

        enum PageContent {
            case text(String)
            case visualPlaceholder(pageNumber: Int)
        }

        var pageContents: [PageContent] = []
        pageContents.reserveCapacity(pageCount)
        var readableTextPages: [String] = []
        readableTextPages.reserveCapacity(pageCount)

        for index in 0..<pageCount {
            guard let page = document.page(at: index) else {
                continue
            }

            let normalized = normalize(page.string ?? "")
            if normalized.isEmpty == false {
                pageContents.append(.text(normalized))
                readableTextPages.append(normalized)
            } else {
                pageContents.append(.visualPlaceholder(pageNumber: index + 1))
            }
        }

        guard readableTextPages.isEmpty == false else {
            throw ImportError.scannedDocument
        }

        let displayText = pageContents
            .map { pageContent -> String in
                switch pageContent {
                case .text(let text):
                    return text
                case .visualPlaceholder(let pageNumber):
                    return Self.visualPageMarker(for: pageNumber)
                }
            }
            .joined(separator: "\u{000C}")
        let plainText = readableTextPages.joined(separator: "\n\n")
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String

        return ParsedPDFDocument(
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
            displayText: displayText,
            plainText: plainText
        )
    }

    static func visualPageMarker(for pageNumber: Int) -> String {
        "\(visualPageMarkerPrefix)\(pageNumber)\(visualPageMarkerSuffix)"
    }

    static func visualPageNumber(from marker: String) -> Int? {
        guard marker.hasPrefix(visualPageMarkerPrefix), marker.hasSuffix(visualPageMarkerSuffix) else {
            return nil
        }

        let startIndex = marker.index(marker.startIndex, offsetBy: visualPageMarkerPrefix.count)
        let endIndex = marker.index(marker.endIndex, offsetBy: -visualPageMarkerSuffix.count)
        return Int(marker[startIndex..<endIndex])
    }

    private func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n(?!\n)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"[ ]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
