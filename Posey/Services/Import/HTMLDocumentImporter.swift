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

        let attributedString: NSAttributedString

        do {
            attributedString = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
            )
        } catch {
            throw ImportError.unreadableDocument
        }

        let normalized = normalize(attributedString.string)
        guard normalized.isEmpty == false else {
            throw ImportError.emptyDocument
        }

        return normalized
    }
// ========== BLOCK 2: IMPORT ENTRY POINTS - END ==========

// ========== BLOCK 3: TEXT NORMALIZATION - START ==========
    private func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
// ========== BLOCK 3: TEXT NORMALIZATION - END ==========
