import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// ========== BLOCK 01: TYPES - START ==========
/// One navigation card surfaced to the user when the classifier
/// returned `.search`. Replaces prose for "where in the document does
/// X appear?"-style questions — the user gets a tappable list of
/// destinations instead of a paragraph that says "section 3.2."
///
/// Persists alongside an assistant turn in
/// `ask_posey_conversations.chunks_injected` (we reuse the existing
/// JSON column rather than adding another) so re-opening a returning
/// conversation surfaces the same cards.
nonisolated struct AskPoseyNavigationCard: Sendable, Equatable, Codable, Identifiable {
    /// Stable card identity for SwiftUI lists. Generated at build
    /// time so persistence round-trips don't re-shuffle.
    let id: UUID
    /// Short headline shown in the card. AFM is asked to keep this
    /// to 6–10 words.
    let title: String
    /// One-sentence reason this destination answers the question.
    /// AFM is asked to keep it specific — quote the chunk where it
    /// helps clarity.
    let reason: String
    /// Character offset in `Document.plainText` to jump to on tap.
    /// Sourced from the chunk the card was built from.
    let plainTextOffset: Int
    /// The underlying chunk's relevance score, kept for the same
    /// "SOURCES" attribution surface prose responses use.
    let relevance: Double
    /// Chunk id from `document_chunks`. Persisted so future audits
    /// can correlate cards back to their source chunks.
    let chunkID: Int

    init(
        id: UUID = UUID(),
        title: String,
        reason: String,
        plainTextOffset: Int,
        relevance: Double,
        chunkID: Int
    ) {
        self.id = id
        self.title = title
        self.reason = reason
        self.plainTextOffset = plainTextOffset
        self.relevance = relevance
        self.chunkID = chunkID
    }
}
// ========== BLOCK 01: TYPES - END ==========


// ========== BLOCK 02: GENERABLE SCHEMA - START ==========
#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct AskPoseyNavigationCardSet: Sendable {

    @Guide(description: "Three to six destination cards, ranked by usefulness for the user's question. Pick from the candidate sections you were given; do not invent destinations.")
    let cards: [Card]

    @Generable
    struct Card: Sendable {

        @Guide(description: "Short headline — 6 to 10 words — describing the section in plain reader-facing language.")
        let title: String

        @Guide(description: "One sentence explaining specifically why this section answers the user's question. Quote the section directly when it makes the answer clearer.")
        let reason: String

        @Guide(description: "Zero-based index into the candidate sections you were given. The candidates are listed in the prompt as [0], [1], [2]... — pick the index whose passage best matches your card.")
        let candidateIndex: Int
    }
}
#endif
// ========== BLOCK 02: GENERABLE SCHEMA - END ==========


// ========== BLOCK 03: PROTOCOL - START ==========
/// Navigation-card generation interface. Same protocol-driven test
/// substitution rationale as the other Ask Posey service surfaces.
@MainActor
protocol AskPoseyNavigating: Sendable {
    /// Given the user's `.search`-classified question and a set of
    /// candidate chunks (M2 RAG retrieval results), ask AFM to pick
    /// 3–6 of them as navigation destinations. Returns the resolved
    /// `AskPoseyNavigationCard` list with chunk offsets baked in.
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func generateNavigationCards(
        question: String,
        candidates: [RetrievedChunk]
    ) async throws -> [AskPoseyNavigationCard]
}
// ========== BLOCK 03: PROTOCOL - END ==========


// ========== BLOCK 04: PROMPT BUILDER - START ==========
/// Pure-string helper for the navigation-card Call-2 prompt. Kept
/// separate from `AskPoseyPrompts` (the classifier prompts) so each
/// surface's prompt shape is independently testable.
nonisolated enum AskPoseyNavigationPrompts {

    /// Stable system framing for the navigation pipeline. Short on
    /// purpose — every token here is paid on every search request.
    static let systemInstructions: String = """
    You are Posey, a quiet, focused reading companion. The user asked \
    where in their document something appears, and you have a list of \
    candidate sections retrieved from the document. Pick the most \
    useful 3 to 6 destinations and return them as navigation cards.

    Each card needs a short title, a one-sentence reason, and the \
    candidate index. Never invent destinations or paraphrase candidates \
    so loosely the reader can't tell what they'll see when they tap.
    """

    /// Render the user-facing portion of the prompt. The candidate
    /// chunks are passed verbatim with `[i]` indices so the model can
    /// address them by index in the `Card.candidateIndex` field.
    static func body(question: String, candidates: [RetrievedChunk]) -> String {
        var lines: [String] = []
        lines.append("User question: \"\(question.trimmingCharacters(in: .whitespacesAndNewlines))\"")
        lines.append("")
        lines.append("Candidate sections from this document (oldest first by relevance ranking):")
        lines.append("")
        for (index, chunk) in candidates.enumerated() {
            lines.append("[\(index)] offset \(chunk.startOffset) | relevance \(String(format: "%.2f", chunk.relevance))")
            lines.append(chunk.text)
            lines.append("")
        }
        lines.append("Pick 3–6 destinations. Return only the structured navigation card set.")
        return lines.joined(separator: "\n")
    }
}
// ========== BLOCK 04: PROMPT BUILDER - END ==========
