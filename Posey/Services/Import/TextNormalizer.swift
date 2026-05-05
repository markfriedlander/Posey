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
        t = stripMojibakeAndControlCharacters(t)  // 2026-05-05 — universal
        t = stripInvisibleCharacters(t)
        t = normalizeLineEndings(t)
        t = stripTrailingWhitespacePerLine(t)
        t = stripLineBreakHyphens(t)        // catches both - and ¬ as line-break markers
        t = stripWaybackPrintHeaders(t)     // PDF-from-Wayback artifacts
        t = collapseSpacedLetters(t)
        t = collapseSpacedDigits(t)
        t = normalizeTabsAndSpaces(t)
        t = collapseExcessiveBlankLines(t)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Universal mojibake + control-character strip. Per Mark's
    /// directive (2026-05-05): bake "remove any of that crap" into
    /// the import process for every format. Categories handled:
    ///
    /// 1. C0 control characters (U+0000–U+001F) EXCEPT the three
    ///    that have semantic meaning: \t (U+0009), \n (U+000A),
    ///    \r (U+000D — kept here, normalized to \n later).
    /// 2. C1 control characters (U+0080–U+009F). These never appear
    ///    in legitimate text — they're the result of misinterpreting
    ///    UTF-8 bytes as Latin-1 / Windows-1252 (the classic
    ///    mojibake source).
    /// 3. DEL (U+007F).
    /// 4. Unicode Private Use Area (U+E000–U+F8FF, U+F0000–U+FFFFD,
    ///    U+100000–U+10FFFD). Real text never contains PUA chars
    ///    in normal prose. Leftover sentinel characters from any
    ///    importer's intermediate processing land here.
    /// 5. Specials block (U+FFF0–U+FFFF), especially the U+FFFD
    ///    REPLACEMENT CHARACTER which encoders produce when they
    ///    can't decode a byte sequence.
    /// 6. Variation selectors that aren't paired with anything
    ///    meaningful (U+FE00–U+FE0F orphans).
    /// 7. Known canonical mojibake sequences (e.g., "î€" + optional
    ///    "U+0081" — the iOS NSAttributedString HTML parser bug
    ///    that turns U+E001 into Latin-1 garble).
    ///
    /// This pass runs early, BEFORE any regex pass that anchors on
    /// specific characters, so the input to those passes is already
    /// clean. Idempotent.
    static func stripMojibakeAndControlCharacters(_ text: String) -> String {
        var t = text
        // First: catch the known iOS NSAttributedString HTML mojibake
        // pattern (U+00EE U+20AC [U+0081]). Without this, the
        // character-class strip below would still leave the U+00EE
        // and U+20AC because they're legitimate Unicode characters
        // (Latin-extended + currency sign) outside our strip ranges.
        // The 3-char sequence has to be matched as a whole.
        t = t.replacingOccurrences(of: "\u{00EE}\u{20AC}\u{0081}", with: "\n")
        t = t.replacingOccurrences(of: "\u{00EE}\u{20AC}", with: "\n")

        // Then: filter all unicodeScalars in one pass.
        let cleaned = String.UnicodeScalarView(t.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            let v = scalar.value
            // Keep \t \n \r — semantic control chars.
            if v == 0x09 || v == 0x0A || v == 0x0D { return scalar }
            // Strip C0 controls (U+0000–U+001F), DEL (U+007F),
            // C1 controls (U+0080–U+009F).
            if v < 0x20 { return nil }
            if v >= 0x7F && v <= 0x9F { return nil }
            // Strip Private Use Area (BMP).
            if v >= 0xE000 && v <= 0xF8FF { return nil }
            // Strip Specials block — replacement char + co.
            if v >= 0xFFF0 && v <= 0xFFFF { return nil }
            // Strip Supplementary Private Use Area-A and -B.
            if v >= 0xF0000 && v <= 0xFFFFD { return nil }
            if v >= 0x100000 && v <= 0x10FFFD { return nil }
            // Variation selectors — keep VS1-VS16 (often used in
            // emoji presentation), strip the supplementary range
            // U+E0100-U+E01EF.
            if v >= 0xE0100 && v <= 0xE01EF { return nil }
            return scalar
        })
        return String(cleaned)
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

    /// Strip Wayback Machine print-header artifacts that appear at
    /// the top of every page when a PDF was generated from a
    /// Wayback-archived web page (browser print-to-PDF inserts a
    /// header on each page). The pattern is:
    ///   `<MM/DD/YY>, <HH:MM> <AM|PM> The Wayback Machine - https://web.archive.org/web/<digits>/...`
    /// repeated dozens of times. Posey's RAG retrieval pulls these
    /// headers as the dominant content of front-matter chunks,
    /// confusing AFM and producing `informativeRefusalFailure` on
    /// vague document-scope questions (Internet Steps PDF in
    /// qa_battery — surfaced 2026-05-04).
    static func stripWaybackPrintHeaders(_ text: String) -> String {
        guard text.contains("Wayback Machine") || text.contains("web.archive.org") else { return text }
        // Two patterns: with leading timestamp ("9/11/25, 1:33 PM ...")
        // and without. Both end at the first whitespace-bounded token
        // that doesn't fit the URL.
        let patterns = [
            #"\d{1,2}/\d{1,2}/\d{2,4},?\s+\d{1,2}:\d{2}\s*(?:AM|PM|am|pm)?\s+The\s+Wayback\s+Machine\s+-\s+https?://[^\s]+"#,
            #"The\s+Wayback\s+Machine\s+-\s+https?://web\.archive\.org/[^\s]+"#,
        ]
        var result = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: " ")
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
