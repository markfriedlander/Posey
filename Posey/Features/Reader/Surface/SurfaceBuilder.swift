import UIKit

// ========== BLOCK 01: SURFACE BUILDER - START ==========

/// Turns Posey's `[ContentUnit]` (+ `[Sentence]`) into ONE attributed string and a
/// `LayoutMap`, in one pass so the two can never drift. This is the Stage-B bridge:
/// the importer/data model upstream is untouched; this replaces the old
/// per-row `UnitRowView` rendering with attribute runs in a single surface.
///
/// Styling matches the current reader (see UnitRowView spec). The sentence anchors
/// (`intraStart/intraEnd` into `unit.text`) are lifted to surface ranges, accounting
/// for any prefix we add (e.g. a list marker) so a spoken/tapped sentence still maps
/// to the exact characters.
enum SurfaceBuilder {

    static func build(units: [ContentUnit],
                      sentences: [Sentence],
                      bodyPointSize: CGFloat,
                      tuning: ReaderTuning = .aml,
                      imageData: (String) -> Data?) -> ReaderSurfaceContent {

        let body = NSMutableAttributedString()
        var unitRanges: [UUID: NSRange] = [:]
        var segments: [SurfaceSegment] = []
        var anchors: [AnchorUnit] = []
        var canonicalCursor = 0     // Character offset into the joined canonical text
        var playbackIndex = 0

        // Sentences grouped by unit, in intra order.
        var sentencesByUnit: [UUID: [Sentence]] = [:]
        for s in sentences { sentencesByUnit[s.unitID, default: []].append(s) }
        for k in sentencesByUnit.keys {
            sentencesByUnit[k]?.sort { $0.sentenceIndex < $1.sentenceIndex }
        }

        let ordered = units.sorted { $0.sequence < $1.sequence }

        for unit in ordered {
            let unitStart = body.length
            // textStart = where unit.text's characters begin in the surface (after a
            // marker prefix); -1 means this unit renders as a non-text attachment.
            let textStart = appendUnit(unit, into: body, bodyPointSize: bodyPointSize,
                                       tuning: tuning, imageData: imageData)
            // Paragraph separator between units (visual gap comes from paragraphSpacing).
            body.append(NSAttributedString(string: "\n"))
            let unitRange = NSRange(location: unitStart, length: body.length - unitStart)
            unitRanges[unit.id] = unitRange

            // Record the canonical ↔ surface anchor for any unit that rendered real
            // text (textStart >= 0). This is the annotation bridge AND the canonical
            // text source; advance the canonical cursor by the unit's Character count
            // + a "\n\n" separator so canonical offsets are globally unique + monotonic.
            if textStart >= 0 {
                anchors.append(AnchorUnit(unitID: unit.id, canonicalStart: canonicalCursor,
                                          charCount: unit.text.count, surfaceTextStart: textStart,
                                          text: unit.text))
                canonicalCursor += unit.text.count + 2
            }

            // Map this unit's sentences to surface ranges (playback order).
            guard unit.kind.carriesProseText, let segs = sentencesByUnit[unit.id] else { continue }
            for sent in segs {
                let range: NSRange
                if textStart >= 0 {
                    let loc = textStart + sent.intraStart
                    let len = max(0, sent.intraEnd - sent.intraStart)
                    // Clamp defensively against any prefix/encoding skew.
                    guard loc >= unitStart, loc + len <= NSMaxRange(unitRange) else { continue }
                    range = NSRange(location: loc, length: len)
                } else {
                    // Attachment-rendered prose (table): no visible text — pin the
                    // attachment itself when read.
                    range = NSRange(location: unitStart, length: max(1, unitRange.length - 1))
                }
                segments.append(SurfaceSegment(sentenceID: sent.id, unitID: unit.id,
                                               playbackIndex: playbackIndex, range: range,
                                               text: sent.text))
                playbackIndex += 1
            }
        }

        return ReaderSurfaceContent(attributed: body,
                                    layout: LayoutMap(unitRanges: unitRanges, segments: segments,
                                                      anchors: anchors))
    }

    // ========== BLOCK 02: PER-KIND RENDERING - START ==========

    /// Appends the unit's rendered content; returns the surface offset where
    /// `unit.text` begins (for sentence mapping), or -1 for attachment units.
    private static func appendUnit(_ unit: ContentUnit, into body: NSMutableAttributedString,
                                   bodyPointSize: CGFloat, tuning: ReaderTuning,
                                   imageData: (String) -> Data?) -> Int {
        let label = UIColor.label
        let lineSpacing = bodyPointSize * 0.35
        let para = paragraph(lineSpacing: lineSpacing, spacingBefore: 0, spacingAfter: bodyPointSize * 0.7)

        switch unit.kind {
        case .prose:
            let start = body.length
            body.append(NSAttributedString(string: unit.text, attributes: [
                .font: UIFont.systemFont(ofSize: bodyPointSize),
                .foregroundColor: label, .paragraphStyle: para,
            ]))
            return start

        case .heading:
            let start = body.length
            let scale = headingScale(unit.metadata.headingLevel ?? 1)
            let hPara = paragraph(lineSpacing: lineSpacing,
                                  spacingBefore: bodyPointSize * 0.75, spacingAfter: bodyPointSize * 0.3)
            let full = unit.text as NSString
            if let titleLen = unit.metadata.titleLength, titleLen > 0, titleLen <= full.length {
                // Mixed title + body: bold the title portion, body font the rest.
                let m = NSMutableAttributedString(string: unit.text, attributes: [
                    .font: UIFont.systemFont(ofSize: bodyPointSize), .foregroundColor: label,
                    .paragraphStyle: hPara,
                ])
                m.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: bodyPointSize * scale),
                               range: NSRange(location: 0, length: titleLen))
                body.append(m)
            } else {
                body.append(NSAttributedString(string: unit.text, attributes: [
                    .font: UIFont.boldSystemFont(ofSize: bodyPointSize * scale),
                    .foregroundColor: label, .paragraphStyle: hPara,
                ]))
            }
            return start

        case .blockquote:
            let start = body.length
            let qPara = paragraph(lineSpacing: lineSpacing, spacingBefore: 0,
                                  spacingAfter: bodyPointSize * 0.7, headIndent: 16, firstLineIndent: 16)
            body.append(NSAttributedString(string: unit.text, attributes: [
                .font: UIFont.italicSystemFont(ofSize: bodyPointSize),
                .foregroundColor: label.withAlphaComponent(0.85), .paragraphStyle: qPara,
            ]))
            return start

        case .listItem:
            let marker = unit.metadata.listMarker ?? "•\t"
            let lPara = paragraph(lineSpacing: lineSpacing, spacingBefore: 0,
                                  spacingAfter: bodyPointSize * 0.3, headIndent: 24, firstLineIndent: 0)
            body.append(NSAttributedString(string: marker, attributes: [
                .font: UIFont.systemFont(ofSize: bodyPointSize),
                .foregroundColor: label, .paragraphStyle: lPara,
            ]))
            let start = body.length   // unit.text begins AFTER the marker
            body.append(NSAttributedString(string: unit.text, attributes: [
                .font: UIFont.systemFont(ofSize: bodyPointSize),
                .foregroundColor: label, .paragraphStyle: lPara,
            ]))
            return start

        case .code:
            let start = body.length
            let cPara = paragraph(lineSpacing: bodyPointSize * 0.25, spacingBefore: bodyPointSize * 0.3,
                                  spacingAfter: bodyPointSize * 0.5, headIndent: 8, firstLineIndent: 8)
            body.append(NSAttributedString(string: unit.text, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: bodyPointSize * 0.9, weight: .regular),
                .foregroundColor: label, .paragraphStyle: cPara,
                .backgroundColor: UIColor.label.withAlphaComponent(0.06),
            ]))
            return start

        case .image, .table:
            appendImage(unit, into: body, bodyPointSize: bodyPointSize, para: para, imageData: imageData)
            return -1

        case .pageBreak:
            let n = (unit.metadata.pageNumber ?? 0) + 1
            appendCentered("page \(n)", into: body, size: bodyPointSize * 0.7,
                           color: .secondaryLabel, spacingBefore: 14, spacingAfter: 14)
            return -1

        case .horizontalRule:
            appendCentered("* * *", into: body, size: bodyPointSize * 0.9,
                           color: .tertiaryLabel, spacingBefore: 16, spacingAfter: 16)
            return -1
        }
    }

    // ========== BLOCK 02: PER-KIND RENDERING - END ==========

    // ========== BLOCK 03: HELPERS - START ==========

    private static func appendImage(_ unit: ContentUnit, into body: NSMutableAttributedString,
                                    bodyPointSize: CGFloat, para: NSParagraphStyle,
                                    imageData: (String) -> Data?) {
        if let id = unit.metadata.imageID, let data = imageData(id), let img = UIImage(data: data) {
            let att = WidthFittingTextAttachment()
            att.image = img
            let center = NSMutableParagraphStyle()
            center.alignment = .center
            center.paragraphSpacing = bodyPointSize * 0.7
            body.append(NSAttributedString(attachment: att))
            body.append(NSAttributedString(string: "\u{200B}", attributes: [.paragraphStyle: center]))
        } else {
            // Fallback: a placeholder line (table keeps its searchable text as mono).
            let text = unit.kind == .table && !unit.text.isEmpty ? unit.text : "[\(unit.kind.rawValue)]"
            body.append(NSAttributedString(string: text, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: bodyPointSize * 0.9, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: para,
            ]))
        }
    }

    private static func appendCentered(_ s: String, into body: NSMutableAttributedString,
                                       size: CGFloat, color: UIColor,
                                       spacingBefore: CGFloat, spacingAfter: CGFloat) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = spacingAfter
        body.append(NSAttributedString(string: s, attributes: [
            .font: UIFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: p,
        ]))
    }

    private static func paragraph(lineSpacing: CGFloat, spacingBefore: CGFloat, spacingAfter: CGFloat,
                                  headIndent: CGFloat = 0, firstLineIndent: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = spacingAfter
        p.headIndent = headIndent
        p.firstLineHeadIndent = firstLineIndent
        return p
    }

    private static func headingScale(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 1.75
        case 2: return 1.40
        case 3: return 1.20
        case 4: return 1.10
        case 5: return 1.05
        default: return 1.00
        }
    }

    // ========== BLOCK 03: HELPERS - END ==========
}

// ========== BLOCK 04: WIDTH-FITTING IMAGE ATTACHMENT - START ==========

/// A text attachment that scales its image down to the line-fragment width (never
/// up), preserving aspect — so images/rasterized tables fit the reading column.
final class WidthFittingTextAttachment: NSTextAttachment {
    override func attachmentBounds(for textContainer: NSTextContainer?,
                                   proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint,
                                   characterIndex charIndex: Int) -> CGRect {
        guard let img = image else {
            return super.attachmentBounds(for: textContainer, proposedLineFragment: lineFrag,
                                          glyphPosition: position, characterIndex: charIndex)
        }
        let maxW = lineFrag.width > 0 ? lineFrag.width : img.size.width
        let scale = min(1, maxW / max(1, img.size.width))
        return CGRect(x: 0, y: 0, width: img.size.width * scale, height: img.size.height * scale)
    }
}

// ========== BLOCK 04: WIDTH-FITTING IMAGE ATTACHMENT - END ==========
// ========== BLOCK 01: SURFACE BUILDER - END ==========
