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

    /// Captured reading offset at invocation. Always set for fresh
    /// invocations regardless of scope — passage scope mirrors
    /// `anchor.plainTextOffset`, document scope captures the active
    /// sentence offset so the doc-scope anchor is still tappable to
    /// jump back to where the question was asked. Nil only for the
    /// Notes-tap-conversation navigation path, where we're NOT
    /// creating a new anchor.
    private let invocationReadingOffset: Int?

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
        budget: AskPoseyTokenBudget = .afmDefault
    ) {
        self.documentID = documentID
        self.documentPlainText = documentPlainText
        self.documentTitle = documentTitle
        self.anchor = anchor
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
            NSLog("AskPosey history load failed: \(error)")
        }

        // Append the anchor marker for THIS invocation (unless we're
        // navigating to an existing one via Notes-tap-conversation).
        // Persist to SQLite so future opens see the full thread.
        appendCurrentInvocationAnchorMarkerIfNeeded(persist: true)
    }

    /// Build + append (and optionally persist) an anchor marker for
    /// the current invocation. Skipped when the caller passed an
    /// `initialScrollAnchorStorageID` — that signals navigation to an
    /// existing anchor row, not a fresh invocation.
    func appendCurrentInvocationAnchorMarkerIfNeeded(persist: Bool) {
        guard initialScrollAnchorStorageID == nil else { return }

        // Determine display text + scope for the marker. Passage
        // scope = full passage text. Document scope = document title
        // (fallback to "this document" if no title is available).
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

        // Captured reading offset at invocation — always populated
        // (passage scope mirrors anchor.plainTextOffset; doc scope
        // gets the active sentence offset from the caller).
        let offset = invocationReadingOffset ?? 0

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
        // Surface the storage id so the view's initial scroll lands
        // on the marker we just appended (default behavior — Notes
        // tap-conversation overrides via the init param).
        initialScrollAnchorStorageID = storageID

        guard persist, let db = databaseManager else { return }
        let stored = StoredAskPoseyTurn(
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
        do {
            try db.appendAskPoseyTurn(stored)
        } catch {
            NSLog("AskPosey anchor marker persist failed: \(error)")
        }
    }

    /// Translate a stored row into the in-memory message type. Returns
    /// nil for rows whose role string doesn't match (defensive — we
    /// haven't shipped non-user/assistant/anchor rows yet but defensive
    /// decoding is cheap).
    func translateStoredTurn(_ stored: StoredAskPoseyTurn) -> AskPoseyMessage? {
        guard let role = AskPoseyMessage.Role(rawValue: stored.role) else {
            return nil
        }
        // Reconstruct a stable UUID from the storage id when it's
        // UUID-shaped. Older rows without UUID-shaped ids fall back
        // to a fresh UUID — losing the ability to cross-reference
        // them but preserving SwiftUI Identifiable correctness.
        let messageID = UUID(uuidString: stored.id) ?? UUID()
        let isAnchor = (role == .anchor)
        return AskPoseyMessage(
            id: messageID,
            role: role,
            content: stored.content,
            isStreaming: false,
            timestamp: stored.timestamp,
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
    ///
    /// **2026-05-02 fix — front-matter injection for document-scoped
    /// invocations.** Real Q&A on a sample document ("Who are the
    /// authors?" on the AI Book Collaboration Project) revealed a
    /// systematic cosine-retrieval miss: meta-questions about a
    /// document ("who wrote it", "what is it about", "what's the
    /// abstract") rarely surface the title-page / front-matter
    /// content because the question's vocabulary
    /// ("authors / writers / abstract") doesn't share a semantic
    /// neighbourhood with how front matter is typically written
    /// ("by X with collaborators Y, Z; A Collaborative Exploration of…").
    /// When the invocation is document-scoped (anchor nil), we now
    /// always prepend the document's first 2 chunks as "front matter"
    /// candidates with relevance 1.0 — the budget enforcer keeps
    /// them by virtue of being top-of-list, and meta-questions get
    /// reliable grounding.
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

        // Front-matter injection for document-scoped invocations.
        // Always prepend the document's first 4 chunks so the prompt
        // sees the title page + table of contents + contributor list.
        // Two chunks (~900 chars at the default 450 char chunk size)
        // covered only the abstract on real-world tests; bumped to 4
        // (~1800 chars) so contributor names listed in the TOC also
        // make it in. Deduplicates against any cosine match for the
        // same chunk ID.
        var frontMatter: [RetrievedChunk] = []
        if anchor == nil, let db = databaseManager {
            let storedFront = (try? db.frontMatterChunks(for: documentID, limit: 4)) ?? []
            for stored in storedFront {
                let alreadyPresent = results.contains { $0.chunk.chunkIndex == stored.chunkIndex }
                if alreadyPresent { continue }
                frontMatter.append(RetrievedChunk(
                    chunkID: stored.chunkIndex,
                    startOffset: stored.startOffset,
                    text: stored.text,
                    relevance: 1.0
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
                text: result.chunk.text,
                relevance: result.similarity
            ))
        }
        // Front matter goes first — its synthetic relevance 1.0
        // makes it a budget-survivor by virtue of position-in-list
        // (the prompt builder iterates top-of-list and drops from
        // the bottom on overflow).
        return frontMatter + translated
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
                        NSLog("AskPosey: classifier refused; defaulting to .general intent")
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
