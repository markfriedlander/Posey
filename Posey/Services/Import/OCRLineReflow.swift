import CoreGraphics
import Foundation
import PDFKit
import Vision

// ========== BLOCK 01: OCR LINE REFLOW - START ==========

/// Reflows Apple Vision OCR observations into text that preserves the page's
/// LINE / PARAGRAPH structure, instead of flattening every recognized line into
/// one space-joined run-on.
///
/// **Why this exists (2026-05-31).** Both OCR call sites — import-time
/// `PDFDocumentImporter.ocrText` and the Tier-2 `PDFTier2VisionExtractor.extract`
/// — used to do `candidates.map(\.string).joined(separator: " ")`. That is
/// correct for a wrapped body paragraph (a sentence that wraps across visual
/// lines should reflow into one paragraph with spaces) but DESTROYS the
/// structure of a table of contents: a scanned TOC page came back as
/// "Table of Contents Chapter I: The Salt Marsh ... 2 Chapter II: ... 3 …" —
/// one unreadable wall. A reader who taps "Start from Beginning" to see the
/// front matter was shown that wall. Broken experience.
///
/// **The signal (verified empirically on the rendered fixture).** Vision returns
/// one observation per visual line, each with a normalized `boundingBox`
/// (origin bottom-left). A line that fills the text column to the right margin
/// is a soft wrap → join the next line with a space. A line that ends well
/// short of the margin is a hard break (a TOC entry, a heading, a paragraph's
/// final line) → start a new paragraph. Measured maxX on the fixture:
///   • body wrapped lines:        0.82 – 0.88   (fill the margin → soft wrap)
///   • TOC entries:               0.57 – 0.63   (end short    → hard break)
///   • headings / paragraph ends: 0.34 – 0.58   (end short    → hard break)
///
/// **TOC pages are gated by the detector, NOT the maxX threshold.** The
/// margin-fill threshold alone is fragile for a table of contents: it works
/// only when the page numbers end short of the threshold (close to the title).
/// A TOC whose numbers are right-aligned to the margin (GEB: "Chapter I: The
/// MU-puzzle 33" reaching maxX 0.76) would read as "margin-filling" and
/// re-flatten into a run-on — the maxX value is partly an artifact of the
/// page's margins. So `reflowLines` first asks `isTOCContent` (the existing
/// Contents-anchor + entry-density detectors): on a TOC page EVERY visual line
/// is preserved as its own paragraph, geometry-independent. The maxX threshold
/// (0.74) is then used ONLY for body / general pages — splitting paragraphs
/// where a line ends short, reflowing wrapped lines where it fills the column.
/// Same gate + same `reflowLines` is reused by the text-layer path
/// (`page.string` lines), so a TOC reads one entry per line whether the text
/// came from Vision OCR or PDFKit extraction.
enum OCRLineReflow {

    /// Fraction of PAGE width a line must reach to be treated as a soft wrap
    /// (margin-filling) rather than a hard line break. See the type doc for the
    /// empirical calibration.
    static let marginFillThreshold: CGFloat = 0.74

    /// Two observations whose vertical centers are within this normalized delta
    /// are treated as fragments of the SAME visual line (Vision sometimes splits
    /// a line into several horizontal boxes) and joined with a space.
    static let sameLineMidYDelta: CGFloat = 0.012

    private struct Fragment {
        let text: String
        let minX: CGFloat
        let maxX: CGFloat
        let midY: CGFloat
    }

    /// A merged visual line: same-midY fragments joined left-to-right.
    struct VisualLine {
        let text: String
        /// Right extent of the line (max fragment maxX), normalized 0–1.
        let maxX: CGFloat
    }

    /// Reflow Vision observations into structure-preserving text. Hard breaks
    /// are emitted as `\n\n` (paragraph breaks) so the downstream unit splitters
    /// — `ContentUnitBuilder.unitsFromPDFDisplayText` (import) and
    /// `DatabaseManager.replaceUnitsForPage` (Tier-2), both of which split on
    /// blank lines — turn each TOC entry / paragraph into its own content unit,
    /// rendering on its own line. Soft wraps are spaces (same paragraph).
    static func reflow(_ observations: [VNRecognizedTextObservation]) -> String {
        var fragments: [Fragment] = []
        for o in observations {
            guard let candidate = o.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let box = o.boundingBox
            fragments.append(Fragment(text: text, minX: box.minX, maxX: box.maxX, midY: box.midY))
        }
        guard !fragments.isEmpty else { return "" }
        return reflowLines(mergeVisualLines(fragments))
    }

    /// Reflow a PDF page's TEXT-LAYER lines by PDFKit selection GEOMETRY, IFF
    /// the page is a table of contents — returns nil otherwise so the caller
    /// keeps its normal `page.string` extraction.
    ///
    /// 2026-05-31 — `page.string` is the wrong source for a two-column TOC.
    /// GEB's "Part II" contents page lists chapter/dialogue titles in a left
    /// column and page numbers in a right column; PDFKit's flat `page.string`
    /// reads them in a jumbled order — fusing some ("…Computer Systems Ant
    /// Fugue 311") and ORPHANING others ("337" / "369" / "406" on their own
    /// lines). The per-line SELECTION geometry, however, places each title and
    /// its page number on the same `midY`, so the existing midY merge pairs
    /// them correctly ("Chapter X: …Computer Systems" + "285" → one entry).
    /// We only switch to this path for TOC pages (gated by `isTOCContent`) to
    /// avoid disturbing body-prose extraction, which `page.string` + the
    /// running-header strip + `normalize` handle well.
    static func reflowPDFTextLayerTOC(_ page: PDFPage) -> String? {
        let pageBounds = page.bounds(for: .mediaBox)
        let w = pageBounds.width, h = pageBounds.height
        guard w > 0, h > 0, let selection = page.selection(for: pageBounds) else { return nil }

        var fragments: [Fragment] = []
        for line in selection.selectionsByLine() {
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let b = line.bounds(for: page)
            fragments.append(Fragment(
                text: text,
                minX: (b.minX - pageBounds.minX) / w,
                maxX: (b.maxX - pageBounds.minX) / w,
                midY: (b.midY - pageBounds.minY) / h
            ))
        }
        guard !fragments.isEmpty else { return nil }

        let lines = mergeVisualLines(fragments)
        guard isTOCContent(lines.map(\.text)) else { return nil }
        // TOC page — one entry per merged visual line.
        return lines.map(\.text).joined(separator: "\n\n")
    }

    /// Merge fragments into visual lines (group by midY, order left-to-right),
    /// top-to-bottom. Shared shape so the text-layer path can build the same
    /// `VisualLine` list from PDFKit line selections and reuse `reflowLines`.
    private static func mergeVisualLines(_ fragments: [Fragment]) -> [VisualLine] {
        let sorted = fragments.sorted { a, b in
            if abs(a.midY - b.midY) < sameLineMidYDelta { return a.minX < b.minX }
            return a.midY > b.midY
        }
        var lines: [VisualLine] = []
        var curText = sorted[0].text
        var curMaxX = sorted[0].maxX
        var curMidY = sorted[0].midY
        for i in 1..<sorted.count {
            let f = sorted[i]
            if abs(f.midY - curMidY) < sameLineMidYDelta {
                curText += " " + f.text
                curMaxX = max(curMaxX, f.maxX)
            } else {
                lines.append(VisualLine(text: curText, maxX: curMaxX))
                curText = f.text; curMaxX = f.maxX; curMidY = f.midY
            }
        }
        lines.append(VisualLine(text: curText, maxX: curMaxX))
        return lines
    }

    /// Turn visual lines into structure-preserving text.
    ///
    /// **TOC pages get every line preserved as its own paragraph** — gated on
    /// the precise `isTOCContent` check (Contents anchor + entry signals), NOT
    /// on per-line geometry. This is the robust path for the case the
    /// maxX-threshold cannot handle: a TOC whose page numbers are right-aligned
    /// to the margin (e.g. GEB's "Chapter I: The MU-puzzle 33" reaching maxX
    /// 0.76). Those lines "fill the margin" and would be wrongly soft-wrapped
    /// back into a run-on; keying on the page being a TOC sidesteps the maxX
    /// dependence entirely. Body pages (no Contents anchor) fall through to the
    /// geometry reflow — zero risk to body-prose reflow.
    static func reflowLines(_ lines: [VisualLine]) -> String {
        guard !lines.isEmpty else { return "" }
        if isTOCContent(lines.map(\.text)) {
            return lines.map(\.text).joined(separator: "\n\n")
        }
        // Body / general page — geometry reflow (soft wrap fills margin).
        var out = lines[0].text
        for i in 1..<lines.count {
            if lines[i - 1].maxX >= marginFillThreshold {
                out += " " + lines[i].text          // soft wrap
            } else {
                out += "\n\n" + lines[i].text        // hard break (paragraph)
            }
        }
        return out
    }

    /// True when a page's lines form a table of contents — reused by both the
    /// OCR path and the text-layer path so "preserve every entry on its own
    /// line" fires identically regardless of how the text was extracted. A TOC
    /// page is the only place we want to defeat the body-prose reflow, and the
    /// existing detectors already identify it precisely (Contents anchor +
    /// dot-leader / structural-entry density). `isContinuationOfTOC` covers the
    /// 2nd+ pages of a multi-page TOC, which carry no anchor.
    static func isTOCContent(_ lines: [String]) -> Bool {
        let blob = lines.joined(separator: "\n")
        return PDFTOCDetector.isTOCPage(blob)
            || PDFGeneralizedTOCDetector.isTOCPage(blob)
            || PDFTOCDetector.isContinuationOfTOC(blob)
            || PDFGeneralizedTOCDetector.isContinuationOfTOC(blob)
    }
}

// ========== BLOCK 01: OCR LINE REFLOW - END ==========
