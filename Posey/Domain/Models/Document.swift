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
    /// listening experience (e.g. PDF TOC, Gutenberg license preamble) and
    /// shouldn't be the very first thing the user hears. Zero means no
    /// skip; the reader opens at offset 0.
    var playbackSkipUntilOffset: Int = 0

    /// Character offset in plainText at which the reader should treat the
    /// document as ended. Set when an importer detects a trailing region
    /// that isn't part of the book (e.g. Gutenberg's license trailer
    /// following `*** END OF THE PROJECT GUTENBERG EBOOK ***`). Zero means
    /// no end boundary recorded — playback runs to the end of plainText.
    /// 2026-05-21.
    var contentEndOffset: Int = 0
}
