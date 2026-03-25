import Foundation

enum NoteKind: String, Equatable, Hashable, Codable {
    case note
    case bookmark
}

struct Note: Identifiable, Equatable, Hashable {
    let id: UUID
    let documentID: UUID
    let createdAt: Date
    let updatedAt: Date
    let kind: NoteKind
    let startOffset: Int
    let endOffset: Int
    let body: String?
}
