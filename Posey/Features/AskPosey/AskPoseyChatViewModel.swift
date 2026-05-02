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

    /// Lazily-constructed embedding index for M6 RAG retrieval.
    /// Built on first need from `databaseManager` so M5's empty-RAG
    /// path doesn't pay any setup cost. `nil` whenever the view
    /// model has no DB (preview / unit-test paths).
    private lazy var embeddingIndex: DocumentEmbeddingIndex? = {
        guard let db = databaseManager else { return nil }
        return DocumentEmbeddingIndex(database: db)
    }()

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

    /// Top-K cap for RAG retrieval. Sized so the budget enforcer can
    /// pick the best chunks rather than the only ones it got handed.
    /// Average chunk ≈ 500 chars ≈ 142 tokens, so K=8 maps to
    /// roughly 1136 tokens of raw chunk content — well under the
    /// 1800-token RAG budget, leaving the cosine-dedup pass and the
    /// builder's own drop logic room to make ranking decisions.
    private let ragTopK: Int = 8

    /// Cosine similarity threshold above which a candidate chunk is
    /// considered redundant with content already in the prompt
    /// (anchor + STM verbatim concatenated). Mirrors Hal's 0.85
    /// default. Tunable via the local-API loop alongside the token
    /// budget constants.
    private let ragDedupThreshold: Double = 0.85

    /// In-flight conversation-summarization task. Set when a turn
    /// finalizes with enough older messages to need summarizing; the
    /// next send awaits this before building its prompt so the
    /// summary section is always current.
    private var summarizationTask: Task<Void, Never>?

    /// Cached summary string fetched from `ask_posey_conversations`
    /// (`is_summary = 1`). Refreshed whenever the summarization task
    /// completes. The prompt builder reads this directly via the
    /// `conversationSummary` input.
    private var cachedConversationSummary: String?

    /// Watermark — the index past which the current summary covers.
    /// `summarizeOlderTurnsIfNeeded` uses this to decide whether the
    /// existing summary is still good or needs to be re-run with the
    /// new boundary.
    private var summaryCoveredThrough: Int = 0

    /// Threshold past which auto-summarization triggers. When the
    /// non-summary turn count exceeds the recent-verbatim window plus
    /// this margin, we summarize the older half. Sized so a typical
    /// ~3-4-turn STM stays untouched and summarization only fires
    /// when conversations grow long.
    private let summarizeWhenTurnsExceed: Int = 8

    /// How many of the most recent turns to keep verbatim (i.e. NOT
    /// fold into the summary). The rest get summarized whenever the
    /// trigger fires above.
    private let keepVerbatimRecent: Int = 6

    /// Optional summarizer for the M6 auto-summarization path.
    /// Defaulted to nil (and tolerated as nil) so M5/older code paths
    /// keep working — when nil, summarization simply doesn't fire and
    /// the prompt builder receives `conversationSummary: nil`. The
    /// live `AskPoseyService` conforms to all three protocols, so
    /// production callers pass the same instance for `streamer` and
    /// `summarizer`.
    private let summarizer: AskPoseySummarizing?

    /// Optional navigation-card generator for M7 `.search` intent.
    /// Defaulted to nil so older code paths keep working — when nil,
    /// `.search` falls through to the prose path with degraded
    /// (anchor-only or chunks-only) grounding. The live
    /// `AskPoseyService` conforms; production callers pass the same
    /// instance for all four service protocols.
    private let navigator: AskPoseyNavigating?

    init(
        documentID: UUID,
        documentPlainText: String,
        anchor: AskPoseyAnchor?,
        classifier: AskPoseyClassifying? = nil,
        streamer: AskPoseyStreaming? = nil,
        summarizer: AskPoseySummarizing? = nil,
        navigator: AskPoseyNavigating? = nil,
        databaseManager: DatabaseManager? = nil,
        budget: AskPoseyTokenBudget = .afmDefault
    ) {
        self.documentID = documentID
        self.documentPlainText = documentPlainText
        self.anchor = anchor
        self.classifier = classifier
        self.streamer = streamer
        self.summarizer = summarizer
        self.navigator = navigator
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

    /// M7 auto-save to notes: persists an Ask Posey turn (the question
    /// the user asked + the assistant's answer) as a Note on the
    /// document, anchored to the offset the conversation was about
    /// (the anchor's offset for passage-scoped, or the assistant
    /// turn's first cited chunk for document-scoped, or 0 as a last
    /// resort). Returns true on success.
    ///
    /// The body text is two-paragraph: "Q: <question>\n\nA: <answer>"
    /// — the same shape Posey's notes already have for surrounding-
    /// context captures. When persistence fails (transient SQLite
    /// issue, no DB) the caller surfaces the error; we don't log.
    func saveAssistantTurnToNotes(_ message: AskPoseyMessage) -> Bool {
        guard message.role == .assistant else { return false }
        guard let db = databaseManager else { return false }

        // Find the user turn that preceded this assistant message —
        // that's the question the user asked. Walk backwards through
        // messages from this index.
        guard let assistantIndex = messages.firstIndex(where: { $0.id == message.id }) else {
            return false
        }
        var question: String?
        if assistantIndex > 0 {
            for i in stride(from: assistantIndex - 1, through: 0, by: -1) {
                if messages[i].role == .user {
                    question = messages[i].content
                    break
                }
            }
        }

        // Anchor: prefer the conversation's anchor offset, then the
        // first injected chunk's start, then 0. End offset matches
        // start (a point anchor — same shape playback-position notes use).
        let startOffset: Int
        if let anchor {
            startOffset = max(0, anchor.plainTextOffset)
        } else if let firstChunk = message.chunksInjected.first {
            startOffset = max(0, firstChunk.startOffset)
        } else {
            startOffset = 0
        }
        let endOffset = startOffset

        let body: String
        if let q = question, !q.isEmpty {
            body = "Q: \(q)\n\nA: \(message.content)"
        } else {
            body = message.content
        }

        let note = Note(
            id: UUID(),
            documentID: documentID,
            createdAt: Date(),
            updatedAt: Date(),
            kind: .note,
            startOffset: startOffset,
            endOffset: endOffset,
            body: body
        )
        do {
            try db.insertNote(note)
            return true
        } catch {
            NSLog("AskPosey saveAssistantTurnToNotes failed: \(error)")
            return false
        }
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
            // Load the most recent summary row (M6 fills these; M5
            // always returns nil). Capture both the text and the
            // watermark so the auto-summarizer trigger knows where
            // the existing summary leaves off.
            if let summary = try db.askPoseyLatestSummary(for: documentID) {
                cachedConversationSummary = summary.content
                summaryCoveredThrough = summary.summaryOfTurnsThrough
            }

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


// ========== BLOCK 02B: RAG RETRIEVAL (M6) - START ==========
private extension AskPoseyChatViewModel {

    /// Retrieve top-K document chunks most similar to the user's
    /// question. M6: lights up the empty-array slot M5's prompt
    /// builder shipped accommodating. The `DocumentEmbeddingIndex`
    /// is the cosine-search engine M2 built; we just translate its
    /// results into the prompt builder's `RetrievedChunk` shape and
    /// drop chunks too similar to content already in the prompt.
    ///
    /// Cosine dedup against the anchor + recent verbatim STM means
    /// the model never sees the same passage twice — once as anchor
    /// quote and once as a "retrieved" chunk. Threshold is
    /// `ragDedupThreshold` (0.85), matching Hal's default.
    func retrieveRAGChunks(for question: String) -> [RetrievedChunk] {
        guard let index = embeddingIndex else { return [] }

        let results: [DocumentEmbeddingSearchResult]
        do {
            // M8 entity-boosted ranking — re-ranks by cosine + Jaccard
            // entity overlap so chunks that share named entities with
            // the question (people, places, organizations) get a
            // relevance bump. Falls back to pure cosine when neither
            // side has named entities.
            results = try index.searchWithEntityBoost(documentID: documentID, query: question, limit: ragTopK)
        } catch {
            // Index unavailable / query failed → fall back to no RAG.
            // Better to ship a less-grounded answer than to error out
            // the whole send.
            NSLog("AskPosey RAG search failed: \(error)")
            return []
        }
        guard !results.isEmpty else { return [] }

        // Reference text for cosine dedup: anchor + recent STM. We
        // don't include the conversation summary here because the
        // summary is by definition compressed — its embedding doesn't
        // accurately reflect the verbatim content a chunk might
        // duplicate. Skip dedup entirely if the index can't embed the
        // reference (an offline-language fallback edge case).
        let referenceText = referenceTextForDedup()
        let referenceVector = referenceText.isEmpty
            ? [Double]()
            : index.embed(referenceText, forDocument: documentID)

        // Translate to RetrievedChunk and dedup.
        var translated: [RetrievedChunk] = []
        for result in results {
            if !referenceVector.isEmpty {
                let chunkVector = result.chunk.embedding
                let sim = DocumentEmbeddingIndex.cosineSimilarity(referenceVector, chunkVector)
                if sim >= ragDedupThreshold {
                    // Skip — too similar to what the prompt already
                    // contains verbatim. Diagnostic logs only; no
                    // user-facing surface in M6.
                    continue
                }
            }
            translated.append(RetrievedChunk(
                chunkID: result.chunk.chunkIndex,
                startOffset: result.chunk.startOffset,
                text: result.chunk.text,
                relevance: result.similarity
            ))
        }
        return translated
    }

    /// Concatenate anchor + recent verbatim STM into a single string
    /// the embedding model can embed for dedup comparison. Empty
    /// when there's nothing to dedup against.
    func referenceTextForDedup() -> String {
        var parts: [String] = []
        if let anchor, !anchor.trimmedDisplayText.isEmpty {
            parts.append(anchor.trimmedDisplayText)
        }
        for message in historyForPromptBuilder.suffix(keepVerbatimRecent) {
            parts.append(message.content)
        }
        return parts.joined(separator: "\n\n")
    }
}
// ========== BLOCK 02B: RAG RETRIEVAL (M6) - END ==========


// ========== BLOCK 02C: AUTO-SUMMARIZATION (M6 hard blocker) - START ==========
private extension AskPoseyChatViewModel {

    /// After a turn finalizes, decide whether to summarize older turns
    /// and kick the work off in the background. The next send() awaits
    /// `summarizationTask` before building its prompt so the summary
    /// is current.
    ///
    /// Trigger condition: total non-summary turn count exceeds
    /// `summarizeWhenTurnsExceed` AND there's at least one turn newer
    /// than `summaryCoveredThrough` that's older than the
    /// `keepVerbatimRecent` window. In English: "we have enough turns
    /// to bother summarizing, and the older half hasn't been folded
    /// into the existing summary yet."
    func summarizeOlderTurnsIfNeeded() {
        guard summarizer != nil, databaseManager != nil else { return }
        guard summarizationTask == nil else { return }

        let total = historyForPromptBuilder.count
        guard total > summarizeWhenTurnsExceed else { return }

        // Identify the older slice that needs summarizing — everything
        // except the most-recent N kept verbatim.
        let olderEndIndex = max(0, total - keepVerbatimRecent)
        let olderTurns = Array(historyForPromptBuilder.prefix(olderEndIndex))
        guard !olderTurns.isEmpty else { return }

        // Skip if the existing summary already covers this watermark.
        // `summaryCoveredThrough` is in "non-summary turn count" units
        // — same dimension as `olderEndIndex`.
        guard olderEndIndex > summaryCoveredThrough else { return }

        // Snapshot the data the task needs so it doesn't capture
        // mutating self state.
        let toSummarize = olderTurns
        let watermark = olderEndIndex
        guard let summarizer else { return }
        guard let db = databaseManager else { return }
        let docID = documentID

        summarizationTask = Task { @MainActor [weak self] in
            defer { self?.summarizationTask = nil }
            do {
                if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                    let summary = try await summarizer.summarizeConversation(turns: toSummarize)
                    guard !summary.isEmpty else { return }

                    // Persist as is_summary = 1 row with the new
                    // watermark.
                    let summaryTurn = StoredAskPoseyTurn(
                        id: UUID().uuidString,
                        documentID: docID,
                        timestamp: Date(),
                        role: "assistant",
                        content: summary,
                        invocation: "passage",
                        anchorOffset: nil,
                        intent: nil,
                        chunksInjectedJSON: "[]",
                        fullPromptForLogging: nil,
                        summaryOfTurnsThrough: watermark,
                        isSummary: true
                    )
                    try db.appendAskPoseyTurn(summaryTurn)

                    // Update view model caches. The next send() picks
                    // up the new summary via `cachedConversationSummary`.
                    self?.cachedConversationSummary = summary
                    self?.summaryCoveredThrough = watermark
                }
            } catch {
                // Summarization failure is non-fatal — the next turn
                // ships without an updated summary; the older verbatim
                // turns silently roll out of the STM window. Logged
                // for the local-API tuning loop.
                NSLog("AskPosey summarization failed: \(error)")
            }
        }
    }
}
// ========== BLOCK 02C: AUTO-SUMMARIZATION (M6 hard blocker) - END ==========


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

                // Wait for any in-flight summarization from the
                // previous turn to land BEFORE building this prompt
                // so the conversation summary is current.
                if let task = self.summarizationTask {
                    await task.value
                }

                // M6 RAG retrieval — top-K chunks for this question,
                // dedup'd against anchor + recent STM. M5 used [];
                // M6 lights up the slot the prompt builder already
                // accommodates.
                //
                // M7 .search routing: when the classifier picked
                // `.search` AND we have a live navigator, divert to
                // the @Generable navigation-card path BEFORE building
                // the prose prompt. The card response replaces the
                // prose response entirely — assistant message
                // content is the prose lead-in ("Here are sections
                // that match…") and `navigationCards` carries the
                // tappable destinations. We retrieve a wider chunk
                // set for navigation candidates because the model
                // picks the best 3-6 from the list.
                let chunks: [RetrievedChunk]
                if intent == .search {
                    chunks = self.retrieveRAGChunks(for: trimmedInput)
                    if let navigator = self.navigator, !chunks.isEmpty {
                        await self.runSearchPipeline(
                            question: trimmedInput,
                            candidates: chunks,
                            placeholderID: placeholderID,
                            navigator: navigator
                        )
                        return
                    }
                    // No navigator OR no candidates: fall through to
                    // the prose path. With chunks=[] (M5 behaviour
                    // for .search) the prose response degrades to
                    // anchor + STM only, which is honest about
                    // not-grounded.
                } else {
                    chunks = self.retrieveRAGChunks(for: trimmedInput)
                }

                // Call 2: prompt build + stream.
                let inputs = AskPoseyPromptInputs(
                    intent: intent,
                    anchor: self.anchor,
                    surroundingContext: self.surroundingContext(for: intent),
                    conversationHistory: self.historyForPromptBuilder,
                    conversationSummary: self.cachedConversationSummary,
                    documentChunks: chunks,
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
    /// exchange. Triggers M6 auto-summarization in the background if
    /// the conversation has grown past the verbatim-STM window.
    func finalizeAssistantTurn(
        metadata: AskPoseyResponseMetadata,
        placeholderID: UUID,
        intent: AskPoseyIntent
    ) {
        if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
            messages[index].content = metadata.finalText
            messages[index].isStreaming = false
            messages[index].chunksInjected = metadata.chunksInjected
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

        // M6 hard-blocker: kick off auto-summarization in the
        // background if the conversation has outgrown the verbatim
        // STM window. Won't fire on most M5/M6-typical exchanges
        // (3-4 turn passages); fires when conversations grow long.
        // The next send() awaits in-flight summarization before
        // building its prompt.
        summarizeOlderTurnsIfNeeded()
    }

    /// M7 navigation-cards execution path — runs when intent is
    /// `.search` and we have a live navigator + candidate chunks.
    /// Replaces the streaming placeholder with a card-bearing
    /// assistant turn; persists exactly like the prose path so the
    /// returning conversation surfaces the same cards on re-open.
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func runSearchPipeline(
        question: String,
        candidates: [RetrievedChunk],
        placeholderID: UUID,
        navigator: AskPoseyNavigating
    ) async {
        do {
            let cards = try await navigator.generateNavigationCards(
                question: question,
                candidates: candidates
            )
            // Lead-in prose for the assistant bubble — keeps the chat
            // shape consistent. The cards do the heavy lifting under it.
            let leadIn: String
            if cards.isEmpty {
                leadIn = "I didn't find a clear destination for that question in this document."
            } else {
                leadIn = "Here are sections that match — tap any one to jump:"
            }
            if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
                messages[index].content = leadIn
                messages[index].isStreaming = false
                messages[index].chunksInjected = candidates
                messages[index].navigationCards = cards
                historyForPromptBuilder.append(messages[index])
            }
            isResponding = false

            // Persist with the same shape as the prose path. The
            // chunks_injected JSON column carries the cards (we
            // serialize them) so re-open re-renders the destinations.
            // The cards extend the existing JSON column rather than
            // adding another to keep schema additions minimal.
            let combinedJSON: String = {
                guard let data = try? JSONEncoder().encode(cards),
                      let s = String(data: data, encoding: .utf8) else {
                    return "[]"
                }
                return s
            }()
            persistTurn(
                role: .assistant,
                content: leadIn,
                intent: .search,
                chunksInjected: candidates,
                fullPromptForLogging: AskPoseyNavigationPrompts.body(
                    question: question,
                    candidates: candidates
                )
            )
            _ = combinedJSON  // reserved for the future "store cards in their own column" cleanup
            summarizeOlderTurnsIfNeeded()
        } catch is CancellationError {
            removeMessage(id: placeholderID)
            isResponding = false
        } catch {
            handleSendError(error, placeholderID: placeholderID, intent: .search)
        }
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
