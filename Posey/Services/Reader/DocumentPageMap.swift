import Foundation

// ========== BLOCK 01: PAGE MAP - START ==========
/// Maps a 1-indexed page number to the plainText offset where that
/// page starts. Built once at reader-view-model init from data we
/// already have (PDF: `pageBreak` units + their plainText offsets;
/// EPUB: "Page N" TOC entries) so no schema migration is needed for
/// v1's "Go to page" jump.
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
    /// type. Pure function so the call site stays simple.
    ///
    /// - `tocEntries` are consulted only for EPUB (the "Page N" spine
    ///   shape).
    /// - `units` + `plainTextOffsetByUnitID` are consulted only for PDF:
    ///   the unit list carries `pageBreak` units (one per page, with a
    ///   0-based `metadata.pageNumber`), and the offset map gives each
    ///   unit's global plainText offset. Both are threaded through both
    ///   paths to keep the API uniform; non-PDF callers can omit them.
    static func build(for document: Document,
                      tocEntries: [StoredTOCEntry],
                      units: [ContentUnit] = [],
                      plainTextOffsetByUnitID: [UUID: Int] = [:]) -> DocumentPageMap {
        switch document.fileType.lowercased() {
        case "pdf":
            return buildForPDF(units: units,
                               plainTextOffsetByUnitID: plainTextOffsetByUnitID)
        case "epub":
            return buildForEPUB(tocEntries: tocEntries)
        default:
            return .empty
        }
    }

    /// Build a page map for a PDF from its content units.
    ///
    /// **Why units, not displayText (audit fix #3, 2026-06-08).** The
    /// previous implementation split `document.displayText` on `\u{000C}`
    /// form feeds and assumed each chunk == one plainText page joined by
    /// `\n\n`. That broke two ways: (1) the derived `displayText` no
    /// longer carries form feeds at all — pagination moved to `pageBreak`
    /// units (DatabaseManager `displayText(for:)` just joins prose units),
    /// so the split produced a single chunk and every PDF collapsed to one
    /// page; and (2) even with form feeds it double-counted visual/blank
    /// pages, drifting offsets on any PDF with a cover/figure/OCR-rejected
    /// page (the form-feed chunk had a `\n\n` added for it, but plainText
    /// has none — visual pages aren't prose-bearing).
    ///
    /// The units ARE the source of truth. Each `pageBreak` unit marks the
    /// start of a 0-based PDF page; its entry in `plainTextOffsetByUnitID`
    /// is the global plainText offset where that page's first prose begins.
    /// That holds because the offset map records the *cumulative* offset at
    /// the break, and pageBreak/image units don't advance the cumulative —
    /// so a visual or blank page resolves to the next text content, which
    /// is the only place go-to-page can land (those pages carry no
    /// sentences). User-facing page numbers are 1-based (`pageNumber + 1`).
    static func buildForPDF(units: [ContentUnit],
                            plainTextOffsetByUnitID: [UUID: Int]) -> DocumentPageMap {
        guard !units.isEmpty else { return .empty }

        // Collect (1-based page, plainText offset) from every pageBreak.
        var pairs: [(page: Int, offset: Int)] = []
        for unit in units where unit.kind == .pageBreak {
            guard let zeroBasedPage = unit.metadata.pageNumber,
                  let offset = plainTextOffsetByUnitID[unit.id] else { continue }
            pairs.append((page: zeroBasedPage + 1, offset: offset))
        }
        guard !pairs.isEmpty else { return .empty }

        // Sort by page (units are normally already in page order, but a
        // re-detect/rewrite could reorder). Then build a dense 1-indexed
        // array, backfilling gaps (blank pages skipped by the importer)
        // with the previous known offset so a typed in-gap page lands
        // reasonably rather than out of range — same policy as buildForEPUB.
        pairs.sort { $0.page < $1.page }
        let maxPage = pairs.last!.page
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
}
// ========== BLOCK 02: BUILDERS - END ==========
