import Foundation

struct TXTDocumentImporter {
    enum ImportError: LocalizedError {
        case unsupportedEncoding
        case emptyDocument
        case notTextLikeContent

        var errorDescription: String? {
            switch self {
            case .unsupportedEncoding:
                return "Posey could not read that TXT file."
            case .emptyDocument:
                return "The TXT file is empty."
            case .notTextLikeContent:
                return "That file doesn't look like a text file. (Posey detected too many non-printable bytes — it may be a binary file with a `.txt` extension.)"
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
        // 2026-05-14 (C-tier) — Reject content that's clearly binary
        // before normalization. The Latin-1 fallback in `loadText(from:)`
        // accepts ANY byte sequence, so a misnamed PDF/PNG/.zip would
        // "import" as garbage. Catch the case where the result is
        // mostly non-printable bytes and surface an honest error
        // instead of silently shipping the user gibberish.
        guard Self.looksLikeText(text) else {
            throw ImportError.notTextLikeContent
        }
        let normalized = normalize(text)
        guard normalized.isEmpty == false else {
            throw ImportError.emptyDocument
        }
        return normalized
    }

    /// Heuristic for "this might genuinely be a text file":
    /// fraction of non-printable / non-whitespace control characters
    /// must be < 15%. Tab, CR, LF count as printable (every real
    /// text file has them). NULs are an immediate fail — they appear
    /// in every binary file and almost no real text file. Scans only
    /// the first 4096 unicode scalars so the cost stays sub-ms even
    /// on multi-MB inputs; binary signatures are reliably visible in
    /// the first 4KB.
    static func looksLikeText(_ text: String) -> Bool {
        if text.isEmpty { return true }
        if text.contains("\u{0000}") { return false }
        var nonPrintable = 0
        var total = 0
        for scalar in text.unicodeScalars.prefix(4096) {
            total += 1
            let v = scalar.value
            if v == 0x09 || v == 0x0A || v == 0x0D { continue }
            if v < 0x20 { nonPrintable += 1; continue }
            if v == 0x7F { nonPrintable += 1; continue }
        }
        guard total > 0 else { return true }
        let ratio = Double(nonPrintable) / Double(total)
        return ratio < 0.15
    }

    private func normalize(_ text: String) -> String {
        // Delegates to the shared TextNormalizer. Brings TXT to parity with
        // the PDF importer so artifacts that came up via the synthetic-corpus
        // verifier (line-break hyphens, ZWSP, tabs, multi-blank collapse,
        // per-line trailing whitespace, spaced letters/digits, ¬ as wrap
        // marker) are handled consistently.
        TextNormalizer.normalize(text)
    }
}
