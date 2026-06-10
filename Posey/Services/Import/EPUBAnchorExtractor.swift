import Foundation

// ========== BLOCK 01: ANCHOR EXTRACTOR - START ==========

/// Captures per-chapter fragment-anchor positions so the EPUB importer can
/// resolve TOC entries that point at `chapter.xhtml#fragment` rather than
/// at the top of a spine file. Critical for Gutenberg-style EPUBs where
/// multiple chapters share a single spine file (Pride and Prejudice's first
/// ten chapters all live in `1342-h-0.htm.xhtml` differentiated only by
/// `#pgepubid…` fragment IDs — without fragment resolution, every chapter
/// collapses to the file's start offset).
///
/// ### Why a sentinel approach
///
/// The EPUB importer's HTML→plainText conversion goes through
/// `NSAttributedString`, which discards element-level attributes — `id="X"`
/// is gone by the time we have a string. We can't trace anchor positions
/// after extraction.
///
/// The workaround mirrors how inline images are tracked: insert a plain-text
/// sentinel into the HTML before extraction (which NSAttributedString
/// preserves verbatim), then scan the post-extraction plainText for the
/// sentinel and record its offset before stripping it. Same pattern as
/// `[[POSEY_VISUAL_PAGE:0:uuid]]`.
///
/// ### Generality
///
/// This is not a Pride-and-Moby fix. Any EPUB whose nav document points at
/// fragments inside a multi-section spine file benefits: Calibre exports,
/// Gutenberg illustrated editions, single-file IA conversions, modern
/// publisher EPUBs that pack a book into a small number of spine items.
/// EPUBs whose nav points at file roots (Alice, Frankenstein, Sherlock —
/// every chapter is its own spine item) get sentinels inserted but the
/// resolver falls back to file-level lookup, so behavior is unchanged.
enum EPUBAnchorExtractor {

    /// Sentinel format: `[[POSEY_TOC_ANCHOR:fragmentID]]`.
    ///
    /// Deliberately distinct from `[[POSEY_VISUAL_PAGE:…]]` so the existing
    /// visual-marker regex doesn't accidentally strip these and the new
    /// anchor regex doesn't accidentally strip visual markers. No form-feed
    /// wrapping — EPUBDisplayParser splits on form-feed for image blocks
    /// and we don't want anchors to create phantom block boundaries.
    static let sentinelPrefix = "[[POSEY_TOC_ANCHOR:"
    static let sentinelSuffix = "]]"
    /// Regex matching one sentinel and capturing the fragment ID in group 1.
    static let sentinelRegex = #"\[\[POSEY_TOC_ANCHOR:([^\]]+)\]\]"#

    /// Heading sentinel: `[[POSEY_HEADING:N]]` (N = 1…6), inserted before
    /// each `<h1>`–`<h6>` opening tag so the heading's position + level can
    /// be recovered after the HTML→plainText (NSAttributedString) conversion
    /// discards element tags. 2026-06-10 (fix-pass): EPUB body-`<hN>` heading
    /// detection. The previous heading source — nav/NCX `tocEntries` with
    /// fuzzy title→offset resolution — silently dropped chapters whose nav
    /// title/offset didn't align with the body (dracula: 9 of 27 detected,
    /// because Gutenberg packs many chapters per spine file so only file-start
    /// chapters got an offset; Illuminatus: 0, because its nav is a page-list).
    /// Scanning the body `<hN>` directly captures EVERY chapter heading with
    /// its EXACT text, which `ContentUnitBuilder.applyHeadingMarkers` then
    /// promotes by title (offset only disambiguates) — robust regardless of
    /// spine-file packing or nav quality.
    static let headingSentinelPrefix = "[[POSEY_HEADING:"
    /// Combined regex matching EITHER sentinel: group 1 = kind
    /// (`TOC_ANCHOR` | `HEADING`), group 2 = value (fragment id | level).
    static let combinedSentinelRegex = #"\[\[POSEY_(TOC_ANCHOR|HEADING):([^\]]+)\]\]"#

    // ──────────────────────────────────────────────────────────────────────
    // MARK: - HTML-side insertion
    // ──────────────────────────────────────────────────────────────────────

    /// Scan `html` for opening tags carrying an `id="…"` attribute and
    /// insert `[[POSEY_TOC_ANCHOR:id]]` immediately before each one.
    ///
    /// Matches any element with an `id` attribute. Conservative on what
    /// constitutes an `id`: matches double-quoted and single-quoted
    /// attribute values, allows any non-whitespace identifier characters
    /// inside. Skips self-closing tags only if they're well-formed XHTML;
    /// inserting an extra sentinel ahead of a self-closing `<a id="X"/>`
    /// is harmless either way — it lands at the same plainText position.
    ///
    /// Idempotent: a sentinel won't be inserted in front of itself.
    static func insertAnchorSentinels(from data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return data
        }

        // Match opening tags with an id attribute. The full match starts
        // at `<` of the opening tag; the id value is captured. Inserting
        // the sentinel at the match's start position places it
        // immediately before the opening tag — and therefore immediately
        // before any text content the tag contains.
        //
        // Pattern explanation:
        //   <        — start of opening tag
        //   [a-zA-Z][a-zA-Z0-9]*  — tag name
        //   (?:\s+[^>]*?)?        — optional non-id attributes before id
        //   \s+id\s*=\s*          — id=
        //   ["']([^"'\s>]+)["']   — quoted id value (captured)
        //   [^>]*                 — remaining attributes
        //   >                     — close of opening tag
        //
        // The `(?si)` flags enable case-insensitive matching (HTML is
        // case-insensitive on tag and attribute names) and let `.` match
        // newlines for multi-line tags.
        let pattern = #"(?si)<[a-zA-Z][a-zA-Z0-9]*(?:\s+[^>]*?)?\s+id\s*=\s*["']([^"'\s>]+)["'][^>]*>"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return data
        }

        let nsHtml = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))

        // Walk matches in reverse so insertion offsets don't shift earlier
        // matches' positions out from under us.
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let idRange = Range(match.range(at: 1), in: html),
                  let tagStart = Range(match.range, in: html) else { continue }
            let fragmentID = String(html[idRange])
            // Skip if a sentinel for this same id immediately precedes the
            // tag — defends against double-insertion when the helper runs
            // twice on the same HTML (shouldn't, but cheap safety).
            let sentinel = "\(sentinelPrefix)\(fragmentID)\(sentinelSuffix)"
            let upToTag = html[..<tagStart.lowerBound]
            if upToTag.hasSuffix(sentinel) { continue }
            html.insert(contentsOf: sentinel, at: tagStart.lowerBound)
        }

        return html.data(using: .utf8) ?? data
    }

    /// Insert `[[POSEY_HEADING:N]]` immediately before each `<h1>`–`<h6>`
    /// opening tag (N = the level digit). Mirrors `insertAnchorSentinels`:
    /// the sentinel lands right before the heading's text content, so after
    /// the HTML→plainText conversion the sentinel sits at the heading text's
    /// start and `extractAnchors` recovers (level, offset). Idempotent.
    ///
    /// Generality: every spine item is scanned, so multi-chapter-per-file
    /// EPUBs (Gutenberg dracula/P&P) get a marker per chapter, and EPUBs
    /// with only a page-list nav (Illuminatus) still get real chapter
    /// headings from their body `<hN>`. EPUBs that already worked via nav
    /// are unaffected: their `<hN>` text equals the body unit text, so the
    /// title-anchored promotion produces the same headings.
    static func insertHeadingSentinels(from data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return data
        }
        // <hN ...> — capture the level digit (group 1). Case-insensitive,
        // dot-matches-newline for multi-line tags.
        let pattern = #"(?si)<h([1-6])(?:\s+[^>]*)?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return data
        }
        let nsHtml = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let levelRange = Range(match.range(at: 1), in: html),
                  let tagStart = Range(match.range, in: html) else { continue }
            let level = String(html[levelRange])
            let sentinel = "\(headingSentinelPrefix)\(level)\(sentinelSuffix)"
            let upToTag = html[..<tagStart.lowerBound]
            if upToTag.hasSuffix(sentinel) { continue }
            html.insert(contentsOf: sentinel, at: tagStart.lowerBound)
        }
        return html.data(using: .utf8) ?? data
    }

    // ──────────────────────────────────────────────────────────────────────
    // MARK: - PlainText-side extraction
    // ──────────────────────────────────────────────────────────────────────

    /// Result of extracting anchors from a plainText chunk.
    struct ExtractionResult {
        /// The input with all sentinel markers removed.
        let plainText: String
        /// One entry per sentinel found, in document order. `offset` is
        /// the character position in `plainText` (post-strip) at which
        /// the sentinel sat — i.e., the position of the next character
        /// after the stripped sentinel.
        let anchors: [Anchor]
        /// One entry per `[[POSEY_HEADING:N]]` sentinel, in document order.
        /// `offset` is the position in the stripped `plainText` of the
        /// heading text's start; `level` is the `<hN>` level (1…6). The
        /// caller reads the title from `plainText` at `offset`.
        let headings: [HeadingHit]

        struct Anchor {
            let fragmentID: String
            let offset: Int
        }
        struct HeadingHit {
            let level: Int
            let offset: Int
        }
    }

    /// Scan a plainText string for `[[POSEY_TOC_ANCHOR:…]]` sentinels.
    /// Returns the sentinel-free string and the list of `(fragmentID,
    /// offsetInStrippedText)` pairs.
    ///
    /// `offset` is measured against the OUTPUT string, not the input —
    /// each sentinel's "position" is the offset of whatever character
    /// follows the sentinel in the original input, translated to the
    /// stripped output. This matches what callers want: "where in the
    /// final plainText does this fragment land."
    static func extractAnchors(from input: String) -> ExtractionResult {
        // 2026-06-10 — single pass strips BOTH anchor and heading sentinels
        // so all recorded offsets are measured against the SAME final output
        // (heading sentinels would otherwise shift anchor offsets and vice
        // versa). Group 1 = kind, group 2 = value.
        guard let regex = try? NSRegularExpression(pattern: combinedSentinelRegex) else {
            return ExtractionResult(plainText: input, anchors: [], headings: [])
        }

        var result = ""
        var anchors: [ExtractionResult.Anchor] = []
        var headings: [ExtractionResult.HeadingHit] = []
        var cursor = input.startIndex
        let nsInput = input as NSString

        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let matchRange = Range(match.range, in: input),
                  let kindRange = Range(match.range(at: 1), in: input),
                  let valueRange = Range(match.range(at: 2), in: input) else { continue }
            // Append the slice from cursor up to the sentinel start.
            result.append(contentsOf: input[cursor..<matchRange.lowerBound])
            // The sentinel itself is dropped; record its post-strip offset.
            let kind = String(input[kindRange])
            let value = String(input[valueRange])
            if kind == "HEADING" {
                if let level = Int(value) {
                    headings.append(ExtractionResult.HeadingHit(level: level, offset: result.count))
                }
            } else {
                anchors.append(ExtractionResult.Anchor(fragmentID: value, offset: result.count))
            }
            cursor = matchRange.upperBound
        }
        // Trailing tail after the last sentinel (or all of input if no matches).
        result.append(contentsOf: input[cursor..<input.endIndex])
        return ExtractionResult(plainText: result, anchors: anchors, headings: headings)
    }

    /// Convenience: strip sentinels from a string without recording
    /// positions. Used for `displayText` cleanup where we don't need
    /// to know where the anchors WERE — we just don't want sentinel
    /// strings rendered to the user.
    static func stripSentinels(from input: String) -> String {
        // Strip BOTH anchor and heading sentinels (2026-06-10) so neither
        // reaches the renderer / plainText.
        guard let regex = try? NSRegularExpression(pattern: combinedSentinelRegex) else {
            return input
        }
        let nsInput = input as NSString
        return regex.stringByReplacingMatches(
            in: input,
            options: [],
            range: NSRange(location: 0, length: nsInput.length),
            withTemplate: ""
        )
    }

    // ──────────────────────────────────────────────────────────────────────
    // MARK: - TOC title normalization
    // ──────────────────────────────────────────────────────────────────────

    /// Strip a leading figure-caption sentence from a Gutenberg-style nav
    /// title that fuses a Hugh-Thomson-style caption with the actual
    /// chapter heading. Conservative: only fires when the title clearly
    /// has the shape `<sentence-ending-in-period>. <CHAPTER N pattern>`.
    ///
    /// Examples (all from Pride and Prejudice's nav):
    ///
    /// - `"I hope Mr. Bingley will like it. CHAPTER II."` → `"CHAPTER II."`
    /// - `"He rode a black horse. CHAPTER III."` → `"CHAPTER III."`
    /// - `"Mrs Bennet and her two youngest girls. CHAPTER IX."` → `"CHAPTER IX."`
    ///
    /// Pass-through for titles that don't match the pattern:
    ///
    /// - `"CHAPTER IV."` → unchanged (no caption prefix)
    /// - `"Chapter I."` → unchanged (no caption prefix)
    /// - `"Foreword by John Smith"` → unchanged (no CHAPTER suffix)
    /// - `"PRIDE. and PREJUDICE"` → unchanged (no CHAPTER suffix)
    /// - `"Walt Whitman has somewhere a fine and just distinction"`
    ///   → unchanged (no CHAPTER suffix)
    ///
    /// Out-of-scope (deliberately not stripped — different shape):
    ///
    /// - `"Introduction"` / `"Preface"` / `"Etymology"` titles — these are
    ///   real headings users want surfaced in the TOC.
    static func cleanGutenbergCaptionPrefix(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // The prefix ends with a sentence-final punctuation
        // (`.`, `!`, or `?`) optionally followed by a closing quotation
        // mark (Gutenberg's illustrated nav uses curly-quote captions
        // like `"to assure you in the most animated language." CHAPTER
        // XIX.` where the period sits INSIDE the closing curly quote),
        // followed by whitespace.
        //
        // The suffix starts with "CHAPTER" (case-insensitive — both
        // "CHAPTER" and "Chapter" appear in Gutenberg editions) plus
        // a roman or arabic numeral. `\b` anchors the numeral boundary
        // so we don't half-match `CHAPTERLY` etc.
        //
        // The optional quote class includes ASCII `"` and `'` plus the
        // four common curly variants (U+201C, U+201D, U+2018, U+2019).
        let pattern = "^(?i)(.+?[.!?][\"'\u{201C}\u{201D}\u{2018}\u{2019}]?\\s+)(chapter\\s+[ivxlcdm0-9]+\\b.*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: trimmed,
                options: [],
                range: NSRange(trimmed.startIndex..., in: trimmed)
              ),
              match.numberOfRanges >= 3,
              let suffixRange = Range(match.range(at: 2), in: trimmed) else {
            return trimmed
        }
        return String(trimmed[suffixRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// ========== BLOCK 01: ANCHOR EXTRACTOR - END ==========
