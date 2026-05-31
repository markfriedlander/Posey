import Foundation

// ========== BLOCK 01: GENERALIZED PDF TOC DETECTOR - START ==========

/// Fallback TOC detector for PDFs that have NEITHER a structural
/// outline (`PDFDocument.outlineRoot`) NOR a classic dot-leader TOC
/// page that `PDFTOCDetector` can fire on.
///
/// This detector looks for a dense cluster of chapter/part/section/
/// appendix entries on the document's first few pages. It handles two
/// physical shapes of the same logical TOC:
///
///   - **Line-structured** (one entry per line), e.g.
///         Chapter 2 - Major League Algorithms
///         Part III. Putting Encryption Technologies to Work for You
///     detected by `entryShapedLineCount` (line-anchored regex).
///
///   - **Run-on / whitespace-aligned** (the whole TOC arrives as a
///     single space-separated stream — the dominant shape for OCR'd
///     scanned books, where line breaks and dot leaders are lost):
///         Chapter I: The MU-puzzle 33 Two-Part Invention 43
///         Chapter II: Meaning and Form in Mathematics 46 ...
///     detected by `runOnEntryKeywordCount` + validated by
///     `parseFlowEntries` (tokenize → accumulate title → page-number
///     delimiter) under the **monotonic-page-number invariant**.
///
/// 2026-05-31 — run-on support + entry emission added (was skip-only).
/// Motivation: Gödel Escher Bach (a scanned PDF whose TOC pages carry a
/// clean Tier-1 text layer) produced a run-on TOC that NO detector
/// fired on — dot-leader count 0, no outline, and this detector's
/// line-anchored regex matched 0 because the OCR'd TOC has no line
/// breaks. Result: zero navigation for a 740-page book whose chapters
/// are right there in the text. The fix de-fragilizes detection (dot
/// leaders / line breaks are no longer required) and, crucially, emits
/// real entries so heading units get built — gated by the monotonic
/// page-number check so an index ("Bach 360, 641, 720 …", which resets
/// per letter) or prose can't masquerade as a TOC.
///
/// The detector remains conservative: BOTH a `Contents` anchor in the
/// first pages AND a validated entry cluster are required. False
/// positives here would silently skip real content.
///
/// Used as the third-tier text signal in `PDFDocumentImporter`:
///   1. Dot-leader text scan (`PDFTOCDetector`)
///   2. Outline walker (`TOCWalkContentStartDetector` on
///      `PDFDocument.outlineRoot` entries)
///   3. This generalized text scan
///
/// Returns nil when no signal is strong enough — caller leaves the
/// skip at zero rather than guessing.
struct PDFGeneralizedTOCDetector {

    struct Result: Equatable {
        /// Character offset in plainText where the TOC region starts.
        let regionStartOffset: Int
        /// Character offset in plainText where the TOC region ends —
        /// the body begins here.
        let regionEndOffset: Int
        /// Parsed entries (run-on flow parse), in document order. Empty
        /// when only the skip region could be established (line-
        /// structured TOC that didn't flow-parse into monotonic
        /// entries) — preserves the original skip-only behavior.
        let entries: [PDFTOCDetector.Entry]

        init(regionStartOffset: Int,
             regionEndOffset: Int,
             entries: [PDFTOCDetector.Entry] = []) {
            self.regionStartOffset = regionStartOffset
            self.regionEndOffset = regionEndOffset
            self.entries = entries
        }
    }

    /// Run detection over a sequence of per-page plaintext strings as
    /// joined with `\n\n` (the same shape `PDFDocumentImporter` uses
    /// for `plainText`). Returns nil when the heuristics don't all
    /// agree.
    static func detect(pageTexts: [String]) -> Result? {
        guard !pageTexts.isEmpty else { return nil }

        // Limit the scan to the first 8 pages. A TOC further in is
        // too risky to auto-skip on a structural guess.
        let searchLimit = min(8, pageTexts.count)
        let separatorLen = 2

        // Find the first page that has a Contents anchor AND enough
        // entry-shaped signal (line-structured OR run-on).
        var anchorIndex: Int? = nil
        for i in 0..<searchLimit where isTOCPage(pageTexts[i]) {
            anchorIndex = i
            break
        }
        guard let firstTOCPage = anchorIndex else { return nil }

        // Did the anchor page carry the ORIGINAL line-structured signal?
        // (Used to preserve the pre-2026-05-31 skip-only behavior even
        // when flow parsing yields too few entries.)
        let anchorHadLineSignal = entryShapedLineCount(in: pageTexts[firstTOCPage]) >= 5

        // Extend forward while pages look like dense entry listings
        // (either physical shape).
        var lastTOCPage = firstTOCPage
        var nextPage = firstTOCPage + 1
        while nextPage < min(pageTexts.count, firstTOCPage + 5),
              isContinuationOfTOC(pageTexts[nextPage]) {
            lastTOCPage = nextPage
            nextPage += 1
        }

        let prefixLen = pageTexts[0..<firstTOCPage]
            .map { $0.count + separatorLen }
            .reduce(0, +)
        let tocSlice = pageTexts[firstTOCPage...lastTOCPage]
        let tocLen = tocSlice
            .enumerated()
            .map { (offset, page) -> Int in
                offset == tocSlice.count - 1 ? page.count : page.count + separatorLen
            }
            .reduce(0, +)

        let regionStart = prefixLen
        let regionEnd = regionStart + tocLen + separatorLen

        // Flow-parse the region and keep the entries only if they pass
        // the monotonic-page-number invariant (the guard that separates
        // a real TOC from an index / bibliography / prose run).
        let region = tocSlice.joined(separator: "\n\n")
        let flow = parseFlowEntries(in: region)
        let validEntries = (flow.count >= 5 && pageNumbersMostlyIncreasing(flow)) ? flow : []

        // Fire only when EITHER the trusted original line signal was
        // present OR we extracted entry-validated run-on entries. This
        // means the relaxed run-on detection can never produce a
        // false-positive skip on its own — it must clear the monotonic
        // entry check first.
        guard anchorHadLineSignal || !validEntries.isEmpty else { return nil }

        return Result(regionStartOffset: regionStart,
                      regionEndOffset: regionEnd,
                      entries: validEntries)
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: - Page-level heuristics

    /// True when a page has a Contents anchor phrase AND ≥5 entry-shaped
    /// signals — counting BOTH line-structured entries and run-on
    /// keyword occurrences, so OCR'd no-line-break TOCs register.
    static func isTOCPage(_ pageText: String) -> Bool {
        guard hasContentsAnchor(in: pageText) else { return false }
        return entryShapedLineCount(in: pageText) >= 5
            || runOnEntryKeywordCount(in: pageText) >= 5
    }

    /// True when a page lacks the anchor but is dominated by entry-
    /// shaped signals (used to extend the region across a multi-page
    /// TOC). Accepts either physical shape.
    static func isContinuationOfTOC(_ pageText: String) -> Bool {
        let lineCount = entryShapedLineCount(in: pageText)
        if lineCount >= 5 {
            let charsPerEntry = pageText.count / max(lineCount, 1)
            return charsPerEntry < 250
        }
        // Run-on continuation: dense keyword occurrences. No per-line
        // density check (there are no lines) — the keyword count plus
        // the caller's region cap (firstTOCPage + 5) bound it.
        return runOnEntryKeywordCount(in: pageText) >= 5
    }

    /// Match the standalone Contents header (whole-word, case-
    /// insensitive). Deliberately narrow — we don't want to match
    /// "contents" inline in prose like "the contents of this book…".
    static func hasContentsAnchor(in pageText: String) -> Bool {
        let lower = pageText.lowercased()
        if lower.contains("table of contents") { return true }
        // Standalone "contents" with whitespace on both sides.
        if let regex = try? NSRegularExpression(
            pattern: #"(?:^|[\s\n])contents(?:[\s\n]|$)"#
        ) {
            let range = NSRange(lower.startIndex..., in: lower)
            return regex.firstMatch(in: lower, range: range) != nil
        }
        return false
    }

    /// Count lines that begin with a recognized structural label —
    /// Chapter / Part / Section / Appendix / Book / Volume — followed by
    /// a number or roman numeral. The original line-structured signal.
    static func entryShapedLineCount(in pageText: String) -> Int {
        let pattern = #"(?im)^\s*(?:chapter|part|section|appendix|book|volume)\s+[ivxlcdm0-9]+\b.{0,200}$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(pageText.startIndex..., in: pageText)
        return regex.numberOfMatches(in: pageText, range: range)
    }

    /// Count structural-label occurrences ANYWHERE (not line-anchored) —
    /// "Chapter I:", "Part II", "Section 3" embedded in a run-on OCR
    /// stream. This is the de-fragilized signal for scanned books whose
    /// TOC arrives without line breaks. Intentionally broad; the
    /// monotonic entry check in `detect` is what makes acting on it safe.
    static func runOnEntryKeywordCount(in pageText: String) -> Int {
        let pattern = #"(?i)\b(?:chapter|part|section|appendix)\s+[ivxlcdm0-9]+\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(pageText.startIndex..., in: pageText)
        return regex.numberOfMatches(in: pageText, range: range)
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: - Run-on flow entry parsing

    /// Parse a run-on / whitespace TOC region into entries. Walks
    /// whitespace-separated tokens, accumulating a title until a
    /// page-number token (arabic, or lowercase roman for front matter)
    /// delimits the entry. Titles that grow too long without a page
    /// number are flushed (a prose run can't be captured as one giant
    /// entry). The page numbers are validated for monotonicity by the
    /// caller — that invariant is what proves the run really is a TOC.
    static func parseFlowEntries(in tocText: String) -> [PDFTOCDetector.Entry] {
        let tokens = tocText.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .map(String.init)
        var entries: [PDFTOCDetector.Entry] = []
        var titleWords: [String] = []
        // Cap a title at ~16 words; past that we've almost certainly run
        // out of the TOC and into prose (a TOC entry title is short).
        let maxTitleWords = 16

        for token in tokens {
            // Strip trailing/leading entry punctuation so "33", "33.",
            // "viii" all read as numbers, and "MU-puzzle" stays a word.
            let trimmed = token.trimmingCharacters(
                in: CharacterSet(charactersIn: ".,:;()[]"))
            if let page = pageNumberValue(trimmed) {
                let title = titleWords.joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                if isPlausibleEntryTitle(title) {
                    entries.append(PDFTOCDetector.Entry(title: title, pageNumber: page))
                }
                titleWords.removeAll(keepingCapacity: true)
            } else {
                titleWords.append(token)
                if titleWords.count > maxTitleWords {
                    titleWords.removeAll(keepingCapacity: true)
                }
            }
        }
        return entries
    }

    /// A token is a page number if it is 1–4 arabic digits, or a
    /// lowercase roman numeral of length ≥ 2 that round-trips exactly
    /// (front-matter pages: viii, xiv, xix). Lowercase + length ≥ 2 +
    /// canonical round-trip avoids mistaking "I"/"II" in "Part I" /
    /// "Chapter II" (uppercase, single/short) or all-roman-letter words
    /// ("dim", "civil") for page numbers.
    static func pageNumberValue(_ token: String) -> Int? {
        if token.count >= 1, token.count <= 4,
           token.allSatisfy({ $0.isNumber }), let n = Int(token), n > 0 {
            return n
        }
        if token.count >= 2, token == token.lowercased(),
           let r = canonicalRomanValue(token) {
            return r
        }
        return nil
    }

    /// Returns the integer value of `token` iff it is a canonical roman
    /// numeral (case-insensitive) — i.e. `intToRoman(value)` equals the
    /// uppercased token. Rejects non-canonical all-roman-letter words.
    static func canonicalRomanValue(_ token: String) -> Int? {
        let upper = token.uppercased()
        guard upper.allSatisfy({ "IVXLCDM".contains($0) }) else { return nil }
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50,
                                        "C": 100, "D": 500, "M": 1000]
        var total = 0
        var prev = 0
        for ch in upper.reversed() {
            guard let v = values[ch] else { return nil }
            if v < prev { total -= v } else { total += v }
            prev = v
        }
        guard total > 0, total < 4000, intToRoman(total) == upper else { return nil }
        return total
    }

    private static func intToRoman(_ n: Int) -> String {
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
        ]
        var n = n
        var out = ""
        for (value, symbol) in table {
            while n >= value { out += symbol; n -= value }
        }
        return out
    }

    /// A plausible TOC entry title: non-trivial length, contains a
    /// letter, and has at least one uppercase letter (titles are
    /// Title-Case; this filters stray lowercase fragments).
    static func isPlausibleEntryTitle(_ title: String) -> Bool {
        guard title.count >= 2, title.count <= 120 else { return false }
        guard title.contains(where: { $0.isLetter }) else { return false }
        return title.contains(where: { $0.isUppercase })
    }

    /// True when the entries' page numbers are *mostly* non-decreasing —
    /// the signature of a real TOC. An index resets/repeats numbers per
    /// letter and a prose run has no number cadence, so both fail this.
    /// Tolerant (≥ 0.7 of adjacent pairs) because OCR scrambles a few
    /// numbers (observed in GEB: "BlooP and FlooP and GlooP 285 337 …").
    static func pageNumbersMostlyIncreasing(_ entries: [PDFTOCDetector.Entry]) -> Bool {
        guard entries.count >= 2 else { return false }
        var nonDecreasing = 0
        for i in 1..<entries.count where entries[i].pageNumber >= entries[i - 1].pageNumber {
            nonDecreasing += 1
        }
        let ratio = Double(nonDecreasing) / Double(entries.count - 1)
        return ratio >= 0.7
    }
}

// ========== BLOCK 01: GENERALIZED PDF TOC DETECTOR - END ==========
