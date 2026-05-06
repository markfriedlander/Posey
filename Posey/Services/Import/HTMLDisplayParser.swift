import Foundation

// ========== BLOCK 01: HTML DISPLAY PARSER - START ==========

/// Thin wrapper around `VisualPlaceholderSplitter`. HTML inline images
/// use the same `[[POSEY_VISUAL_PAGE:...]]` marker convention as EPUB / DOCX.
struct HTMLDisplayParser {
    func parse(displayText source: String) -> [DisplayBlock] {
        VisualPlaceholderSplitter.parse(displayText: source)
    }
}

// ========== BLOCK 01: HTML DISPLAY PARSER - END ==========
