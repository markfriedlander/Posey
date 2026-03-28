import Foundation

// ========== BLOCK 01: EPUB DISPLAY PARSER - START ==========

/// Parses an EPUB displayText (which contains inline \x0c-delimited visual-image
/// markers) into DisplayBlocks for the reader. Unlike PDFDisplayParser, it does
/// not add "Page N" headings — EPUB has no page concept. It produces:
///   • .visualPlaceholder blocks for [[POSEY_VISUAL_PAGE:0:uuid]] markers
///   • .paragraph blocks for all other text, split on \n\n
struct EPUBDisplayParser {

    private let imageSeparator = "\u{000C}"  // form-feed, same character PDFs use

    func parse(displayText source: String) -> [DisplayBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var blocks: [DisplayBlock] = []
        var plainOffset = 0  // tracks position in plainText (no markers) for segment lookup

        let segments = normalized.components(separatedBy: imageSeparator)

        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Visual image marker?
            if let (_, imageID) = PDFDocumentImporter.parseVisualPageMarker(from: trimmed) {
                blocks.append(DisplayBlock(
                    id: blocks.count,
                    kind: .visualPlaceholder,
                    text: "Image",
                    displayPrefix: nil,
                    startOffset: plainOffset,
                    endOffset: plainOffset,
                    imageID: imageID
                ))
                continue
            }

            // Regular text — split into paragraphs
            let paragraphs = trimmed
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for para in paragraphs {
                let start = plainOffset
                let end   = start + para.count
                blocks.append(DisplayBlock(
                    id: blocks.count,
                    kind: .paragraph,
                    text: para,
                    displayPrefix: nil,
                    startOffset: start,
                    endOffset: end
                ))
                plainOffset = end + 2  // +2 for the \n\n separator
            }
        }

        return blocks
    }
}

// ========== BLOCK 01: EPUB DISPLAY PARSER - END ==========
