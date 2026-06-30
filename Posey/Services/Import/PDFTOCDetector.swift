import Foundation

// ========== BLOCK 01: PDF TOC DETECTOR - START ==========

/// Detects a Table of Contents region in a multi-page PDF and (best-effort)
/// parses its individual entries. Used by `PDFDocumentImporter` to mark a
/// playback-skip region so the user doesn't have to listen to the TOC read
/// aloud — a uniformly poor TTS experience — and to populate the existing
/// TOC sheet for navigation.
///
/// The detector is conservative on purpose: false-positives (treating ordinary
/// prose as TOC) would cause the reader to silently skip real content. The
/// algorithm therefore requires BOTH a TOC anchor phrase AND a high density
/// of dot-leader entries on the same page.
struct PDFTOCDetector {

    /// One detected entry. `title` is the visible label; `pageNumber` is the
    /// page number printed in the TOC (NOT the document's logical page index).
    struct Entry: Equatable {
        let title: String
        let pageNumber: Int
    }

    /// Result of running the detector.
    /// - regionStartOffset / regionEndOffset are character offsets into
    ///   plainText (the joined-pages plain string). The body of the document
    ///   begins at `regionEndOffset`.
    /// - entries are the parsed TOC entries, in document order. Empty if
    ///   parsing failed but the region was still detected.
    struct Result: Equatable {
        let regionStartOffset: Int
        let regionEndOffset: Int
        let entries: [Entry]
    }

    /// Run detection over a sequence of per-page plaintext strings as joined
    /// with `\n\n` (the same shape used by `PDFDocumentImporter` to build
    /// `plainText`). The detector returns nil when no TOC is found.
    static func detect(pageTexts: [String]) -> Result? {
        guard !pageTexts.isEmpty else { return nil }

        // Find the first TOC-anchor page. Limit search to the first 5 pages —
        // a TOC further into a document is too risky to auto-skip.
        let searchLimit = min(5, pageTexts.count)
        var anchorIndex: Int? = nil
        for i in 0..<searchLimit where isTOCPage(pageTexts[i]) {
            anchorIndex = i
            break
        }
        guard let firstTOCPage = anchorIndex else { return nil }

        // Walk forward while subsequent pages look like TOC continuations.
        var lastTOCPage = firstTOCPage
        var nextPage = firstTOCPage + 1
        while nextPage < pageTexts.count, isContinuationOfTOC(pageTexts[nextPage]) {
            lastTOCPage = nextPage
            nextPage += 1
        }

        // Compute character offsets in the joined plainText.
        // plainText = pageTexts.joined(separator: "\n\n")
        let separatorLen = 2
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
        // End points just after the last TOC page; +separatorLen lands on the
        // first character of the body page.
        let regionEnd = regionStart + tocLen + separatorLen

        let entries = parseEntries(in: tocSlice.joined(separator: "\n\n"))

        return Result(regionStartOffset: regionStart,
                      regionEndOffset: regionEnd,
                      entries: entries)
    }

    // ========== BLOCK 01: PDF TOC DETECTOR - END ==========

    // ========== BLOCK 02: PAGE-LEVEL HEURISTICS - START ==========

    /// Returns true when a page contains the canonical TOC anchor phrase AND
    /// has enough dot-leader entries to justify a region-skip.
    static func isTOCPage(_ pageText: String) -> Bool {
        let lower = pageText.lowercased()
        // Anchor phrase. We accept the long form "table of contents" or a
        // standalone "contents" surrounded by whitespace. We deliberately
        // do NOT accept "contents" inline in the middle of prose.
        let hasAnchor = lower.contains("table of contents") || hasStandaloneContents(in: lower)
        guard hasAnchor else { return false }
        return dotLeaderEntryCount(in: pageText) >= 5
    }

    /// Returns true when a page lacks the anchor but still looks dominated by
    /// TOC entries — used to extend the region across a multi-page TOC.
    static func isContinuationOfTOC(_ pageText: String) -> Bool {
        let dotLeaders = dotLeaderEntryCount(in: pageText)
        guard dotLeaders >= 5 else { return false }
        // Density check — a TOC continuation page is mostly entries, not prose.
        // A typical entry is ~50–100 chars, so a TOC-dominant page has
        // (chars / dotLeaders) < ~120.
        let charsPerEntry = pageText.count / max(dotLeaders, 1)
        return charsPerEntry < 200
    }

    private static func hasStandaloneContents(in lower: String) -> Bool {
        // Match \bcontents\b at a position where nothing prose-like immediately
        // precedes it. Allow start-of-string or whitespace/newline before.
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|[\s])contents(?:[\s]|$)"#) else {
            return false
        }
        let range = NSRange(lower.startIndex..., in: lower)
        return regex.firstMatch(in: lower, range: range) != nil
    }

    /// Counts dot-leader entries on a page. A dot leader is two-or-more dots
    /// (or Unicode horizontal ellipsis `…`) followed by optional whitespace
    /// and a number — the canonical visual cue of a TOC entry.
    static func dotLeaderEntryCount(in pageText: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"[.…]{2,}\s*\d+"#) else {
            return 0
        }
        let range = NSRange(pageText.startIndex..., in: pageText)
        return regex.numberOfMatches(in: pageText, range: range)
    }

    // ========== BLOCK 02: PAGE-LEVEL HEURISTICS - END ==========

    // ========== BLOCK 03: ENTRY PARSING - START ==========

    /// Best-effort entry extraction. The structure of TOC entries is:
    ///
    ///     <label>. <title> [<dot leaders or spaces>] <page number>
    ///
    /// where the label is a roman numeral (`I`, `II`, `III`, `IV`, …),
    /// a single capital letter (`A`, `B`, `C`, …), a digit (`1`, `2`),
    /// or a lowercase letter (`a`, `b`, `c`, …) — i.e. the conventional
    /// nested-outline shapes academic and legal documents use.
    ///
    /// The regex is intentionally forgiving: dot leaders can be 0 or more
    /// dots/ellipsis, the title can include normal punctuation, and the
    /// trailing page number is digits only.
    ///
    /// This will miss exotic formats (Chinese numerals, custom symbols) and
    /// occasionally produce partial titles. That's an acceptable tradeoff —
    /// the playback-skip region is the primary value of detection; entries
    /// are a secondary navigation aid.
    static func parseEntries(in tocText: String) -> [Entry] {
        // LINE-BASED STITCHING PARSE (2026-06-29, rebuild). The prior single
        // regex over the whole concatenated TOC could not handle entries whose
        // TITLE WRAPS across multiple lines — common in legal docs, textbooks,
        // and manuals (the SAG-AFTRA Codified Basic Agreement dropped §4/§7/§8/
        // §11/§25/§26/§31 because their titles span 2–3 lines, often with embedded
        // numbers like "January 31, 1960" that confused the page-number capture).
        //
        // The robust, general signal: a TOC entry ENDS at a line carrying
        // dot-leaders followed by a page number; any line WITHOUT that is a
        // wrapped continuation of the current title. We accumulate lines into a
        // buffer, emit on a terminator line, and start a fresh entry whenever a
        // line begins with a label ("N." / "N.N." / Roman) — which discards
        // page-header junk that precedes the first real entry.
        let lines = tocText
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard
            // Dot-leader terminator: ≥1 dot/ellipsis then a trailing page number.
            let termDots = try? NSRegularExpression(pattern: #"[.…]+\s*(\d{1,4})\s*$"#),
            // A bare trailing page number (no dot leaders) — only trusted on a
            // line that itself starts with a label (a complete single-line entry
            // like "28. Injuries … Safety 84"). Wrapped continuation lines never
            // start with a label, so this can't false-terminate a multi-line title.
            let endNum = try? NSRegularExpression(pattern: #"\s(\d{1,4})\s*$"#),
            // Label start: "N." / "N.N." / Roman numeral, then a space + content.
            let label = try? NSRegularExpression(pattern: #"^(?:\d+(?:\.\d+)?|[IVXLCDM]+)\.\s+\S"#)
        else { return [] }
        func match(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
            re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
        }
        // The page number a line ends an entry at, or nil if it's a continuation.
        func terminatorPage(_ s: String, isLabelStart: Bool) -> Int? {
            if let m = match(termDots, s), let r = Range(m.range(at: 1), in: s) { return Int(s[r]) }
            if isLabelStart, let m = match(endNum, s), let r = Range(m.range(at: 1), in: s) { return Int(s[r]) }
            return nil
        }

        var entries: [Entry] = []
        var buffer: [String] = []
        for line in lines {
            let isLabelStart = match(label, line) != nil
            // A new labelled entry begins: drop any unterminated buffer (page-header
            // junk / a malformed prior fragment) so it doesn't pollute this title.
            if isLabelStart, !buffer.isEmpty,
               terminatorPage(buffer.joined(separator: " "),
                              isLabelStart: match(label, buffer[0]) != nil) == nil {
                buffer.removeAll(keepingCapacity: true)
            }
            buffer.append(line)

            if let page = terminatorPage(line, isLabelStart: isLabelStart), page > 0 {
                let joined = buffer.joined(separator: " ")
                let title = joined
                    .replacingOccurrences(of: #"[.…]*\s*\d{1,4}\s*$"#, with: "",
                                          options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                // Keep an entry that either is labelled or was stitched from a
                // wrapped title (>1 line); reject stray single junk lines.
                if !title.isEmpty, title.count < 300,
                   (match(label, title) != nil || buffer.count > 1) {
                    entries.append(Entry(title: title, pageNumber: page))
                }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        return entries
    }

    // ========== BLOCK 03: ENTRY PARSING - END ==========
}
