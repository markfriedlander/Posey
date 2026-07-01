import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#endif

// `PDFTextLine` moved to its own Foundation-only file (`PDFTextLine.swift`,
// 2026-06-30) so the pure importer logic can compile in the fast standalone
// harness without this file's PDFKit/UIKit imports. Same type, same module.

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
            let raw = (lineSel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Reuse the EXISTING PDFWatermarkStripper (built 2026-05-22 for Crypto's
            // ChmMagic converter banner). The old displayText path stripped it
            // (PDFDocumentImporter); the new line path bypassed it, so the watermark
            // survived as a prose unit. A converter watermark is its OWN complete line
            // (verified Crypto, 2 methods: L0, body font ~8.5pt, top of EVERY page —
            // never a heading) → strips to empty → dropped by the guard below. The
            // patterns are narrow + brand-anchored, so real prose is never touched.
            let text = PDFWatermarkStripper.strip(raw)
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
