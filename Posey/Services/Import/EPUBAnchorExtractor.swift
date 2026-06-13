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
        guard let html = String(data: data, encoding: .utf8)
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
        if matches.isEmpty { return data }

        // 2026-06-10 — SINGLE-PASS construction. The previous reverse-insert
        // loop held `html[..<tagStart]` (a Substring sharing html's storage)
        // across `html.insert`, forcing a full copy-on-write of the whole
        // string EVERY iteration → on a large, marker-dense chapter (moby:
        // ~270 markers in one 1.2 MB spine file) that churned ~hundreds of
        // 1.2 MB copies and OOM'd the import. Build one output string forward
        // instead: O(n) total, one allocation.
        var out = ""
        out.reserveCapacity(html.count + matches.count * 24)
        var cursor = html.startIndex
        for match in matches {
            guard match.numberOfRanges >= 2,
                  let idRange = Range(match.range(at: 1), in: html),
                  let tagStart = Range(match.range, in: html) else { continue }
            let fragmentID = String(html[idRange])
            out.append(contentsOf: html[cursor..<tagStart.lowerBound])
            out.append("\(sentinelPrefix)\(fragmentID)\(sentinelSuffix)")
            cursor = tagStart.lowerBound  // the tag itself is emitted on the next slice
        }
        out.append(contentsOf: html[cursor..<html.endIndex])
        return out.data(using: .utf8) ?? data
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
        guard let html = String(data: data, encoding: .utf8)
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
        if matches.isEmpty { return data }
        // SINGLE-PASS construction (see insertAnchorSentinels for why — repeated
        // String.insert with a held substring COW-copies the whole chapter each
        // time and OOM'd heading-dense EPUBs).
        var out = ""
        out.reserveCapacity(html.count + matches.count * 18)
        var cursor = html.startIndex
        for match in matches {
            guard match.numberOfRanges >= 2,
                  let levelRange = Range(match.range(at: 1), in: html),
                  let tagStart = Range(match.range, in: html) else { continue }
            out.append(contentsOf: html[cursor..<tagStart.lowerBound])
            out.append("\(headingSentinelPrefix)\(String(html[levelRange]))\(sentinelSuffix)")
            cursor = tagStart.lowerBound
        }
        out.append(contentsOf: html[cursor..<html.endIndex])
        return out.data(using: .utf8) ?? data
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
        /// heading text's start; `level` is the `<hN>` level (1…6); `title`
        /// is the heading line text (computed once, cheaply — see below).
        let headings: [HeadingHit]

        struct Anchor {
            let fragmentID: String
            let offset: Int
        }
        struct HeadingHit {
            let level: Int
            let offset: Int
            let title: String
        }
    }

    /// 2026-06-13 — Guarantee a blank line after a heading sentinel's line when
    /// the chapter body opens with BARE text on the very next line (single `\n`).
    /// No-op when the heading is already followed by a blank line (the `<p>`-
    /// wrapped chapters) or by another sentinel — so only the fused case (e.g.
    /// frankenstein Ch7) is touched. See `extractAnchors` for the full rationale.
    private static func insertHeadingBodyBoundary(_ text: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: #"(\[\[POSEY_HEADING:[1-6]\]\][^\n]*)\n(?=\S)"#) else { return text }
        let ns = text as NSString
        return re.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length),
            withTemplate: "$1\n\n")
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
    static func extractAnchors(from rawInput: String) -> ExtractionResult {
        // 2026-06-13 (DEFECT-heading-merge-absorbs-sentence) — ensure a PARAGRAPH
        // boundary after a heading whose chapter opens with BARE text (no `<p>`
        // wrapper) right after `</hN>`. frankenstein Ch7 is `<h2>Chapter 7</h2>On
        // my return…` → the HTML→text conversion left a SINGLE `\n` between the
        // heading and its opening sentence, so the downstream block builder
        // (splits units on `\n\n`) FUSED them and `applyHeadingMarkers` promoted
        // the whole block as the heading ("Chapter 7: On my return…"). 27
        // `<p>`-wrapped chapters already carry the `\n\n` and are untouched.
        // Inserting the break HERE — BEFORE the offset-recording pass below — means
        // every heading/anchor offset is computed against the corrected text and
        // stays self-consistent (no offset re-bookkeeping). EPUB/HTML-extraction-
        // scoped (NOT the shared `applyHeadingMarkers`). The unit-SPLIT effect of
        // the inserted `\n\n` is phone-verified.
        let input = insertHeadingBodyBoundary(rawInput)
        // 2026-06-10 — single pass strips BOTH anchor and heading sentinels
        // so all recorded offsets are measured against the SAME final output
        // (heading sentinels would otherwise shift anchor offsets and vice
        // versa). Group 1 = kind, group 2 = value.
        guard let regex = try? NSRegularExpression(pattern: combinedSentinelRegex) else {
            return ExtractionResult(plainText: input, anchors: [], headings: [])
        }

        var result = ""
        var anchors: [ExtractionResult.Anchor] = []
        // Heading (level, offset) recorded during the pass; titles resolved
        // ONCE after `result` is built (see below) so we never re-scan the
        // chapter text per heading — that O(headings × textLen) cost OOM'd
        // heading-dense, multi-chapter-per-spine EPUBs (moby: 136 `<h2>`).
        var headingMarks: [(level: Int, offset: Int)] = []
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
                    headingMarks.append((level, result.count))
                }
            } else {
                anchors.append(ExtractionResult.Anchor(fragmentID: value, offset: result.count))
            }
            cursor = matchRange.upperBound
        }
        // Trailing tail after the last sentinel (or all of input if no matches).
        result.append(contentsOf: input[cursor..<input.endIndex])

        // Resolve heading titles with a SINGLE Array conversion (O(n) total,
        // not O(headings × n)): the title is the heading line — from the
        // offset, skip leading whitespace/newlines, take to the next newline.
        var headings: [ExtractionResult.HeadingHit] = []
        if !headingMarks.isEmpty {
            let chars = Array(result)
            for (level, offset) in headingMarks {
                var i = offset
                while i < chars.count, chars[i] == "\n" || chars[i] == " " || chars[i] == "\t" { i += 1 }
                var titleChars: [Character] = []
                while i < chars.count, chars[i] != "\n" { titleChars.append(chars[i]); i += 1 }
                let title = String(titleChars).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    headings.append(ExtractionResult.HeadingHit(level: level, offset: offset, title: title))
                }
            }
        }
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
