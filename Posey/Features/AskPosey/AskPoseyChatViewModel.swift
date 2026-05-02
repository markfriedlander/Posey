import Combine
import Foundation
import SwiftUI

#if canImport(FoundationModels)
import FoundationModels
#endif

// ========== BLOCK 01: VIEW MODEL CORE - START ==========
/// State and behavior for the Ask Posey modal sheet.
///
/// **M5 architectural correction (2026-05-01).** Conversation history
/// is permanent: prior Ask Posey turns for a document live in
/// `ask_posey_conversations` and survive across sheet opens. The view
/// model loads them from SQLite at init so the UI can show prior
/// history above the fold (iMessage pattern) and the prompt builder
/// has access to everything ever discussed about this document.
///
/// Two `send` paths share the surface:
/// - **`sendEchoStub`** — preview/test path. Appends a fake assistant
///   reply after a short delay. Doesn't touch AFM, doesn't persist.
/// - **`send`** — live path. Classifies intent, builds the prompt,
///   streams a real AFM response, persists both turns to SQLite. The
///   path most users hit.
///
/// `@MainActor` because every published property mutation drives a
/// SwiftUI view update; pinning to main avoids cross-actor publishing
/// gymnastics.
@MainActor
final class AskPoseyChatViewModel: ObservableObject, Identifiable {

    /// Stable per-instance ID so SwiftUI's `sheet(item:)` can use
    /// the view model itself as the presentation key. Reconstructing
    /// the view model on every sheet open gets a new id, which
    /// correctly drives a fresh sheet present.
    let id = UUID()

    /// Transcript in chronological order. Most recent message at the
    /// end. The first messages on a returning conversation are loaded
    /// from `ask_posey_conversations`; subsequent messages append as
    /// the user sends them.
    @Published private(set) var messages: [AskPoseyMessage] = []

    /// Index into `messages` where this opening's session starts.
    /// Everything before this index was loaded from SQLite at sheet
    /// open; everything from this index forward was added in the
    /// current sheet session. The view uses this to render the
    /// anchor row at the boundary (iMessage pattern: prior history
    /// above, anchor as section divider, this session below).
    ///
    /// Set after `loadHistory()` completes. Stays constant after
    /// that — appending to `messages` grows the "this session" half
    /// without moving the boundary.
    @Published private(set) var historyBoundary: Int = 0

    /// Two-way bound to the composer TextField.
    @Published var inputText: String = ""

    /// True between message submission and the assistant's last
    /// streamed snapshot. UI uses this to disable the Send button
    /// and show a typing indicator.
    @Published private(set) var isResponding: Bool = false

    /// True while the per-document history is being loaded from
    /// SQLite. Brief — a single SELECT — but the UI uses it to
    /// suppress the "no prior history" flash on a returning open.
    @Published private(set) var isLoadingHistory: Bool = true

    /// Translated `AskPoseyServiceError` for the most recent failed
    /// send, or nil when no error is current. Surface to the user as
    /// an alert; clear when the user dismisses or retries.
    @Published var lastError: AskPoseyServiceError?

    /// Last response's metadata. Captured for the local-API tuning
    /// loop (token counts, drops, full prompt). Not persisted by the
    /// view model — the assistant turn row carries those fields.
    @Published private(set) var lastMetadata: AskPoseyResponseMetadata?

    /// The passage that was active at sheet invocation. Constant
    /// for the lifetime of this view model — re-opening the sheet
    /// creates a new view model with a new anchor.
    let anchor: AskPoseyAnchor?

    /// Document the conversation is anchored to. Used for both
    /// SQLite reads (prior history) and writes (every turn appends).
    let documentID: UUID

    /// Document plainText, used to compute surrounding context around
    /// the anchor offset per intent. Held by reference internally so
    /// large documents don't get copied on every send.
    private let documentPlainText: String

    /// Live classifier injected at construction. Optional in the M4
    /// stub canvases; required for the live `send` path.
    private let classifier: AskPoseyClassifying?

    /// Live prose streamer. Required for the live `send` path; nil
    /// for tests/previews that drive `sendEchoStub` only.
    private let streamer: AskPoseyStreaming?

    /// SQLite handle for history reads + turn persistence. Optional
    /// so previews/tests can run without a real DB.
    private let databaseManager: DatabaseManager?

    /// Token budget passed to the prompt builder. Single tuning point.
    private let budget: AskPoseyTokenBudget

    /// Used to cancel the in-flight response if the user dismisses
    /// the sheet mid-generation.
    private var inFlightTask: Task<Void, Never>?

    /// Background load task for prior history. Tests await its
    /// completion via `awaitHistoryLoaded()` to observe a stable
    /// state before assertions.
    private var historyLoadTask: Task<Void, Never>?

    /// Cached recent-conversation history sized for the prompt
    /// builder's STM window. Updated on every successful send so the
    /// next turn includes the just-completed exchange.
    private var historyForPromptBuilder: [AskPoseyMessage] = []

    /// Cap on history rows fetched from SQLite. Sized so the prompt
    /// builder has more raw rows than the STM budget can fit — extras
    /// are silently dropped at build time, which is the correct
    /// behavior. Set generously here; M6's summarization path will
    /// compress turns dropped by the budget into a summary.
    private let historyFetchLimit: Int = 30

    init(
        documentID: UUID,
        documentPlainText: String,
        anchor: AskPoseyAnchor?,
        classifier: AskPoseyClassifying? = nil,
        streamer: AskPoseyStreaming? = nil,
        databaseManager: DatabaseManager? = nil,
        budget: AskPoseyTokenBudget = .afmDefault
    ) {
        self.documentID = documentID
        self.documentPlainText = documentPlainText
        self.anchor = anchor
        self.classifier = classifier
        self.streamer = streamer
        self.databaseManager = databaseManager
        self.budget = budget

        // Kick off history load. UI shows isLoadingHistory until
        // this completes; on a fresh-document open it returns
        // immediately so no flash.
        self.historyLoadTask = Task { @MainActor [weak self] in
            await self?.loadHistory()
        }
    }

    deinit {
        // Direct .cancel() on the captured task references is enough.
        // Not capturing self into a closure because deinit is sync
        // and the cancellation propagates through whatever is
        // awaiting the task.
        inFlightTask?.cancel()
        historyLoadTask?.cancel()
    }

    /// Whether the composer is enabled. Disabled while a response is
    /// in flight (one Q&A at a time in v1) and when the input is
    /// empty/whitespace-only.
    var canSend: Bool {
        guard !isResponding else { return false }
        return !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    /// Test/automation hook so callers can synchronise on the initial
    /// history load before asserting against `messages`.
    func awaitHistoryLoaded() async {
        await historyLoadTask?.value
    }
}
// ========== BLOCK 01: VIEW MODEL CORE - END ==========


// ========== BLOCK 02: HISTORY LOADING + PERSISTENCE - START ==========
private extension AskPoseyChatViewModel {

    /// Load prior conversation turns for `documentID` from SQLite.
    /// Runs on init; idempotent if called twice (overwrites
    /// `messages` with whatever's currently in the DB).
    func loadHistory() async {
        defer { isLoadingHistory = false }

        guard let db = databaseManager else {
            // Preview/test paths without a DB just start empty.
            return
        }

        do {
            let count = try db.askPoseyTurnCount(for: documentID)
            guard count > 0 else { return }
            let stored = try db.askPoseyTurns(for: documentID, limit: historyFetchLimit)
            let translated = stored.compactMap(translateStoredTurn)
            messages = translated
            // Mark the boundary between prior-session history and
            // this-session additions. The view renders the anchor row
            // at this index.
            historyBoundary = translated.count
            // Populate the prompt-builder cache from the same
            // history; the cache is what the live send path passes
            // to the builder.
            historyForPromptBuilder = translated
        } catch {
            // History load failure is non-fatal — we just start
            // with an empty conversation rather than blocking the
            // sheet. Surface the error so it shows up in logs but
            // don't gate the UI on it.
            NSLog("AskPosey history load failed: \(error)")
        }
    }

    /// Translate a stored row into the in-memory message type. Returns
    /// nil for rows whose role string doesn't match (defensive — we
    /// haven't shipped non-user/assistant rows yet but defensive
    /// decoding is cheap).
    func translateStoredTurn(_ stored: StoredAskPoseyTurn) -> AskPoseyMessage? {
        guard let role = AskPoseyMessage.Role(rawValue: stored.role) else {
            return nil
        }
        // We don't reconstruct UUIDs from the stored row id (those
        // are textual, not UUIDs in our schema). Generate fresh —
        // the SwiftUI Identifiable contract just needs uniqueness
        // within the current view's data set.
        return AskPoseyMessage(
            id: UUID(),
            role: role,
            content: stored.content,
            isStreaming: false,
            timestamp: stored.timestamp
        )
    }

    /// Persist a single turn to SQLite. Best-effort: a failure logs
    /// and continues so a transient DB issue doesn't block the user
    /// from seeing the response in the UI.
    func persistTurn(
        role: AskPoseyMessage.Role,
        content: String,
        intent: AskPoseyIntent?,
        chunksInjected: [RetrievedChunk],
        fullPromptForLogging: String?
    ) {
        guard let db = databaseManager else { return }

        let chunksJSON: String
        if chunksInjected.isEmpty {
            chunksJSON = "[]"
        } else if let data = try? JSONEncoder().encode(chunksInjected),
                  let s = String(data: data, encoding: .utf8) {
            chunksJSON = s
        } else {
            chunksJSON = "[]"
        }

        let turn = StoredAskPoseyTurn(
            id: UUID().uuidString,
            documentID: documentID,
            timestamp: Date(),
            role: role.rawValue,
            content: content,
            invocation: "passage",
            anchorOffset: anchor?.plainTextOffset,
            intent: intent?.rawValue,
            chunksInjectedJSON: chunksJSON,
            fullPromptForLogging: fullPromptForLogging,
            summaryOfTurnsThrough: 0,
            isSummary: false
        )

        do {
            try db.appendAskPoseyTurn(turn)
        } catch {
            NSLog("AskPosey turn persist failed: \(error)")
        }
    }
}
// ========== BLOCK 02: HISTORY LOADING + PERSISTENCE - END ==========


// ========== BLOCK 03: SURROUNDING CONTEXT - START ==========
private extension AskPoseyChatViewModel {

    /// Extract a sentence-aware surrounding window around the anchor
    /// offset, sized to the per-intent token budget. Returns nil when
    /// the anchor offset is out of range or the intent's window is
    /// zero (`.search`).
    ///
    /// The window is split roughly half-before / half-after the
    /// anchor's start offset, then expanded outward to the nearest
    /// whitespace boundaries so we don't slice in the middle of a
    /// word. This is a deliberately simple implementation — M6's
    /// retriever can substitute a sentence-segmenter-aware variant
    /// when better quality is needed.
    func surroundingContext(for intent: AskPoseyIntent) -> String? {
        guard let anchor else { return nil }
        let windowTokens = AskPoseyPromptBuilder.surroundingWindowTokens(for: intent)
        guard windowTokens > 0 else { return nil }

        let totalChars = AskPoseyTokenEstimator.chars(in: windowTokens)
        guard totalChars > 0 else { return nil }

        let plain = documentPlainText
        guard !plain.isEmpty else { return nil }

        let anchorOffset = max(0, min(plain.count, anchor.plainTextOffset))
        let halfBefore = totalChars / 2
        let halfAfter = totalChars - halfBefore
        let startOffset = max(0, anchorOffset - halfBefore)
        let anchorEndOffset = min(plain.count, anchorOffset + anchor.text.count)
        let endOffset = min(plain.count, anchorEndOffset + halfAfter)

        guard startOffset < endOffset else { return nil }

        let startIndex = plain.index(plain.startIndex, offsetBy: startOffset)
        let endIndex = plain.index(plain.startIndex, offsetBy: endOffset)
        let raw = String(plain[startIndex..<endIndex])
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
// ========== BLOCK 03: SURROUNDING CONTEXT - END ==========


// ========== BLOCK 04: ECHO STUB (preview/test) - START ==========
extension AskPoseyChatViewModel {

    /// M4 stub send path retained for previews and the M3-M4 test
    /// canvases. Appends a user message, then after a short async
    /// delay appends an assistant message that echoes the question.
    /// Doesn't touch AFM and doesn't persist.
    func sendEchoStub() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }
        let userMessage = AskPoseyMessage(role: .user, content: trimmed)
        messages.append(userMessage)
        inputText = ""
        isResponding = true

        let task = Task { @MainActor [weak self] in
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

    #if DEBUG
    /// Preview-only seeding hook so `#Preview` canvases can render
    /// with a populated transcript.
    func previewSeedTranscript(_ seed: [AskPoseyMessage]) {
        messages = seed
    }
    #endif
}
// ========== BLOCK 04: ECHO STUB (preview/test) - END ==========


// ========== BLOCK 05: LIVE SEND (M5) - START ==========
extension AskPoseyChatViewModel {

    /// Live send path. Classifies intent, builds the prompt, streams
    /// a real AFM response, persists both turns. No-op when no
    /// classifier/streamer/DB are available — the caller falls back
    /// to `sendEchoStub` in that case.
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func send() async {
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty, !isResponding else { return }
        guard let classifier, let streamer else {
            // No live deps — degrade to echo so previews/tests keep
            // working.
            await sendEchoStub()
            return
        }

        // Snapshot the user-visible message and clear the composer
        // immediately so the UI feels responsive even before AFM
        // returns a token.
        let userMessage = AskPoseyMessage(role: .user, content: trimmedInput)
        messages.append(userMessage)
        historyForPromptBuilder.append(userMessage)
        inputText = ""
        isResponding = true
        lastError = nil

        // Persist user turn immediately so a crash mid-stream still
        // preserves what was asked.
        persistTurn(
            role: .user,
            content: trimmedInput,
            intent: nil,
            chunksInjected: [],
            fullPromptForLogging: nil
        )

        // Add a streaming-placeholder assistant message that will be
        // rewritten in place by the snapshot callback.
        let placeholderID = UUID()
        let placeholder = AskPoseyMessage(
            id: placeholderID,
            role: .assistant,
            content: "",
            isStreaming: true,
            timestamp: Date()
        )
        messages.append(placeholder)

        let anchorTextForClassifier = anchor?.trimmedDisplayText
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Call 1: intent classification.
                let intent: AskPoseyIntent
                do {
                    intent = try await classifier.classifyIntent(
                        question: trimmedInput,
                        anchor: anchorTextForClassifier
                    )
                } catch {
                    self.handleSendError(error, placeholderID: placeholderID, intent: nil)
                    return
                }

                // Call 2: prompt build + stream.
                let inputs = AskPoseyPromptInputs(
                    intent: intent,
                    anchor: self.anchor,
                    surroundingContext: self.surroundingContext(for: intent),
                    conversationHistory: self.historyForPromptBuilder,
                    conversationSummary: nil,         // M6 fills
                    documentChunks: [],               // M6 fills
                    currentQuestion: trimmedInput
                )

                do {
                    let metadata = try await streamer.streamProseResponse(
                        inputs: inputs,
                        budget: self.budget,
                        onSnapshot: { [weak self] snapshot in
                            self?.applyStreamingSnapshot(snapshot, to: placeholderID)
                        }
                    )
                    self.finalizeAssistantTurn(
                        metadata: metadata,
                        placeholderID: placeholderID,
                        intent: intent
                    )
                } catch is CancellationError {
                    // User dismissed — strip the placeholder and bail.
                    self.removeMessage(id: placeholderID)
                    self.isResponding = false
                } catch {
                    self.handleSendError(error, placeholderID: placeholderID, intent: intent)
                }
            }
        }
        self.inFlightTask = task
        await task.value
    }

    /// Snapshot callback target. Updates the placeholder bubble's
    /// content in place. Called on the main actor by the streamer.
    func applyStreamingSnapshot(_ snapshot: String, to placeholderID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == placeholderID }) else { return }
        messages[index].content = snapshot
        // Keep `isStreaming = true` until finalize swaps it.
    }

    /// Finalize the assistant turn after streaming completes. Marks
    /// the placeholder non-streaming, persists the turn with metadata,
    /// updates the prompt-builder cache so the next send sees this
    /// exchange.
    func finalizeAssistantTurn(
        metadata: AskPoseyResponseMetadata,
        placeholderID: UUID,
        intent: AskPoseyIntent
    ) {
        if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
            messages[index].content = metadata.finalText
            messages[index].isStreaming = false
            // Mirror the finalized turn into the prompt-builder cache
            // (replacing the placeholder we appended at send-start
            // with content "" — that placeholder was never in the
            // cache, so just append the final).
            historyForPromptBuilder.append(messages[index])
        }
        lastMetadata = metadata
        isResponding = false

        persistTurn(
            role: .assistant,
            content: metadata.finalText,
            intent: intent,
            chunksInjected: metadata.chunksInjected,
            fullPromptForLogging: metadata.fullPromptForLogging
        )
    }

    /// Translate a send-path error into UI state. Removes the
    /// streaming placeholder, surfaces the typed error, clears
    /// in-flight state.
    func handleSendError(_ error: Error, placeholderID: UUID, intent: AskPoseyIntent?) {
        removeMessage(id: placeholderID)
        if let serviceError = error as? AskPoseyServiceError {
            lastError = serviceError
        } else {
            lastError = .permanent(underlyingDescription: "\(error)")
        }
        _ = intent  // intent reserved for analytics in M5+ — unused for now
        isResponding = false
    }

    func removeMessage(id: UUID) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages.remove(at: index)
        }
    }
}
// ========== BLOCK 05: LIVE SEND (M5) - END ==========
