import Foundation

// ========== BLOCK 01: VISUAL PLACEHOLDER SPLITTER - START ==========

/// Shared parser used by EPUB / DOCX / HTML to convert a marker-bearing
/// displayText into DisplayBlocks. Markers look like
/// `[[POSEY_VISUAL_PAGE:0:<uuid>]]` and are emitted by the importers at
/// each inline-image position.
///
/// The marker delimiters were originally form-feed (U+000C), but
/// `TextNormalizer.stripMojibakeAndControlCharacters` (which runs in the
/// EPUB / DOCX / HTML normalize passes) strips C0 controls including
/// form-feed. So we no longer rely on a surrounding sentinel — we find
/// the marker substring directly via a single regex scan over the
/// displayText.
///
/// Output offsets are in *plainText space* (markers contribute zero
/// characters) so they line up with sentence segments built from
/// plainText.
enum VisualPlaceholderSplitter {

    private static let markerRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\[\\[POSEY_VISUAL_PAGE:[^\\]]+\\]\\]")
    }()

    static func parse(displayText source: String) -> [DisplayBlock] {
        guard let regex = markerRegex else { return [] }

        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let nsString = normalized as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let matches = regex.matches(in: normalized, range: fullRange)

        // Fast path: no markers → no work for the displayBlocks renderer.
        // Returning [] keeps the document on the existing sentence-row
        // reader path with its known performance profile on large files.
        guard !matches.isEmpty else { return [] }

        var blocks: [DisplayBlock] = []
        var plainOffset = 0
        var cursor = 0

        @inline(__always) func emitParagraphs(in textChunk: String) {
            let paragraphs = textChunk
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for para in paragraphs {
                let start = plainOffset
                let end = start + para.count
                blocks.append(DisplayBlock(
                    id: blocks.count,
                    kind: .paragraph,
                    text: para,
                    displayPrefix: nil,
                    startOffset: start,
                    endOffset: end
                ))
                plainOffset = end + 2
            }
        }

        for match in matches {
            // Text before this marker.
            if match.range.location > cursor {
                let preRange = NSRange(location: cursor, length: match.range.location - cursor)
                let preText = nsString.substring(with: preRange)
                emitParagraphs(in: preText)
            }
            let markerText = nsString.substring(with: match.range)
            if let (_, imageID) = PDFDocumentImporter.parseVisualPageMarker(from: markerText) {
                blocks.append(DisplayBlock(
                    id: blocks.count,
                    kind: .visualPlaceholder,
                    text: "Image",
                    displayPrefix: nil,
                    startOffset: plainOffset,
                    endOffset: plainOffset,
                    imageID: imageID
                ))
            }
            cursor = match.range.location + match.range.length
        }

        // Trailing text after the last marker.
        if cursor < nsString.length {
            let tailRange = NSRange(location: cursor, length: nsString.length - cursor)
            let tailText = nsString.substring(with: tailRange)
            emitParagraphs(in: tailText)
        }

        return blocks
    }
}

// ========== BLOCK 01: VISUAL PLACEHOLDER SPLITTER - END ==========
