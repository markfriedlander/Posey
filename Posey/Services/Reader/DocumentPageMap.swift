import Foundation

// ========== BLOCK 01: PAGE MAP - START ==========
/// Maps a 1-indexed page number to the plainText offset where that
/// page starts. Built once at reader-view-model init from data we
/// already have (displayText and TOC entries) so no schema migration
/// is needed for v1's "Go to page" jump.
///
/// Construction is per-format — PDFs and EPUBs have different ground
/// truth for what a "page" is — but the public API is uniform. The
/// caller asks `offset(forPage:)` and gets either a plainText offset
/// or `nil` if the page number is out of range or the document has
/// no page-level structure (TXT/MD/RTF/DOCX/HTML produce empty maps).
struct DocumentPageMap: Sendable {

    /// 1-based pageOffsets[N-1] = plainText offset where page N starts.
    /// Empty when the document has no recognizable page structure.
    let pageOffsets: [Int]

    var pageCount: Int { pageOffsets.count }

    /// True when there's enough page data to make a Go-to-page input
    /// useful. UI gates on this so we don't render the input for
    /// formats that can't honor it.
    var hasPages: Bool { !pageOffsets.isEmpty }

    /// Resolve a 1-indexed page number to its plainText offset.
    /// Returns nil for out-of-range numbers — caller surfaces a
    /// gentle error in the UI ("page out of range") rather than
    /// silently jumping somewhere unexpected.
    func offset(forPage page: Int) -> Int? {
        guard page >= 1, page <= pageOffsets.count else { return nil }
        return pageOffsets[page - 1]
    }

    /// Range of valid pages, 1-indexed inclusive. Empty when the map
    /// has no pages.
    var pageRange: ClosedRange<Int>? {
        guard pageOffsets.count > 0 else { return nil }
        return 1...pageOffsets.count
    }
}
// ========== BLOCK 01: PAGE MAP - END ==========


// ========== BLOCK 02: BUILDERS - START ==========
extension DocumentPageMap {

    /// Empty map for formats with no page concept (TXT/MD/RTF/DOCX/HTML).
    /// Caller's UI hides the Go-to-page input when `hasPages == false`.
    static let empty = DocumentPageMap(pageOffsets: [])

    /// Build a page map for any document by dispatching on its file
    /// type. Pure function so the call site stays simple. Caller
    /// supplies the document's persisted TOC entries (from
    /// `document_toc`); they're only consulted for EPUB but threading
    /// them through both paths keeps the API uniform.
    static func build(for document: Document, tocEntries: [StoredTOCEntry]) -> DocumentPageMap {
        switch document.fileType.lowercased() {
        case "pdf":
            return buildForPDF(displayText: document.displayText)
        case "epub":
            return buildForEPUB(tocEntries: tocEntries)
        default:
            return .empty
        }
    }

    /// Build a page map for a PDF from its `displayText`. Pages are
    /// separated by `\u{000C}` (form feed) in displayText. The
    /// corresponding plainText separator is `\n\n` (two characters).
    /// Visual-only pages are written as `[[POSEY_VISUAL_PAGE:N:UUID]]`
    /// markers in displayText and are NOT present in plainText, so we
    /// account for them by tracking how many displayText chars get
    /// stripped per page.
    static func buildForPDF(displayText: String) -> DocumentPageMap {
        guard !displayText.isEmpty else { return .empty }

        // Each page in displayText = the substring between consecutive
        // form feeds (or document edges). For each page we compute the
        // length of the corresponding plainText slice (which is just
        // the page text WITHOUT the visual-page markers — those are
        // stripped during plainText construction).
        var offsets: [Int] = [0]  // page 1 starts at plainText offset 0
        var plainOffset = 0
        let pages = displayText.components(separatedBy: "\u{000C}")
        for (index, page) in pages.enumerated() {
            // The plainText length contributed by this page: the page
            // text minus any visual-page markers.
            let plainPage = stripVisualPageMarkers(from: page)
            plainOffset += plainPage.count
            // The next page starts AFTER the "\n\n" separator that was
            // inserted in plainText between pages. The last page has
            // no trailing separator.
            if index < pages.count - 1 {
                plainOffset += 2 // "\n\n"
                offsets.append(plainOffset)
            }
        }
        return DocumentPageMap(pageOffsets: offsets)
    }

    /// Build a page map for an EPUB from its parsed TOC entries.
    /// We look for entries whose titles look like "Page N" (the
    /// shape produced by the spine-fallback synthesizer for
    /// hocr-to-epub-style EPUBs). Entries whose offsets are
    /// negative (-1 means "couldn't resolve href") are skipped.
    /// For EPUBs whose TOC is chapter-titled rather than page-titled,
    /// the map is empty and the Go-to-page input stays hidden — there
    /// IS no per-page metadata to honor.
    static func buildForEPUB(tocEntries: [StoredTOCEntry]) -> DocumentPageMap {
        guard !tocEntries.isEmpty else { return .empty }

        // Pull (pageNumber, offset) pairs from any "Page N" titles.
        // We accept "Page 1", "page 1", "Page 1.", "Page 1 — Foo" etc.
        // — the regex grabs the first integer after the word "page".
        let pattern = #"(?i)\bpage\b\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return .empty
        }
        var pairs: [(page: Int, offset: Int)] = []
        for entry in tocEntries {
            guard entry.plainTextOffset >= 0 else { continue }
            let title = entry.title
            let range = NSRange(title.startIndex..<title.endIndex, in: title)
            if let match = regex.firstMatch(in: title, options: [], range: range),
               match.numberOfRanges >= 2,
               let numRange = Range(match.range(at: 1), in: title),
               let n = Int(title[numRange]) {
                pairs.append((page: n, offset: entry.plainTextOffset))
            }
        }
        guard !pairs.isEmpty else { return .empty }

        // Sort by page number ascending. Some EPUB TOCs aren't in
        // strict page order (rare, but possible — a navMap with
        // forward-references) and we want the lookup table dense.
        pairs.sort { $0.page < $1.page }

        // Build a 1-indexed dense array. We accept gaps: if pages
        // 1, 2, 4 are present we extend the array to length 4 and
        // backfill page 3 with the previous known offset (page 2's)
        // so a user typing "3" jumps somewhere reasonable rather
        // than nowhere. This is a v1 best-effort; future work can
        // add per-page metadata to the database for stricter
        // accuracy.
        let maxPage = pairs.last?.page ?? 0
        guard maxPage >= 1 else { return .empty }
        var offsets = Array(repeating: 0, count: maxPage)
        var lastOffset = 0
        var nextPair = 0
        for page in 1...maxPage {
            if nextPair < pairs.count, pairs[nextPair].page == page {
                offsets[page - 1] = pairs[nextPair].offset
                lastOffset = pairs[nextPair].offset
                nextPair += 1
            } else {
                offsets[page - 1] = lastOffset
            }
        }
        return DocumentPageMap(pageOffsets: offsets)
    }

    /// Strip `[[POSEY_VISUAL_PAGE:N:UUID]]` markers (and the older
    /// no-UUID variant `[[POSEY_VISUAL_PAGE:N]]`) from a string
    /// without otherwise altering it. Used to compute plainText-
    /// equivalent length per PDF page.
    fileprivate static func stripVisualPageMarkers(from text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[\[POSEY_VISUAL_PAGE:[^\]]*\]\]"#,
            options: []
        ) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: ""
        )
    }
}
// ========== BLOCK 02: BUILDERS - END ==========
