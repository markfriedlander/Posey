import Foundation

// ========== BLOCK 01: GENERALIZED PDF TOC DETECTOR - START ==========

/// Fallback TOC detector for PDFs that have NEITHER a structural
/// outline (`PDFDocument.outlineRoot`) NOR a classic dot-leader TOC
/// page that `PDFTOCDetector` can fire on.
///
/// This detector looks for a dense cluster of lines that look like
/// chapter/part/section/appendix entries on the document's first few
/// pages. The shape it matches is the universal "outline listing"
/// shape:
///
///     Chapter 1 [optional leader/dash/spaces] [optional title]
///     Chapter 2 - Major League Algorithms
///     Part III. Putting Encryption Technologies to Work for You
///     Appendix A: Cryptographic Attacks
///
/// The detector is conservative on purpose: it requires BOTH a TOC
/// anchor word (`Contents` / `Table of Contents`) somewhere in the
/// candidate region AND a sufficient density of chapter-shaped lines.
/// False positives here would silently skip real content.
///
/// Used as the third-tier signal in `PDFDocumentImporter`:
///   1. Dot-leader text scan (`PDFTOCDetector`)
///   2. Outline walker (`TOCWalkContentStartDetector` on
///      `PDFDocument.outlineRoot` entries)
///   3. This generalized text scan
///
/// Returns nil when no signal is strong enough — caller leaves the
/// skip at zero rather than guessing.
///
/// Added 2026-05-22 as the safety net for the rare PDF that ships
/// neither an outline nor dot-leader formatting.
struct PDFGeneralizedTOCDetector {

    struct Result: Equatable {
        /// Character offset in plainText where the TOC region starts.
        let regionStartOffset: Int
        /// Character offset in plainText where the TOC region ends —
        /// the body begins here.
        let regionEndOffset: Int
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

        // Find the first page that BOTH contains a Contents anchor
        // AND has at least 5 entry-shaped lines.
        var anchorIndex: Int? = nil
        for i in 0..<searchLimit where isTOCPage(pageTexts[i]) {
            anchorIndex = i
            break
        }
        guard let firstTOCPage = anchorIndex else { return nil }

        // Extend forward while pages look like dense entry listings.
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

        return Result(regionStartOffset: regionStart,
                      regionEndOffset: regionEnd)
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: - Heuristics

    /// True when a page has BOTH a Contents anchor phrase AND ≥5 lines
    /// that look like chapter/part/section/appendix entries.
    static func isTOCPage(_ pageText: String) -> Bool {
        guard hasContentsAnchor(in: pageText) else { return false }
        return entryShapedLineCount(in: pageText) >= 5
    }

    /// True when a page lacks the anchor but is dominated by entry-
    /// shaped lines (used to extend the region across a multi-page TOC).
    static func isContinuationOfTOC(_ pageText: String) -> Bool {
        let count = entryShapedLineCount(in: pageText)
        guard count >= 5 else { return false }
        let charsPerEntry = pageText.count / max(count, 1)
        return charsPerEntry < 250
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

    /// Count lines on a page that begin with a recognized structural
    /// label — Chapter / Part / Section / Appendix / Book / Volume —
    /// followed by a number or roman numeral. The leader between the
    /// label and the title can be a dash, a colon, a dot, multiple
    /// dots, multiple spaces, or nothing at all. Page numbers at the
    /// end of the line are optional.
    static func entryShapedLineCount(in pageText: String) -> Int {
        // Word-anchored at line start, label + (roman | digits),
        // optional title chunk. The whole pattern allows leader/title
        // to be empty — "Chapter 1" on its own line still counts.
        let pattern = #"(?im)^\s*(?:chapter|part|section|appendix|book|volume)\s+[ivxlcdm0-9]+\b.{0,200}$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(pageText.startIndex..., in: pageText)
        return regex.numberOfMatches(in: pageText, range: range)
    }
}

// ========== BLOCK 01: GENERALIZED PDF TOC DETECTOR - END ==========
