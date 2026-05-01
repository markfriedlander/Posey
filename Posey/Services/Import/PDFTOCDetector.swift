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
        // Strip the anchor header so it doesn't confuse the entry scan.
        let cleaned = tocText.replacingOccurrences(of: "Table of Contents",
                                                   with: " ",
                                                   options: .caseInsensitive)
        // The regex breaks the text at label markers and captures
        // (label) (title-with-dots) (page number).
        // Title content is allowed to include letters, digits, common
        // punctuation, and embedded periods (e.g., "v." in "RIAA v. mp3.com").
        // Lookahead requires the ENTRY end (digits then label-marker or end).
        let pattern = #"""
        (?xs)
        (?<![A-Za-z])                                  # label is not glued to a word
        ([IVXLCDM]+|[A-Z]|\d+|[a-z])                   # 1: label
        \.                                             # literal "."
        \s+
        ([A-Z][^.…]*?(?:[.…][^.…]*?)*?)                # 2: title — allow embedded dots
        \s*[.…]{0,}\s*                                 # optional dot leaders
        (\d{1,4})                                      # 3: page number
        (?=\s+(?:[IVXLCDM]+|[A-Z]|\d+|[a-z])\.\s|\s*$) # next label or end
        """#

        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.allowCommentsAndWhitespace]) else {
            return []
        }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        var entries: [Entry] = []
        regex.enumerateMatches(in: cleaned, range: range) { match, _, _ in
            guard let match,
                  match.numberOfRanges == 4,
                  let labelRange = Range(match.range(at: 1), in: cleaned),
                  let titleRange = Range(match.range(at: 2), in: cleaned),
                  let pageRange  = Range(match.range(at: 3), in: cleaned) else { return }
            let label = String(cleaned[labelRange])
            var title = String(cleaned[titleRange]).trimmingCharacters(in: .whitespaces)
            // Strip trailing dot-leader fragments and run-on of next entry's
            // start (defense in depth — the lookahead should already catch this).
            title = title.replacingOccurrences(of: #"[.…\s]+$"#,
                                               with: "",
                                               options: .regularExpression)
            guard let page = Int(cleaned[pageRange]),
                  !title.isEmpty,
                  title.count < 200
            else { return }
            // Compose the displayed entry like "I. Introduction" — keeping
            // the label preserves context for the navigation list.
            entries.append(Entry(title: "\(label). \(title)", pageNumber: page))
        }
        return entries
    }

    // ========== BLOCK 03: ENTRY PARSING - END ==========
}
