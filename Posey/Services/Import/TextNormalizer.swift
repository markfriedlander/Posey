import Foundation

// ========== BLOCK 01: TEXT NORMALIZER - START ==========

/// Canonical normalization passes shared across importers.
///
/// Originally each importer (PDF, TXT, RTF, DOCX, HTML, EPUB, MD) carried its
/// own ad-hoc normalization. The PDF path evolved most aggressively in
/// response to real-world artifacts and ended up with passes the others
/// quietly lacked. The synthetic-corpus verifier surfaced the gap (TXT
/// failed 11 specs that PDF passed). This type centralizes the passes so
/// every importer can reach them and they evolve together.
///
/// `normalize(_:)` is the canonical full pass for plain text. It's safe
/// to apply to clean text (no-ops where there's nothing to fix). Each
/// pass is also exposed individually for importers that need to compose
/// them in a different order (e.g. PDF runs `collapseLineBreakHyphens`
/// twice — once per page and again across page boundaries).
enum TextNormalizer {

    /// Apply the full normalization pass appropriate for plain-text input.
    /// Order matters — line-ending normalization must run before regex
    /// passes that anchor on `\n`, hyphen collapsing must run before
    /// newline-to-space conversion, etc. Idempotent and safe on clean text.
    static func normalize(_ text: String) -> String {
        var t = text
        t = stripBOM(t)
        t = stripInvisibleCharacters(t)
        t = normalizeLineEndings(t)
        t = stripTrailingWhitespacePerLine(t)
        t = stripLineBreakHyphens(t)        // catches both - and ¬ as line-break markers
        t = collapseSpacedLetters(t)
        t = collapseSpacedDigits(t)
        t = normalizeTabsAndSpaces(t)
        t = collapseExcessiveBlankLines(t)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ========== BLOCK 02: INVISIBLE-CHARACTER PASSES - START ==========

    /// Strip the U+FEFF BOM if it appears at the start of the text.
    /// `String(contentsOf:encoding:)` strips it for UTF-8 in many cases,
    /// but raw or transcoded inputs can still carry it.
    static func stripBOM(_ text: String) -> String {
        guard text.first == "\u{FEFF}" else { return text }
        return String(text.dropFirst())
    }

    /// Strip soft hyphens (U+00AD) and zero-width characters that have no
    /// place in spoken text and confuse word-boundary recognition. Also
    /// converts non-breaking spaces (U+00A0) to ordinary spaces so the
    /// segmenter can find word boundaries.
    static func stripInvisibleCharacters(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ")   // non-breaking space → space
        t = t.replacingOccurrences(of: "\u{00AD}", with: "")    // soft hyphen → strip
        t = t.replacingOccurrences(of: "\u{200B}", with: "")    // zero-width space
        t = t.replacingOccurrences(of: "\u{200C}", with: "")    // zero-width non-joiner
        t = t.replacingOccurrences(of: "\u{200D}", with: "")    // zero-width joiner
        return t
    }

    // ========== BLOCK 02: INVISIBLE-CHARACTER PASSES - END ==========

    // ========== BLOCK 03: LINE-ENDING & WHITESPACE PASSES - START ==========

    /// Normalize CRLF / CR to LF. Required before any regex anchored on \n.
    static func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Strip whitespace at the end of each line. Source files from many
    /// editors carry trailing spaces invisibly; they don't matter for
    /// rendering but they matter for content-equality comparisons and for
    /// not introducing artifacts when joining lines.
    static func stripTrailingWhitespacePerLine(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[ \t]+(?=\n)"#) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Convert all tabs to single spaces, then collapse any 2+ space runs
    /// to a single space. Real TXT files use tabs for alignment which is
    /// meaningless on a reflowable surface.
    static func normalizeTabsAndSpaces(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\t", with: " ")
        if let regex = try? NSRegularExpression(pattern: #"[ ]{2,}"#) {
            let range = NSRange(t.startIndex..., in: t)
            t = regex.stringByReplacingMatches(in: t, range: range, withTemplate: " ")
        }
        return t
    }

    /// Collapse runs of 3+ newlines to a single paragraph break (\n\n).
    /// Documents pasted from various sources accumulate these.
    static func collapseExcessiveBlankLines(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\n{3,}"#) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "\n\n")
    }

    // ========== BLOCK 03: LINE-ENDING & WHITESPACE PASSES - END ==========

    // ========== BLOCK 04: HYPHEN AND SPACED-CHARACTER PASSES - START ==========

    /// Collapse line-break hyphens introduced by PDF/text wrapping:
    /// `inde- pendent` → `independent`. Also catches `¬` (U+00AC, NOT SIGN)
    /// used as a line-break marker by some PDF generators. Only fires when
    /// a lowercase continuation follows the marker so intentional hyphenated
    /// compounds (`anti-fascist`) survive.
    static func stripLineBreakHyphens(_ text: String) -> String {
        // Use ICU regex syntax (`¬`, `\x0c`) inside a raw string —
        // Swift's `\u{...}` escape only works in normal strings; inside
        // `#"..."#` it's passed verbatim and the regex engine doesn't
        // recognize it.
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z]+)[-¬][ \n\x0c] ?([a-z]+)"#
        ) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1$2"
        )
    }

    /// Collapse PDF glyph-positioning artifacts: `C O N T E N T S` → `CONTENTS`.
    /// Only fires on runs of 3+ same-case Unicode letters separated by single
    /// spaces. Conservative on purpose — false positives on prose like
    /// "I    am" would be costly. Uses Unicode property classes so accented
    /// capitals (`Á` in `PASARÁN`) collapse alongside ASCII.
    static func collapseSpacedLetters(_ text: String) -> String {
        let patterns = [
            #"(?<!\p{Lu})\p{Lu}(?: \p{Lu}){2,}(?!\p{Lu})"#,
            #"(?<!\p{Ll})\p{Ll}(?: \p{Ll}){2,}(?!\p{Ll})"#
        ]
        var result = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            var rebuilt = ""
            var lastEnd = result.startIndex
            regex.enumerateMatches(in: result, range: NSRange(result.startIndex..., in: result)) { match, _, _ in
                guard let match, let matchRange = Range(match.range, in: result) else { return }
                rebuilt += result[lastEnd..<matchRange.lowerBound]
                rebuilt += result[matchRange].replacingOccurrences(of: " ", with: "")
                lastEnd = matchRange.upperBound
            }
            rebuilt += result[lastEnd...]
            result = rebuilt
        }
        return result
    }

    /// Collapse PDF glyph-positioning artifacts for digit sequences:
    /// `1 9 4 5` → `1945`. Only fires on runs of 4+ single digits to
    /// avoid false positives on legitimate short numeric tokens.
    static func collapseSpacedDigits(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\d(?: \d){3,}"#) else { return text }
        var rebuilt = ""
        var lastEnd = text.startIndex
        regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let match, let matchRange = Range(match.range, in: text) else { return }
            rebuilt += text[lastEnd..<matchRange.lowerBound]
            rebuilt += text[matchRange].replacingOccurrences(of: " ", with: "")
            lastEnd = matchRange.upperBound
        }
        rebuilt += text[lastEnd...]
        return rebuilt
    }

    // ========== BLOCK 04: HYPHEN AND SPACED-CHARACTER PASSES - END ==========

    // ========== BLOCK 05: KNOWN LIMITATIONS - START ==========
    //
    // **WORD - WORD (space-hyphen-space) artifact (Task 8 — 2026-05-03).**
    // Some PDFs surface text like `"anti - fascist"` (with surrounding
    // spaces around the hyphen) when the original text was the
    // unhyphenated compound. We do NOT collapse this pattern because
    // the same shape is legitimate prose:
    //   - em-dash spacing: `"It was a long - and difficult - journey"`
    //   - en-dash ranges: `"pages 12 - 24"` (some PDFs render en-dash this way)
    //   - juxtaposed terms: `"Italy - the founding member"`
    //
    // Without surrounding font / glyph metrics (which `pdfText.string`
    // discards) we cannot distinguish artifact from intent. A
    // conservative collapse would corrupt prose; an aggressive one
    // would only catch maybe 30% of artifact cases. Deferred until we
    // have a per-PDF heuristic (e.g. count occurrences relative to
    // legitimate em-dash usage, or use `PDFSelection` page-coordinates
    // to detect where the surrounding word is positioned).
    //
    // The artifact is rare in real-world reading (we've seen it once
    // in 47 synthetic + 28 Gutenberg + ~12 Mark-imported documents).
    // ========== BLOCK 05: KNOWN LIMITATIONS - END ==========
}
