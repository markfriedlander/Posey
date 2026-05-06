import Foundation

// ========== BLOCK 01: DOCX DISPLAY PARSER - START ==========

/// Thin wrapper around `VisualPlaceholderSplitter` so the call site in
/// ReaderViewModel can stay format-symmetric. DOCX inline images use
/// the same `[[POSEY_VISUAL_PAGE:...]]` marker convention as EPUB / HTML.
struct DOCXDisplayParser {
    func parse(displayText source: String) -> [DisplayBlock] {
        VisualPlaceholderSplitter.parse(displayText: source)
    }
}

// ========== BLOCK 01: DOCX DISPLAY PARSER - END ==========
