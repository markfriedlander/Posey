import Foundation
#if canImport(UIKit)
import UIKit
#endif

// ========== BLOCK 01: DOCX TABLE RASTERIZER - START ==========

/// 2026-06-15 — Renders a DOCX table's captured row/cell structure to a
/// PNG for DISPLAY in the reader, while the importer retains the
/// joined-row text for search / RAG / TTS (see `ContentUnitKind.table`).
///
/// **Why rasterize at all:** a table flattened into prose ("Chapter |
/// Words | Notes\nCHAPTER I | 521 | …") reads as gibberish and loses the
/// row/column relationships a reader needs. Mark's call (2026-06-15):
/// show the table as an image (visual fidelity), keep the text invisible
/// behind it for search + meaning.
///
/// **Why Core Graphics, not WebKit/NSAttributedString(html:):** DOCX
/// import runs OFF the main thread (`Task.detached`). `UIGraphicsImageRenderer`
/// renders offscreen and is safe off-main; a WKWebView snapshot would
/// force a main-thread hop + async ripple through the synchronous SAX
/// parser. CG keeps it deterministic and thread-agnostic.
///
/// Layout: equal-width columns within a fixed content width, per-cell
/// word-wrap, header row (row 0) bold over a light fill, 1px hairline
/// grid. Rendered at 2× for crisp text on Retina. Returns nil if UIKit
/// is unavailable or the table is empty — caller then leaves the table
/// as its text unit (graceful degradation to step-1 behavior).
enum DOCXTableRasterizer {

    #if canImport(UIKit)

    // Layout constants (points, pre-scale).
    private static let contentWidth: CGFloat = 720      // table body width
    private static let outerMargin: CGFloat = 12        // padding around the whole table
    private static let cellPaddingX: CGFloat = 10
    private static let cellPaddingY: CGFloat = 7
    private static let fontSize: CGFloat = 15
    private static let renderScale: CGFloat = 2.0
    private static let maxRows = 400                    // sanity cap on pathological tables

    static func render(rows: [[String]]) -> Data? {
        let normalized = normalize(rows)
        guard !normalized.isEmpty, let columnCount = normalized.map(\.count).max(), columnCount > 0 else {
            return nil
        }

        let bodyFont = UIFont.systemFont(ofSize: fontSize)
        let headerFont = UIFont.boldSystemFont(ofSize: fontSize)
        let columnWidth = contentWidth / CGFloat(columnCount)
        let textWidth = max(1, columnWidth - cellPaddingX * 2)

        // ── Measure each row's height = tallest wrapped cell + padding.
        var rowHeights: [CGFloat] = []
        rowHeights.reserveCapacity(normalized.count)
        for (rowIndex, row) in normalized.enumerated() {
            let font = rowIndex == 0 ? headerFont : bodyFont
            var tallest: CGFloat = font.lineHeight
            for col in 0..<columnCount {
                let text = col < row.count ? row[col] : ""
                guard !text.isEmpty else { continue }
                let h = measure(text, font: font, width: textWidth)
                tallest = max(tallest, h)
            }
            rowHeights.append(ceil(tallest) + cellPaddingY * 2)
        }

        let tableHeight = rowHeights.reduce(0, +)
        let totalSize = CGSize(width: contentWidth + outerMargin * 2,
                               height: tableHeight + outerMargin * 2)

        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: totalSize, format: format)

        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            // Background.
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: totalSize))

            let gridColor = UIColor(white: 0.78, alpha: 1.0)
            let headerFill = UIColor(white: 0.94, alpha: 1.0)
            let textColor = UIColor.black

            var y = outerMargin
            for (rowIndex, row) in normalized.enumerated() {
                let rowHeight = rowHeights[rowIndex]
                let isHeader = rowIndex == 0
                let font = isHeader ? headerFont : bodyFont

                // Header fill.
                if isHeader {
                    headerFill.setFill()
                    cg.fill(CGRect(x: outerMargin, y: y, width: contentWidth, height: rowHeight))
                }

                // Cell text.
                for col in 0..<columnCount {
                    let text = col < row.count ? row[col] : ""
                    guard !text.isEmpty else { continue }
                    let x = outerMargin + CGFloat(col) * columnWidth + cellPaddingX
                    let rect = CGRect(x: x, y: y + cellPaddingY,
                                      width: textWidth, height: rowHeight - cellPaddingY * 2)
                    let para = NSMutableParagraphStyle()
                    para.lineBreakMode = .byWordWrapping
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: textColor,
                        .paragraphStyle: para
                    ]
                    (text as NSString).draw(with: rect,
                                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                            attributes: attrs, context: nil)
                }

                y += rowHeight
            }

            // ── Grid: outer border + row separators + column separators.
            cg.setStrokeColor(gridColor.cgColor)
            cg.setLineWidth(1.0)
            let left = outerMargin, right = outerMargin + contentWidth
            let top = outerMargin, bottom = outerMargin + tableHeight

            // Horizontal lines (top of each row + bottom).
            var lineY = top
            cg.move(to: CGPoint(x: left, y: lineY)); cg.addLine(to: CGPoint(x: right, y: lineY))
            for h in rowHeights {
                lineY += h
                cg.move(to: CGPoint(x: left, y: lineY)); cg.addLine(to: CGPoint(x: right, y: lineY))
            }
            // Vertical lines (left of each column + right).
            for col in 0...columnCount {
                let x = left + CGFloat(col) * columnWidth
                cg.move(to: CGPoint(x: x, y: top)); cg.addLine(to: CGPoint(x: x, y: bottom))
            }
            cg.strokePath()
        }

        return image.pngData()
    }

    /// Wrapped height of `text` at `width` in `font`.
    private static func measure(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: para],
            context: nil
        )
        return bounds.height
    }

    /// Drop fully-empty trailing rows and cap pathological row counts so a
    /// malformed table can't produce an enormous image.
    private static func normalize(_ rows: [[String]]) -> [[String]] {
        var trimmed = rows.map { row in
            row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        while let last = trimmed.last, last.allSatisfy(\.isEmpty) {
            trimmed.removeLast()
        }
        if trimmed.count > maxRows { trimmed = Array(trimmed.prefix(maxRows)) }
        return trimmed
    }

    #else

    static func render(rows: [[String]]) -> Data? { nil }

    #endif
}

// ========== BLOCK 01: DOCX TABLE RASTERIZER - END ==========
