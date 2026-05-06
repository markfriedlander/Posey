import Foundation

// ========== BLOCK 01: EPUB DISPLAY PARSER - START ==========

/// Parses an EPUB displayText (which contains inline \x0c-delimited visual-image
/// markers) into DisplayBlocks for the reader. Unlike PDFDisplayParser, it does
/// not add "Page N" headings — EPUB has no page concept. It produces:
///   • .visualPlaceholder blocks for [[POSEY_VISUAL_PAGE:0:uuid]] markers
///   • .paragraph blocks for all other text, split on \n\n
struct EPUBDisplayParser {

    func parse(displayText source: String) -> [DisplayBlock] {
        VisualPlaceholderSplitter.parse(displayText: source)
    }
}

// ========== BLOCK 01: EPUB DISPLAY PARSER - END ==========
