import CoreGraphics
import Foundation
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
/// **Why a FIXED page-width threshold, not content-relative.** A page that is
/// ALL table-of-contents has no full-width paragraph line to calibrate "fills
/// the margin" against — the longest TOC entry would set the reference and
/// every entry would read as "full," re-flattening the list. A fixed fraction
/// of PAGE width (0.74) sidesteps that: a book's body column reaches ≥ ~0.82 of
/// page width, a list entry reaches ~0.6, and the threshold sits cleanly
/// between. Known limit: a document with an unusually wide right margin (text
/// column ending before 0.74 of page width) would over-split body prose into
/// per-line paragraphs. That is rare for book-shaped scans and strictly no
/// worse to read than the previous run-on; documented rather than over-built.
enum OCRLineReflow {

    /// Fraction of PAGE width a line must reach to be treated as a soft wrap
    /// (margin-filling) rather than a hard line break. See the type doc for the
    /// empirical calibration.
    static let marginFillThreshold: CGFloat = 0.74

    /// Two observations whose vertical centers are within this normalized delta
    /// are treated as fragments of the SAME visual line (Vision sometimes splits
    /// a line into several horizontal boxes) and joined with a space.
    static let sameLineMidYDelta: CGFloat = 0.012

    private struct Line {
        let text: String
        let minX: CGFloat
        let maxX: CGFloat
        let midY: CGFloat
    }

    /// Reflow Vision observations into structure-preserving text. Hard breaks
    /// are emitted as `\n\n` (paragraph breaks) so the downstream unit splitters
    /// — `ContentUnitBuilder.unitsFromPDFDisplayText` (import) and
    /// `DatabaseManager.replaceUnitsForPage` (Tier-2), both of which split on
    /// blank lines — turn each TOC entry / paragraph into its own content unit,
    /// rendering on its own line. Soft wraps are spaces (same paragraph).
    static func reflow(_ observations: [VNRecognizedTextObservation]) -> String {
        var lines: [Line] = []
        for o in observations {
            guard let candidate = o.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let box = o.boundingBox
            lines.append(Line(text: text, minX: box.minX, maxX: box.maxX, midY: box.midY))
        }
        guard !lines.isEmpty else { return "" }

        // Reading order: top-to-bottom (larger midY = higher on the page), then
        // left-to-right for fragments sharing a visual line.
        lines.sort { a, b in
            if abs(a.midY - b.midY) < sameLineMidYDelta { return a.minX < b.minX }
            return a.midY > b.midY
        }

        var out = lines[0].text
        for i in 1..<lines.count {
            let prev = lines[i - 1]
            let cur = lines[i]
            if abs(prev.midY - cur.midY) < sameLineMidYDelta {
                // Same visual line, split into fragments — rejoin with a space.
                out += " " + cur.text
            } else if prev.maxX >= marginFillThreshold {
                // Previous line filled the column → this line is a soft wrap.
                out += " " + cur.text
            } else {
                // Previous line ended short → hard break (new paragraph).
                out += "\n\n" + cur.text
            }
        }
        return out
    }
}

// ========== BLOCK 01: OCR LINE REFLOW - END ==========
