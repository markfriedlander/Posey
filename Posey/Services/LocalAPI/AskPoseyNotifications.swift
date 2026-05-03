import Foundation

// ========== BLOCK 01: NOTIFICATIONS - START ==========
/// NotificationCenter names for the local API → UI handoff path.
/// Used by `LocalAPIServer`'s `/open-ask-posey` endpoint to drive
/// the running app's navigation + sheet state programmatically so
/// the simulator MCP can screenshot the user experience for
/// autonomous UI verification (M6 test infrastructure per Mark's
/// directive 2026-05-01).
extension Notification.Name {
    /// Posted by `LibraryViewModel.apiOpenAskPosey(...)` with
    /// `userInfo["documentID"]: UUID` and `userInfo["scope"]: String`
    /// (`"passage"` or `"document"`). Observed by:
    ///
    /// - `LibraryView` to navigate to the matching document.
    /// - `ReaderView` to open the Ask Posey sheet on appear.
    static let openAskPoseyForDocument = Notification.Name("PoseyOpenAskPoseyForDocument")

    /// Task 4 #10 (2026-05-03) — posted by `AskPoseyChatViewModel`
    /// whenever it appends a turn (or anchor row) to
    /// `ask_posey_conversations`. UserInfo: `documentID: UUID` and
    /// `originator: UUID` (the posting view-model's `id`). Observed
    /// by every `AskPoseyChatViewModel`; matching documents whose
    /// originator differs reload from SQLite so the open sheet
    /// reflects /ask turns persisted by a separate (headless) VM
    /// without a dismiss/reopen cycle.
    static let askPoseyConversationDidUpdate = Notification.Name("PoseyAskPoseyConversationDidUpdate")
}
// ========== BLOCK 01: NOTIFICATIONS - END ==========
