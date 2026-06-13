import Foundation

// ========== BLOCK 01: PDF TEXT-PATTERN STRUCTURE DETECTOR - START ==========

/// Shared TEXT-PATTERN structure detection for PDFs — the dot-leader
/// (`PDFTOCDetector`) and run-on/whitespace (`PDFGeneralizedTOCDetector`)
/// detectors, plus the `buildEntries` title→offset resolver.
///
/// **Why this type exists (2026-05-31, ingestion audit — Bug F).** TOC and
/// heading detection used to run exactly once, at Tier-1 import, inside
/// `PDFDocumentImporter.parsedDocument`. For a PDF whose TOC page is a
/// SCANNED IMAGE (no text layer), Tier-1 extracts zero text from that page,
/// so the detectors find nothing and the document opens with 0 navigation.
/// Tier-2 Vision later OCRs the TOC page and fills the text in — but
/// detection never re-ran, so the document stayed 0-nav permanently and the
/// recovered TOC read aloud as a wall of dot-leader prose.
///
/// The fix re-runs detection after enhancement against the corrected unit
/// text. To do that WITHOUT reinventing the importer's logic (Rule 9A — port
/// faithfully, don't pattern-match-and-rebuild), the text-pattern portion is
/// extracted here and called from BOTH sites: `PDFDocumentImporter` (at
/// import) and `PDFEnhancementService` (at end-of-enhancement re-detect).
///
/// **What is and is NOT here.** Only the two detectors that read PAGE TEXT —
/// the exact inputs Tier-2 changes. The importer's *other* TOC strategies —
/// the PDFKit native outline (`document.outlineRoot`) and the outline-walk
/// skip detector (`TOCWalkContentStartDetector`) — are deliberately NOT here:
/// they read the PDF's embedded structural outline, which is import-time
/// metadata that Tier-2 OCR does not change. Re-running them post-enhancement
/// would find exactly what Tier-1 already found. So the re-detect path needs
/// only the text-pattern detectors; the importer keeps its full strategy
/// chain (dot-leader → outline → walker → generalized) inline and calls into
/// this type only for `buildEntries`.
enum PDFTextStructureDetector {

    /// Result of a text-pattern structure pass.
    struct Result {
        /// plainText offset past which the reader auto-skips on first open
        /// (the TOC region end). Zero when nothing was detected.
        let skipOffset: Int
        /// Best-effort navigable TOC entries (each anchored to the title's
        /// first occurrence in the body, after the TOC region).
        let entries: [PDFTOCEntry]

        static let none = Result(skipOffset: 0, entries: [])
    }

    /// Run the text-pattern detectors against per-page text and the joined
    /// plainText. Mirrors `PDFDocumentImporter.parsedDocument`'s dot-leader
    /// pass (lines that produced `tocResult` + `buildEntries`) and its
    /// generalized fallback (the `PDFGeneralizedTOCDetector` branch), in the
    /// same order and with the same precedence: the generalized fallback only
    /// fires when the dot-leader pass produced no skip region, and only
    /// supplies entries when the dot-leader pass produced none.
    ///
    /// - Parameters:
    ///   - pageTexts: per-PDF-page readable text, in page order. For the
    ///     importer this is `readableTextPages`; for the re-detect path it is
    ///     reconstructed from the corrected units (prose text grouped by
    ///     `pageBreak` boundary, joined with "\n\n" — the same join the
    ///     persister uses to build plainText).
    ///   - plainText: the joined document plainText the entry offsets index
    ///     into. Must be the SAME text the units currently produce, or the
    ///     title-search offsets will be wrong.
    static func detect(pageTexts: [String], plainText: String) -> Result {
        // ── Dot-leader detector (primary). ──
        let tocResult = PDFTOCDetector.detect(pageTexts: pageTexts)
        var skipOffset = tocResult?.regionEndOffset ?? 0
        var entries: [PDFTOCEntry] = tocResult.map { result in
            buildEntries(for: result.entries,
                         in: plainText,
                         postTOCOffset: result.regionEndOffset)
        } ?? []

        // ── Generalized run-on / whitespace fallback. ──
        //
        // 2026-05-31 (Bug F) — this runs when the dot-leader pass produced no
        // skip region OR no entries. The "or no entries" half is load-bearing
        // and is where this DELIBERATELY diverges from the importer's inline
        // chain (Rule 9A — the divergence is conscious + documented):
        //
        //   The importer only runs its generalized fallback when
        //   `tocSkipUntilOffset == 0`. That is correct AT IMPORT, where a
        //   dot-leader skip-with-no-entries can still be supplemented by the
        //   PDFKit outline (which the importer tries between the two text
        //   passes). But on the RE-DETECT path there is no outline pass, and an
        //   OCR'd TOC is the exact shape that makes `PDFTOCDetector` fire on
        //   its dot-leader COUNT (≥5 "… 2"/"… 3" cues) yet parse ZERO entries
        //   from the single run-on line — leaving skip>0, entries=0, no nav.
        //   `PDFGeneralizedTOCDetector` is built to parse that run-on shape, so
        //   we MUST reach it whenever entries are still empty, regardless of
        //   the dot-leader skip. Verified on the synthetic scanned-TOC fixture:
        //   dot-leader set skip=221/0-entries; the generalized pass then yields
        //   the 6 chapter entries.
        if skipOffset == 0 || entries.isEmpty,
           let generalized = PDFGeneralizedTOCDetector.detect(pageTexts: pageTexts) {
            if skipOffset == 0 { skipOffset = generalized.regionEndOffset }
            if entries.isEmpty, !generalized.entries.isEmpty {
                entries = buildEntries(for: generalized.entries,
                                       in: plainText,
                                       postTOCOffset: generalized.regionEndOffset)
            }
        }

        return Result(skipOffset: skipOffset, entries: entries)
    }

    /// For each detector entry, find the title's first occurrence in plainText
    /// AFTER the TOC region. That offset is where the chapter actually begins
    /// and is what the TOC sheet jumps to.
    ///
    /// **Moved verbatim from `PDFDocumentImporter.buildEntries` (2026-05-31)**
    /// so the importer and the re-detect path share ONE implementation. The
    /// importer's two former call sites (dot-leader + generalized) now call
    /// here. Behavior is identical — this is a pure relocation, not a rewrite.
    static func buildEntries(for entries: [PDFTOCDetector.Entry],
                             in plainText: String,
                             postTOCOffset: Int) -> [PDFTOCEntry] {
        guard postTOCOffset >= 0, postTOCOffset <= plainText.count else { return [] }
        let total = plainText.count
        guard !entries.isEmpty else { return [] }

        // 2026-06-13 — TOC offset resolution (root-caused in
        // DEFECT-pdf-heading-detection-positioning.md). The previous resolver
        // searched for each title from the START of the body every time and
        // defaulted ANY unlocated title to `postTOCOffset`. Two defects:
        //  (a) a short or repeated title ("Introduction", "Summary") matched its
        //      FIRST body occurrence — often a running header or an earlier
        //      mention — not the chapter it labels, and offsets were not
        //      monotonic; and
        //  (b) every unlocated title collapsed onto the single `postTOCOffset`
        //      anchor, so N chapters shared one offset and `jumpToTOCEntry`
        //      landed them all on the same segment — "tap-nav can't tell the
        //      chapters apart" (GEB / arxiv / The-Internet).
        // Fix: a two-pass resolver that gives EVERY entry a distinct,
        // order-preserving offset.

        // PASS 1 — sequential, monotonic search. TOC entries are in document
        // order, so each chapter's heading appears AFTER the previous one. Search
        // from a cursor that only advances; this resolves a repeated/short title
        // to its correct in-order occurrence and yields distinct offsets for the
        // hits. A title not locatable from the cursor stays nil for pass 2.
        var resolved: [Int?] = []
        var cursor = postTOCOffset
        for entry in entries {
            // Title with its label ("I. Introduction") first, then the bare
            // title ("Introduction") — the body header may omit the label.
            let bareTitle = entry.title.split(separator: " ", maxSplits: 1).last.map(String.init) ?? entry.title
            let needles = [entry.title, bareTitle]
            let searchStart = plainText.index(plainText.startIndex, offsetBy: cursor)
            let region = plainText[searchStart...]
            var found: Int? = nil
            for needle in needles where !needle.isEmpty {
                if let r = region.range(of: needle, options: .caseInsensitive) {
                    found = cursor + region.distance(from: region.startIndex, to: r.lowerBound)
                    break
                }
            }
            resolved.append(found)
            if let f = found { cursor = min(total, f + 1) }
        }

        // PASS 2 — assign final offsets, strictly increasing. Located titles keep
        // their exact offset; runs of unlocated titles are spread evenly across
        // the gap up to the NEXT located anchor (or end-of-text), so each gets a
        // distinct in-region estimate instead of the old shared-anchor cluster.
        var offsets = [Int](repeating: 0, count: entries.count)
        var lastAssigned = postTOCOffset - 1
        var i = 0
        while i < entries.count {
            if let f = resolved[i] {
                offsets[i] = max(f, lastAssigned + 1)
                lastAssigned = offsets[i]
                i += 1
                continue
            }
            var j = i
            while j < entries.count, resolved[j] == nil { j += 1 }
            let n = j - i
            let lo = lastAssigned + 1
            let hi = (j < entries.count) ? max(resolved[j] ?? total, lo + n) : max(total, lo + n)
            let span = hi - lo
            for k in 0..<n {
                var o = lo + (span * k) / n
                if o <= lastAssigned { o = lastAssigned + 1 }
                offsets[i + k] = min(total, o)
                lastAssigned = offsets[i + k]
            }
            i = j
        }

        var built: [PDFTOCEntry] = []
        for (index, entry) in entries.enumerated() {
            let clamped = min(total, max(postTOCOffset, offsets[index]))
            built.append(PDFTOCEntry(title: entry.title,
                                     plainTextOffset: clamped,
                                     playOrder: index,
                                     level: 1))
        }
        return built
    }
}

// ========== BLOCK 01: PDF TEXT-PATTERN STRUCTURE DETECTOR - END ==========
