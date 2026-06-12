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

    /// **THE shared entry point every importer routes through (2026-06-08
    /// normalizer-parity pass).** Applies the full universal cleanup so all 7
    /// formats clean text identically, then folds in the two universal
    /// à-la-carte fixes that previously only TXT ran:
    ///   - `stripGutenbergItalics` — `_Mem._` → `Mem.` (now universal: real
    ///     RTF/DOCX/HTML/EPUB/MD derived from Gutenberg carry literal
    ///     underscores that NSAttributedString / Readability preserve).
    ///   - `unwrapHardLineBreaks` — ONLY when `hardWrapped` is true (TXT and
    ///     other ~72-char hard-wrapped sources). Structured formats emit
    ///     discrete paragraphs already, so they pass `hardWrapped: false`.
    ///
    /// Genuinely format-specific passes stay OUT of here: PDF glyph-spacing
    /// repair (`normalizePDFGlyphArtifacts`) and the PDF cross-page hyphen
    /// second pass are applied by the PDF importer on top of this.
    static func normalizeUniversal(_ text: String, hardWrapped: Bool = false) -> String {
        var t = normalize(text)
        if hardWrapped { t = unwrapHardLineBreaks(t) }
        t = stripGutenbergItalics(t)
        return t
    }

    /// The universal cleanup pipeline (no format-specific passes). Order
    /// matters — line-ending normalization must run before regex passes that
    /// anchor on `\n`, hyphen collapsing must run before newline-to-space
    /// conversion, etc. Idempotent and safe on clean text. Most callers
    /// should use `normalizeUniversal(_:hardWrapped:)`; this is exposed for
    /// the PDF path, which composes it with its own glyph/hyphen passes.
    static func normalize(_ text: String) -> String {
        var t = text
        t = repairCP1252Mojibake(t)         // 2026-06-08 — universal (before control strip, per its docstring)
        t = stripBOM(t)
        t = stripMojibakeAndControlCharacters(t)  // 2026-05-05 — universal
        t = stripInvisibleCharacters(t)
        t = normalizeLineEndings(t)
        t = stripTrailingWhitespacePerLine(t)
        t = stripLineBreakHyphens(t)        // catches both - and ¬ as line-break markers
        t = stripWaybackPrintHeaders(t)     // PDF-from-Wayback artifacts
        t = stripAsterismLines(t)           // 2026-05-20 — PG scene-break asterisks
        t = stripIllustrationMarkers(t)     // 2026-06-11 — PG [Illustration: caption] markers
        t = stripPrintPageNumberList(t)     // 2026-06-12 — print List-of-Illustrations/TOC rows (must precede tab/space collapse)
        // collapseSpacedLetters / collapseSpacedDigits are PDF-glyph-specific
        // (see normalizePDFGlyphArtifacts) — NOT run here: other formats have
        // real text runs and would suffer false collapses on intentional
        // letter-spacing.
        t = normalizeTabsAndSpaces(t)
        t = collapseExcessiveBlankLines(t)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// PDF-specific glyph-positioning repair: `C O N T E N T S` → `CONTENTS`,
    /// `1 9 4 5` → `1945`. These artifacts come from PDFKit splitting glyphs
    /// during extraction; real-text formats don't produce them, so this is
    /// applied ONLY by the PDF importer (on top of `normalize`), never in the
    /// universal path — collapsing intentional letter-spacing in a DOCX/HTML
    /// would corrupt prose.
    static func normalizePDFGlyphArtifacts(_ text: String) -> String {
        var t = collapseSpacedLetters(text)
        t = collapseSpacedDigits(t)
        return t
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

    /// 2026-06-04 — Repair UTF-8-misread-as-Windows-1252 mojibake.
    ///
    /// Common real-world RTF/DOCX/HTML (pandoc, web exports, scripts) embed raw
    /// UTF-8 bytes while declaring `\ansi` (or no charset). `NSAttributedString`
    /// then decodes those bytes per Windows-1252, so e.g. the UTF-8 bytes for `’`
    /// (E2 80 99) surface as the three glyphs `â€™` (â=0xE2, €=0x80→U+20AC,
    /// ™=0x99→U+2122). The char-class strip above can't fix this — â/€/™ are all
    /// legitimate Unicode outside its strip ranges. This pass REASSEMBLES the
    /// original UTF-8: walk the scalars, and wherever a maximal run re-encodes
    /// (via CP1252) to a valid UTF-8 multi-byte sequence, decode it back.
    ///
    /// Safety: it only acts on a scalar whose CP1252 byte is a UTF-8 *lead*
    /// (0xC2–0xF4) followed by the exact number of CP1252-continuation bytes
    /// (0x80–0xBF), and only when those bytes decode to exactly ONE scalar. A
    /// correctly-decoded `’` (U+2019, CP1252 byte 0x92), em dash, accented letter
    /// surrounded by ASCII, etc. all fail that test and pass through untouched —
    /// so this is a no-op on clean text. Idempotent. Run BEFORE the control strip.
    static func repairCP1252Mojibake(_ text: String) -> String {
        // Quick exit: mojibake always carries a high-Latin lead glyph.
        guard text.unicodeScalars.contains(where: { $0.value >= 0xC2 }) else { return text }

        func cp1252Byte(_ s: Unicode.Scalar) -> UInt8? {
            guard let d = String(s).data(using: .windowsCP1252), d.count == 1 else { return nil }
            return d[0]
        }

        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if let lead = cp1252Byte(scalars[i]), lead >= 0xC2, lead <= 0xF4 {
                let need = lead >= 0xF0 ? 4 : (lead >= 0xE0 ? 3 : 2)
                if i + need <= scalars.count {
                    var bytes: [UInt8] = [lead]
                    var ok = true
                    for k in 1..<need {
                        guard let b = cp1252Byte(scalars[i + k]), b >= 0x80, b <= 0xBF else { ok = false; break }
                        bytes.append(b)
                    }
                    if ok, let decoded = String(bytes: bytes, encoding: .utf8),
                       decoded.unicodeScalars.count == 1 {
                        out.append(contentsOf: decoded.unicodeScalars)
                        i += need
                        continue
                    }
                }
            }
            out.append(scalars[i])
            i += 1
        }
        return String(out)
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

    /// **2026-05-27** — strip Gutenberg's `_underscored_` italic
    /// markers from prose. Gutenberg's plain-TXT convention wraps
    /// italicized words in underscores: `_hval_`, `_Wallen_`,
    /// `_Webster's Dictionary._`. The reader doesn't currently render
    /// these as italic typography; without stripping them the
    /// underscores show up as literal punctuation and disrupt
    /// reading. Stripping preserves the word content (better than
    /// leaving `_hval_` visible), at the cost of losing the
    /// emphasis signal. Actual italic rendering can be wired later.
    ///
    /// Only matches `_word_` and `_multi word phrase_` where the
    /// content between underscores is non-empty and the closing
    /// underscore is followed by a non-letter (so legitimate
    /// snake_case identifiers in code-bearing docs don't get torn
    /// apart). Conservative — same `_word_` pattern that real
    /// Gutenberg TXTs use, narrowed to the contexts where it's
    /// signal not noise.
    static func stripGutenbergItalics(_ text: String) -> String {
        // _content_ where content has no underscore + is bounded by
        // word/punctuation boundaries on both sides. Greedy enough
        // to catch multi-word phrases, narrow enough not to chain
        // across multiple paragraphs.
        let pattern = #"(?<![A-Za-z0-9_])_([^_\n]{1,80}?)_(?![A-Za-z0-9_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: ns.length),
            withTemplate: "$1"
        )
    }

    /// **2026-05-27** — reflow hard-wrapped paragraphs (Gutenberg-TXT
    /// shape). Lines inside a paragraph block (block = consecutive
    /// non-empty lines separated only by single `\n`) are joined with
    /// a single space; leading/trailing whitespace per line is
    /// dropped first so the indent that Gutenberg leaves on every
    /// line doesn't survive into the joined paragraph. Empty lines
    /// (paragraph separators) are preserved as `\n\n`.
    ///
    /// Why this is TXT-specific: HTML / EPUB / DOCX / MD / PDF
    /// importers all produce paragraphs as discrete units (or as
    /// already-reflowed strings) — they don't carry the ~72-char
    /// hard-wrap convention. TXT is the only format where in-paragraph
    /// `\n` breaks ARE artifacts of the source file's display-width
    /// wrap rather than authorial intent. The TXT importer calls this
    /// explicitly; nothing else does.
    ///
    /// Risk: poems and other line-meaningful TXT content get joined
    /// into single lines. This is an accepted tradeoff — the
    /// dominant TXT corpus is Project Gutenberg prose, and the
    /// readability gain on novels is huge. If we ship enough poetry-
    /// heavy TXTs to surface complaints, the pass can be made
    /// poem-aware later (line-length variance + capitalized line
    /// starts).
    static func unwrapHardLineBreaks(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        let unwrapped: [String] = paragraphs.map { para in
            let lines = para.components(separatedBy: "\n")
            let cleaned = lines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return cleaned.joined(separator: " ")
        }
        return unwrapped.joined(separator: "\n\n")
    }

    /// Collapse runs of 3+ newlines to a single paragraph break (\n\n).
    /// Documents pasted from various sources accumulate these.
    static func collapseExcessiveBlankLines(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\n{3,}"#) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "\n\n")
    }

    /// 2026-05-20 — Strip lines that are nothing but whitespace-separated
    /// asterisks (Project Gutenberg's scene-break "asterism"). The
    /// EPUB/HTML importers strip `<p class="asterism">` blocks at the
    /// HTML level; this pass is the format-agnostic safety net for
    /// PG content that arrives via other paths:
    ///
    ///   - PG EPUBs that wrap asterism rows in a different tag (Moby
    ///     Dick uses `<p>` with no class; survives the class-targeted
    ///     pre-strip).
    ///   - PG-derived PDFs imported via the PDF path (no HTML parsing
    ///     at all, so the HTML-level strip never fires).
    ///   - RTF / DOCX / MD / TXT sources copied from PG (same story).
    ///   - Standalone HTML where the asterism row uses a `<div>` /
    ///     `<pre>` / `<center>` element this importer's regex doesn't
    ///     cover.
    ///
    /// Match criterion: the entire line is whitespace + `*` glyphs,
    /// with at least 2 asterisks. False positives are essentially
    /// impossible — natural prose never produces a line consisting
    /// only of bare asterisks. Markdown emphasis (`*italic*`),
    /// arithmetic (`2 * 3 = 6`), and inline `*` survive because they
    /// share a line with other content.
    ///
    /// U+2028 (line separator) is normalized to `\n` first because
    /// some HTML→text paths emit LSEP between row-internal breaks
    /// (observed in Alice's plainText where asterism rows are joined
    /// by U+2028 not \n).
    static func stripAsterismLines(_ text: String) -> String {
        // Normalize any U+2028 / U+2029 line separators to \n so the
        // regex line-anchors fire consistently. NSAttributedString
        // sometimes emits LSEP for `<br/>` inside a single paragraph;
        // we want each asterisk row treated as its own line.
        let normalized = text
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        // Match a whole line containing only whitespace and >= 2
        // asterisks separated by whitespace. Use multiline + ICU
        // syntax. \h is the ICU horizontal-whitespace class.
        let pattern = #"(?m)^\h*\*(?:\h+\*){1,}\h*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return normalized }
        // Replace with empty so collapseExcessiveBlankLines (which
        // runs AFTER us in the pipeline) folds the resulting blank
        // line into the surrounding \n\n paragraph break.
        return regex.stringByReplacingMatches(
            in: normalized,
            range: NSRange(normalized.startIndex..., in: normalized),
            withTemplate: ""
        )
    }

    /// 2026-06-11 — Project Gutenberg `[Illustration: caption]` markers.
    /// Illustrated PG editions (Pride & Prejudice #1342, illustrated Alice
    /// #19033, etc.) mark every figure with a literal `[Illustration: <caption>]`
    /// block in the plain-text — which previously rendered as RAW bracketed text
    /// in the reader ("[Illustration: Reading Jane's Letters. Chap 34. ]").
    /// FIX (Mark/auditor, shared so ALL formats with these markers benefit):
    ///   • A marker with NO real caption (pure image placeholder — ~half of
    ///     P&P's 162) → removed entirely (the blank line folds into the
    ///     surrounding paragraph break via collapseExcessiveBlankLines after us).
    ///   • A marker WITH a caption → the `[Illustration:` … `]` wrapper is
    ///     stripped and the cleaned caption is emitted as its own line (a nested
    ///     `[_Copyright …_` engraver/copyright fragment and `_emphasis_` are
    ///     removed). Caption text only — no raw brackets.
    /// The literal token `[Illustration` does not occur in real prose, so this
    /// is safe to run universally. (A future enhancement can promote the caption
    /// to a styled `.image`-caption unit; this pass alone removes the defect.)
    static func stripIllustrationMarkers(_ text: String) -> String {
        guard text.contains("[Illustration") else { return text }
        guard let regex = try? NSRegularExpression(
            pattern: #"(?s)\[Illustration:?(.*?)\]"#) else { return text }
        let out = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: out.length))
        // Replace last-to-first so earlier ranges stay valid (NSString/UTF-16
        // ranges throughout — no Character/UTF-16 index mixing).
        for m in matches.reversed() {
            var caption = out.substring(with: m.range(at: 1))
            // Drop a nested copyright/engraver fragment ("[_Copyright 1894…_").
            caption = caption.replacingOccurrences(
                of: #"\[_[^\]]*"#, with: "", options: .regularExpression)
            // Drop `_emphasis_` wrappers within the caption.
            caption = caption.replacingOccurrences(
                of: #"_([^_]+)_"#, with: "$1", options: .regularExpression)
            // Drop decorative middle-dot (U+00B7) title-bands that illustrated PG
            // editions wrap a chapter-head image in — the band repeats the running
            // book title and gets glued onto the real chapter label
            // (P&P #1342 ch I: "[Illustration: ·PRIDE AND PREJUDICE·  …  Chapter I.]"
            // → caption "·PRIDE AND PREJUDICE· Chapter I." → clean "Chapter I.").
            // Scoped to caption text only (never touches body prose); a ·…· band is
            // decorative apparatus, not content. Replace with a space so the
            // surrounding words don't merge; the \s+ collapse below tidies it.
            caption = caption.replacingOccurrences(
                of: #"·[^·]*·"#, with: " ", options: .regularExpression)
            caption = caption.replacingOccurrences(
                of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.replaceCharacters(in: m.range, with: caption.isEmpty ? "" : "\n\n" + caption + "\n\n")
        }
        return out as String
    }

    /// 2026-06-12 — Print "List of Illustrations / List of Figures / Table of
    /// Contents" tables (AUDITOR/Mark, scope ruling a1). Print-sourced and
    /// illustrated PG editions embed a front-matter list whose rows are
    /// `<caption><run of spaces><print page number>` — Pride & Prejudice #1342
    /// carries ~60 such rows ('"After a short survey"      434', 'Heading to
    /// Chapter LXI.   472', 'The End   476'). In a REFLOWED document the page
    /// integers are dead (no print pagination), the captions point at plates a
    /// plain-text/Gutenberg edition never bundles, and TTS would speak the bare
    /// integers as junk (c14) — so the whole block is front-matter apparatus,
    /// dropped entirely like publisher boilerplate.
    ///
    /// Detection (Rule 10 — safe to generalize): a CONTIGUOUS RUN of >= 3 rows
    /// of the `caption␣␣pagenum` shape (blank lines between rows allowed). A run
    /// of >= 3 right-aligned page-number rows never occurs in real prose — it is
    /// a fixed-width PRINT-LAYOUT signature — so this is universal-safe, and
    /// reflow formats (EPUB/HTML) don't produce the pattern at all (no column
    /// alignment), which is also why the "image-bearing format keeps the list as
    /// nav" branch of the disposition doesn't arise here: the pattern is absent
    /// unless the source was fixed-width print text.
    ///
    /// The navigable TOC is UNAFFECTED: it is built from the body CHAPTER-heading
    /// units (see `TXTLibraryImporter` tocEntries ← `.heading` units), NOT from
    /// this print list; a heading line ("CHAPTER N.") is not a caption+pagenum
    /// row, so it survives the strip. MUST run before `normalizeTabsAndSpaces`
    /// (which would collapse the column spaces the pattern keys on). Idempotent.
    static func stripPrintPageNumberList(_ text: String) -> String {
        // A row: <non-empty caption ending in a non-space> <2+ spaces/tabs>
        // <page number>, where the page number is ARABIC (1–4 digits) or ROMAN
        // (front matter is paginated i, ii, … xxv). The 2+-space column gap plus
        // the >=3-row run requirement keep the roman branch safe: real prose has
        // single inter-word spaces, and three consecutive lines each ending in a
        // space-column + all-roman-letter token effectively never occurs.
        guard let rowRegex = try? NSRegularExpression(
            pattern: #"(?i)^\s*\S.*\S[ \t]{2,}(\d{1,4}|[ivxlcdm]{1,8})[ \t]*$"#) else { return text }
        // A header/column-title line that captions a print list ("List of
        // Illustrations.", "ILLUSTRATIONS", "List of Figures", "Contents", or the
        // "PAGE" column header). Only stripped when it is adjacent to a dropped
        // run, so a real "Contents" body heading (not abutting a page-number run)
        // is never touched.
        guard let headerRegex = try? NSRegularExpression(
            pattern: #"(?i)^\s*(page|(list of\s+)?(illustrations?|figures?|tables?|plates?)|contents)\.?\s*$"#) else { return text }
        func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
            re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        func isRow(_ s: String) -> Bool { matches(rowRegex, s) }
        func isHeader(_ s: String) -> Bool { matches(headerRegex, s) }
        func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }
        let lines = text.components(separatedBy: "\n")
        var kept: [String] = []
        var i = 0
        while i < lines.count {
            guard isRow(lines[i]) else { kept.append(lines[i]); i += 1; continue }
            // Extend a run over matching rows separated only by blank lines.
            var j = i, rowCount = 0, lastRow = i
            while j < lines.count {
                if isRow(lines[j]) { rowCount += 1; lastRow = j; j += 1 }
                else if isBlank(lines[j]) { j += 1 }
                else { break }
            }
            if rowCount >= 3 {
                // Also absorb the list's own header/column-title lines sitting
                // just above it (past blank lines) — e.g. "List of Illustrations."
                // and the "PAGE" column header — so no orphaned apparatus remains.
                while let last = kept.last, isBlank(last) || isHeader(last) { kept.removeLast() }
                i = lastRow + 1   // drop the whole print-list run [i ... lastRow]
            } else {
                kept.append(lines[i]); i += 1
            }
        }
        return kept.joined(separator: "\n")
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
