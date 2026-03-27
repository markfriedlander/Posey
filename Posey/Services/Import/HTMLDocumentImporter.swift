import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// ========== BLOCK 1: ERROR TYPES - START ==========
struct HTMLDocumentImporter {
    enum ImportError: LocalizedError, Equatable {
        case unreadableDocument
        case emptyDocument

        var errorDescription: String? {
            switch self {
            case .unreadableDocument:
                return "Posey could not read that HTML file."
            case .emptyDocument:
                return "The HTML file is empty."
            }
        }
    }
// ========== BLOCK 1: ERROR TYPES - END ==========

// ========== BLOCK 2: IMPORT ENTRY POINTS - START ==========
    func loadText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return try loadText(fromData: data)
    }

    /// NSAttributedString HTML parsing uses WebKit internally under UIKit and
    /// must be called on the main thread. This method asserts that requirement
    /// so violations surface immediately rather than as subtle threading bugs.
    func loadText(fromData data: Data) throws -> String {
        #if canImport(UIKit)
        dispatchPrecondition(condition: .onQueue(.main))
        #endif

        // Pre-inject paragraph markers before closing block-level tags.
        // NSAttributedString collapses <p>…</p> boundaries to a single \n,
        // merging consecutive paragraphs into one undifferentiated block.
        // U+E001 (Private Use Area) survives the HTML → plain-text conversion
        // as literal text content; after extraction it becomes \n, so each
        // block boundary yields (our \n)(NSAttributedString's own \n) = \n\n.
        let markedData = injectParagraphMarkers(data)

        let attributedString: NSAttributedString
        do {
            attributedString = try NSAttributedString(
                data: markedData,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
            )
        } catch {
            throw ImportError.unreadableDocument
        }

        let rawText = attributedString.string
            .replacingOccurrences(of: "\u{E001}", with: "\n")
        let normalized = normalize(rawText)
        guard normalized.isEmpty == false else {
            throw ImportError.emptyDocument
        }

        return normalized
    }

    /// Inserts U+E001 before each closing block-level tag in the raw HTML so
    /// that paragraph boundaries produce \n\n in the final plain text rather
    /// than the single \n that NSAttributedString emits for each <p> end.
    private func injectParagraphMarkers(_ data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8) ??
                         String(data: data, encoding: .isoLatin1) else {
            return data
        }
        let blockTags = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote"]
        for tag in blockTags {
            html = html.replacingOccurrences(
                of: "</\(tag)>",
                with: "\u{E001}</\(tag)>",
                options: .caseInsensitive
            )
        }
        return html.data(using: .utf8) ?? data
    }
// ========== BLOCK 2: IMPORT ENTRY POINTS - END ==========

// ========== BLOCK 3: TEXT NORMALIZATION - START ==========
    private func normalize(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ")   // non-breaking space
        t = t.replacingOccurrences(of: "\u{00AD}", with: "")    // Unicode soft hyphen (invisible; strip entirely)
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        t = t.replacingOccurrences(of: "\r",   with: "\n")
        t = t.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        t = collapseLineBreakHyphens(t)                         // "word-\nword" → "wordword" (EPUB/HTML line-break hyphens)
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapses line-break hyphenation: "fas-\ncism" or "fas- cism" → "fascism".
    /// Only fires when a lowercase continuation follows "- " or "-\n",
    /// distinguishing line-break splits from intentional compound words like "anti-fascist".
    private func collapseLineBreakHyphens(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"([A-Za-z]+)-[ \n]([a-z]+)"#) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1$2"
        )
    }
}
// ========== BLOCK 3: TEXT NORMALIZATION - END ==========
