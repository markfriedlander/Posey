import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#endif

// ========== BLOCK 01: PDF TEXT LINE MODEL - START ==========

/// One reconstructed visual line of a PDF page, with the typographic signals the
/// heading-key deriver needs. PDF rebuild (2026-06-29, Mark's framing + a 4-way
/// design consult): there is NO universal "what is a heading" rule across books
/// — GEB uses font *size*, Cryptography uses *bold*, Measure What Matters uses
/// size + ALL-CAPS, the Transformer paper uses a numbered standalone line at body
/// size. The tool reads these per-line signals so a later step can DERIVE each
/// book's own `HeadingProfile` and apply it (a "style-inference engine").
struct PDFTextLine: Equatable, Hashable {
    /// The line's text (clean, reading-order — from PDFKit's own line selection).
    let text: String
    /// The line's representative font size (length-weighted mode of its runs).
    let fontSize: Double
    /// True if a majority (by length) of the line's text is bold.
    let isBold: Bool
    /// True if the line's letters are all uppercase (and it has letters).
    let isAllCaps: Bool
    /// Left edge (min x) of the line in page space — the indent / centering signal.
    let indentX: Double
    /// Horizontal midpoint of the line in page space — used to detect centering.
    let midX: Double
    /// Top of the line in page space (max y). PDF origin is bottom-left, y up →
    /// reading order is DECREASING yTop.
    let yTop: Double
    /// Bottom of the line in page space (min y).
    let yBottom: Double
    /// Vertical whitespace between this line's top and the previous line's bottom.
    /// A large value marks a paragraph or section break.
    let gapAbove: Double
    /// 0-based PDFKit sheet index this line sits on.
    let pageIndex: Int
}

// ========== BLOCK 01: PDF TEXT LINE MODEL - END ==========

// ========== BLOCK 02: LINE EXTRACTION (PDFKit-native) - START ==========

enum PDFLineExtractor {

    /// Reconstruct the visual lines of one page, top→bottom, with typographic
    /// signals — using PDFKit's OWN line selections (`selectionsByLine`) for the
    /// text + geometry and the line's `attributedString` for the font. We do NOT
    /// place glyphs by `characterBounds`: on iOS that returns draw/encode order,
    /// not reading order, which shatters words ("The MU-puzzle" → "Th M-puzzl"/
    /// "U"/"e"). PDFKit assembles lines correctly from its text-run structure.
    /// (Validated off-device 2026-06-29 across Crypto / GEB / Attention.)
    static func lines(from page: PDFPage, pageIndex: Int) -> [PDFTextLine] {
        let nsLen = (page.string as NSString?)?.length ?? 0
        guard nsLen > 0, let pageSel = page.selection(for: NSRange(location: 0, length: nsLen)) else { return [] }

        var lines: [PDFTextLine] = []
        var prevBottom: Double? = nil
        for lineSel in pageSel.selectionsByLine() {
            let text = (lineSel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let bounds = lineSel.bounds(for: page)
            let yTop = Double(bounds.maxY)
            let yBottom = Double(bounds.minY)
            let (size, bold) = fontSignal(of: lineSel.attributedString)
            let letters = text.filter { $0.isLetter }
            lines.append(PDFTextLine(
                text: text,
                fontSize: size,
                isBold: bold,
                isAllCaps: !letters.isEmpty && letters == letters.uppercased(),
                indentX: Double(bounds.minX),
                midX: Double(bounds.midX),
                yTop: yTop,
                yBottom: yBottom,
                gapAbove: prevBottom.map { max(0, $0 - yTop) } ?? 0,
                pageIndex: pageIndex
            ))
            prevBottom = yBottom
        }
        return lines
    }

    /// Length-weighted dominant font size + majority-bold for a line's attributed
    /// string. Length-weighting keeps a run-in heading ("Encoder: …body…") or a
    /// stray inline symbol from skewing the line's representative size.
    private static func fontSignal(of attr: NSAttributedString?) -> (size: Double, bold: Bool) {
        guard let attr, attr.length > 0 else { return (0, false) }
        var sizeWeight: [Double: Int] = [:]
        var boldLen = 0
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            #if canImport(UIKit)
            guard let f = value as? UIFont else { return }
            let size = (Double(f.pointSize) * 2).rounded() / 2   // 0.5pt buckets
            sizeWeight[size, default: 0] += range.length
            if f.fontDescriptor.symbolicTraits.contains(.traitBold) { boldLen += range.length }
            #endif
        }
        let size = sizeWeight.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key ?? 0
        return (size, boldLen * 2 >= attr.length)
    }
}

// ========== BLOCK 02: LINE EXTRACTION (PDFKit-native) - END ==========
