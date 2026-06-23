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

    // E2 R8 — durable anchor (legal-grade). Captured at creation against the canonical
    // document text. If a later text mutation drifts the offsets, these let the reader
    // RE-FIND the exact substring (or FLAG it as unanchorable) instead of silently
    // highlighting the wrong words. nil for legacy/offset-only rows + bookmarks created
    // before R8; treated as "trust the offset, no verification."
    var anchorText: String? = nil
    var contextBefore: String? = nil
    var contextAfter: String? = nil
}
