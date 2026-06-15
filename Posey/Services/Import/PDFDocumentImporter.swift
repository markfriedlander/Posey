import Foundation
import ImageIO
import PDFKit
import UIKit
import Vision

// ========== BLOCK 01: MODELS AND ERRORS - START ==========

/// Image data captured from a single visual page during import.
/// Stored as PNG (lossless) for fidelity on detailed artwork.
struct PageImageRecord: Sendable {
    let imageID: String  // UUID string — embedded in the visual-page marker
    let data: Data       // PNG bytes
}

/// Explicit Sendable so ParsedPDFDocument can cross actor boundaries safely.
struct ParsedPDFDocument: Sendable {
    let title: String?
    let displayText: String
    let plainText: String
    /// One record per visual page that was rendered to an image.
    /// Empty for text-only PDFs.
    let images: [PageImageRecord]
    /// Detected TOC region in plainText. When non-zero, the reader auto-skips
    /// the active sentence past `tocSkipUntilOffset` on first open so the
    /// listener doesn't have to hear the TOC read aloud (a uniformly poor
    /// TTS experience). Zero means no TOC was detected.
    let tocSkipUntilOffset: Int
    /// Detected TOC entries (best-effort). Persisted via the existing
    /// `document_toc` table so the existing TOC sheet shows them.
    let tocEntries: [PDFTOCEntry]
    /// 2026-05-22 — Phase 1 of the Tier 1/2 PDF extraction architecture.
    /// One `PDFPageFlags` per page in page-index order, written by the
    /// importer for later persistence in a JSON sidecar and inspection
    /// via `LIST_PAGE_FLAGS:<doc-id>`. **Logging + persistence only at
    /// this phase — nothing branches on `needsTier2` yet.** See
    /// `PDFPageConfidenceDetector` + DECISIONS.md (2026-05-22 late).
    let pageFlags: [PDFPageFlags]
    // 2026-05-27 — `contentBoundaries` field removed. PDFEnhancementService
    // now reads via DatabaseManager.contentBoundaries(for:), which derives
    // from pageBreak units on demand. The importer no longer pre-computes
    // or persists the array.
}

/// Carries a parsed TOC entry from importer to library to DB.
struct PDFTOCEntry: Sendable {
    let title: String
    /// Character offset in plainText where the chapter actually begins. The
    /// importer searches for the entry's title text after the TOC region to
    /// compute this.
    let plainTextOffset: Int
    let playOrder: Int
    /// Heading level. From `PDFOutline` traversal depth when the outline
    /// fallback is used; from the text-pattern detector this is always 1
    /// (no level signal in the dot-leader pattern).
    let level: Int
}

struct PDFDocumentImporter {
    private static let visualPageMarkerPrefix = "[[POSEY_VISUAL_PAGE:"
    private static let visualPageMarkerSuffix = "]]"

    /// Progress events emitted during import. Sent only when OCR is needed.
    /// Conforms to Sendable so the callback can cross actor boundaries.
    enum ImportProgress: Sendable {
        /// Emitted once per page that requires Vision OCR (PDFKit found no text).
        case ocr(page: Int, of: Int)

        var message: String {
            switch self {
            case .ocr(let page, let total): return "OCR: page \(page) of \(total)"
            }
        }
    }

    enum ImportError: LocalizedError, Equatable {
        case unreadableDocument
        case emptyDocument
        case scannedDocument

        var errorDescription: String? {
            switch self {
            case .unreadableDocument:
                return "Posey could not read that PDF file."
            case .emptyDocument:
                return "The PDF file is empty."
            case .scannedDocument:
                return "Posey could not extract text from this PDF, even after attempting OCR. The document may be too low quality or in a format that could not be recognised."
            }
        }
    }
}

// ========== BLOCK 01: MODELS AND ERRORS - END ==========

// ========== BLOCK 02: IMPORT ENTRY POINTS - START ==========

extension PDFDocumentImporter {
    func loadDocument(
        from url: URL,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) throws -> ParsedPDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw ImportError.unreadableDocument
        }
        return try parsedDocument(from: document, progress: progress)
    }

    func loadDocument(
        fromData data: Data,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) throws -> ParsedPDFDocument {
        guard let document = PDFDocument(data: data) else {
            throw ImportError.unreadableDocument
        }
        return try parsedDocument(from: document, progress: progress)
    }
}

// ========== BLOCK 02: IMPORT ENTRY POINTS - END ==========

// ========== BLOCK 03: CORE PAGE PARSING - START ==========

extension PDFDocumentImporter {
    private func parsedDocument(
        from document: PDFDocument,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) throws -> ParsedPDFDocument {
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw ImportError.emptyDocument
        }

        enum PageContent {
            case text(String)
            case visualPlaceholder(pageNumber: Int, imageID: String)
        }

        var pageContents: [PageContent] = []
        pageContents.reserveCapacity(pageCount)
        var readableTextPages: [String] = []
        readableTextPages.reserveCapacity(pageCount)
        var imageRecords: [PageImageRecord] = []

        // 2026-05-22 — Detect running headers/footers across the
        // whole document before per-page extraction. Returns a
        // per-page-index dictionary of character ranges in the
        // page's raw `string` to strip out. Pages without repeating
        // margin-zone text get nothing (no-op for those pages).
        // See PDFRunningHeaderDetector for the algorithm + the
        // visual-audit-driven rationale behind the tunables.
        let headerStripRanges = PDFRunningHeaderDetector.detect(in: document)

        // 2026-05-22 — Phase 1 of the Tier 1/2 PDF extraction
        // architecture. Walk every page with the confidence detector
        // and capture per-page flags + signals. **Logging-only at
        // this phase.** No page extraction path branches on the
        // result. The flags ride out on `ParsedPDFDocument.pageFlags`
        // so `PDFLibraryImporter` can persist them via
        // `PageFlagsStore` for later inspection through the
        // `LIST_PAGE_FLAGS:<doc-id>` antenna verb.
        //
        // See `PDFPageConfidenceDetector` for the heuristics and the
        // generous-side starting thresholds. Calibration on the audit
        // corpus tightens these before Phase 2 wires Tier 2 (Vision
        // OCR) in to the importer's per-page branch.
        // 2026-05-22 Phase 2 — `pageFlags` is mutable here because
        // the Tier 2 branch in the per-page loop annotates each
        // flag with its runtime outcome (`tier2: Tier2Outcome`).
        // The final array is what gets persisted in the sidecar so
        // `LIST_PAGE_FLAGS` shows both the static heuristic decision
        // and what Vision actually did.
        var pageFlags = PDFPageConfidenceDetector.assess(document)
        let flagSummary = pageFlags.filter { $0.needsTier2 }
        dbgLog(
            "PDF page flags: %d/%d pages flagged for Tier 2 (full=%d fusionRepair=%d figureRegion=%d)",
            flagSummary.count, pageFlags.count,
            flagSummary.filter { $0.tier2Mode == .full }.count,
            flagSummary.filter { $0.tier2Mode == .fusionRepair }.count,
            flagSummary.filter { $0.tier2Mode == .figureRegion }.count
        )

        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }

            // Strip running header/footer ranges (if any detected
            // for this page) from the raw PDFKit page text BEFORE
            // normalization. The detector returns ranges in
            // `page.string`'s utf16 index space.
            let rawPageString = page.string ?? ""
            let stripped: String = {
                if let ranges = headerStripRanges[index], !ranges.isEmpty {
                    return PDFRunningHeaderDetector.applyStrips(ranges, to: rawPageString)
                }
                return rawPageString
            }()
            // 2026-05-31 — TOC-page line preservation (text-layer path). PDFKit's
            // `page.string` already carries a newline per visual line; normalize()
            // collapses single newlines to spaces to REFLOW wrapped body prose
            // (the body page emits a newline per wrap, e.g. "…keys: music\nand
            // art."). That collapse flattens a table of contents into one
            // unreadable run-on ("Contents Overview viii List of Illustrations
            // xiv …"), which the reader sees on "Start from Beginning". Same
            // symptom as the scanned-TOC case but a different mechanism (text
            // layer, not Vision OCR), so the geometry reflow doesn't apply.
            // Gate on the precise TOC-page detectors (Contents anchor + entry
            // density): a TOC page preserves EVERY line as its own paragraph;
            // body pages collapse/reflow exactly as before (zero body risk —
            // the gate is false without a Contents anchor).
            let pdfText: String = {
                // TOC pages: reflow by PDFKit selection GEOMETRY, not page.string.
                // page.string flattens a two-column TOC (titles left, page numbers
                // right) in a jumbled read order — fusing some entries and
                // orphaning page numbers (GEB's "Part II" contents page). The
                // selection geometry pairs each title with its number by shared
                // midY. Returns nil for non-TOC pages → normal extraction.
                if let tocText = OCRLineReflow.reflowPDFTextLayerTOC(page) {
                    return tocText
                        .components(separatedBy: "\n\n")
                        .map { normalize($0) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n\n")
                }
                // Résumé / CV structured-line page (no \n\n + ALL-CAPS section
                // headers): reflow into one paragraph per logical line instead
                // of collapsing the whole page into one wall-of-text unit.
                // GATED to SHORT documents (≤ 2 pages): the caps-colon header
                // signal alone also matches incidental book content (GEBen's
                // BlooP/FlooP pseudocode listings, formal "RULES OF EQUALITY:"
                // pages), so without a length gate the reflow re-segments a
                // long book it has no business touching. A book is long; a
                // résumé/CV/cover-letter/flyer is 1–2 pages — that's the
                // discriminator. Multi-page CVs are a future extension (needs
                // more real-doc verification before loosening the gate).
                if pageCount <= 2, let reflowed = reflowStructuredLineBlobPage(stripped) {
                    return reflowed
                }
                return normalize(stripped)
            }()

            // 2026-05-22 Phase 2.2 Step 4 — Tier 2 Vision OCR no
            // longer runs synchronously during import. Flagged pages
            // are persisted via the page-flags sidecar; the
            // PDFEnhancementService background runner picks them up
            // after persistence (Step 5). Synchronous import path
            // is Tier 1 only — fast, deterministic, no jetsam risk
            // on large documents.

            if !pdfText.isEmpty {
                pageContents.append(.text(pdfText))
                readableTextPages.append(pdfText)
                // If the page also contains PDF image XObjects (figures, photos, charts),
                // preserve them as a visual stop immediately after the text. Neither is dropped.
                //
                // 2026-05-27 — suppress the full-page render when the
                // page already has substantial text. The previous
                // behavior rendered the entire page bitmap (text +
                // XObjects + any embedded watermark) and stored it as
                // the image side-store entry. For converter-watermarked
                // PDFs (Cryptography for Dummies has a CHM-to-PDF
                // watermark on every page), the renderer faithfully
                // captures the watermark — even though
                // PDFWatermarkStripper successfully scrubbed it from
                // the text path. Result: the user sees the watermark
                // bitmap inline despite the text being clean.
                //
                // Threshold: a page with > 200 chars of extracted text
                // is "primarily a text page." Its XObjects are
                // typically small (nav buttons, line decorations,
                // watermarks) — not informative figures the reader
                // would want preserved as a visual stop. Pages BELOW
                // the threshold (cover, figure-only pages) still get
                // the full-page render.
                if pageHasImageXObjects(page) && pdfText.count < 200 {
                    let imageID = UUID().uuidString
                    if let pngData = renderPageToPNG(page) {
                        imageRecords.append(PageImageRecord(imageID: imageID, data: pngData))
                    }
                    pageContents.append(.visualPlaceholder(pageNumber: index + 1, imageID: imageID))
                }
            } else {
                // PDFKit found no text — report progress then try Vision OCR.
                progress?(.ocr(page: index + 1, of: pageCount))
                let ocr = ocrText(from: page)
                // 2026-05-22 Phase 2 — record fallback Vision outcome
                // in the page-flags telemetry so calibration sees a
                // unified view of which pages went through Vision and
                // what happened.
                if index < pageFlags.count {
                    pageFlags[index].tier2 = PDFPageFlags.Tier2Outcome(
                        ran: true,
                        decision: ocr.count >= 10 ? "fallback_ocr_used" : "fallback_ocr_empty",
                        tier2Chars: ocr.count
                    )
                }
                // Require at least 10 chars of OCR text before treating a page as readable.
                // Fewer than that (page numbers, "iii", lone captions) means the page is
                // effectively visual — render it as an image stop instead.
                //
                // 2026-05-27 — Also reject OCR output that looks like
                // decorative cover-page typography (the GEB-cover
                // failure mode: Vision returns "ANETERNAL GOLDEN BRAID
                // HOFSTADTER" — fused long-caps tokens). Without this
                // check those covers landed in the text path and the
                // reader read them aloud verbatim.
                if ocr.count >= 10 && !PDFPageConfidenceDetector.looksLikeDecorativeCoverOCR(ocr) {
                    pageContents.append(.text(ocr))
                    readableTextPages.append(ocr)
                } else if ocr.count >= 10 {
                    // Decorative cover detected — treat as visual.
                    dbgLog("PDF import: page %d OCR rejected as decorative cover (%d chars)", index + 1, ocr.count)
                    let imageID = UUID().uuidString
                    if let pngData = renderPageToPNG(page) {
                        imageRecords.append(PageImageRecord(imageID: imageID, data: pngData))
                    }
                    pageContents.append(.visualPlaceholder(pageNumber: index + 1, imageID: imageID))
                } else if pageIsEffectivelyBlank(page) {
                    // Task 8 #5 (2026-05-03 — pixel-uniformity
                    // blank detection): genuinely blank section-
                    // divider page (no extractable text + < 10 OCR
                    // chars + pixel-uniformity scoring confirms
                    // ≥99% of sampled pixels share the dominant
                    // colour within a tight delta). Pausing TTS
                    // for these pages is an annoyance, not an
                    // affordance — flow through. Antifa corpus
                    // had 11 such pages all firing visual stops
                    // before this gate.
                    dbgLog("PDF import: skipping blank visual stop on page %d", index + 1)
                } else {
                    // Truly visual page — render to PNG and emit
                    // a visual stop so the user sees the figure
                    // inline.
                    let imageID = UUID().uuidString
                    if let pngData = renderPageToPNG(page) {
                        imageRecords.append(PageImageRecord(imageID: imageID, data: pngData))
                    }
                    pageContents.append(.visualPlaceholder(pageNumber: index + 1, imageID: imageID))
                }
            }
        }

        guard !readableTextPages.isEmpty else {
            throw ImportError.scannedDocument
        }

        // 2026-05-22 — Watermark strip. Converter watermarks (ChmMagic,
        // Aspose, Calibre, generic "Evaluation Only" notices) are
        // injected by upstream tools and repeat on every page of the
        // resulting PDF. Without this strip, they read aloud as if
        // they were prose, embed into the RAG index, and surface as
        // the document's first sentence. Applied per-page so the
        // downstream TOC detector also sees clean text.
        readableTextPages = readableTextPages.map { PDFWatermarkStripper.strip($0) }
        pageContents = pageContents.map { content in
            switch content {
            case .text(let t): return .text(PDFWatermarkStripper.strip(t))
            case .visualPlaceholder: return content
            }
        }

        // 2026-05-27 — content_boundaries pre-computation removed.
        // DatabaseManager.contentBoundaries(for:) now derives the
        // same array on-demand from pageBreak units.

        // Join pages, then run a second collapseLineBreakHyphens pass so that
        // hyphens spanning a page boundary (word-\x0cword) are collapsed too.
        // Per-page normalize() can't catch these because it runs before joining.
        let joinedDisplay = pageContents
            .map { content -> String in
                switch content {
                case .text(let text):
                    return text
                case .visualPlaceholder(let n, let imageID):
                    return Self.visualPageMarker(for: n, imageID: imageID)
                }
            }
            .joined(separator: "\u{000C}")
        // 2026-06-14 (PDF c14) — strip a TRAILING "Page N of M" page-layout
        // footer. PDFRunningHeaderDetector catches repeating footers across
        // MULTIPLE pages, but a SINGLE-page PDF (e.g. a 1-page résumé) has no
        // repetition to detect, so its lone "Page 1 of 1" leaks to the very end
        // of the text → spoken by TTS (c14 junk) + visible (c3). Scoped to the
        // document tail only (after the last page's real content), so multi-page
        // interior footers stay the detector's job and legit "Page N of M" inside
        // prose (rare) is untouched. The number-of-pages text is layout, not content.
        // `\s` (ICU) already matches the form-feed page separator.
        let trailingPageFooter = #"(?i)\s*Page\s+\d+\s+of\s+\d+\s*$"#
        let preDisplayText = TextNormalizer.stripLineBreakHyphens(joinedDisplay)
            .replacingOccurrences(of: trailingPageFooter, with: "", options: .regularExpression)
        let prePlainText = readableTextPages.joined(separator: "\n\n")
            .replacingOccurrences(of: trailingPageFooter, with: "", options: .regularExpression)

        // 2026-05-07 (parity #10): collapse whitespace inside any
        // numeric bracketed marker (`[12]`, `[1 2]`, `[1\n2]`,
        // `[1\n\n2]`) so citation markers remain atomic. PDFKit's
        // text engine often inserts a space between digits when a
        // marker visually wraps across lines (`[12]` → `[1 2]`),
        // and rarer `[1\n\n2]` patterns would otherwise be split
        // across DisplayBlocks by `PDFDisplayParser`'s paragraph
        // segmenter. Apply to both displayText and plainText so the
        // marker reads correctly in the rendered text AND through
        // search / Ask Posey embeddings / TTS.
        // 2026-05-08 — strip PDFKit dimension-metadata artifacts
        // (e.g. "3.8701 in", "2.4512 in") that leak from cover-page
        // image alt-text into extracted prose. Discovered on Measure
        // What Matters first segment. See `stripPDFDimensionArtifacts`.
        let postDimDisplay = Self.stripPDFDimensionArtifacts(preDisplayText)
        let postDimPlain = Self.stripPDFDimensionArtifacts(prePlainText)
        let displayText = Self.collapseWhitespaceInsideNumericBrackets(postDimDisplay)
        let plainText = Self.collapseWhitespaceInsideNumericBrackets(postDimPlain)
        let rawTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Discard titles that look like file paths (Windows or Unix) — use filename fallback instead.
        let title: String? = rawTitle.flatMap { t in
            (t.contains("\\") || t.contains("/") || t.hasSuffix(".pdf") || t.hasSuffix(".obd")) ? nil : t
        }

        // Detect a Table of Contents region. When found, the reader auto-skips
        // past it on first open so the TOC isn't read aloud (uniformly poor
        // listening experience). Entries (best-effort) are persisted so the
        // existing TOC sheet can navigate the document.
        let tocResult = PDFTOCDetector.detect(pageTexts: readableTextPages)
        var tocSkipUntilOffset = tocResult?.regionEndOffset ?? 0
        // 2026-05-31 (Bug F) — `buildEntries` moved to the shared
        // `PDFTextStructureDetector` so the end-of-enhancement re-detect path
        // uses the identical resolver. This is a pure relocation.
        var tocEntries: [PDFTOCEntry] = tocResult.map { result in
            PDFTextStructureDetector.buildEntries(for: result.entries,
                                                  in: plainText,
                                                  postTOCOffset: result.regionEndOffset)
        } ?? []

        // 2026-05-06 — PDF native outline (PDFKit's outlineRoot) as a
        // fallback when text-pattern TOC detection found nothing.
        // Many PDFs (papers, ebooks) ship a structural outline even
        // when they don't print a visible table-of-contents page.
        if tocEntries.isEmpty,
           let outline = document.outlineRoot, outline.numberOfChildren > 0 {
            tocEntries = extractOutlineEntries(from: outline,
                                               in: document,
                                               readableTextPages: readableTextPages)
        }

        // 2026-05-22 — Outline-based skip detection. When the
        // text-pattern TOC detector found nothing but the PDF carries
        // a structural outline (Cryptography for Dummies is the
        // canonical case — outline lists "Table of Contents",
        // "BackCover", "Cryptography for Dummies", "Introduction",
        // …), feed the outline entries through `TOCWalkContentStartDetector`
        // to skip past TOC / publishing-info entries and land at the
        // first body section.
        //
        // Three guard conditions to avoid false positives:
        //   1. text-pattern detector didn't fire (`tocSkipUntilOffset == 0`)
        //   2. at least 3 outline entries (single-section outlines
        //      lack the structural cues the walker relies on)
        //   3. the walker actually advanced past offset 0
        //
        // skipSource classification carries through as "heuristic"
        // in PDFLibraryImporter (any positive skip on PDF is
        // heuristic — there's no Gutenberg-PDF wiring yet).
        if tocSkipUntilOffset == 0, tocEntries.count >= 3 {
            let walkerEntries = tocEntries
                .map { TOCWalkContentStartDetector.TOCEntry(
                    title: $0.title, plainTextOffset: $0.plainTextOffset) }
                .sorted { $0.plainTextOffset < $1.plainTextOffset }
            let walkResult = TOCWalkContentStartDetector.detect(
                tocEntries: walkerEntries,
                plainText: plainText,
                currentSkip: 0
            )
            if let advanced = walkResult.newSkipOffset, advanced > 0 {
                tocSkipUntilOffset = advanced
            }
        }

        // 2026-05-22 — Generalized text-pattern TOC fallback. Last
        // resort: runs only when (1) the dot-leader detector found
        // nothing, (2) no outline walker advance, AND (3) the
        // generalized detector finds a dense cluster of
        // chapter/part/section/appendix lines on the first ~8 pages
        // alongside a "Contents" anchor. Safety net for PDFs that
        // ship neither structural outline nor dot-leader TOC.
        if tocSkipUntilOffset == 0,
           let generalized = PDFGeneralizedTOCDetector.detect(pageTexts: readableTextPages) {
            tocSkipUntilOffset = generalized.regionEndOffset
            // 2026-05-31 — the generalized detector now emits entries for
            // run-on / whitespace TOCs (OCR'd scanned books like GEB, whose
            // TOC has no dot leaders and no line breaks). Wire them through
            // the same buildEntries path so navigable TOC entries AND heading
            // units get built — not just a silent skip region. Only when the
            // earlier strategies produced no entries (this is the fallback).
            if tocEntries.isEmpty, !generalized.entries.isEmpty {
                tocEntries = PDFTextStructureDetector.buildEntries(
                    for: generalized.entries,
                    in: plainText,
                    postTOCOffset: generalized.regionEndOffset)
            }
        }

        return ParsedPDFDocument(
            title: title,
            displayText: displayText,
            plainText: plainText,
            images: imageRecords,
            tocSkipUntilOffset: tocSkipUntilOffset,
            tocEntries: tocEntries,
            pageFlags: pageFlags
        )
    }

    /// 2026-05-31 (Bug F) — `buildEntries` moved to
    /// `PDFTextStructureDetector.buildEntries` so the importer and the
    /// end-of-enhancement re-detect path share one resolver. Call sites above
    /// now use the shared static.

    /// 2026-05-06 — Walk the PDF native outline tree and emit
    /// `PDFTOCEntry` rows. Fallback used when the text-pattern TOC
    /// detector finds nothing. For each outline entry, resolve its
    /// destination page (PDFOutline.destination?.page) and compute a
    /// plainText offset by summing the lengths of all earlier
    /// readable-text pages plus separators.
    private func extractOutlineEntries(from root: PDFOutline,
                                       in document: PDFDocument,
                                       readableTextPages: [String]) -> [PDFTOCEntry] {
        // Precompute the start offset of each page in the joined
        // plainText. plainText was joined with "\n\n" between pages.
        var pageStartOffsets: [Int] = []
        var running = 0
        for (i, p) in readableTextPages.enumerated() {
            pageStartOffsets.append(running)
            running += p.count
            if i < readableTextPages.count - 1 { running += 2 }
        }
        // 2026-06-13 — Resolve each outline entry to the REAL position of its
        // heading, not merely the start of its page
        // (DEFECT-pdf-heading-detection-positioning.md, arxiv/attention case).
        // The old code stored `pageStartOffsets[pageIndex]` for EVERY entry, so
        // all entries on one page collapsed to a single offset — e.g. the 5
        // section headings on the Transformer paper's page 6 (Training, Training
        // Data, Hardware, Optimizer, Regularization) all shared one anchor and
        // `jumpToTOCEntry` landed them on the same segment. Search for the
        // entry's title from a page-anchored, monotonically-advancing cursor (the
        // same joined-page coordinate space as `pageStartOffsets`), so same-page
        // headings resolve to distinct, in-order body positions. Unlocated titles
        // fall back to the page anchor, still kept strictly increasing so they
        // never re-cluster.
        let joined = readableTextPages.joined(separator: "\n\n")
        let totalChars = joined.count

        var entries: [PDFTOCEntry] = []
        var order = 0
        var lastAssigned = -1
        func walk(_ node: PDFOutline, depth: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty,
                   let dest = child.destination,
                   let page = dest.page,
                   let pageIndex = document.index(for: page) as Int?,
                   pageIndex >= 0,
                   pageIndex < pageStartOffsets.count {
                    order += 1
                    let floor = max(lastAssigned + 1, pageStartOffsets[pageIndex])
                    var resolved = min(floor, totalChars)
                    if floor < totalChars {
                        let searchStart = joined.index(joined.startIndex, offsetBy: floor)
                        let region = joined[searchStart...]
                        if let r = region.range(of: title, options: .caseInsensitive) {
                            resolved = floor + region.distance(from: region.startIndex, to: r.lowerBound)
                        }
                    }
                    if resolved <= lastAssigned { resolved = min(totalChars, lastAssigned + 1) }
                    lastAssigned = resolved
                    entries.append(PDFTOCEntry(
                        title: title,
                        plainTextOffset: resolved,
                        playOrder: order,
                        level: max(1, min(6, depth + 1))
                    ))
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return entries
    }
}

// ========== BLOCK 03: CORE PAGE PARSING - END ==========

// ========== BLOCK 04: OCR - START ==========

extension PDFDocumentImporter {
    /// Minimum average Vision confidence to treat OCR output as readable text.
    /// Pages below this threshold are garbled scan content — better shown as
    /// a visual stop than read as potentially meaningless character soup.
    private static let ocrConfidenceThreshold: Float = 0.75

    /// Renders the PDF page to a CGImage and runs Vision text recognition on it.
    /// Returns normalised plain text, or an empty string if nothing could be read
    /// or if the average recognition confidence is below `ocrConfidenceThreshold`.
    /// Runs synchronously — `VNImageRequestHandler.perform` blocks until complete.
    private func ocrText(from page: PDFPage) -> String {
        // 2026-05-22 Phase 2.2 quick-win — autoreleasepool wrap so
        // Vision's autoreleased observations + the rendered CGImage
        // drain after each per-page call. Mirrors the same wrap in
        // PDFTier2VisionExtractor.extract; without these, sequential
        // per-page Vision invocations on iPhone exhausted memory
        // and triggered a jetsam kill mid-import.
        autoreleasepool {
            guard let image = renderPageToCGImage(page, colorSpace: CGColorSpaceCreateDeviceGray()) else { return "" }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil else { return "" }

            let observations = request.results ?? []
            let candidates = observations.compactMap { $0.topCandidates(1).first }
            guard !candidates.isEmpty else { return "" }

            // Gate on average confidence. Low confidence = garbled scan or form
            // page — surface as a visual block instead of reading garbage aloud.
            let avgConfidence = candidates.map(\.confidence).reduce(0, +) / Float(candidates.count)
            guard avgConfidence >= Self.ocrConfidenceThreshold else { return "" }

            // 2026-05-31 — reflow by line geometry (OCRLineReflow) instead of
            // joining every recognized line with a space. The geometry-aware
            // joiner preserves hard line breaks (a scanned TOC reads one entry
            // per line) while still reflowing wrapped body-prose lines into
            // paragraphs. Hard breaks come back as "\n\n"; normalize() collapses
            // single newlines to spaces, so normalize PER PARAGRAPH and rejoin
            // with "\n\n" to keep the paragraph structure through to the unit
            // splitter.
            let reflowed = OCRLineReflow.reflow(observations)
            guard !reflowed.isEmpty else { return "" }
            return reflowed
                .components(separatedBy: "\n\n")
                .map { normalize($0) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
    }

    /// Task 8 #5 (2026-05-03): is the page effectively blank?
    /// Renders a low-resolution grayscale snapshot, samples pixels on
    /// a regular grid, and scores luminance variance. Returns true
    /// when ≥99 % of samples are within a tight delta of the dominant
    /// luminance (i.e., the page is essentially uniform — section
    /// divider, intentional blank, or page-break filler). Conservative
    /// thresholds prevent false positives on light watercolour /
    /// faint-grey artwork.
    private func pageIsEffectivelyBlank(_ page: PDFPage) -> Bool {
        // Render at 0.25× to keep the buffer tiny (a US Letter page
        // becomes ~153×198 px). Variance on such a small render is
        // a robust proxy for the full page — a single dark glyph
        // still produces detectable variance at this scale.
        guard let cgImage = renderPageToCGImage(
            page,
            colorSpace: CGColorSpaceCreateDeviceGray(),
            scale: 0.25
        ) else {
            return false
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return false }

        // Pull bytes via a fresh DeviceGray context so the row stride
        // is predictable (one byte per pixel).
        let bytesPerRow = width
        let totalBytes = bytesPerRow * height
        guard let data = malloc(totalBytes) else { return false }
        defer { free(data) }
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let buf = data.assumingMemoryBound(to: UInt8.self)

        // Sample on a regular grid — 32×32 = 1024 samples. Cheap,
        // covers the whole page, robust against gradients.
        let sampleStride = 32
        let stepX = max(1, width / sampleStride)
        let stepY = max(1, height / sampleStride)
        var samples: [UInt8] = []
        samples.reserveCapacity(sampleStride * sampleStride)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                samples.append(buf[y * bytesPerRow + x])
                x += stepX
            }
            y += stepY
        }
        guard !samples.isEmpty else { return false }

        // Find the dominant luminance bucket (each bucket = 8
        // grayscale levels). Then count samples within ±deltaLuma
        // of its center. If ≥99 % match, the page is uniform.
        var buckets = [Int](repeating: 0, count: 32) // 256 / 8 = 32
        for s in samples { buckets[Int(s) / 8] += 1 }
        guard let domIdx = buckets.indices.max(by: { buckets[$0] < buckets[$1] }) else {
            return false
        }
        let domCenter = domIdx * 8 + 4
        let deltaLuma = 12 // tolerance ≈ 5 % of 0–255 range
        var withinDelta = 0
        for s in samples {
            if abs(Int(s) - domCenter) <= deltaLuma { withinDelta += 1 }
        }
        let ratio = Double(withinDelta) / Double(samples.count)
        return ratio >= 0.99
    }

    /// Renders a page to PNG data using PDFPage.thumbnail — Apple's purpose-built,
    /// thread-safe renderer. 2× scale for fidelity on detailed artwork.
    private func renderPageToPNG(_ page: PDFPage, scale: CGFloat = 2.0) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        return image.pngData()
    }

    /// Renders a page to CGImage for Vision OCR. Uses DeviceGray to keep the
    /// buffer small. Not used for display — see renderPageToPNG for that.
    private func renderPageToCGImage(_ page: PDFPage, colorSpace: CGColorSpace, scale: CGFloat = 2.0) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width  = max(1, Int(bounds.width  * scale))
        let height = max(1, Int(bounds.height * scale))

        let bitmapInfo: UInt32 = colorSpace.model == .monochrome
            ? CGImageAlphaInfo.none.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        if colorSpace.model == .monochrome {
            ctx.setFillColor(gray: 1, alpha: 1)
        } else {
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        }
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        return ctx.makeImage()
    }
}

// ========== BLOCK 04: OCR - END ==========

// ========== BLOCK 05: HELPERS - START ==========

extension PDFDocumentImporter {
    /// Encodes a visual-page marker with the imageID embedded.
    /// Format: `[[POSEY_VISUAL_PAGE:<pageNumber>:<imageID>]]`
    static func visualPageMarker(for pageNumber: Int, imageID: String) -> String {
        "\(visualPageMarkerPrefix)\(pageNumber):\(imageID)\(visualPageMarkerSuffix)"
    }

    /// 2026-05-07 (parity #10): collapse all whitespace inside any
    /// numeric bracketed marker (`[12]`, `[1 2]`, `[1\n2]`, …). PDFKit
    /// frequently inserts spaces and/or newlines inside markers when
    /// they wrap visually across lines or pages; both produce broken
    /// markers downstream (a `\n\n` inside `[1\n\n2]` would split the
    /// marker across two displayBlocks via `PDFDisplayParser`'s
    /// paragraph segmenter; a single space yields a wrong marker
    /// `[1 2]` in plainText that's read aloud and indexed). Collapsing
    /// at the importer means both `displayText` and `plainText`
    /// contain the canonical `[N]` form. Non-numeric brackets
    /// (`[Smith 2003]`) are left alone.
    /// Strip PDF dimension/positional artifacts that PDFKit's text
    /// extractor occasionally surfaces from cover-page image metadata.
    /// Pattern: a decimal number with **3+ fractional digits** followed
    /// by an inch / cm / mm / pt / px unit. The 3+ fractional digit
    /// threshold is the discriminator — real English prose almost
    /// never says "0.123 in"; PDFKit's positional output frequently
    /// does ("3.8701 in", "2.4512 in", "0.5625 cm").
    ///
    /// Discovered 2026-05-08 on `Measure What Matters - John Doerr.pdf`,
    /// whose first segment surfaced as:
    /// `"Measure What Matters 3.8701 in How Google, Bono, ... LARRY PAGE 2.4512 in"`.
    /// Both `3.8701 in` and `2.4512 in` were image-dimension metadata
    /// from the cover, leaking into the body text and getting both
    /// read aloud and indexed as if they were prose.
    ///
    /// After the artifact strip, collapse the resulting double spaces
    /// so the surrounding prose reads cleanly.
    static func stripPDFDimensionArtifacts(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\s*\b\d+\.\d{3,}\s+(?:in|cm|mm|pt|px)\b"#,
            options: []
        ) else { return text }
        let stripped = regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
        // Collapse runs of 2+ ASCII spaces into one (the strip can
        // leave doubled spaces around the removed artifact). Don't
        // touch newlines or non-ASCII spaces — those are paragraph /
        // line structure that other passes care about.
        guard let wsRegex = try? NSRegularExpression(pattern: #" {2,}"#) else { return stripped }
        return wsRegex.stringByReplacingMatches(
            in: stripped,
            range: NSRange(stripped.startIndex..., in: stripped),
            withTemplate: " "
        )
    }

    static func collapseWhitespaceInsideNumericBrackets(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[\s*\d[\d\s]*\]"#,
            options: [.dotMatchesLineSeparators]
        ) else { return text }
        var result = text
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let collapsed = result[range]
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            result.replaceSubrange(range, with: collapsed)
        }
        return result
    }

    /// Parses both old-format `[[POSEY_VISUAL_PAGE:N]]` and new-format `[[POSEY_VISUAL_PAGE:N:UUID]]`.
    /// Returns `(pageNumber, imageID)` — imageID is nil for old-format markers.
    static func parseVisualPageMarker(from marker: String) -> (pageNumber: Int, imageID: String?)? {
        guard marker.hasPrefix(visualPageMarkerPrefix),
              marker.hasSuffix(visualPageMarkerSuffix) else { return nil }
        let start = marker.index(marker.startIndex, offsetBy: visualPageMarkerPrefix.count)
        let end   = marker.index(marker.endIndex,   offsetBy: -visualPageMarkerSuffix.count)
        let inner = String(marker[start..<end])
        if let colonRange = inner.range(of: ":") {
            let pageStr = String(inner[inner.startIndex..<colonRange.lowerBound])
            let imageID = String(inner[colonRange.upperBound...])
            guard let pageNumber = Int(pageStr) else { return nil }
            return (pageNumber, imageID.isEmpty ? nil : imageID)
        } else {
            guard let pageNumber = Int(inner) else { return nil }
            return (pageNumber, nil)
        }
    }

    private func normalize(_ text: String) -> String {
        // 2026-06-08 (normalizer-parity pass): run the shared universal
        // pipeline (`TextNormalizer.normalize`: BOM/mojibake/control strip,
        // CP1252 repair, line-ending normalize, trailing-ws trim, line-break
        // hyphen collapse, asterism strip, tab→space, blank-line collapse),
        // then layer the PDF-specific passes ON TOP — these live OUTSIDE the
        // universal path so other formats don't false-collapse intentional
        // spacing:
        //   - `normalizePDFGlyphArtifacts`: spaced-letter (`C O N T E N T S`)
        //     + spaced-digit (`1 9 4 5`) repair (PDFKit glyph-positioning).
        //   - single-newline → space: PDF extraction emits soft line breaks
        //     within paragraphs that would otherwise read as hard breaks.
        // The page-boundary `stripLineBreakHyphens` pass still runs once more
        // in `loadDocument` after pages are joined with `\f`.
        var t = TextNormalizer.normalizeUniversal(text)   // shared path (incl. _Mem._ strip)
        t = TextNormalizer.normalizePDFGlyphArtifacts(t)
        t = t.replacingOccurrences(of: #"\n(?!\n)"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 2026-06-15 — Résumé / CV "wall of text" fix (Mark-requested). Some
    /// PDFs (single-spaced résumés, structured one-pagers) come back from
    /// PDFKit with a newline per VISUAL line but NO blank-line paragraph
    /// breaks. The normal path (`normalize`) collapses single `\n` → space
    /// to reflow wrapped BODY prose — correct for books, but it flattens
    /// such a page into ONE giant prose unit: an unscannable wall of text
    /// that also reads terribly under TTS. Mark: the résumé should render
    /// in a more reader-friendly presentation.
    ///
    /// When a page is clearly a structured-line document — no `\n\n`
    /// paragraph structure AND it carries an ALL-CAPS section header ending
    /// in a colon (e.g. `EDUCATION:`, `SKILLS AND EXPERIENCE:`), a strong
    /// signal flowing prose never produces — reflow it so each logical line
    /// becomes its own paragraph (→ its own unit), MERGING only true wrapped
    /// continuations (a line ending mid-clause whose successor begins
    /// lowercase). Returns nil for everything else (flowing prose, TOC pages
    /// handled upstream, anything with `\n\n`) so the established path is
    /// untouched — the golden harness proves the other corpus PDFs stay
    /// byte-identical. The IRS-1040 form (no caps-colon headers) is
    /// deliberately NOT reflowed — accepted as a known limitation (Mark).
    ///
    /// SCOPE / edge note (Rule 10): the gate intentionally requires the
    /// COLON to stay conservative — a colon-less header ("EDUCATION") won't
    /// trigger. Loosening that risks fragmenting an all-caps-titled prose
    /// page, so it's left as a future refinement verified against more real
    /// résumés.
    private func reflowStructuredLineBlobPage(_ raw: String) -> String? {
        // Pages that already have paragraph structure use the normal path.
        if raw.contains("\n\n") { return nil }

        let lines = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 4 else { return nil }   // too small to be a blob worth splitting

        // Gate: at least one ALL-CAPS, colon-terminated section header.
        guard lines.contains(where: { Self.isStructuredSectionHeader($0) }) else { return nil }

        var paragraphs: [String] = []
        for line in lines {
            if let last = paragraphs.last,
               !Self.isStructuredSectionHeader(line),
               Self.isWrappedContinuation(previous: last, next: line) {
                paragraphs[paragraphs.count - 1] = last + " " + line
            } else {
                paragraphs.append(line)
            }
        }
        let cleaned = paragraphs.map { normalize($0) }.filter { !$0.isEmpty }
        guard cleaned.count >= 2 else { return nil }
        return cleaned.joined(separator: "\n\n")
    }

    /// An ALL-CAPS line ending in `:` — e.g. `EDUCATION:`. Conservative
    /// structured-document signal (see `reflowStructuredLineBlobPage`).
    private static func isStructuredSectionHeader(_ s: String) -> Bool {
        guard s.count >= 3, s.count <= 50, s.hasSuffix(":") else { return false }
        let letters = s.filter { $0.isLetter }
        guard letters.count >= 2, letters.allSatisfy({ $0.isUppercase }) else { return false }
        return true
    }

    /// True when `next` is a wrapped continuation of `previous` (a soft
    /// line break mid-clause), so they rejoin into one paragraph rather
    /// than split into two units. Requires the previous line to end on a
    /// word char or comma (not sentence/clause punctuation) AND the next
    /// line to begin lowercase — the shape of reflowed body prose, not of
    /// two discrete résumé entries.
    private static func isWrappedContinuation(previous: String, next: String) -> Bool {
        guard let prevLast = previous.last, let nextFirst = next.first else { return false }
        if ".!?:;".contains(prevLast) { return false }
        let prevContinues = prevLast.isLowercase || prevLast == ","
        return prevContinues && nextFirst.isLowercase
    }

    // 2026-05-03 (Task 8 — format parity): the PDF importer's local
    // `collapseLineBreakHyphens`, `collapseSpacedDigits`, and
    // `collapseSpacedLetters` helpers were removed. Their behavior
    // moved to `TextNormalizer` (full Unicode-aware passes) and is
    // now invoked via `TextNormalizer.normalize(_:)` inside
    // `normalize(_:)` and via `TextNormalizer.stripLineBreakHyphens(_:)`
    // for the page-boundary join in `loadDocument`. Every importer
    // now reaches the same passes — TXT/MD/RTF/DOCX/HTML/EPUB/PDF.


    /// Returns true if the page's PDF resource dictionary contains at least one
    /// Image-type XObject — indicating the page has embedded figures, photos, or
    /// charts in addition to any extractable text.
    ///
    /// Uses the CGPDFPage resource dictionary directly so the check is fast (no
    /// rendering needed). False negatives are possible for unusual PDF constructs
    /// (images in Form XObjects or pattern streams) but those are rare.
    private func pageHasImageXObjects(_ page: PDFPage) -> Bool {
        guard let cgPage = page.pageRef,
              let pageDict = cgPage.dictionary else { return false }

        var resourcesDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resourcesDict),
              let res = resourcesDict else { return false }

        var xObjDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xObjDict),
              let xObj = xObjDict else { return false }

        var found = false
        // CGPDFDictionaryApplyFunction uses a C function pointer; pass &found as
        // context. The closure is non-capturing so it satisfies @convention(c).
        withUnsafeMutablePointer(to: &found) { ptr in
            CGPDFDictionaryApplyFunction(xObj, { _, obj, ctx in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(obj, .stream, &stream),
                      let st = stream,
                      let stDict = CGPDFStreamGetDictionary(st) else { return }
                var subtype: UnsafePointer<Int8>?
                guard CGPDFDictionaryGetName(stDict, "Subtype", &subtype),
                      let st = subtype else { return }
                if strcmp(st, "Image") == 0 {
                    ctx?.assumingMemoryBound(to: Bool.self).pointee = true
                }
            }, ptr)
        }
        return found
    }
}

// ========== BLOCK 05: HELPERS - END ==========
