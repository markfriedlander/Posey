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

        // 2026-05-21 — corrected. The previous implementation advanced
        // `plainOffset` by `para.count + 2` per emitted paragraph. That
        // works when chunks are exactly `para1\n\npara2\n\npara3` —
        // but EPUB title pages and front-matter typically contain
        // whitespace-only runs like `\n\n  \n\n` between image markers
        // and prose. Those runs split into ["", "  ", ""] and trim to
        // all-empty, so no block is emitted — and `plainOffset` does
        // not advance even though the whitespace IS in plainText. Drift
        // accumulates, downstream block offsets land low, and the
        // reader's `startOffset >= skipUntil` filter silently drops
        // paragraphs whose true plainText offset is past the threshold
        // but whose splitter-computed offset is below.
        //
        // The corrected algorithm walks the chunk, finds each `\n\n`
        // separator, and positions each non-empty paragraph block at
        // its actual character offset inside the chunk (accounting for
        // leading-whitespace trim). `plainOffset` always advances by
        // the chunk's full character count, matching how plainText
        // is built from displayText (markers excluded, all other
        // chars included).
        @inline(__always) func emitParagraphs(in textChunk: String) {
            let chunkStartOffset = plainOffset
            var partStart = textChunk.startIndex
            while partStart < textChunk.endIndex {
                let separatorRange = textChunk.range(
                    of: "\n\n",
                    range: partStart..<textChunk.endIndex
                )
                let partEnd = separatorRange?.lowerBound ?? textChunk.endIndex
                let part = textChunk[partStart..<partEnd]
                let leadingWS = part.prefix(while: { $0.isWhitespace || $0.isNewline })
                let trailingWS = part.reversed().prefix(while: { $0.isWhitespace || $0.isNewline })
                if part.count > leadingWS.count + trailingWS.count {
                    let trimStart = textChunk.index(partStart, offsetBy: leadingWS.count)
                    let trimEnd = textChunk.index(partEnd, offsetBy: -trailingWS.count)
                    let trimmed = String(textChunk[trimStart..<trimEnd])
                    let paraOffsetInChunk = textChunk.distance(
                        from: textChunk.startIndex,
                        to: trimStart
                    )
                    let start = chunkStartOffset + paraOffsetInChunk
                    let end = start + trimmed.count
                    blocks.append(DisplayBlock(
                        id: blocks.count,
                        kind: .paragraph,
                        text: trimmed,
                        displayPrefix: nil,
                        startOffset: start,
                        endOffset: end
                    ))
                }
                partStart = separatorRange?.upperBound ?? textChunk.endIndex
            }
            // Always advance by the full chunk length — the chars are
            // in plainText regardless of whether they produced a block.
            plainOffset += textChunk.count
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
