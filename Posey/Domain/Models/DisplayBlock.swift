import Foundation

// ========== BLOCK 01: DISPLAY BLOCK KIND - START ==========

enum DisplayBlockKind: Equatable, Hashable {
    case heading(level: Int)
    case paragraph
    case bullet
    case numbered
    case quote
    case visualPlaceholder
}

// ========== BLOCK 01: DISPLAY BLOCK KIND - END ==========

// ========== BLOCK 02: DISPLAY BLOCK - START ==========

struct DisplayBlock: Identifiable, Equatable, Hashable {
    let id: Int
    let kind: DisplayBlockKind
    let text: String
    let displayPrefix: String?
    let startOffset: Int
    let endOffset: Int
    /// Non-nil for `.visualPlaceholder` blocks that have a stored image in `document_images`.
    /// Nil for text-only placeholders (old documents or pages where rendering failed).
    let imageID: String?

    init(
        id: Int,
        kind: DisplayBlockKind,
        text: String,
        displayPrefix: String?,
        startOffset: Int,
        endOffset: Int,
        imageID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.displayPrefix = displayPrefix
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.imageID = imageID
    }
}

// ========== BLOCK 02: DISPLAY BLOCK - END ==========
