import Combine
import Foundation
import SwiftUI

// ========== BLOCK 01: VIEW MODEL - START ==========
/// State and behavior for the Ask Posey modal sheet. Owns the chat
/// transcript, the input text, the in-flight response state, and the
/// anchor passage. Created when the sheet opens and discarded when
/// it closes — no persistence in M4 (M7 will persist via
/// `ask_posey_conversations`).
///
/// Two `send` paths share the same view-model surface:
///
/// - **M4 stub:** `sendEchoStub(_:)` appends a fake assistant
///   response after a short delay. Used to drive the half-sheet
///   layout validation Mark called out as a design risk in the
///   implementation plan — we want to see the threaded chat with
///   real text on a real document before deciding the sheet detents.
///
/// - **M5+ live:** `send(_:)` will route through the intent
///   classifier (`AskPoseyClassifying`) and the response generator
///   (Call 2). Wiring lands in M5; the function signature on this
///   view model already accepts a classifier so the sheet layout
///   doesn't need to change between milestones.
///
/// `@MainActor` because every published property mutation drives a
/// SwiftUI view update; pinning to main avoids the cross-actor
/// publishing gymnastics.
@MainActor
final class AskPoseyChatViewModel: ObservableObject, Identifiable {

    /// Stable per-instance ID so SwiftUI's `sheet(item:)` can use
    /// the view model itself as the presentation key. Reconstructing
    /// the view model (which we do on every sheet open) gets a new
    /// id, which correctly drives a fresh sheet present.
    let id = UUID()

    /// Transcript in chronological order. Most recent message at the
    /// end. SwiftUI's List/ScrollView reads this directly.
    @Published private(set) var messages: [AskPoseyMessage] = []

    /// Two-way bound to the composer TextField.
    @Published var inputText: String = ""

    /// True between message submission and the assistant's last
    /// streamed snapshot. UI uses this to disable the Send button
    /// and show a typing indicator instead.
    @Published private(set) var isResponding: Bool = false

    /// The passage that was active at sheet invocation. Constant
    /// for the lifetime of this view model — re-opening the sheet
    /// creates a new view model with the new anchor.
    let anchor: AskPoseyAnchor?

    /// Live classifier injected at construction. Optional in M4
    /// because the echo-stub path doesn't actually call it; M5
    /// will always pass one. Keeping it optional now means M4's
    /// preview canvases don't need a working AFM stack.
    private let classifier: AskPoseyClassifying?

    /// Used to cancel the in-flight response if the user dismisses
    /// the sheet mid-generation. M4 stub simulates a delay; M5 will
    /// cancel a real `streamResponse` task.
    private var inFlightTask: Task<Void, Never>?

    init(
        anchor: AskPoseyAnchor?,
        classifier: AskPoseyClassifying? = nil
    ) {
        self.anchor = anchor
        self.classifier = classifier
    }

    deinit {
        // Don't capture self into the cancel call — the Task holds a
        // reference until its closure returns and we just need it to
        // unwind early. Direct .cancel() is enough.
        inFlightTask?.cancel()
    }

    /// Whether the composer is enabled. Disabled while a response is
    /// in flight (one Q&A at a time in v1) and when the input is
    /// empty/whitespace-only (no point sending nothing).
    var canSend: Bool {
        guard !isResponding else { return false }
        return !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// M4 stub send path. Appends a user message, then after a
    /// short async delay appends an assistant message that echoes
    /// the question with a clearly-labeled "[stub]" prefix so a
    /// real user immediately sees this isn't a real answer. M5
    /// replaces this with real AFM streaming.
    func sendEchoStub() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }
        let userMessage = AskPoseyMessage(role: .user, content: trimmed)
        messages.append(userMessage)
        inputText = ""
        isResponding = true

        let task = Task { @MainActor [weak self] in
            // Visible delay so the typing indicator has time to
            // appear and the layout transitions can be evaluated
            // during design validation. M5's real streaming will
            // make this irrelevant.
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            let response = AskPoseyMessage(
                role: .assistant,
                content: "[stub] You asked: \(trimmed)\n\nM4 sheet shell is wired. M5 will replace this with a real Apple Foundation Models response.",
                isStreaming: false
            )
            self.messages.append(response)
            self.isResponding = false
        }
        self.inFlightTask = task
        await task.value
    }

    /// Cancel any in-flight response. Called from the sheet's
    /// dismiss path so a long generation doesn't keep running after
    /// the user closes the sheet.
    func cancelInFlight() {
        inFlightTask?.cancel()
        inFlightTask = nil
        if isResponding {
            isResponding = false
        }
    }

    #if DEBUG
    /// Preview-only seeding hook so `#Preview` canvases can render
    /// with a populated transcript. Production callers go through
    /// `sendEchoStub` / `send` which exercise the real flow. Guarded
    /// to DEBUG so the seeding path doesn't ship in release builds.
    func previewSeedTranscript(_ seed: [AskPoseyMessage]) {
        messages = seed
    }
    #endif
}
// ========== BLOCK 01: VIEW MODEL - END ==========
