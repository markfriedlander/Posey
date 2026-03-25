import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct DOCXDocumentImporter {
    enum ImportError: LocalizedError, Equatable {
        case unreadableDocument
        case emptyDocument

        var errorDescription: String? {
            switch self {
            case .unreadableDocument:
                return "Posey could not read that DOCX file."
            case .emptyDocument:
                return "The DOCX file is empty."
            }
        }
    }

    func loadText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return try loadText(fromData: data)
    }

    func loadText(fromData data: Data) throws -> String {
        let archive = try archive(from: data)
        let documentXML = try archive.entryData(named: "word/document.xml")
        let extractedText = try WordDocumentXMLExtractor.extractText(from: documentXML)
        let normalized = normalize(extractedText)
        guard normalized.isEmpty == false else {
            throw ImportError.emptyDocument
        }
        return normalized
    }

    private func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func archive(from data: Data) throws -> ZIPArchive {
        do {
            return try ZIPArchive(data: data)
        } catch {
            throw ImportError.unreadableDocument
        }
    }
}

private final class WordDocumentXMLExtractor: NSObject, XMLParserDelegate {
    private var paragraphs: [String] = []
    private var currentParagraph = ""
    private var currentRun = ""
    private var insideTextNode = false

    static func extractText(from data: Data) throws -> String {
        let extractor = WordDocumentXMLExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor

        guard parser.parse() else {
            throw DOCXDocumentImporter.ImportError.unreadableDocument
        }

        return extractor.paragraphs.joined(separator: "\n\n")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName _: String?, attributes _: [String: String] = [:]) {
        if matches(elementName, suffix: "t") {
            insideTextNode = true
            currentRun = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideTextNode {
            currentRun.append(string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        if matches(elementName, suffix: "t") {
            currentParagraph.append(currentRun)
            currentRun = ""
            insideTextNode = false
            return
        }

        if matches(elementName, suffix: "tab") {
            currentParagraph.append("\t")
            return
        }

        if matches(elementName, suffix: "br") || matches(elementName, suffix: "cr") {
            currentParagraph.append("\n")
            return
        }

        if matches(elementName, suffix: "p") {
            let paragraph = currentParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if paragraph.isEmpty == false {
                paragraphs.append(paragraph)
            }
            currentParagraph = ""
        }
    }

    private func matches(_ elementName: String, suffix: String) -> Bool {
        elementName == suffix || elementName.hasSuffix(":\(suffix)")
    }
}
