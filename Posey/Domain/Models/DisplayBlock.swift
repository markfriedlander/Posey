import Foundation

enum DisplayBlockKind: Equatable, Hashable {
    case heading(level: Int)
    case paragraph
    case bullet
    case numbered
    case quote
    case visualPlaceholder
}

struct DisplayBlock: Identifiable, Equatable, Hashable {
    let id: Int
    let kind: DisplayBlockKind
    let text: String
    let displayPrefix: String?
    let startOffset: Int
    let endOffset: Int
}
