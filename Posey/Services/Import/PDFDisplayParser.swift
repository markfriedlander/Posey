import Foundation

// ========== BLOCK 01: PARSED PDF DISPLAY - START ==========

struct ParsedPDFDisplay {
    let blocks: [DisplayBlock]
}

// ========== BLOCK 01: PARSED PDF DISPLAY - END ==========

// ========== BLOCK 02: PDF DISPLAY PARSER - START ==========

struct PDFDisplayParser {
    private let pageSeparator = "\u{000C}"

    func parse(displayText source: String) -> ParsedPDFDisplay {
        let normalizedSource = normalizeSource(source)
        guard normalizedSource.isEmpty == false else {
            return ParsedPDFDisplay(blocks: [])
        }

        let pages = normalizedSource.components(separatedBy: pageSeparator)
        var blocks: [DisplayBlock] = []
        var offset = 0

        for (pageIndex, page) in pages.enumerated() {
            let normalizedPage = normalizePage(page)
            guard normalizedPage.isEmpty == false else {
                continue
            }

            if let (visualPageNumber, imageID) = PDFDocumentImporter.parseVisualPageMarker(from: normalizedPage) {
                blocks.append(
                    DisplayBlock(
                        id: blocks.count,
                        kind: .visualPlaceholder,
                        text: "Visual content on page \(visualPageNumber)",
                        displayPrefix: nil,
                        startOffset: offset,
                        endOffset: offset,
                        imageID: imageID
                    )
                )
                continue
            }

            let pageStartOffset = offset
            let paragraphs = normalizedPage
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }

            // Page boundaries are preserved as metadata in displayText (form-feed
            // separators) and as block start offsets, but we deliberately do not
            // emit a visible "Page N" heading. The reader is a continuous
            // reflowable stream; page numbers belong in document metadata, not in
            // the reading flow. (pageIndex is intentionally unused here.)
            _ = pageIndex

            var paragraphOffset = pageStartOffset
            for paragraph in paragraphs {
                let startOffset = paragraphOffset
                let endOffset = startOffset + paragraph.count
                blocks.append(
                    DisplayBlock(
                        id: blocks.count,
                        kind: .paragraph,
                        text: paragraph,
                        displayPrefix: nil,
                        startOffset: startOffset,
                        endOffset: endOffset
                    )
                )
                paragraphOffset = endOffset + 2
            }

            offset += normalizedPage.count + 2
        }

        return ParsedPDFDisplay(blocks: blocks)
    }

    private func normalizeSource(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizePage(_ page: String) -> String {
        page
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// ========== BLOCK 02: PDF DISPLAY PARSER - END ==========
