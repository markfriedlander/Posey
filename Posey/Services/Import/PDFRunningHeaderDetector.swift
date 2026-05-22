import Foundation
import PDFKit

// ========== BLOCK 01: PDF RUNNING HEADER DETECTOR - START ==========

/// Detects repeating running headers / footers in a `PDFDocument` and
/// returns, per page, the substring ranges in `page.string` that
/// should be excluded from the extracted plainText.
///
/// Running headers/footers in real-world PDFs share a consistent shape:
/// short text fragments at the top OR bottom of each page that repeat
/// across many consecutive pages with only a numeric or roman-numeral
/// page-number-like component varying. Examples observed during the
/// 2026-05-22 GEB visual audit:
///
///   "The MU-puzzle 49", "The MU-puzzle 50", "The MU-puzzle 51", …
///   "A Mu Offering 249", "A Mu Offering 250", …
///   "Contents I", "Contents II", "Contents III"
///   Plain "42", "43", "44", … (bare page-number footers)
///
/// Without stripping, these contaminate every aspect of the reading
/// experience: TTS reads them aloud once per page, search/RAG indexes
/// them as if they were content, and the smart-skip detector trips
/// on them as if they were dot-leader TOC patterns.
///
/// Algorithm (string-pattern, not geometric):
///
///   1. For each page, isolate the FIRST line and the LAST line of
///      `page.string`. PDFKit places running headers/footers at
///      predictable string positions — bottom footers as the last
///      line, top headers as the first line.
///   2. Normalize each candidate by replacing `\d+` with `<N>` and
///      `\b[ivxlcdm]+\b` (case-insensitive) with `<R>`.
///   3. Require the normalized form to DIFFER from the original
///      (i.e., a number/roman substitution actually happened). This
///      protects against legitimate page-starting content like
///      "Preface" or "Introduction" that doesn't have page-number
///      variation. Real running headers always carry a page number.
///   4. Group candidates by (zone, normalized text). If ≥3
///      occurrences across pages in the same zone, mark every
///      occurrence's character range for stripping.
///   5. Safety valve: skip stripping any page where the strip would
///      remove > 30% of the page's characters (probably a false
///      positive — page is too short for the assumption to hold).
///
/// The geometric approach (per-character Y position) was tried first
/// but PDFKit's `characterBounds(at:)` is unreliable for many
/// characters — footers in particular often have empty bounds for
/// glyphs that PDFKit can't resolve positionally. The string-pattern
/// approach is geometry-free and works as long as the running header
/// is at a predictable position in `page.string` — which holds for
/// every PDF I've seen so far.
///
/// Output is keyed by page index (0-based, matching `PDFDocument`),
/// values are arrays of `Range<Int>` in `page.string`'s utf16 index
/// space (matching what `applyStrips` consumes).
struct PDFRunningHeaderDetector {

    // MARK: Tunables

    /// A `(zone, normalizedText)` group must appear at least this many
    /// times across the document to be classified as a running header.
    /// 3 catches narrow patterns (3-page prefaces with a footer)
    /// without false-positive on single-page banners.
    static let minRepetitionCount: Int = 3

    /// Per-occurrence neighbour-density check. For an individual
    /// occurrence on page p to be stripped, at least
    /// `minNeighboursWithinWindow` OTHER occurrences of the same
    /// (zone, normalized) must appear within ±neighborPageWindow pages
    /// of p.
    ///
    /// This distinguishes true running headers (appear on
    /// consecutive pages of a chapter) from per-chapter headings
    /// that share a normalized form but are 15-50 pages apart
    /// (e.g., "CHAPTER III", "CHAPTER IV", "CHAPTER V" — same
    /// normalized "CHAPTER <R>" but only one per chapter).
    ///
    /// 2026-05-22 — added after GEB.docx test showed the
    /// chapter-start "CHAPTER <R>" headings being false-positively
    /// stripped from their (single) chapter-start page.
    static let neighborPageWindow: Int = 5
    static let minNeighboursWithinWindow: Int = 2

    /// Pages shorter than this many characters are too short to have
    /// a meaningful "first line vs body" or "body vs last line"
    /// distinction. Skip them.
    static let minPageChars: Int = 80

    /// Candidate header/footer lines longer than this character count
    /// are dropped. Running headers are short; long lines at top or
    /// bottom of a page are almost always body content.
    static let maxCandidateLength: Int = 120

    /// Safety valve. If applying strips to a page would remove more
    /// than this fraction of its characters, skip stripping that
    /// page (probably a false positive). Defends against unusual
    /// short pages where the assumption breaks down.
    static let maxPageStripFraction: Double = 0.30

    // MARK: Public

    /// Walk the document, detect running headers/footers, return per-
    /// page character ranges to strip from `page.string` during text
    /// extraction.
    static func detect(in document: PDFDocument) -> [Int: [Range<Int>]] {
        let candidates = collectCandidates(in: document)
        let runningHeaders = filterToRunningHeaders(candidates: candidates)
        return assemblePerPageStrips(from: runningHeaders)
    }

    /// Apply the per-page strip ranges to `pageString` and return the
    /// cleaned text. Ranges are in `pageString.utf16` units. Pages
    /// where the strip would exceed the safety threshold are returned
    /// unmodified.
    static func applyStrips(_ ranges: [Range<Int>], to pageString: String) -> String {
        guard !ranges.isEmpty else { return pageString }
        let utf16 = Array(pageString.utf16)
        let total = utf16.count
        let stripChars = ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        if Double(stripChars) / Double(max(1, total)) > maxPageStripFraction {
            return pageString
        }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var pieces: [String] = []
        var cursor = 0
        for r in sorted {
            let lo = min(max(r.lowerBound, 0), utf16.count)
            let hi = min(max(r.upperBound, lo), utf16.count)
            if cursor < lo {
                let chunk = Array(utf16[cursor..<lo])
                pieces.append(String(utf16CodeUnits: chunk, count: chunk.count))
            }
            cursor = hi
        }
        if cursor < utf16.count {
            let chunk = Array(utf16[cursor..<utf16.count])
            pieces.append(String(utf16CodeUnits: chunk, count: chunk.count))
        }
        return pieces.joined()
    }

    // MARK: Internal

    fileprivate enum Zone {
        case head   // first line of page.string
        case tail   // last line of page.string
    }

    fileprivate struct Candidate {
        let pageIndex: Int
        let zone: Zone
        /// UTF-16 range in page.string of the candidate line, INCLUDING
        /// its trailing newline (so stripping removes the empty-line
        /// artifact a stripped header/footer would leave).
        let range: Range<Int>
        let text: String
        let normalized: String
    }

    fileprivate static func collectCandidates(in document: PDFDocument) -> [Candidate] {
        var out: [Candidate] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageString = page.string ?? ""
            let utf16 = Array(pageString.utf16)
            guard utf16.count >= minPageChars else { continue }

            // First-line candidate (HEAD).
            if let (range, text) = firstLine(of: utf16),
               text.count <= maxCandidateLength {
                let normalized = normalize(text)
                if normalized != text {
                    out.append(Candidate(
                        pageIndex: pageIndex, zone: .head,
                        range: range, text: text, normalized: normalized
                    ))
                }
            }

            // Last-line candidate (TAIL).
            if let (range, text) = lastLine(of: utf16),
               text.count <= maxCandidateLength {
                let normalized = normalize(text)
                if normalized != text {
                    out.append(Candidate(
                        pageIndex: pageIndex, zone: .tail,
                        range: range, text: text, normalized: normalized
                    ))
                }
            }
        }
        return out
    }

    fileprivate static func firstLine(of utf16: [UInt16]) -> (range: Range<Int>, text: String)? {
        // Skip leading blank/whitespace-only lines, take the first
        // non-empty line. Range covers from the start of the page
        // through the newline that terminates this line (so removing
        // it doesn't leave a blank-line artifact).
        var i = 0
        var lineStart = 0
        while i < utf16.count {
            let c = utf16[i]
            if c == 0x0A { // \n
                let chunk = Array(utf16[lineStart..<i])
                let raw = String(utf16CodeUnits: chunk, count: chunk.count)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return (lineStart..<(i + 1), trimmed)
                }
                lineStart = i + 1
            }
            i += 1
        }
        // No newline at all — entire page is one line.
        let chunk = Array(utf16[lineStart..<utf16.count])
        let raw = String(utf16CodeUnits: chunk, count: chunk.count)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (lineStart..<utf16.count, trimmed)
    }

    fileprivate static func lastLine(of utf16: [UInt16]) -> (range: Range<Int>, text: String)? {
        var i = utf16.count - 1
        // Skip trailing whitespace.
        while i >= 0 {
            let c = utf16[i]
            if c == 0x0A || c == 0x20 || c == 0x09 || c == 0x0D { i -= 1; continue }
            break
        }
        guard i >= 0 else { return nil }
        // Walk back to find the start of the last non-empty line.
        let lineEndExclusive = i + 1
        var j = i
        while j >= 0 && utf16[j] != 0x0A { j -= 1 }
        let lineStart = j + 1  // char after the \n (or 0 if no \n found)
        let chunk = Array(utf16[lineStart..<lineEndExclusive])
        let raw = String(utf16CodeUnits: chunk, count: chunk.count)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Extend the range BACKWARD to include the leading newline
        // that introduces this line, if present (so we don't leave a
        // blank line behind after stripping).
        let rangeStart = (lineStart > 0 && utf16[lineStart - 1] == 0x0A)
            ? lineStart - 1 : lineStart
        return (rangeStart..<lineEndExclusive, trimmed)
    }

    fileprivate static func filterToRunningHeaders(
        candidates: [Candidate]
    ) -> [Candidate] {
        var groups: [String: [Candidate]] = [:]
        for c in candidates {
            let key = "\(c.zone)|\(c.normalized)"
            groups[key, default: []].append(c)
        }
        var out: [Candidate] = []
        for (_, list) in groups where list.count >= minRepetitionCount {
            // 2026-05-22 — Per-occurrence density check. A running
            // header repeats on NEAR-CONSECUTIVE pages of a chapter.
            // A per-chapter heading (e.g., "CHAPTER III" on the body
            // page where chapter III starts) repeats too if you look
            // at the document as a whole, but each instance is
            // 15-50 pages apart from the next. Distinguish by
            // requiring each occurrence to have at least
            // `minNeighboursWithinWindow` siblings within ±window
            // pages.
            let pageSet = Set(list.map { $0.pageIndex })
            for c in list {
                var neighbours = 0
                for off in 1...neighborPageWindow {
                    if pageSet.contains(c.pageIndex - off) { neighbours += 1 }
                    if pageSet.contains(c.pageIndex + off) { neighbours += 1 }
                    if neighbours >= minNeighboursWithinWindow { break }
                }
                if neighbours >= minNeighboursWithinWindow {
                    out.append(c)
                }
            }
        }
        return out
    }

    fileprivate static func assemblePerPageStrips(
        from cands: [Candidate]
    ) -> [Int: [Range<Int>]] {
        var out: [Int: [Range<Int>]] = [:]
        for c in cands {
            out[c.pageIndex, default: []].append(c.range)
        }
        return out
    }

    fileprivate static func normalize(_ text: String) -> String {
        var s = text
        // Collapse internal whitespace.
        if let ws = try? NSRegularExpression(pattern: #"\s+"#) {
            s = ws.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        }
        // Replace digit runs.
        if let digits = try? NSRegularExpression(pattern: #"\d+"#) {
            s = digits.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "<N>")
        }
        // Replace standalone roman-numeral words (case-insensitive).
        if let romans = try? NSRegularExpression(
            pattern: #"\b[ivxlcdm]+\b"#,
            options: [.caseInsensitive]
        ) {
            s = romans.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "<R>")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// ========== BLOCK 01: PDF RUNNING HEADER DETECTOR - END ==========
