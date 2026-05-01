import Foundation

struct Document: Identifiable, Equatable, Hashable {
    let id: UUID
    let title: String
    let fileName: String
    let fileType: String
    let importedAt: Date
    let modifiedAt: Date
    let displayText: String
    let plainText: String
    let characterCount: Int
    /// Character offset in plainText past which the reader auto-jumps on
    /// first open. Set when an importer detects a region that's a poor
    /// listening experience (e.g. PDF TOC) and shouldn't be the very first
    /// thing the user hears. Zero means no skip.
    var playbackSkipUntilOffset: Int = 0
}
