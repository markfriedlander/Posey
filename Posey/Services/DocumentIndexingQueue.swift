import Foundation

// ========== BLOCK 01: DOCUMENT INDEXER SEAM - START ==========

/// Which pass of the pipeline a document is in. Embedding (tier 1) makes a
/// document Ask-able; RAPTOR (tier 2) is the lower-priority "improves in the
/// background" deepening.
enum DocumentIndexingPhase: Sendable {
    case embedding
    case raptor
}

/// The per-document indexing work that `DocumentIndexingQueue` serializes,
/// split into the two passes so the queue can run ALL embeddings before ANY
/// RAPTOR (see the queue's two-priority model below).
///
/// **Why a seam.** Production wires this to the real pipeline — `embed` builds
/// chunks + embeds every leaf (`UnitEmbeddingService`), `buildRaptor` builds the
/// summary tree (`RaptorTreeService`). Tests inject a fake to prove the queue's
/// ordering and one-at-a-time guarantee WITHOUT a database or any model, so the
/// central safety property is verifiable entirely off-device.
///
/// **Contract.** Each method MUST run its pass to completion and return only
/// when done (or cancelled). The queue awaits that return before moving on, so
/// only one pass of one document runs at any instant.
///
/// **Cooperative cancellation.** Implementations MUST honor `Task` cancellation:
/// check `Task.isCancelled` at fine granularity (every chunk / between
/// summaries) and return promptly. The escape switch and per-document cancel
/// both work by cancelling the in-flight `Task`, so a halt only lands as fast as
/// the implementation checks — fine-grained checks are what let a halt land in
/// ~1–2s even under sustained load (the antenna `RESET_ALL` failure during the
/// 2026-06-17 incident was that it had no fast cooperative-cancel path).
protocol DocumentIndexer: Sendable {
    /// `forceRebuild == false` (the default for imports + the launch resume):
    /// if the document already has chunk rows, RESUME — fill only the NULL
    /// embeddings, leaving existing chunks/vectors intact (so a large doc
    /// interrupted mid-embed accumulates progress across sessions instead of
    /// restarting from zero). `forceRebuild == true` (REINDEX): re-chunk from
    /// scratch regardless. (2026-06-19)
    func embed(_ documentID: UUID, forceRebuild: Bool) async
    func buildRaptor(_ documentID: UUID) async
}

// ========== BLOCK 01: DOCUMENT INDEXER SEAM - END ==========


// ========== BLOCK 02: DOCUMENT INDEXING QUEUE - START ==========

/// The single front door for ALL background document indexing — the
/// document-level serial gate.
///
/// **Why this exists (2026-06-18, post-incident).** `HeavyWorkLane` serializes
/// heavy compute at *single-op* granularity (one embed / one summary app-wide),
/// which prevents memory-jetsam stacking but lets documents **interleave**
/// chunk-by-chunk, and it has no admission control. On 2026-06-17 a three-book
/// batch import poured ~5,000 embed ops + RAPTOR through the lane back-to-back
/// and the phone overheated to unusable. The lane's guarantee is "one op at a
/// time," never "okay to dump 5,000 ops." This queue is the missing admission
/// layer: **exactly one document-pass runs at a time**, so no operator action
/// (antenna or file-picker, 1 doc or 10) can stack work on the device.
/// `HeavyWorkLane` stays underneath as defense-in-depth.
///
/// **Two-priority model (2026-06-18, Mark).** To get the user the best
/// experience fastest while respecting hardware, work runs in two tiers, both
/// drained one-document-at-a-time through this single gate:
///   1. **Embedding (high priority)** — embed every document, in received
///      order, so each becomes Ask-able as soon as ITS embedding finishes. The
///      whole library is usable before any deepening starts.
///   2. **RAPTOR (low priority)** — only once the embed lane is empty, build
///      summary trees for documents that lack one, in received order.
/// A document imported mid-RAPTOR joins the embed lane and is picked up at the
/// next document boundary (we never interrupt a pass mid-document), so embedding
/// always preempts deepening. This is purely a reordering — still exactly one
/// heavy pass at a time, so the thermal/no-saturation guarantee is unchanged.
///
/// **State model.** Two FIFO lanes (`embedQueue` / `raptorQueue`), a
/// `currentDocumentID` + `currentPhase`, a `cancelled` set, a `draining`
/// re-entrancy guard, and `currentJob` (the in-flight `Task`, held so the escape
/// switch / per-doc cancel can halt it mid-pass).
actor DocumentIndexingQueue {

    // MARK: Shared instance

    /// App-wide singleton. Configured once at launch via `configure(indexer:)`.
    /// Before configuration, enqueued work runs as an instant no-op (nothing to
    /// index without a wired pipeline), so it is always safe to call.
    static let shared = DocumentIndexingQueue()

    // MARK: Change notification (drives the library status indicators / Pillar 4b)

    /// Posted (on the main actor) whenever the lane state transitions — enqueue,
    /// drain step start/finish, cancel, expunge. Lets `IndexingTracker` mirror
    /// the queue so a library card can show its precise "Queued #k" position
    /// without the view ever touching this actor. userInfo: `currentDocumentID`
    /// (UUID, omitted when idle), `embedQueue` ([UUID]), `raptorQueue` ([UUID]).
    static let queueDidChangeNotification = Notification.Name("posey.indexingQueue.didChange")
    static let currentDocumentIDKey = "posey.indexingQueue.currentDocumentID"
    static let embedQueueKey = "posey.indexingQueue.embedQueue"
    static let raptorQueueKey = "posey.indexingQueue.raptorQueue"

    /// UserDefaults key for the master "Allow background preparation" switch (the
    /// Preparation board's control). Missing = enabled (preserves prior behavior).
    /// It gates EXECUTION only: OFF holds the run loop (nothing runs / no heat,
    /// even across a relaunch) while the queue still FILLS to show pending work.
    static let backgroundPrepDefaultsKey = "posey.backgroundPrepEnabled"
    /// Nonisolated read of the persisted switch — used to seed the actor's gate at
    /// construction (and available to any non-actor caller). Missing → true.
    static var backgroundPrepEnabledDefault: Bool {
        UserDefaults.standard.object(forKey: backgroundPrepDefaultsKey) as? Bool ?? true
    }

    // MARK: Injected work

    private var indexer: DocumentIndexer?

    // MARK: State

    /// Tier-1 FIFO: documents awaiting embedding (high priority).
    private var embedQueue: [UUID] = []
    /// Tier-2 FIFO: documents awaiting a RAPTOR build (low priority).
    private var raptorQueue: [UUID] = []
    /// The document currently being worked, or nil if idle.
    private var currentDocumentID: UUID?
    /// The pass the current document is in.
    private var currentPhase: DocumentIndexingPhase?
    /// IDs cancelled (per-doc delete / escape switch) — checked before work and
    /// before scheduling the RAPTOR follow-up.
    private var cancelled: Set<UUID> = []
    /// IDs whose next embed pass must RE-CHUNK from scratch (REINDEX), rather
    /// than resume-fill existing chunks. Populated by `enqueue(_:forceRebuild:)`,
    /// consumed (and cleared) when the embed pass runs. (2026-06-19)
    private var forceRebuildIDs: Set<UUID> = []
    /// True while `drainQueue` is iterating — only one drain loop at a time.
    private var draining = false
    /// The `Task` running the in-flight pass. Cancelled by the escape switch /
    /// per-doc cancel so a halt lands fast even mid-pass.
    private var currentJob: Task<Void, Never>?

    /// Master "Allow background preparation" gate (the board toggle / launch
    /// guard). Checked at the top of the run loop: OFF stops STARTING new passes
    /// (the current pass finishes, then the loop holds with queues intact); ON
    /// re-kicks the drain. This is user INTENT — thermal pacing still governs HOW
    /// fast an allowed pass actually runs (everything stays subject to the
    /// governor; the user never bypasses the safety valve).
    private var backgroundPrepEnabled: Bool = DocumentIndexingQueue.backgroundPrepEnabledDefault

    /// Internal (not private) so `@testable` unit tests can construct a fresh,
    /// isolated instance per test. Production always uses `.shared`.
    init() {}

    // MARK: Configuration

    /// Wire the live per-document pipeline. Called once at launch.
    ///
    /// 2026-06-19 — the antenna server starts from `LibraryView.onAppear`,
    /// which is UNORDERED relative to the `PoseyApp.task` that calls this. An
    /// antenna `REINDEX`/import that lands in that startup window enqueues
    /// against a nil indexer. Previously `drainQueue` consumed those items as
    /// no-ops and discarded them silently — the document sat at "Preparing"
    /// forever with no recovery (and a transient escape glyph as the no-op job
    /// flashed through). Now `drainQueue` DEFERS while the indexer is nil and
    /// we re-kick it here, so any work enqueued before wiring runs the instant
    /// the indexer lands. Self-healing instead of silently lossy.
    func configure(indexer: DocumentIndexer) {
        self.indexer = indexer
        dbgLog("DocumentIndexingQueue: configured")
        // Drain anything that enqueued before the indexer was wired.
        if !embedQueue.isEmpty || !raptorQueue.isEmpty {
            dbgLog("DocumentIndexingQueue: configure — draining %d pre-wire enqueue(s) (embed=%d raptor=%d)",
                   embedQueue.count + raptorQueue.count, embedQueue.count, raptorQueue.count)
            Task { await drainQueue() }
        }
    }

    // MARK: Public API

    /// Enqueue a document for indexing, starting at the EMBED pass (tier 1).
    /// Idempotent. A pending RAPTOR for the same document is superseded — a
    /// (re-)embed rebuilds the chunks, so its tree must be rebuilt afterward.
    func enqueue(_ documentID: UUID, forceRebuild: Bool = false) {
        cancelled.remove(documentID)
        // forceRebuild (REINDEX) wins if requested; a normal/resume enqueue never
        // CLEARS a pending forceRebuild (so REINDEX intent survives a coincident
        // re-enqueue). Cleared after the embed pass consumes it (drainQueue).
        if forceRebuild { forceRebuildIDs.insert(documentID) }
        raptorQueue.removeAll { $0 == documentID }   // re-embed supersedes a pending tree
        if currentDocumentID == documentID && currentPhase == .embedding { return }
        if embedQueue.contains(documentID) { return }
        embedQueue.append(documentID)
        dbgLog("DocumentIndexingQueue: enqueued(embed) %@ (embed=%d raptor=%d)",
               documentID.uuidString, embedQueue.count, raptorQueue.count)
        postChange()
        Task { await drainQueue() }
    }

    /// Enqueue a document directly into the RAPTOR pass (tier 2) — for the
    /// on-launch sweep of documents that are already embedded but have no tree
    /// yet. Skips the redundant embed no-op. Idempotent.
    func enqueueRaptorOnly(_ documentID: UUID) {
        cancelled.remove(documentID)
        if currentDocumentID == documentID && currentPhase == .raptor { return }
        if raptorQueue.contains(documentID) || embedQueue.contains(documentID) { return }
        raptorQueue.append(documentID)
        dbgLog("DocumentIndexingQueue: enqueued(raptor) %@ (embed=%d raptor=%d)",
               documentID.uuidString, embedQueue.count, raptorQueue.count)
        postChange()
        Task { await drainQueue() }
    }

    /// Cancel any queued or in-flight work for one document (document delete).
    /// If it is the in-flight document, its `Task` is cancelled so it stops
    /// promptly; queued entries (either lane) are removed.
    func cancel(_ documentID: UUID) {
        cancelled.insert(documentID)
        embedQueue.removeAll { $0 == documentID }
        raptorQueue.removeAll { $0 == documentID }
        if currentDocumentID == documentID { currentJob?.cancel() }
        dbgLog("DocumentIndexingQueue: cancelled %@", documentID.uuidString)
        postChange()
    }

    /// Flip the master "Allow background preparation" switch (the board toggle).
    /// OFF holds the line — no NEW pass starts; the current document finishes,
    /// then the loop stops with both queues intact. ON resumes by re-kicking the
    /// drain. Persisted so a launch honors it (the auto-resume guard). Does NOT
    /// cancel the in-flight pass — it stops AFTER the current document. Thermal
    /// pacing is unaffected: it still governs an allowed pass's speed.
    func setBackgroundPrep(_ enabled: Bool) {
        guard backgroundPrepEnabled != enabled else { return }
        backgroundPrepEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DocumentIndexingQueue.backgroundPrepDefaultsKey)
        dbgLog("DocumentIndexingQueue: background prep %@", enabled ? "ENABLED" : "DISABLED")
        if enabled { Task { await drainQueue() } }
    }

    /// THE ESCAPE SWITCH. Halt all background indexing immediately: cancel the
    /// in-flight document's `Task` (stops heavy work within a fine-grained
    /// cancellation check — ~1–2s even under load) and clear BOTH lanes.
    ///
    /// Returns every affected document ID (the in-flight one plus everything
    /// queued in either lane) so the caller can discard partial index state and
    /// re-index later through THIS same safe queue. By design it does NOT
    /// auto-resume — the device is hot when the user taps it. Document text is
    /// untouched (written atomically at import), so only the index is expunged.
    @discardableResult
    func expungeAll() -> [UUID] {
        var affected: [UUID] = []
        if let current = currentDocumentID { affected.append(current) }
        affected.append(contentsOf: embedQueue)
        affected.append(contentsOf: raptorQueue)
        var seen = Set<UUID>()
        affected = affected.filter { seen.insert($0).inserted }   // dedupe, keep order
        for id in affected { cancelled.insert(id) }
        embedQueue.removeAll()
        raptorQueue.removeAll()
        currentJob?.cancel()
        dbgLog("DocumentIndexingQueue: EXPUNGE — halted + cleared %d document(s)",
               affected.count)
        postChange()
        return affected
    }

    /// Ordered snapshot for the queue-aware status surface (Pillar 4 / library
    /// indicators) and diagnostics: the document currently working and its pass,
    /// plus both lanes in the exact order they will run.
    func snapshot() -> (current: UUID?, phase: DocumentIndexingPhase?,
                        embedQueue: [UUID], raptorQueue: [UUID]) {
        (currentDocumentID, currentPhase, embedQueue, raptorQueue)
    }

    /// Broadcast the current lane state to the main-actor mirror
    /// (`IndexingTracker`) so library cards can show a live "Queued #k". Snapshot
    /// the Sendable values here, then post inside a main-actor `Task` (the actor
    /// methods that call this are synchronous; the post must hop to the main
    /// actor where the tracker's Combine sinks deliver). Values are plain
    /// value-type UUIDs, so the capture is concurrency-safe.
    private func postChange() {
        let current = currentDocumentID
        let embed = embedQueue
        let raptor = raptorQueue
        Task { @MainActor in
            var info: [AnyHashable: Any] = [
                DocumentIndexingQueue.embedQueueKey: embed,
                DocumentIndexingQueue.raptorQueueKey: raptor,
            ]
            if let current { info[DocumentIndexingQueue.currentDocumentIDKey] = current }
            NotificationCenter.default.post(
                name: DocumentIndexingQueue.queueDidChangeNotification,
                object: nil, userInfo: info)
        }
    }

    // MARK: Drain loop

    /// Run document-passes one at a time, embed lane fully before raptor lane.
    /// Re-entrant-safe via `draining`. The in-flight pass runs in its own `Task`
    /// (`currentJob`) so a cancel/expunge can stop it mid-pass while this loop is
    /// suspended on `await job.value`.
    private func drainQueue() async {
        if draining { return }
        // 2026-06-19 — DEFER while the indexer isn't wired yet. Leaving the
        // lanes intact (rather than dequeuing into a no-op job) is what makes
        // a pre-wire enqueue survive: `configure(indexer:)` re-kicks this drain
        // once the indexer lands. Without this guard the loop below would
        // `removeFirst()` the item, run an empty `if let work` no-op, and drop
        // it — the silent "stuck at Preparing" failure (antenna racing launch).
        guard indexer != nil else {
            dbgLog("DocumentIndexingQueue: drain deferred — indexer not configured (embed=%d raptor=%d)",
                   embedQueue.count, raptorQueue.count)
            return
        }
        draining = true
        defer { draining = false }

        while !embedQueue.isEmpty || !raptorQueue.isEmpty {
            // Master switch (user intent): OFF holds the line BETWEEN documents —
            // leave both queues intact and stop; re-enabling re-kicks this drain.
            // (Thermal pacing is separate and governs an ALLOWED pass's speed.)
            if !backgroundPrepEnabled {
                dbgLog("DocumentIndexingQueue: held — background prep disabled (embed=%d raptor=%d)",
                       embedQueue.count, raptorQueue.count)
                break
            }
            // Embedding always outranks RAPTOR — a newly imported document
            // (embed lane) preempts pending deepening at this boundary.
            let id: UUID
            let phase: DocumentIndexingPhase
            if !embedQueue.isEmpty {
                id = embedQueue.removeFirst(); phase = .embedding
            } else {
                id = raptorQueue.removeFirst(); phase = .raptor
            }
            if cancelled.contains(id) { cancelled.remove(id); continue }

            currentDocumentID = id
            currentPhase = phase
            postChange()
            dbgLog("DocumentIndexingQueue: RUN %@ %@ (embed=%d raptor=%d)",
                   phase == .embedding ? "embed" : "raptor",
                   id.uuidString, embedQueue.count, raptorQueue.count)
            let work = indexer
            // Consume the force-rebuild flag for this embed pass (REINDEX);
            // a normal/launch-resume enqueue leaves it false → resume-fill.
            let forceRebuild = (phase == .embedding) && forceRebuildIDs.contains(id)
            if phase == .embedding { forceRebuildIDs.remove(id) }
            let job = Task {
                if let work {
                    switch phase {
                    case .embedding: await work.embed(id, forceRebuild: forceRebuild)
                    case .raptor:    await work.buildRaptor(id)
                    }
                }
            }
            currentJob = job
            await job.value
            currentJob = nil
            currentDocumentID = nil
            currentPhase = nil

            // After a successful EMBED, schedule this document's RAPTOR pass
            // (low priority) — unless it was cancelled mid-embed.
            if phase == .embedding && !cancelled.contains(id) {
                raptorQueue.append(id)
            }
            cancelled.remove(id)
            postChange()
        }
        // Loop fully drained — broadcast the idle state so cards clear "Queued".
        postChange()
    }
}

// ========== BLOCK 02: DOCUMENT INDEXING QUEUE - END ==========


// ========== BLOCK 03: LIVE DOCUMENT INDEXER - START ==========

/// Production `DocumentIndexer`: `embed` runs the chunk-build + leaf embedding
/// (`UnitEmbeddingService.indexAndWait`); `buildRaptor` runs the summary-tree
/// build (`RaptorTreeService.build`). The queue owns the ordering (all embeds
/// before any RAPTOR), so neither method triggers the other — this is what
/// moved embed→RAPTOR sequencing out of `fillEmbeddings`' fire-and-forget defer.
struct LiveDocumentIndexer: DocumentIndexer {
    let databaseManager: DatabaseManager

    func embed(_ documentID: UUID, forceRebuild: Bool) async {
        await UnitEmbeddingService.shared.indexAndWait(
            documentID: documentID, databaseManager: databaseManager,
            forceRebuild: forceRebuild)
    }

    func buildRaptor(_ documentID: UUID) async {
        if Task.isCancelled { return }
        // Self-gates on AFM + minimum leaf count, so a cheap no-op when unmet.
        await RaptorTreeService.shared.build(documentID)
    }
}

// ========== BLOCK 03: LIVE DOCUMENT INDEXER - END ==========
