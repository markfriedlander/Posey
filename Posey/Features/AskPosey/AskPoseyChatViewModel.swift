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

    /// Storage id of the anchor marker the view should scroll to on
    /// initial appear. Defaults to the most recently appended anchor
    /// in `messages` (the one created for this invocation), but the
    /// Notes-tap-conversation path can override via the init param so
    /// the sheet opens scrolled to a previous anchor in the thread.
    ///
    /// Published so the view's onAppear can read it after history
    /// load completes (the actual anchor row may not be appended
    /// until then).
    @Published private(set) var initialScrollAnchorStorageID: String? = nil

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

    /// Last classified intent (from Call 1 of the most recent send).
    /// Surface for the local-API tuning loop so /ask responses can
    /// report what the classifier picked. The intent on the persisted
    /// turn row is the canonical source; this is the in-memory mirror
    /// for the API path that doesn't re-query SQLite.
    @Published private(set) var lastIntent: AskPoseyIntent?

    /// The passage that was active at sheet invocation. Constant
    /// for the lifetime of this view model — re-opening the sheet
    /// creates a new view model with a new anchor.
    let anchor: AskPoseyAnchor?

    /// 2026-05-04 — Initial-action plumbing for the chrome-level
    /// quick-actions menu. When the chrome Ask Posey button is a
    /// menu (Explain / Define / Find related / Ask), the chosen
    /// action's templated question travels through here so the
    /// sheet opens already in flight. Consumed once, then cleared.
    var pendingInitialQuery: String?
    var pendingInitialQueryShouldAutoSubmit: Bool

    /// True when AFM metadata extraction flagged the document as
    /// non-English. Read on init from `documents.metadata_detected_non_english`.
    /// The view surfaces a gentle "still studying [language]" notice
    /// when this is true. Defaults to false on docs that haven't been
    /// extracted yet (no notice shown until we know).
    @Published var documentDetectedNonEnglish: Bool = false

    /// Document the conversation is anchored to. Used for both
    /// SQLite reads (prior history) and writes (every turn appends).
    let documentID: UUID

    /// Document title — surfaced to the user in the sheet's nav bar
    /// so document-scoped opens don't feel orphaned (just "Ask Posey"
    /// with no doc context). Optional so older test/preview call
    /// sites that didn't pass a title keep working with the
    /// "Ask Posey" fallback the view applies.
    let documentTitle: String?

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

    /// 2026-05-12 — Closure the View sets at construction time so the
    /// VM can ask "is this document still being indexed right now?"
    /// when deciding what message to surface for a weak-retrieval
    /// shortcut. Returning true triggers a "Still learning this
    /// document — try again in a moment" message instead of the
    /// canned "I'm not finding a strong answer" refusal. View injects
    /// a closure that calls IndexingTracker.isEnhancing(_:).
    var isStillIndexingChecker: ((UUID) -> Bool)?

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

    /// Task 4 #10 — observer for cross-VM persistence notifications.
    /// When the local-API `/ask` path runs while the sheet is open, a
    /// separate headless VM persists turns to SQLite; this VM (the
    /// visible one) listens and re-runs `loadHistory()` so the open
    /// sheet updates without dismiss/reopen. Released in `deinit`.
    private var conversationUpdateObserver: NSObjectProtocol?

    /// Cached recent-conversation history sized for the prompt
    /// builder's STM window. Updated on every successful send so the
    /// next turn includes the just-completed exchange.
    private var historyForPromptBuilder: [AskPoseyMessage] = []

    /// Task 4 #4 (b) — anchor row deferred until first user send.
    /// `appendCurrentInvocationAnchorMarkerIfNeeded` builds the
    /// in-memory anchor and stashes its DB row here. The first
    /// `persistTurn(role: .user, ...)` flushes it; if the user
    /// dismisses without sending, this stays nil and no orphan
    /// anchor lands in the persisted thread.
    private var pendingAnchorPersist: StoredAskPoseyTurn?

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

    /// Task 4 #9 — when true, the prompt builder receives per-pair
    /// summaries (tiered + embedding-verified) instead of the
    /// verbatim user-questions-only STM rendering. Default false:
    /// production UI keeps the existing verbatim mode unchanged.
    /// The local-API `/ask` endpoint flips this on per-call via the
    /// `summarizationMode: "pairwise"` body field for testing.
    let useSummarizedSTM: Bool

    /// Lazily-constructed pairwise summarizer. Created only on the
    /// first turn that needs it (when `useSummarizedSTM == true` and
    /// at least one prior Q/A pair exists). Owns its own cache so
    /// stable older pairs don't re-summarize on every send.
    var pairwiseSummarizer: AskPoseyPairwiseSummarizer?

    /// Per-turn stats from the most recent pairwise summarization
    /// pass. Surface via metadata so the local-API `/ask` response
    /// can include cost/quality numbers in the testing loop. nil
    /// when pairwise mode wasn't engaged this turn.
    @Published private(set) var lastPairwiseStats: AskPoseyPairwiseStats?

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

    /// Captured reading offset at invocation. Always set for fresh
    /// invocations regardless of scope — passage scope mirrors
    /// `anchor.plainTextOffset`, document scope captures the active
    /// sentence offset so the doc-scope anchor is still tappable to
    /// jump back to where the question was asked. Nil only for the
    /// Notes-tap-conversation navigation path, where we're NOT
    /// creating a new anchor.
    private let invocationReadingOffset: Int?

    /// 2026-05-04 — `initialQuery` + `autoSubmitInitialQuery` allow
    /// the chrome-level Ask Posey menu to open the sheet AND start
    /// a templated action (e.g. "Explain this passage") in one tap.
    /// When `autoSubmitInitialQuery` is true, the question fires
    /// automatically once history loads. When false, the text just
    /// pre-fills the composer and the user types/sends the rest
    /// (used for "Define a term" — prefills "Define " for the user
    /// to complete).
    init(
        documentID: UUID,
        documentPlainText: String,
        documentTitle: String? = nil,
        anchor: AskPoseyAnchor?,
        invocationReadingOffset: Int? = nil,
        initialScrollAnchorStorageID: String? = nil,
        classifier: AskPoseyClassifying? = nil,
        streamer: AskPoseyStreaming? = nil,
        summarizer: AskPoseySummarizing? = nil,
        navigator: AskPoseyNavigating? = nil,
        databaseManager: DatabaseManager? = nil,
        budget: AskPoseyTokenBudget = .afmDefault,
        useSummarizedSTM: Bool = false,
        initialQuery: String? = nil,
        autoSubmitInitialQuery: Bool = false
    ) {
        self.useSummarizedSTM = useSummarizedSTM
        self.documentID = documentID
        self.documentPlainText = documentPlainText
        self.documentTitle = documentTitle
        self.anchor = anchor
        self.pendingInitialQuery = initialQuery
        self.pendingInitialQueryShouldAutoSubmit = autoSubmitInitialQuery
        // Default invocation offset: derive from passage anchor when
        // available so passage-scoped callers don't have to pass it
        // twice. Document-scoped callers must pass it explicitly.
        self.invocationReadingOffset = invocationReadingOffset ?? anchor?.plainTextOffset
        self.initialScrollAnchorStorageID = initialScrollAnchorStorageID
        self.classifier = classifier
        self.streamer = streamer
        self.summarizer = summarizer
        self.navigator = navigator
        self.databaseManager = databaseManager
        // Task 4 #6 — pick the long-document budget when the
        // document is over the long-doc threshold. The chunks
        // were indexed at 2000 chars apiece, so the RAG budget
        // needs to be doubled (2800 vs 1400) to fit 3-4 chunks
        // per turn instead of just 1. Caller-supplied budget
        // wins (tests pass explicit budgets); only the default
        // gets the adaptive swap.
        if budget == .afmDefault,
           documentPlainText.count >= DocumentEmbeddingIndexConfiguration.longDocumentThresholdChars {
            self.budget = .forLongDocument()
        } else {
            self.budget = budget
        }

        // Read non-English flag from extracted metadata so the UI
        // can surface a "still studying [language]" notice. Silent
        // failure is fine — if metadata isn't extracted yet the
        // flag stays false and no notice shows; once extraction
        // completes on the next sheet open the notice appears.
        if let db = databaseManager,
           let meta = try? db.documentMetadata(for: documentID) {
            self.documentDetectedNonEnglish = meta.detectedNonEnglish
        }

        // Kick off history load. UI shows isLoadingHistory until
        // this completes; on a fresh-document open it returns
        // immediately so no flash.
        self.historyLoadTask = Task { @MainActor [weak self] in
            await self?.loadHistory()
        }

        // Task 4 #10 — observe cross-VM persistence so local-API /ask
        // calls that run while the sheet is open update the visible
        // thread without requiring dismiss/reopen. Self-originated
        // posts (this VM's own persistTurn) are ignored via the
        // originator id in userInfo.
        let myID = self.id
        let myDoc = documentID
        conversationUpdateObserver = NotificationCenter.default.addObserver(
            forName: .askPoseyConversationDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let info = note.userInfo ?? [:]
            guard let docID = info["documentID"] as? UUID, docID == myDoc else { return }
            if let originator = info["originator"] as? UUID, originator == myID { return }
            Task { @MainActor [weak self] in
                await self?.loadHistory()
            }
        }
    }

    deinit {
        // Direct .cancel() on the captured task references is enough.
        // Not capturing self into a closure because deinit is sync
        // and the cancellation propagates through whatever is
        // awaiting the task.
        inFlightTask?.cancel()
        historyLoadTask?.cancel()
        if let conversationUpdateObserver {
            NotificationCenter.default.removeObserver(conversationUpdateObserver)
        }
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
            dbgLog("AskPosey saveAssistantTurnToNotes failed: \(error)")
            return false
        }
    }
}
// ========== BLOCK 01: VIEW MODEL CORE - END ==========


// ========== BLOCK 02: HISTORY LOADING + PERSISTENCE - START ==========
// 2026-05-03: this extension was `private`; relaxed to `internal` so
// `@testable import Posey` tests can call `flushPendingAnchorPersistIfAny()`
// directly. Task 4 #4 deferred anchor persist to the first user send,
// which broke `testMultipleInvocationsAccumulateAnchors` — that test
// now flushes the pending anchor explicitly to simulate "user sent".
extension AskPoseyChatViewModel {

    /// Load prior conversation turns for `documentID` from SQLite.
    /// Runs on init; idempotent if called twice (overwrites
    /// `messages` with whatever's currently in the DB).
    func loadHistory() async {
        defer { isLoadingHistory = false }

        guard let db = databaseManager else {
            // Preview/test paths without a DB. Still append the
            // in-memory anchor marker for the current invocation so
            // the sheet renders the same shape as production.
            appendCurrentInvocationAnchorMarkerIfNeeded(persist: false)
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

            // Load every non-summary row (anchor + user + assistant)
            // so the thread renders chronologically with anchor
            // markers inline. Prompt builder gets a separately-
            // filtered slice so anchor markers don't pollute STM.
            let stored = try db.askPoseyTurns(for: documentID, limit: historyFetchLimit)
            let translated = stored.compactMap(translateStoredTurn)
            messages = translated
            historyForPromptBuilder = translated.filter {
                $0.role == .user || $0.role == .assistant
            }
        } catch {
            // History load failure is non-fatal — we just start
            // with an empty conversation rather than blocking the
            // sheet. Surface the error so it shows up in logs but
            // don't gate the UI on it.
            dbgLog("AskPosey history load failed: \(error)")
        }

        // Append the anchor marker for THIS invocation (unless we're
        // navigating to an existing one via Notes-tap-conversation).
        // Persist to SQLite so future opens see the full thread.
        appendCurrentInvocationAnchorMarkerIfNeeded(persist: true)
    }

    /// Build + append an anchor marker for the current invocation,
    /// with two suppression rules per Mark's Task 4 #4 directive:
    ///
    /// (a) **Reuse identical anchors.** If the most recent stored
    ///     anchor for this document has the same `(offset, scope)`
    ///     tuple, reuse its `storageID` instead of writing a
    ///     duplicate. The Ask Posey sheet just scrolls to the
    ///     existing anchor in the thread. Surfaced when Mark tapped
    ///     the bottom-bar Ask Posey glyph twice from the same
    ///     position and saw two identical "Demystifying the
    ///     Machine…" anchor cards back-to-back.
    ///
    /// (b) **Defer DB persistence to first send.** The in-memory
    ///     anchor still appears in the sheet immediately on open
    ///     (good UX — the user sees what they're asking about). But
    ///     the DB row gets written only when the user actually
    ///     sends their first question. If the user dismisses
    ///     without sending, no orphan anchor is left in the
    ///     persisted thread. The first call to `persistTurn(role:
    ///     .user, ...)` flushes the pending anchor first.
    ///
    /// Skipped entirely when the caller passed an
    /// `initialScrollAnchorStorageID` — that signals navigation to
    /// an existing anchor row, not a fresh invocation.
    func appendCurrentInvocationAnchorMarkerIfNeeded(persist: Bool) {
        guard initialScrollAnchorStorageID == nil else { return }

        // Determine display text + scope for the marker.
        let scope: String = (anchor != nil) ? "passage" : "document"
        let displayText: String
        if let anchor, !anchor.trimmedDisplayText.isEmpty {
            displayText = anchor.text
        } else if let title = documentTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty {
            displayText = title
        } else {
            displayText = "this document"
        }
        let offset = invocationReadingOffset ?? 0

        // (a) Look up the most recent stored anchor. If same
        //     (offset, scope) tuple, reuse — no new row, no in-
        //     memory dupe (the existing one is already loaded into
        //     `messages` by `loadHistory`).
        if persist, let db = databaseManager,
           let mostRecent = (try? db.askPoseyAnchorRows(for: documentID))?.first,
           mostRecent.invocation == scope,
           mostRecent.anchorOffset == offset {
            initialScrollAnchorStorageID = mostRecent.id
            dbgLog("AskPosey: reusing anchor %@ (same offset+scope as most recent)", mostRecent.id as NSString)
            return
        }

        // Build the in-memory marker — always shown in the sheet so
        // the user sees what they're asking about.
        let storageID = UUID().uuidString
        let marker = AskPoseyMessage(
            role: .anchor,
            content: displayText,
            timestamp: Date(),
            anchorOffset: offset,
            anchorScope: scope,
            storageID: storageID
        )
        messages.append(marker)
        initialScrollAnchorStorageID = storageID

        // (b) Defer DB persistence — stash the row to write at first
        //     user send. If the user dismisses without sending, the
        //     row never lands and no orphan anchor pollutes the
        //     thread on the next sheet open.
        guard persist, databaseManager != nil else { return }
        pendingAnchorPersist = StoredAskPoseyTurn(
            id: storageID,
            documentID: documentID,
            timestamp: marker.timestamp,
            role: AskPoseyMessage.Role.anchor.rawValue,
            content: displayText,
            invocation: scope,
            anchorOffset: offset,
            intent: nil,
            chunksInjectedJSON: "[]",
            fullPromptForLogging: nil,
            summaryOfTurnsThrough: 0,
            isSummary: false
        )
    }

    /// Flush the deferred anchor persist (if any). Called from
    /// `persistTurn` immediately before the user-turn write.
    /// (`pendingAnchorPersist` itself lives on the main class body
    /// so it doesn't run afoul of the no-stored-properties-in-
    /// extensions rule.)
    func flushPendingAnchorPersistIfAny() {
        guard let pending = pendingAnchorPersist,
              let db = databaseManager else { return }
        do {
            try db.appendAskPoseyTurn(pending)
            dbgLog("AskPosey: persisted deferred anchor %@", pending.id as NSString)
            postConversationDidUpdate()
        } catch {
            dbgLog("AskPosey deferred anchor persist failed: \(error)")
        }
        pendingAnchorPersist = nil
    }

    /// Task 4 #10 — broadcast that this VM persisted a turn so any
    /// other VM observing the same documentID can refresh its
    /// in-memory thread. Originator id is included so the posting
    /// VM ignores its own broadcast.
    func postConversationDidUpdate() {
        NotificationCenter.default.post(
            name: .askPoseyConversationDidUpdate,
            object: nil,
            userInfo: [
                "documentID": documentID,
                "originator": id
            ]
        )
    }

    /// Translate a stored row into the in-memory message type. Returns
    /// nil for rows whose role string doesn't match (defensive — we
    /// haven't shipped non-user/assistant/anchor rows yet but defensive
    /// decoding is cheap).
    func translateStoredTurn(_ stored: StoredAskPoseyTurn) -> AskPoseyMessage? {
        guard let role = AskPoseyMessage.Role(rawValue: stored.role) else {
            return nil
        }
        // Task 4 #1 — auto-summary rows are persisted as
        // role="assistant" with `is_summary = 1` so the prompt
        // builder can inject them into future calls. They are NOT
        // user-visible turns — they're third-person narrations
        // ("Posey explained the Two-Round Response Process…")
        // generated by `summarizeConversation` to compress dropped
        // STM. The visible thread must filter them out; without
        // this guard they appear as bubbles next to the real
        // exchanges. Surfaced in Task 3 conversation #1 (TXT) DB
        // dump where two such rows showed up between user turns.
        if stored.isSummary { return nil }
        // Reconstruct a stable UUID from the storage id when it's
        // UUID-shaped. Older rows without UUID-shaped ids fall back
        // to a fresh UUID — losing the ability to cross-reference
        // them but preserving SwiftUI Identifiable correctness.
        let messageID = UUID(uuidString: stored.id) ?? UUID()
        let isAnchor = (role == .anchor)
        // Restore the source chunks from the persisted JSON so the
        // sources strip / inline citations re-appear when the sheet
        // re-opens. Without this, every assistant reply would lose
        // its sources after the user dismisses + re-opens the sheet
        // (or after a tap-jump dismisses + re-opens via the Notes
        // entry — Issue 2 in Mark's Task 2 list).
        let restoredChunks: [RetrievedChunk] = {
            guard role == .assistant,
                  let data = stored.chunksInjectedJSON.data(using: .utf8),
                  let chunks = try? JSONDecoder().decode([RetrievedChunk].self, from: data)
            else { return [] }
            return chunks
        }()
        return AskPoseyMessage(
            id: messageID,
            role: role,
            content: stored.content,
            isStreaming: false,
            timestamp: stored.timestamp,
            chunksInjected: restoredChunks,
            anchorOffset: isAnchor ? stored.anchorOffset : nil,
            anchorScope: isAnchor ? stored.invocation : nil,
            storageID: stored.id
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

        // Task 4 #4 (b) — flush the deferred anchor (if any) BEFORE
        // the user turn lands. Guarantees the anchor row precedes
        // the first user/assistant pair in the persisted thread,
        // and never lands when the user dismisses without sending.
        if role == .user {
            flushPendingAnchorPersistIfAny()
        }

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
            postConversationDidUpdate()
        } catch {
            dbgLog("AskPosey turn persist failed: \(error)")
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
    ///
    /// **2026-05-02 fix — front-matter injection for ALL invocations
    /// (was: doc-scope only).** Real Q&A on a sample document
    /// ("Who are the authors?" on the AI Book Collaboration Project)
    /// revealed a systematic cosine-retrieval miss: meta-questions
    /// about a document ("who wrote it", "what is it about", "what's
    /// the abstract") rarely surface the title-page / front-matter
    /// content because the question's vocabulary
    /// ("authors / writers / abstract") doesn't share a semantic
    /// neighbourhood with how front matter is typically written
    /// ("by X with collaborators Y, Z; A Collaborative Exploration of…").
    /// The 2026-05-02 (later) threshold-tuning battery hit the same
    /// failure on a PASSAGE-scoped invocation — the user is always
    /// allowed to ask "who wrote this?" while sitting on any
    /// passage; gating front-matter on `anchor == nil` left those
    /// questions ungrounded. We now always prepend the document's
    /// first 4 chunks as "front matter" candidates with relevance
    /// 1.0 — the budget enforcer keeps them by virtue of being
    /// top-of-list, and meta-questions get reliable grounding
    /// regardless of scope. Cost is small (~1800 chars).
    func retrieveRAGChunks(for question: String) -> [RetrievedChunk] {
        guard let index = embeddingIndex else { return [] }

        let results: [DocumentEmbeddingSearchResult]
        do {
            // 2026-05-04 — Hybrid retrieval (cosine + lexical as
            // peers). Replaces the entity-boost-only ranking. NLEmbedding
            // can't reliably surface IR queries on its own; lexical
            // scoring catches verbatim-phrase matches (and most "find
            // information about X" queries) that cosine misses. Entity-
            // index hits still get folded in. See DocumentEmbeddingIndex
            // .searchHybrid for the algorithm and the RAG audit findings
            // in DECISIONS.md (2026-05-04).
            results = try index.searchHybrid(documentID: documentID, query: question, limit: ragTopK)
        } catch {
            // Index unavailable / query failed → fall back to no RAG.
            // Better to ship a less-grounded answer than to error out
            // the whole send.
            dbgLog("AskPosey RAG search failed: \(error)")
            return []
        }

        // 2026-05-04 — Skip front-matter prepend when there's an
        // anchor. Real-conversation testing showed front-matter
        // chunks (title page / contributor list / prologue work
        // items) competing with the user's actual passage focus —
        // for "what's next on THIS" questions, AFM was answering
        // from the prologue's "Run clean memory test" content
        // instead of the immediate-following sentence in the
        // surrounding context. The user is asking about a specific
        // passage; the document's title-page metadata is noise here.
        // Document-scope queries (no anchor) still get front matter
        // prepended — that's where it actually helps ("who wrote
        // this", "what is this about").
        let skipFrontMatter = anchor != nil

        // Front-matter injection — runs for EVERY invocation
        // (passage or document scope). Always prepend the document's
        // first 4 chunks so the prompt sees the title page + table
        // of contents + contributor list. Two chunks (~900 chars at
        // the default 450 char chunk size) covered only the abstract
        // on real-world tests; 4 (~1800 chars) reliably reaches
        // contributor names listed below the abstract. Deduplicates
        // against any cosine match for the same chunk ID.
        // Long documents (1.6M-char books) use 2000-char chunks
        // (Task 4 #6 A) which means each front-matter chunk costs
        // ~800 tokens. 4 of them × 800 = 3200 tokens — that's more
        // than the entire RAG budget for long-doc mode and crowds
        // out the entity-index hits that actually answer
        // mid-book questions. Drop to 1 front-matter chunk for
        // long docs (titles + author + abstract still fit in
        // 2000 chars at the start of the document); short docs
        // keep all 4.
        let frontMatterLimit: Int = skipFrontMatter ? 0 : (documentPlainText.count
            >= DocumentEmbeddingIndexConfiguration.longDocumentThresholdChars
            ? 1 : 4)
        // 2026-05-05 — Front-matter relevance lowered from 1.0 to 0.30.
        // The diagnostic harness caught a BUDGET MISS where the answer
        // chunk for "What is an example of an advantage of using ADR?"
        // ranked at cosine 0.66 in retrieval but got dropped because 4
        // front-matter chunks (artificially relevance=1.0) ate the RAG
        // token budget first. Front matter is a fallback for when
        // retrieval is weak — it shouldn't crowd out high-confidence
        // organic hits. With 0.30, front-matter beats only-weak
        // retrieval (<0.30) and still gets included for "who wrote
        // this" / "what's this about" questions where ALL organic
        // chunks score low. Strong organic retrieval wins.
        let frontMatterRelevance = 0.30
        var frontMatter: [RetrievedChunk] = []
        if !skipFrontMatter, let db = databaseManager {
            let storedFront = (try? db.frontMatterChunks(for: documentID, limit: frontMatterLimit)) ?? []
            for stored in storedFront {
                let alreadyPresent = results.contains { $0.chunk.chunkIndex == stored.chunkIndex }
                if alreadyPresent { continue }
                frontMatter.append(RetrievedChunk(
                    chunkID: stored.chunkIndex,
                    startOffset: stored.startOffset,
                    // Strip Wayback Machine print-header artifacts at
                    // chunk-fetch time so existing imports get the
                    // benefit without re-indexing. The embedding
                    // vector still scores against un-stripped text
                    // (cosine retrieval was good enough to surface
                    // this chunk for "what's this paper about");
                    // AFM gets the cleaned text so it doesn't choke
                    // on dozens of repeated URLs.
                    text: TextNormalizer.stripWaybackPrintHeaders(stored.text),
                    relevance: frontMatterRelevance
                ))
            }
        }

        guard !results.isEmpty || !frontMatter.isEmpty else { return [] }

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
                text: TextNormalizer.stripWaybackPrintHeaders(result.chunk.text),
                relevance: result.similarity
            ))
        }
        // 2026-05-04 — Verbatim phrase fallback REMOVED. The hybrid
        // retrieval (cosine + lexical, see searchHybrid) now subsumes
        // it as a first-class ranking signal — chunks containing
        // verbatim query phrases get a high lexical score and rank
        // alongside (often above) cosine matches. The fallback is
        // no longer needed.
        //
        // 2026-05-05 — Sort the merged list (front-matter + organic
        // retrieval) by relevance descending before returning, so the
        // RAG budget enforcer in renderRAGBlock takes them in true
        // relevance order. Without this, front-matter-first array
        // order combined with the budget enforcer's "drop from the
        // tail" behavior caused high-confidence answer chunks to be
        // dropped while low-confidence front-matter ate the budget.
        // Stable sort: chunks with equal relevance retain their
        // original ordering (front-matter first, then organic).
        let merged = frontMatter + translated
        // 2026-05-05 — Drop chunks with relevance < 0.40 from the AFM
        // input. Mark caught a low-confidence (empty-circle) pill in
        // a sources strip — the chunk had been passed to AFM and AFM
        // cited it, but the relevance was below our "weak grounding"
        // threshold. Filter here so AFM never sees sub-40% material
        // and can't cite it. Synthetic metadata chunks (startOffset
        // < 0) are exempt — their relevance is artificially set and
        // they're curated content, not retrieval results.
        let final = merged
            .filter { $0.startOffset < 0 || $0.relevance >= 0.40 }
            .sorted { $0.relevance > $1.relevance }
        // 2026-05-14 (B-tier diagnostic) — Log retrieval pipeline
        // stats so the antenna's LOGS verb can show why a question
        // wound up with `chunksInjected: 0`. results = searchHybrid
        // output; frontMatter = unconditional first-N chunks;
        // translated = post-conversation-dedup organic chunks;
        // final = post-relevance-filter merged list.
        dbgLog("retrieveRAGChunks: results=%d frontMatter=%d translated=%d final=%d",
               results.count, frontMatter.count, translated.count, final.count)
        return final
    }

    /// 2026-05-04 — DEPRECATED. Kept temporarily so any test code
    /// or future restoration has a reference; not called by the
    /// runtime path anymore. Hybrid retrieval (DocumentEmbeddingIndex
    /// .searchHybrid) now does this as a first-class ranking signal.
    /// Verbatim noun-phrase fallback retrieval. See call site for
    /// the failure modes this addresses. Approach:
    /// 1. Tokenize the question, drop stopwords, keep tokens ≥3 chars.
    /// 2. Build candidate phrases from longest (most specific) down
    ///    to single words. Stop at the first window size that hits.
    /// 3. For each phrase, scan the document plain text for
    ///    case-insensitive substring matches.
    /// 4. Map each match offset to its containing chunk via
    ///    startOffset / endOffset. Return up to `maxMatches` distinct
    ///    chunks that aren't already in the candidate pool.
    /// Empty return when nothing matches — caller falls back to the
    /// embedding-only result, same as before.
    func verbatimPhraseChunks(for question: String, excluding alreadyHave: Set<Int>, maxMatches: Int = 3) -> [RetrievedChunk] {
        // Common-word stoplist. Conservative — better to miss a
        // hit than to scan the doc for "the" or "is" and inject
        // chunks that everywhere mention common words.
        let stopwords: Set<String> = [
            "the", "is", "are", "was", "were", "be", "been", "being",
            "of", "in", "on", "at", "to", "for", "with", "from", "by",
            "and", "or", "but", "not", "no", "nor", "so",
            "a", "an", "this", "that", "these", "those", "it", "its",
            "they", "them", "their", "there", "here",
            "what", "who", "where", "when", "why", "how", "which",
            "does", "do", "did", "doing", "done", "has", "have", "had",
            "tell", "told", "say", "said", "ask", "asked",
            "me", "my", "mine", "you", "your", "yours", "i", "we", "us", "our",
            "about", "please", "also", "too", "any", "some", "all",
            "can", "could", "would", "should", "will", "may", "might", "must",
            "mention", "mentioned", "mentions", "discuss", "discussed", "discusses",
            "explain", "explains", "explained", "describe", "describes", "described",
            "give", "gave", "given", "show", "shows", "showed", "shown",
            "yes", "yeah", "ok", "okay", "thanks", "thank",
            "book", "document", "article", "paper", "text", "chapter",
            "passage", "section", "page", "story",
            "thing", "things", "stuff", "kind", "type", "sort", "way",
            "really", "very", "much", "many", "more", "less",
            "good", "bad", "well", "right", "wrong", "fine"
        ]
        let rawTokens = question
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let contentTokens = rawTokens.filter { !stopwords.contains($0) && $0.count >= 3 }
        guard !contentTokens.isEmpty else { return [] }

        guard let db = databaseManager else { return [] }
        let stored: [StoredDocumentChunk] = (try? db.chunks(for: documentID)) ?? []
        guard !stored.isEmpty else { return [] }

        // Use NSString for fast substring search. We keep ranges in
        // UTF-16 units, which match the (NSString-backed) startOffset
        // / endOffset coordinates the rest of the indexing pipeline
        // uses (chunks(for:) writes startOffset/endOffset that come
        // from `(text as NSString).length`-style math at chunk time).
        let docNS = documentPlainText as NSString
        let docLowerNS = (documentPlainText as NSString).lowercased as NSString

        var matchedChunkIds = Set<Int>(alreadyHave)
        var matched: [RetrievedChunk] = []

        // Longest content phrase first (most specific). Multi-word
        // phrases only — single-word matches on common content terms
        // ("editor", "year", "title") pull too much noise into the
        // candidate pool and crowd out the embedding-best chunks.
        // Exception: if the question itself only has one content
        // token, single-word search is the only option.
        let maxWindow = min(contentTokens.count, 4)
        let minWindow = contentTokens.count == 1 ? 1 : 2
        outer: for windowSize in stride(from: maxWindow, through: minWindow, by: -1) {
            for start in 0...(contentTokens.count - windowSize) {
                let phrase = contentTokens[start..<(start + windowSize)].joined(separator: " ")
                let phraseNS = phrase as NSString
                guard phraseNS.length >= 3 else { continue }
                var searchRange = NSRange(location: 0, length: docLowerNS.length)
                while searchRange.length > 0 {
                    let found = docLowerNS.range(of: phrase as String, options: [.literal], range: searchRange)
                    if found.location == NSNotFound { break }
                    // Map UTF-16 offset to chunk via startOffset bounds.
                    let offset = found.location
                    if let chunk = stored.first(where: { offset >= $0.startOffset && offset < $0.endOffset }),
                       !matchedChunkIds.contains(chunk.chunkIndex) {
                        matchedChunkIds.insert(chunk.chunkIndex)
                        matched.append(RetrievedChunk(
                            chunkID: chunk.chunkIndex,
                            startOffset: chunk.startOffset,
                            // High relevance but distinguishable from
                            // 1.0 front-matter sentinel.
                            text: TextNormalizer.stripWaybackPrintHeaders(chunk.text),
                            relevance: 0.97
                        ))
                        if matched.count >= maxMatches { break outer }
                    }
                    let next = found.location + found.length
                    if next >= docLowerNS.length { break }
                    searchRange = NSRange(location: next, length: docLowerNS.length - next)
                }
            }
            if !matched.isEmpty { break }
        }
        _ = docNS  // silence unused warning; kept for symmetry / future use
        return matched
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
                dbgLog("AskPosey summarization failed: \(error)")
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

        // 2026-05-04 — Asymmetric split: 1/3 before, 2/3 after.
        // Real-conversation testing showed that for natural reader
        // questions ("what comes next", "what's the implication",
        // "explain this") the answer usually lives in the text
        // immediately AFTER the anchor — the user has just read up
        // to the anchor and is asking forward. The wide before-window
        // (previously 1/2 of the budget) reached back across section
        // breaks and pulled in unrelated content that AFM weighted
        // over the immediate-following sentence.
        let beforeChars = totalChars / 3
        let afterChars = totalChars - beforeChars

        let anchorEndOffset = min(plain.count, anchorOffset + anchor.text.count)
        var startOffset = max(0, anchorOffset - beforeChars)
        var endOffset = min(plain.count, anchorEndOffset + afterChars)

        // 2026-05-04 — Section-boundary clipping. Real-conversation
        // testing showed the surrounding window crossing strong
        // section breaks (MD `---`, page-break `\f`, triple-newline
        // paragraph gaps, and `\n\n##`/`\n\n###` markdown headings)
        // and pulling in cross-section content. Clip the window at
        // the nearest boundary in each direction so the proximity
        // stays inside the same conceptual section as the anchor.
        startOffset = clipWindowStart(plain: plain, startOffset: startOffset, anchorOffset: anchorOffset)
        endOffset = clipWindowEnd(plain: plain, endOffset: endOffset, anchorEndOffset: anchorEndOffset)

        guard startOffset < endOffset else { return nil }

        let startIndex = plain.index(plain.startIndex, offsetBy: startOffset)
        let endIndex = plain.index(plain.startIndex, offsetBy: endOffset)
        let raw = String(plain[startIndex..<endIndex])
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Walk backward from `startOffset` looking for the latest strong
    /// section break before the anchor. Strong break: line containing
    /// only "---" (MD horizontal rule), form-feed `\f` (PDF page
    /// break), `\n\n##` or `\n\n###` (MD heading), triple-newline gap.
    /// Returns the offset just past the boundary (so the window
    /// starts at the beginning of the same section as the anchor).
    private func clipWindowStart(plain: String, startOffset: Int, anchorOffset: Int) -> Int {
        let segment = plain.utf16Slice(from: startOffset, to: anchorOffset)
        let breakPatterns = ["\n---\n", "\n\n## ", "\n\n### ", "\n\n\n", "\u{000C}"]
        var bestBreakEnd = startOffset
        for pat in breakPatterns {
            if let r = segment.range(of: pat, options: .backwards) {
                let breakAbsoluteEnd = startOffset + segment.distance(from: segment.startIndex, to: r.upperBound)
                if breakAbsoluteEnd > bestBreakEnd { bestBreakEnd = breakAbsoluteEnd }
            }
        }
        return bestBreakEnd
    }

    /// Walk forward from `anchorEndOffset` looking for the earliest
    /// strong section break after the anchor; cap the window there.
    private func clipWindowEnd(plain: String, endOffset: Int, anchorEndOffset: Int) -> Int {
        guard anchorEndOffset < endOffset else { return endOffset }
        let segment = plain.utf16Slice(from: anchorEndOffset, to: endOffset)
        let breakPatterns = ["\n---\n", "\n\n## ", "\n\n### ", "\n\n\n", "\u{000C}"]
        var earliestBreakStart = endOffset
        for pat in breakPatterns {
            if let r = segment.range(of: pat) {
                let breakAbsoluteStart = anchorEndOffset + segment.distance(from: segment.startIndex, to: r.lowerBound)
                if breakAbsoluteStart < earliestBreakStart { earliestBreakStart = breakAbsoluteStart }
            }
        }
        return earliestBreakStart
    }
}

private extension String {
    /// Safe substring by character offsets — clamps to bounds.
    func utf16Slice(from: Int, to: Int) -> Substring {
        let lower = Swift.max(0, Swift.min(count, from))
        let upper = Swift.max(lower, Swift.min(count, to))
        let lowerIdx = index(startIndex, offsetBy: lower)
        let upperIdx = index(startIndex, offsetBy: upper)
        return self[lowerIdx..<upperIdx]
    }
}
// ========== BLOCK 03: SURROUNDING CONTEXT - END ==========


// ========== BLOCK 04: ECHO STUB (preview/test) - START ==========
extension AskPoseyChatViewModel {

    /// Detects "should I read this?" / "is this worth reading?" /
    /// "would you recommend?" question shapes. The polish prompt
    /// forbids recommendations as HARD RULE 4 (FAILED: "Yeah, I'd
    /// definitely recommend this book."). AFM ignores the rule
    /// frequently enough that detecting these questions and
    /// returning the canonical SUCCEEDED form directly is the
    /// only reliable path. Surfaced 2026-05-04 in Task 3 v2 QA.
    static func isRecommendationQuestion(_ question: String) -> Bool {
        let q = question.lowercased()
        // Patterns that are clear recommendation requests.
        let triggers = [
            "should i read",
            "should i get",
            "should i buy",
            "should i pick up",
            "is this worth reading",
            "is this worth your time",
            "is it worth reading",
            "is it worth my time",
            "would you recommend this",
            "would you recommend that",
            "do you recommend this",
            "do you recommend that",
            "is this a good read",
            "is this any good",
            "should i bother",
            "do i need to read",
        ]
        for t in triggers {
            if q.contains(t) { return true }
        }
        return false
    }

    /// Short-circuit response for recommendation questions. Builds
    /// a clean refusal in Posey's voice that follows the polish
    /// prompt's SUCCEEDED example: "The document doesn't make a
    /// recommendation. It does cover X, Y, Z if those interest you."
    /// The X/Y/Z list is empty here — we don't have time to extract
    /// chunks for this branch and using a generic phrasing is
    /// safer than risking a hallucinated topic list.
    func handleRecommendationShortCircuit(question: String) async {
        let userMessage = AskPoseyMessage(role: .user, content: question)
        messages.append(userMessage)
        inputText = ""
        isResponding = true
        lastError = nil

        persistTurn(
            role: .user,
            content: question,
            intent: nil,
            chunksInjected: [],
            fullPromptForLogging: nil
        )

        let answer = "The document doesn't make a recommendation about itself, and I won't either — that's your call. If you'd like, I can summarise what the document actually covers so you can decide."
        let assistantMessage = AskPoseyMessage(
            role: .assistant,
            content: answer,
            isStreaming: false,
            timestamp: Date()
        )
        messages.append(assistantMessage)
        persistTurn(
            role: .assistant,
            content: answer,
            intent: nil,
            chunksInjected: [],
            fullPromptForLogging: "[recommendation-short-circuit]"
        )
        isResponding = false
    }

    /// 2026-05-04 — Weak-retrieval check used by the confidence
    /// signal in send(). Returns true when no chunk outside the
    /// front-matter prepend has relevance ≥ the configured
    /// strictness threshold — meaning RAG retrieved nothing
    /// meaningful for this question, and AFM is going to either
    /// refuse or substitute summary boilerplate. Front-matter band
    /// derived from the 2026-05-04 conversational sweep (see commit
    /// 68ad883).
    ///
    /// 2026-05-14 (B3) — Threshold is now read from
    /// `PlaybackPreferences.shared.retrievalStrictness`
    /// (Permissive 0.35 / Balanced 0.45 / Strict 0.55). Default
    /// `.balanced` preserves the prior 0.45 behavior for users who
    /// don't visit Preferences.
    static func isWeakRetrieval(chunks: [RetrievedChunk]) -> Bool {
        // Empirical band per 2026-05-04 sweep:
        // 0.50+ chunks consistently produce real answers; 0.40 chunks
        // can produce confident fabrication when the chunk is
        // semantically near the question but doesn't actually answer
        // it. The user-tunable strictness lets them slide that floor
        // up (more honest refusals) or down (more attempts).
        let strongThreshold = PlaybackPreferences.shared
            .retrievalStrictness.weakRetrievalThreshold
        // Front-matter prepend is the first 4 chunks (or 1 for long
        // docs); always relevance 1.0; injected regardless of the
        // question. Conservatively skip the first 4 chunkIDs.
        // Lexical-full-match chunks may also have relevance 1.0; if
        // they're outside the front-matter band, they count as a
        // strong signal.
        let frontMatterUpperBound = 4
        for chunk in chunks {
            // 2026-05-05 — Synthetic metadata chunks (startOffset = -1
            // sentinel) are clean distillations of title/author/year/
            // summary. Their cosine is artificially low because the
            // text is short and doesn't share lots of vocabulary with
            // typical questions, but their MERE PRESENCE in the
            // top-K means the question matched the doc's metadata
            // beacon — that's exactly the case we WANT to answer
            // rather than refuse. Treat synthetic chunks as strong
            // evidence regardless of their cosine score.
            if chunk.startOffset < 0 { return false }
            if chunk.chunkID < frontMatterUpperBound { continue }
            if chunk.relevance >= strongThreshold { return false }
        }
        return true
    }

    /// 2026-05-04 — Short-circuit response when retrieval was weak
    /// AND the question is document-scope (no anchor). Replaces the
    /// AFM call with an honest message that points the user toward
    /// the action that actually works (passage-anchored asking).
    /// This is the surface form of the re-scoped 1.0 promise.
    func handleWeakRetrievalShortCircuit(
        question: String,
        placeholderID: UUID
    ) async {
        // 2026-05-12 — distinguish "no good RAG match" (canonical
        // refusal) from "indexing still in flight" (different message
        // telling the user to wait, not to rephrase). Indexing race
        // was a real issue on fresh imports — users would ask Q1, get
        // the canned refusal, and conclude Posey couldn't help on
        // their doc. The truth was just: chunks weren't ready yet.
        let stillIndexing = isStillIndexingChecker?(documentID) ?? false
        let answer: String
        if stillIndexing {
            answer = "I'm still learning this document — chunks are being indexed. Give me a moment and try the same question again. If you have something specific in mind, you can also tap a passage in the reader and ask from there; passage-anchored questions work even before indexing finishes."
        } else {
            answer = "I'm not finding a strong answer to that in the document. I do best when you select a sentence or passage you're curious about and ask me from there — try tapping a line in the reader, then asking again."
        }
        // Replace the streaming placeholder with the honest message.
        if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
            messages[index].content = answer
            messages[index].isStreaming = false
        } else {
            messages.append(AskPoseyMessage(
                role: .assistant,
                content: answer,
                isStreaming: false,
                timestamp: Date()
            ))
        }
        persistTurn(
            role: .assistant,
            content: answer,
            intent: nil,
            chunksInjected: [],
            fullPromptForLogging: "[weak-retrieval-short-circuit]"
        )
        isResponding = false
    }

    /// 2026-05-04 — Role-question short-circuit. AFM has a strong
    /// "give-an-answer" tendency: when the user asks "Who's the
    /// editor?" and the document doesn't identify one, AFM will
    /// promote whoever's name is in the front matter (typically a
    /// moderator/contributor) into the asked-about role. HARD RULE
    /// 1a in the grounded prompt explicitly forbids this with
    /// FAILED/SUCCEEDED examples and AFM still does it. So we
    /// validate at query time: if the user's question is asking
    /// for a specific named role and that role term doesn't appear
    /// ANYWHERE in the document, we return an honest refusal
    /// directly — the model never sees the question. Same pattern
    /// as `isRecommendationQuestion` short-circuit. Returns the
    /// matched role term (lowercased) when triggered, otherwise nil.
    static func roleAskedFor(in question: String) -> String? {
        let q = question.lowercased()
        // Role terms users might ask about. Only includes roles that
        // are typically explicit document metadata — not vague terms
        // like "leader" or "person responsible." If the role term is
        // ambiguous in normal English, leave it out (AFM might give
        // a useful answer).
        let roleTerms: [String] = [
            "editor", "publisher", "illustrator", "translator",
            "narrator", "co-author", "co author", "ghostwriter",
            "typesetter", "designer", "photographer", "screenwriter",
            "director", "producer"
        ]
        // Trigger patterns asking who fills a role.
        let prefixes = [
            "who is the ", "who's the ", "who was the ",
            "whos the ", "name the ", "who are the ",
            "who edited ", "who published ",
            "who illustrated ", "who translated ", "who narrated ",
            "who directed ", "who produced "
        ]
        for prefix in prefixes {
            guard q.contains(prefix) else { continue }
            for term in roleTerms {
                // "who is the editor", "who edited", etc.
                if q.contains(prefix + term) { return term }
                // verb form: "who edited", "who published"
                let verb = prefix.replacingOccurrences(of: "who ", with: "").trimmingCharacters(in: .whitespaces)
                if verb.hasSuffix("ed ") || verb.hasSuffix("ed") {
                    // already a verb form; the prefix itself encodes the role
                    if q.contains(prefix) {
                        // map verb back to role term
                        let roleFromVerb = String(verb.dropLast(verb.hasSuffix("ed ") ? 3 : 2))
                        if !roleFromVerb.isEmpty { return roleFromVerb }
                    }
                }
            }
        }
        return nil
    }

    /// Returns true if the role term doesn't appear anywhere in the
    /// document plain text (case-insensitive). Single-word substring
    /// check — fast on the largest doc tested (~1.6M chars, sub-ms).
    func documentLacksRoleTerm(_ role: String) -> Bool {
        guard !role.isEmpty else { return true }
        return !documentPlainText.lowercased().contains(role.lowercased())
    }

    /// Short-circuit response for role questions when the role term
    /// isn't in the document. Posts the user turn + a clean refusal,
    /// persists both, no AFM call. Mirror of
    /// `handleRecommendationShortCircuit`.
    func handleRoleShortCircuit(question: String, role: String) async {
        let userMessage = AskPoseyMessage(role: .user, content: question)
        messages.append(userMessage)
        inputText = ""
        isResponding = true
        lastError = nil

        persistTurn(
            role: .user,
            content: question,
            intent: nil,
            chunksInjected: [],
            fullPromptForLogging: nil
        )

        // Pick "a" or "an" based on the role term's first sound.
        let firstChar = role.first.map(String.init)?.lowercased() ?? ""
        let article = ["a","e","i","o","u"].contains(firstChar) ? "an" : "a"
        let answer = "The document doesn't identify \(article) \(role). If you're looking for a specific name, try asking about the role the document does mention (author, contributor, moderator, etc.)."
        let assistantMessage = AskPoseyMessage(
            role: .assistant,
            content: answer,
            isStreaming: false,
            timestamp: Date()
        )
        messages.append(assistantMessage)
        persistTurn(
            role: .assistant,
            content: answer,
            intent: nil,
            chunksInjected: [],
            fullPromptForLogging: "[role-short-circuit:\(role)]"
        )
        isResponding = false
    }

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

        // Recommendation-question short-circuit. Polish HARD RULE 4
        // and grounded HARD RULE 5 forbid recommendations, but AFM
        // ignores both ~half the time on questions of the shape
        // "should I read this?" / "is this worth reading?". Five
        // rounds of regex strips on the answer didn't catch every
        // variant either. The robust fix is to detect the question
        // pattern BEFORE calling AFM and return the canonical
        // refusal directly. The user gets the polish prompt's own
        // SUCCEEDED-form answer without any model variance.
        if Self.isRecommendationQuestion(trimmedInput) {
            await handleRecommendationShortCircuit(question: trimmedInput)
            return
        }

        // Role-question short-circuit. If the user is asking who fills
        // a specific role (editor, publisher, narrator, etc.) and that
        // role term doesn't appear anywhere in the document, AFM has a
        // strong tendency to promote a moderator/contributor into that
        // role. Validate at query time rather than rely on AFM honoring
        // HARD RULE 1a. See `roleAskedFor(in:)` for the trigger logic.
        if let role = Self.roleAskedFor(in: trimmedInput),
           documentLacksRoleTerm(role) {
            await handleRoleShortCircuit(question: trimmedInput, role: role)
            return
        }

        // Snapshot the user-visible message and clear the composer
        // immediately so the UI feels responsive even before AFM
        // returns a token.
        //
        // **2026-05-02 fix.** Do NOT append the current user message
        // to `historyForPromptBuilder` here — the prompt builder
        // already places the current question in `<current_question>`,
        // and duplicating it in `<past_exchanges>` confuses the model
        // (it treats the question both as history and as the active
        // turn). The user message lands in `historyForPromptBuilder`
        // at finalize time alongside the assistant reply, so the
        // *next* send's prompt has the just-completed exchange in
        // its past_exchanges section.
        let userMessage = AskPoseyMessage(role: .user, content: trimmedInput)
        messages.append(userMessage)
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
                //
                // **2026-05-02 fix.** AFM's safety filter sometimes
                // refuses the classifier call itself for questions
                // it considers sensitive (e.g. "How does Mark's role
                // compare to the AI contributors?"). The classifier
                // is internal infrastructure — its refusal shouldn't
                // surface to the user as a hard failure. Fall back
                // to `.general` intent so the prose pipeline still
                // runs, where the proper retry-with-rephrasing logic
                // can handle the user-facing refusal path. Other
                // classifier errors (transient, AFM unavailable)
                // still surface via handleSendError.
                let intent: AskPoseyIntent
                do {
                    intent = try await classifier.classifyIntent(
                        question: trimmedInput,
                        anchor: anchorTextForClassifier
                    )
                } catch {
                    let errorString = "\(error)"
                    let isClassifierRefusal = errorString.lowercased().contains("refusal")
                    if isClassifierRefusal {
                        dbgLog("AskPosey: classifier refused; defaulting to .general intent")
                        intent = .general
                    } else {
                        self.handleSendError(error, placeholderID: placeholderID, intent: nil)
                        return
                    }
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

                // 2026-05-04 — Confidence signal for weak retrieval.
                // When the question is document-scope (no anchor) and
                // RAG returned no chunks with meaningful relevance,
                // short-circuit with an honest message rather than
                // letting AFM substitute summary boilerplate. This
                // implements the re-scoped Ask Posey promise: we
                // tell the user what works ("try selecting a
                // passage") rather than papering over a retrieval
                // miss with confident-sounding fluff.
                //
                // Threshold (0.35) chosen from the conversational
                // sweep: 0.50+ chunks produced real answers, 0.28
                // chunks produced TOC-summary boilerplate, 0.0
                // chunks produced fabrication. 0.35 catches the
                // boilerplate band cleanly without false-positiving
                // legitimate moderate-relevance retrievals.
                //
                // Anchored (passage-scope) questions skip the check
                // — the anchor + surrounding context provides
                // grounding even when wider RAG is weak.
                if self.anchor == nil,
                   Self.isWeakRetrieval(chunks: chunks) {
                    await self.handleWeakRetrievalShortCircuit(
                        question: trimmedInput,
                        placeholderID: placeholderID
                    )
                    return
                }

                // Task 4 #9 — pairwise STM mode (parallel; opt-in).
                // When enabled, compress prior verbatim Q/A pairs into
                // tiered, embedding-verified per-pair summaries and
                // pass to the builder via `pairwiseSummaries`. The
                // builder swaps STM rendering accordingly. Stats are
                // captured for the local-API tuning loop.
                var pairwiseSummaries: [String]? = nil
                var pairwiseStatsThisTurn: AskPoseyPairwiseStats? = nil
                #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *),
                   self.useSummarizedSTM,
                   let summarizer = self.summarizer {
                    let pairs = AskPoseyConversationPairExtractor.pairs(from: self.historyForPromptBuilder)
                    if !pairs.isEmpty {
                        if self.pairwiseSummarizer == nil {
                            self.pairwiseSummarizer = AskPoseyPairwiseSummarizer(summarizer: summarizer)
                        }
                        if let sum = self.pairwiseSummarizer {
                            let result = await sum.summarize(pairs: pairs)
                            pairwiseSummaries = result.summaries
                            pairwiseStatsThisTurn = result.stats
                        }
                    }
                }
                #endif
                self.lastPairwiseStats = pairwiseStatsThisTurn

                // Call 2: prompt build + stream.
                let inputs = AskPoseyPromptInputs(
                    intent: intent,
                    anchor: self.anchor,
                    surroundingContext: self.surroundingContext(for: intent),
                    conversationHistory: self.historyForPromptBuilder,
                    conversationSummary: self.cachedConversationSummary,
                    documentChunks: chunks,
                    currentQuestion: trimmedInput,
                    pairwiseSummaries: pairwiseSummaries
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
        // Task 2 — embedding-based citation attribution. Always runs
        // on every answer. AFM does not emit citations; the model's
        // job is the answer text in voice, the embedding's job is
        // the citations. Clean separation. Each sentence in the
        // polished answer is matched to its best chunk in the same
        // NLEmbedding vector space the M2 index uses, and `[N]`
        // markers are appended where cosine clears the threshold.
        // Per-sentence scores logged via NSLog so the threshold can
        // be tuned on real answers without code changes.
        let attributedFinalText: String = {
            // Defensive post-strip — removes polish-preamble patterns
            // ("Here is a rewrite of the draft answer in the
            // requested voice:", "Sure! Here's…", etc.) that AFM
            // sometimes emits despite the polish prompt's
            // "**NEVER announce the rewrite.**" hard rule. Per
            // Mark's 2026-05-02 (later) directive: "the prompt rule
            // stays, the heuristic catches what AFM misses."
            //
            // 2026-05-06 — Also dedupe repeated comma-separated items
            // in the response. AFM's count-mismatch hallucination
            // (e.g. user asks for "four things", doc has three, AFM
            // pads by repeating an item) survives prompt rules. The
            // heuristic catches the worst case: when a list of
            // comma-separated phrases contains duplicates, collapse
            // the duplicates while preserving order.
            let depolished = AskPoseyPromptBuilder.stripPolishPreamble(metadata.finalText)
            let commaDeduped = AskPoseyPromptBuilder.dedupeRepeatedListItems(depolished)
            let stripped = AskPoseyPromptBuilder.dedupeNumberedListItems(commaDeduped)
            guard let index = embeddingIndex,
                  !metadata.chunksInjected.isEmpty else { return stripped }
            let chunkRefs = metadata.chunksInjected.enumerated().map { (i, c) in
                (chunkID: c.chunkID, citationNumber: i + 1, text: c.text)
            }
            // Threshold + delta come from the named constants on
            // DocumentEmbeddingIndex (single source of truth).
            return index.attributeCitations(
                text: stripped,
                chunks: chunkRefs,
                documentID: documentID
            )
        }()

        if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
            messages[index].content = attributedFinalText
            messages[index].isStreaming = false
            messages[index].chunksInjected = metadata.chunksInjected
            // Append BOTH the user turn (which we deliberately held
            // out of historyForPromptBuilder at send-start to avoid
            // duplicating the current question into <past_exchanges>)
            // AND the finalized assistant turn. The next send's
            // prompt sees this Q+A pair as background context.
            if let userIndex = messages[..<index].lastIndex(where: { $0.role == .user }) {
                let userTurn = messages[userIndex]
                if !historyForPromptBuilder.contains(where: { $0.id == userTurn.id }) {
                    historyForPromptBuilder.append(userTurn)
                }
            }
            historyForPromptBuilder.append(messages[index])
        }
        lastMetadata = metadata
        lastIntent = intent
        isResponding = false

        persistTurn(
            role: .assistant,
            // Persist the attributed text (with `[N]` markers
            // baked in) so the DB matches what the user saw and
            // re-opens of the sheet show the same citations.
            content: attributedFinalText,
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
                // Same dedup-then-append pattern as the prose finalize
                // — pair the just-finalized user turn with this
                // assistant reply.
                if let userIndex = messages[..<index].lastIndex(where: { $0.role == .user }) {
                    let userTurn = messages[userIndex]
                    if !historyForPromptBuilder.contains(where: { $0.id == userTurn.id }) {
                        historyForPromptBuilder.append(userTurn)
                    }
                }
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

    /// Translate a send-path error into UI state. Replaces the
    /// streaming placeholder with a user-visible failure message
    /// (rather than removing it silently — leaving an unanswered user
    /// question with no response feels broken). Surfaces the typed
    /// error via `lastError` for the alert path too. AFM refusals
    /// (`.permanent` from a guardrail violation) get the
    /// "couldn't answer this one — try rephrasing" message; transient
    /// errors get a softer try-again message; AFM-unavailable gets
    /// the explicit unavailability note.
    func handleSendError(_ error: Error, placeholderID: UUID, intent: AskPoseyIntent?) {
        let serviceError: AskPoseyServiceError
        if let typed = error as? AskPoseyServiceError {
            serviceError = typed
        } else {
            serviceError = .permanent(underlyingDescription: "\(error)")
        }
        lastError = serviceError

        let bubbleText: String
        switch serviceError {
        case .afmUnavailable:
            bubbleText = "Posey can't answer right now — Apple Intelligence isn't available on this device."
        case .transient:
            bubbleText = "Posey ran into a temporary issue. Try again in a moment."
        case .permanent(let description):
            // AskPoseyService surfaces `informativeRefusalFailure` as
            // the underlyingDescription when both the primary
            // grounded call AND the neutral-rephrased retry both got
            // .refusal'd by AFM. Per Mark 2026-05-02 the failure
            // message should be more actionable than "try
            // rephrasing" — give the user a hint at what kinds of
            // questions Posey can usually handle.
            if description.contains("informativeRefusalFailure") {
                bubbleText = "Posey had trouble with that one. Try asking about a specific passage or a more concrete aspect of the topic."
            } else {
                bubbleText = "Posey couldn't answer this one — try rephrasing the question."
            }
        }

        if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
            messages[index].content = bubbleText
            messages[index].isStreaming = false
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
