import Foundation

// ========== BLOCK 01: MESSAGE - START ==========
/// One message in an Ask Posey conversation, as rendered in the
/// threaded chat history of the modal sheet. Storage on this struct
/// is intentionally minimal — it covers the v1 sheet UI's needs:
///
/// - `id` for SwiftUI list identity (UUID, stable across view updates).
/// - `role` user vs assistant so the bubble renders on the correct side.
/// - `content` the message body. Updated incrementally by the streaming
///   response loop in M5; appended to atomically by the M4 echo stub.
/// - `isStreaming` true while AFM is still emitting tokens for an
///   assistant message; M4's stub flips this once at the end of the
///   echo so the UI can validate transitions before M5 wires the
///   real `streamResponse`.
/// - `timestamp` for the persisted-conversation milestone (M7); kept
///   on every message even in M4 so the type doesn't need a schema
///   bump later.
///
/// `Sendable` because the chat view model passes message snapshots
/// across actor boundaries when the streaming response arrives on a
/// background queue and updates UI state on main.
struct AskPoseyMessage: Identifiable, Equatable, Sendable {

    enum Role: String, Sendable, Codable, Equatable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var content: String
    var isStreaming: Bool
    let timestamp: Date
    /// Document chunks the prompt builder injected to ground this
    /// assistant turn (M7 source attribution surface). Empty for
    /// user messages and for assistant turns that didn't receive any
    /// RAG chunks. Populated by the chat view model in
    /// `finalizeAssistantTurn(...)` from the response metadata. The
    /// view renders these as a tappable "Sources" strip below the
    /// bubble — each pill jumps the reader to the chunk's offset.
    var chunksInjected: [RetrievedChunk]
    /// M7 navigation-card response. When the classifier returned
    /// `.search`, the assistant turn ships a list of tappable
    /// destination cards instead of prose. Empty for `.immediate` /
    /// `.general` responses and for user messages.
    var navigationCards: [AskPoseyNavigationCard]

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        isStreaming: Bool = false,
        timestamp: Date = .now,
        chunksInjected: [RetrievedChunk] = [],
        navigationCards: [AskPoseyNavigationCard] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.timestamp = timestamp
        self.chunksInjected = chunksInjected
        self.navigationCards = navigationCards
    }
}
// ========== BLOCK 01: MESSAGE - END ==========


// ========== BLOCK 02: ANCHOR - START ==========
/// The passage the user was looking at when Ask Posey was invoked.
/// Quoted at the top of the sheet so the model (M5+) and the user
/// both have shared context. For document-scoped invocations the
/// anchor is the active sentence; for passage-scoped invocations
/// (M5+) it's the selected text.
struct AskPoseyAnchor: Equatable, Sendable {

    /// The verbatim text shown at the top of the sheet.
    let text: String
    /// Character offset in `Document.plainText` so the anchor pill
    /// (and future "jump to passage" links from source attribution
    /// in M7) can navigate back to this position.
    let plainTextOffset: Int

    var trimmedDisplayText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
// ========== BLOCK 02: ANCHOR - END ==========
