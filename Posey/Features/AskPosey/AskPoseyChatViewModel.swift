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

    /// 2026-06-17 — Spoiler firewall (Layer 0). Per-document toggle, loaded on
    /// init from `documents.spoiler_protection` (default ON). The chat quick
    /// toggle flips it; the prompt builder (Layer 1) and catcher (Layer 2)
    /// consult it. Mirrors the DB column — `toggleSpoilerProtection()` persists.
    @Published var spoilerProtectionEnabled: Bool = true

    /// 2026-06-17 — Spoiler firewall (Layer 2). Result of the catcher's pass on
    /// the most recent answer (nil when protection was off or no send has run).
    /// Surfaced through the local-API `/ask` payload so the A/B catcher test can
    /// measure leak rates (caughtSpoiler + flaggedCount + engine) headlessly.
    @Published private(set) var lastSpoilerCatch: SpoilerCatcher.CatchResult?

    /// Structured bibliographic metadata loaded from the `metadata_*`
    /// columns (populated by `DocumentMetadataExtractor` at import). Passed
    /// into the prompt builder so "who wrote this / when" answer from clean
    /// structured fields rather than retrieved front matter. nil when not
    /// yet extracted.
    private var documentAuthors: [String]?
    private var documentYear: String?

    /// 2026-05-30 — STRUCTURED KNOWLEDGE injection (mechanism proof). When
    /// set (currently only via the /ask `structuredKnowledge` field), a
    /// hand-written source-verified chapter summary is passed into the
    /// prompt builder as a labeled, non-droppable, supplement-not-replace
    /// block alongside the raw RAG chunks. Proves whether a perfect
    /// summary improves answers before any generation pipeline is built.
    var injectedStructuredKnowledge: String?

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

    // 2026-05-23 — Step 8f: the lazy `embeddingIndex`
    // (DocumentEmbeddingIndex) was torn out. RAG retrieval routes
    // exclusively through HybridRetriever now (built per-call in
    // retrieveRAGChunks).

    /// Explicit budget injected by a caller (tests). nil in production —
    /// the `budget` computed property then derives the per-model adaptive
    /// budget from the *active* model at access time, so a mid-conversation
    /// model switch takes effect on the next turn (#3).
    private let injectedBudget: AskPoseyTokenBudget?

    /// Token budget passed to the prompt builder. Single tuning point.
    /// Production: derived per-access from `ModelCatalog.current()` +
    /// document length so it scales with the active model's window
    /// (AFM 4K unchanged; MLX gets the memory-capped, continuity-favoring
    /// budget — see `AskPoseyTokenBudget.forModel`). Tests inject a fixed
    /// budget via init, which wins.
    private var budget: AskPoseyTokenBudget {
        if let injectedBudget { return injectedBudget }
        let isLong = documentPlainText.count >= UnitEmbeddingChunker.Configuration.longDocumentThresholdChars
        // Answers run on the MLX answer model (never AFM) — budget matches it.
        return AskPoseyTokenBudget.forModel(ModelCatalog.answerModel(), longDocument: isLong)
    }

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

    /// 2026-05-23 — Step 8c: latched after each `retrieveRAGChunks`
    /// call so 8d's prompt-builder can read the RRF top score and
    /// inject the anti-confabulation guard when no high-relevance
    /// match was found. Reset to defaults at each call entry.
    /// Natural RRF top-1 from one retriever sits around
    /// `1/(60+1) ≈ 0.0164`; from both retrievers ranking the same
    /// chunk #1 it doubles. The 8d guard threshold reads
    /// `HybridRetriever.confidenceFloor`.
    var lastRetrievalTopRelevance: Double = 0

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

    /// Active model's verbatim memory depth in EXCHANGES (Q+A pairs):
    /// AFM 3 / 128K-window MLX 6 / 256K-window MLX 8. Seeded in the
    /// catalog's `defaultSettings.effectiveMemoryDepth`; this is the
    /// lever the larger context windows buy — deeper *conversation*
    /// memory, NOT more RAG (RAG budget is unchanged by decree). Falls
    /// back to 3 (AFM-equivalent) when a model leaves it unset, so an
    /// unconfigured model degrades safely rather than to zero.
    private var activeMemoryDepthExchanges: Int {
        let depth = ModelSettingsStore.shared
            .effectiveSettings(for: ModelCatalog.answerModel())
            .effectiveMemoryDepth ?? 3
        return max(1, depth)
    }

    /// How many of the most recent verbatim MESSAGES to keep un-folded
    /// (i.e. NOT compressed into the rolling summary). The rest get
    /// summarized whenever the trigger below fires.
    ///
    /// `historyForPromptBuilder` holds individual user/assistant
    /// messages, so one exchange = 2 entries → `depth × 2`. AFM depth 3
    /// → 6 (exactly the prior hard-coded value, so AFM behavior is
    /// unchanged); 128K → 12; 256K → 16. Derived per-access from the
    /// active model so a mid-conversation model switch takes effect on
    /// the next turn — same per-access pattern as the adaptive budget
    /// (#3a). Wires DECISION 3's `effectiveMemoryDepth` lever to the
    /// verbatim window.
    private var keepVerbatimRecent: Int { activeMemoryDepthExchanges * 2 }

    /// Auto-summarization fires once the non-summary message count
    /// exceeds the verbatim window plus this fixed margin. Margin held
    /// at +2 (the prior 6→8 relationship) so summarization only kicks
    /// in once there is genuinely older history to fold, regardless of
    /// window size.
    private var summarizeWhenTurnsExceed: Int { keepVerbatimRecent + 2 }

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
        streamer: AskPoseyStreaming? = nil,
        summarizer: AskPoseySummarizing? = nil,
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
        self.streamer = streamer
        self.summarizer = summarizer
        self.databaseManager = databaseManager
        // #3 (2026-05-29) — the budget is now derived per-access from the
        // ACTIVE model (see the `budget` computed property), so it scales
        // with the model's window and the long-document threshold without
        // being frozen at init. A caller that passed an explicit budget
        // (tests) injects it; production passes the `.afmDefault` default,
        // which means "derive adaptively" → injectedBudget stays nil.
        self.injectedBudget = (budget == .afmDefault) ? nil : budget

        // Read non-English flag from extracted metadata so the UI
        // can surface a "still studying [language]" notice. Silent
        // failure is fine — if metadata isn't extracted yet the
        // flag stays false and no notice shows; once extraction
        // completes on the next sheet open the notice appears.
        if let db = databaseManager,
           let meta = try? db.documentMetadata(for: documentID) {
            self.documentDetectedNonEnglish = meta.detectedNonEnglish
            self.documentAuthors = meta.authors.isEmpty ? nil : meta.authors
            self.documentYear = (meta.year?.isEmpty == false) ? meta.year : nil
        }

        // Spoiler firewall (Layer 0) — load the per-document toggle. Default ON
        // when the column read fails (defensive: protection-by-default).
        if let db = databaseManager {
            self.spoilerProtectionEnabled = (try? db.spoilerProtectionEnabled(for: documentID)) ?? true
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

    /// Spoiler firewall (Layer 0) — flip the per-document toggle and persist it
    /// to `documents.spoiler_protection`. Driven by the chat quick toggle. The
    /// in-memory flag is the source of truth for the in-flight request; the DB
    /// write makes it stick across opens and is read by the Preferences toggle.
    func toggleSpoilerProtection() {
        let next = !spoilerProtectionEnabled
        spoilerProtectionEnabled = next
        try? databaseManager?.setSpoilerProtection(next, for: documentID)
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
    func retrieveRAGChunks(for question: String) async -> [RetrievedChunk] {
        // 2026-05-23 — Step 8f: retrieval flows exclusively through
        // HybridRetriever (semantic via the active EmbeddingProvider
        // backend over unit_embedding_chunks + BM25 via FTS5 mirror,
        // fused via Reciprocal Rank Fusion). The legacy
        // DocumentEmbeddingIndex path was removed in this slice.
        guard let db = databaseManager else {
            self.lastRetrievalTopRelevance = 0
            return []
        }
        let retriever = HybridRetriever(database: db)
        let base = retriever.retrieve(
            documentID: documentID, query: question, limit: ragTopK
        )

        // 2026-05-30 — QUERY EXPANSION (Hal QueryExpansion port). When the
        // base retrieval is weak (low fused top-1) OR lexically-
        // unsupported (top results all BM25-only — the natural-question-
        // vs-passage vocabulary gap measured via RAG_DEBUG on P&P), ask
        // the active LLM for bridging terms, OR them into the BM25 pass,
        // and re-retrieve. Keep-if-better: adopt the expanded result only
        // when it improves the fused top-1 (Hal's `>=`), so expansion can
        // only help. Semantic pass is NOT expanded. Cost: one LLM call on
        // weak turns only (Rule 6 — local inference is effectively free).
        var outcome = base
        if AskPoseyQueryExpansion.isEnabled,
           let reason = AskPoseyQueryExpansion.triggerReason(
            topRelevance: base.topRelevance, topChunks: base.results
        ) {
            let terms = await AskPoseyQueryExpansion.expand(query: question)
            if terms.isEmpty {
                dbgLog("AskPosey expansion: trigger=%@ but LLM returned no terms", reason)
            } else {
                let expanded = retriever.retrieve(
                    documentID: documentID, query: question,
                    limit: ragTopK, expansionTerms: terms
                )
                let kept = expanded.topRelevance >= base.topRelevance
                dbgLog("AskPosey expansion: trigger=%@ terms=[%@] baseTop=%.4f expandedTop=%.4f kept=%@",
                       reason, terms.joined(separator: ","),
                       base.topRelevance, expanded.topRelevance,
                       kept ? "expanded" : "base")
                if kept { outcome = expanded }
            }
        }

        self.lastRetrievalTopRelevance = outcome.topRelevance
        let translated: [RetrievedChunk] = outcome.results.map { rc in
            RetrievedChunk(
                chunkID: rc.chunkID,
                startOffset: rc.startOffset,
                text: TextNormalizer.stripWaybackPrintHeaders(rc.text),
                relevance: rc.relevance,
                // Thread the semantic cosine through — `isWeakRetrieval`
                // gates on it. Dropping it here (the prior behavior)
                // would silently nil it out and defeat the gate.
                semanticScore: rc.semanticScore
            )
        }
        // Filter + sort (matches the legacy tail logic). Chunks with
        // `startOffset < 0` (the unit-anchored sentinel) are exempt
        // from the relevance floor — RRF scores live in a different
        // numeric band than the 0.40 cosine threshold the floor was
        // calibrated for, and the dedup-as-fabrication-guard already
        // happens via Layer-2 prompt rules + the anti-confab guard.
        return translated
            .filter { $0.startOffset < 0 || $0.relevance >= 0.40 }
            .sorted { $0.relevance > $1.relevance }
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
        // Diagnostic — makes DECISION 3's effectiveMemoryDepth wiring
        // observable on-device: the depth, the derived verbatim window,
        // and the trigger threshold for the active model. Greppable via
        // the LOGS antenna verb.
        dbgLog("AskPosey memory: total=%d depth=%d keepVerbatim=%d trigger=%d",
               total, activeMemoryDepthExchanges, keepVerbatimRecent, summarizeWhenTurnsExceed)
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
    // ============================================================
    // 2026-05-16 — B5 / B5b short-circuits
    // ============================================================

    /// Word-boundary, case-insensitive check for "falafel" anywhere
    /// in the user input. B5b. Used at the very top of `send()` so
    /// the easter egg fires regardless of document scope.
    static func containsFalafelToken(_ text: String) -> Bool {
        let pattern = #"\bfalafel\b"#
        return text.range(of: pattern,
                          options: [.regularExpression, .caseInsensitive])
            != nil
    }

    /// Posts the canonical Party Girl line as if it were a citation
    /// hit. Persists the turn so dismissing + reopening the sheet
    /// keeps the joke in the history.
    func handleFalafelEasterEgg(question: String) async {
        let userMessage = AskPoseyMessage(role: .user, content: question)
        messages.append(userMessage)
        inputText = ""
        isResponding = true
        lastError = nil

        persistTurn(
            role: .user, content: question, intent: nil,
            chunksInjected: [], fullPromptForLogging: nil
        )

        // Wrapped to look like a real Posey answer with a citation
        // chip. The chip text is the source attribution; the prose
        // is the actual line as a quote.
        let answer = "“Can I have a falafel with hot sauce, a side order of baba ghanoush, and a seltzer, please?”[1]\n\n— *Party Girl*, 1995"
        let assistantMessage = AskPoseyMessage(
            role: .assistant, content: answer,
            isStreaming: false, timestamp: Date()
        )
        messages.append(assistantMessage)
        persistTurn(
            role: .assistant, content: answer, intent: nil,
            chunksInjected: [],
            fullPromptForLogging: "[falafel-easter-egg]"
        )
        isResponding = false
    }

    /// True when the input is so short or so non-textual that there's
    /// nothing meaningful to feed AFM. Catches: single non-letter
    /// character, repeated single character (`...`, `aaaaa`, `???`),
    /// fewer than two alphabetic characters total, or pure
    /// punctuation/symbols. False on any reasonable short question
    /// (e.g. "ok?", "why", "how" — these get the regular pipeline).
    static func looksLikeNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        // Letters-only count. "why" → 3, "??" → 0, "ok?" → 2.
        let letterCount = trimmed.unicodeScalars
            .filter { CharacterSet.letters.contains($0) }
            .count
        if letterCount < 2 { return true }
        // Repeated single character ignoring case ("aaa", "....").
        let normalized = trimmed.lowercased()
        if let first = normalized.first,
           normalized.allSatisfy({ $0 == first }) {
            return true
        }
        return false
    }

    /// Personality-light response for nonsense input. Doesn't refuse
    /// — invites the user to try again with a real question. Persists
    /// so the conversation history accurately reflects the exchange.
    func handleNoiseShortCircuit(question: String) async {
        let userMessage = AskPoseyMessage(role: .user, content: question)
        messages.append(userMessage)
        inputText = ""
        isResponding = true
        lastError = nil

        persistTurn(
            role: .user, content: question, intent: nil,
            chunksInjected: [], fullPromptForLogging: nil
        )

        let answer = "I'm not sure what you're asking. Try a question about the document — like \"what's this chapter about\" or \"who is the main character\"."
        let assistantMessage = AskPoseyMessage(
            role: .assistant, content: answer,
            isStreaming: false, timestamp: Date()
        )
        messages.append(assistantMessage)
        persistTurn(
            role: .assistant, content: answer, intent: nil,
            chunksInjected: [],
            fullPromptForLogging: "[noise-short-circuit]"
        )
        isResponding = false
    }

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
    /// RRF top-1 floor below which retrieval reads as "weak" (nothing
    /// with cross-retriever support came back). Aligned with Hal's
    /// `QueryExpansion` weak-retrieval trigger (0.020): a single-list
    /// RRF contribution is ~1/(60+1) ≈ 0.0164 (ONE retriever, no
    /// corroboration); both retrievers agreeing yields ~0.033+. 0.020
    /// sits just above the single-list value, so "weak" means "no
    /// cross-retriever agreement and a low rank."
    static let weakRetrievalRRFFloor: Double = 0.020

    static func isWeakRetrieval(chunks: [RetrievedChunk]) -> Bool {
        // 2026-05-29 — gate on the RRF AGREEMENT signal, not an absolute
        // cosine. Two things were learned the hard way (#2, with Hal
        // CC's RAG history):
        //   • An absolute cosine floor is meaningless here. NLContextual
        //     cosines run 0.85–0.95 for relevant AND tangential chunks
        //     (measured: Frankenstein's WRONG "narrator" chunk scored
        //     0.89, Moby's RIGHT Ahab chunk scored 0.92). So no single
        //     cosine number separates strong from weak — Hal moved off
        //     absolute floors to relative-spread / two-retriever
        //     agreement for exactly this reason.
        //   • The RRF fused score already encodes agreement: it only
        //     climbs above the single-list ~0.0164 when both retrievers
        //     corroborate, and it rides on the BM25 quality gate (which
        //     now drops lexical-only matches semantic disagrees with —
        //     the zero-overlap branch ported from Hal). So a low RRF top
        //     genuinely means "nothing both retrievers back."
        // This is therefore a TWO-signal notion by construction, not the
        // brittle single-cosine threshold that the old code (mis)used.
        //
        // Diagnostic kept (greppable "AskPosey weak-gate") — logs the
        // semantic cosines + RRF top so the gate stays observable.
        let semScores = chunks.prefix(8).map { c -> String in
            if let s = c.semanticScore { return String(format: "%.2f", s) }
            return "nil"
        }.joined(separator: ",")
        let rrfTop = chunks.first?.relevance ?? 0
        dbgLog("AskPosey weak-gate: rrfTop=%.3f floor=%.3f sem=[%@] weak=%@",
               rrfTop, Self.weakRetrievalRRFFloor, semScores as NSString,
               (rrfTop < Self.weakRetrievalRRFFloor ? "yes" : "no") as NSString)
        return rrfTop < Self.weakRetrievalRRFFloor
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
            answer = "I'm still getting to know this document — give me a moment to finish reading it through, then ask me that again. If you'd rather not wait, tap a passage in the reader and ask me from there; that works even while I'm still settling in."
        } else {
            answer = "I went looking and couldn't find where this document really speaks to that — and I'd rather tell you straight than make something up. If there's a particular passage you're curious about, tap a line in the reader and ask me from there. I'm at my best when we're looking at the same spot on the page."
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
        let answer = "I looked, and this document doesn't actually name \(article) \(role) — and I won't invent one for you. If there's someone specific you're trying to place, point me at a passage that mentions them and we'll work it out together."
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
        guard let streamer else {
            // No live deps — degrade to echo so previews/tests keep
            // working.
            await sendEchoStub()
            return
        }

        // 2026-05-16 (B5b) — Falafel easter egg. Mark's quiet wink at
        // Parker Posey's character in Party Girl. Word-boundary match,
        // case-insensitive. Returns the canonical line as if it were
        // a citation hit — feels like a real search result, not a
        // sight gag. Runs BEFORE any pipeline work so it never touches
        // AFM or RAG.
        if Self.containsFalafelToken(trimmedInput) {
            await handleFalafelEasterEgg(question: trimmedInput)
            return
        }

        // 2026-05-16 (B5) — Nonsense / noise short-circuit. Single
        // punctuation, repeated single character, or extremely short
        // non-word input gets a personality response rather than
        // entering the AFM pipeline where it'd waste tokens and
        // typically produce a confused refusal anyway.
        if Self.looksLikeNoise(trimmedInput) {
            await handleNoiseShortCircuit(question: trimmedInput)
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

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Intent classification REMOVED 2026-06-19 (Mark + A/B). The
                // immediate/search/general classifier was an AFM-era "Call 1"
                // built to pre-narrow context for AFM's 4K window. On the MLX
                // answer path (8K budget) the A/B showed it adds ~2× latency and
                // an AFM dependency for no quality gain, so every question now
                // takes the single full-retrieval `.general` route (anchor +
                // surrounding + summary + RAG — the model focuses itself).
                let intent: AskPoseyIntent = .general

                // Wait for any in-flight summarization from the
                // previous turn to land BEFORE building this prompt
                // so the conversation summary is current.
                if let task = self.summarizationTask {
                    await task.value
                }

                // M6 RAG retrieval — top-K chunks for this question,
                // dedup'd against anchor + recent STM. M5 used [];
                // M6 lights up the slot the prompt builder already
                // accommodates. All intents (including `.search`, a
                // where/location question) answer in prose from these
                // chunks — the old `.search` navigation-card path was
                // removed 2026-06-19 (Mark: the card UI was vestigial).
                let chunks = await self.retrieveRAGChunks(for: trimmedInput)

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
                // 2026-05-23 — Step 8d: anti-confabulation guard.
                // Retrieval landed `lastRetrievalTopRelevance` during
                // `retrieveRAGChunks`. When the top RRF score is below
                // `HybridRetriever.confidenceFloor`, the builder
                // appends an explicit "no high-relevance match" note
                // before the user question so the model is told the
                // retrieval was weak rather than silently filling the
                // gap. We only fire the guard when chunks WERE
                // attempted (`chunks` non-empty would still be low-
                // confidence; chunks empty + zero relevance means
                // RAG wasn't even attempted, so no signal to give).
                let lowConfidence = !chunks.isEmpty
                    && self.lastRetrievalTopRelevance < HybridRetriever.confidenceFloor
                // Spoiler firewall (Layer 1) — pass the per-doc toggle + the
                // reader's furthest-read offset (the spoiler line). Fold the
                // invocation offset in via max() so a position the reader just
                // reached but hasn't persisted yet still counts. Off → nil, no
                // spoiler framing in the prompt at all.
                let spoilerActive = self.spoilerProtectionEnabled
                let storedFurthest = (try? self.databaseManager?.furthestReadOffset(for: self.documentID)) ?? nil
                let furthestOffset = max(storedFurthest ?? 0, self.invocationReadingOffset ?? 0)
                let inputs = AskPoseyPromptInputs(
                    intent: intent,
                    anchor: self.anchor,
                    surroundingContext: self.surroundingContext(for: intent),
                    conversationHistory: self.historyForPromptBuilder,
                    conversationSummary: self.cachedConversationSummary,
                    documentChunks: chunks,
                    currentQuestion: trimmedInput,
                    pairwiseSummaries: pairwiseSummaries,
                    lowConfidenceRetrieval: lowConfidence,
                    documentTitle: self.documentTitle,
                    documentPlainText: self.documentPlainText,
                    documentAuthors: self.documentAuthors,
                    documentYear: self.documentYear,
                    structuredKnowledge: self.injectedStructuredKnowledge,
                    spoilerProtectionActive: spoilerActive,
                    readerFurthestOffset: spoilerActive ? furthestOffset : nil
                )

                do {
                    let metadata = try await streamer.streamProseResponse(
                        inputs: inputs,
                        budget: self.budget,
                        onSnapshot: { [weak self] snapshot in
                            self?.applyStreamingSnapshot(snapshot, to: placeholderID)
                        }
                    )
                    // Spoiler firewall (Layer 2) — the post-generation catcher.
                    // Runs only when protection is active for this doc; live
                    // streaming was suppressed (the thinking indicator stayed up)
                    // precisely so a leak can't flash on screen before this
                    // verifies + rewrites the full answer. Off → original text.
                    var overrideText: String? = nil
                    self.lastSpoilerCatch = nil
                    if spoilerActive, let db = self.databaseManager {
                        let result = await SpoilerCatcher(database: db).process(
                            answer: metadata.finalText,
                            question: trimmedInput,
                            documentID: self.documentID,
                            furthestOffset: furthestOffset,
                            plainText: self.documentPlainText
                        )
                        if result.caughtSpoiler {
                            dbgLog("SpoilerCatcher[%@]: caught %d spoiler sentence(s); rewrote answer",
                                   result.engine.rawValue as NSString, result.flagged.count)
                        }
                        self.lastSpoilerCatch = result
                        overrideText = result.safeAnswer
                    }
                    self.finalizeAssistantTurn(
                        metadata: metadata,
                        placeholderID: placeholderID,
                        intent: intent,
                        overrideFinalText: overrideText
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
        // Spoiler firewall (Layer 2) — when protection is active for this doc we
        // must NOT reveal partial tokens: a spoiler could flash on screen before
        // the post-gen catcher gets to verify the full answer. Suppress live
        // updates so the placeholder keeps showing the thinking indicator; the
        // checked (and possibly rewritten) answer appears all at once at
        // finalize. Off → normal live streaming, unchanged.
        if spoilerProtectionEnabled { return }
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
        intent: AskPoseyIntent,
        // Spoiler firewall (Layer 2) — when non-nil, this catcher-approved text
        // (the original draft if clean, an in-character rewrite if a spoiler was
        // caught) replaces `metadata.finalText` as the answer shown + persisted.
        // It still flows through the normal preamble-strip / dedupe pipeline.
        overrideFinalText: String? = nil
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
            let depolished = AskPoseyPromptBuilder.stripPolishPreamble(overrideFinalText ?? metadata.finalText)
            let commaDeduped = AskPoseyPromptBuilder.dedupeRepeatedListItems(depolished)
            let stripped = AskPoseyPromptBuilder.dedupeNumberedListItems(commaDeduped)
            // 2026-05-23 — Step 8f: citation attribution used to be
            // a DocumentEmbeddingIndex.attributeCitations call that
            // re-embedded chunks + answer sentences and chose the
            // best-cosine chunk per sentence. With the legacy index
            // torn out, citations now stay as the model wrote them
            // (already [N] tagged in the AFM prompt body). A future
            // polish pass can rebuild attribution on top of
            // EmbeddingProvider; deferred.
            return stripped
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
