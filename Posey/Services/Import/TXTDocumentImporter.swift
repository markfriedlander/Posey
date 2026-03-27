import Foundation

struct TXTDocumentImporter {
    enum ImportError: LocalizedError {
        case unsupportedEncoding
        case emptyDocument

        var errorDescription: String? {
            switch self {
            case .unsupportedEncoding:
                return "Posey could not read that TXT file."
            case .emptyDocument:
                return "The TXT file is empty."
            }
        }
    }

    func loadText(from url: URL) throws -> String {
        for encoding in [String.Encoding.utf8, .unicode, .utf16, .utf16LittleEndian, .utf16BigEndian, .ascii, .isoLatin1] {
            if let text = try? String(contentsOf: url, encoding: encoding) {
                return try loadText(fromContents: text)
            }
        }

        throw ImportError.unsupportedEncoding
    }

    func loadText(fromContents text: String) throws -> String {
        let normalized = normalize(text)
        guard normalized.isEmpty == false else {
            throw ImportError.emptyDocument
        }
        return normalized
    }

    private func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00A0}", with: " ")   // non-breaking space
            .replacingOccurrences(of: "\u{00AD}", with: "")    // Unicode soft hyphen
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
