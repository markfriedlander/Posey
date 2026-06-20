import Foundation

// ========== BLOCK 01: UNIT EMBEDDING SERVICE - START ==========

/// Coordinates building + embedding the unit-anchored chunk set for
/// a document. Replaces `DocumentEmbeddingIndex.enqueueIndexing(_:)`
/// for the new architecture.
///
/// **Flow per call:**
///   1. Read units from the DB (atomic snapshot via
///      `databaseManager.units(for:)`).
///   2. Build chunks via `UnitEmbeddingChunker.chunks(for:units:)`.
///   3. Persist via `replaceAllUnitEmbeddingChunks` — atomic delete
///      + insert, triggers keep the FTS5 mirror in sync.
///   4. Asynchronously: walk every chunk's text through
///      `EmbeddingProvider.embed(_:as: .document)` and write the
///      vector back via `updateUnitEmbeddingChunkEmbedding`. Batched
///      so progress is reportable and the SQLite handle isn't held
///      across multi-second runs.
///
/// **Concurrency:** uses a serial actor so per-document enqueues
/// stack rather than race. Multiple documents can be in flight in
/// parallel from the actor's perspective; the actual embedding
/// work is bounded by `EmbeddingProvider`'s own thread-safety
/// (NSLock-serialized) and SQLite's single-threaded handle.
///
/// **Progress notifications.** Posts `Notification.Name.unit*`
/// notifications at start / progress / complete so
/// `IndexingTracker` (and the reader's "Still learning this
/// document — N%" banner) can reflect the embed fill state.
/// Posted on the main thread; cumulative `processed` + `total`
/// in userInfo. Total = chunks.count at start (every chunk row
/// is NULL at insert time and the fill loop processes all of
/// them).
///
/// 2026-05-23 — introduced in Step 8b. 2026-05-24 — Step 8f
/// follow-up: progress notifications wired (was previously
/// silent — the legacy `DocumentEmbeddingIndex` notifications
/// were torn out in 8f without a replacement).
actor UnitEmbeddingService {

    static let shared = UnitEmbeddingService()

    // MARK: - Notification API

    /// Posted on the main thread when a document's chunk fill
    /// begins. userInfo: `documentID` (UUID), `totalChunks` (Int).
    static let didStartNotification = Notification.Name("posey.unitEmbedding.didStart")
    /// Posted on the main thread after each batch of fills.
    /// userInfo: `documentID` (UUID), `processedChunks` (Int),
    /// `totalChunks` (Int).
    static let didProgressNotification = Notification.Name("posey.unitEmbedding.didProgress")
    /// Posted on the main thread when the fill loop exits, regardless
    /// of whether it succeeded fully or bailed on the empty-batch
    /// guard. userInfo: `documentID` (UUID), `processedChunks`
    /// (Int), `totalChunks` (Int).
    static let didCompleteNotification = Notification.Name("posey.unitEmbedding.didComplete")

    /// userInfo keys (shared across the three notifications).
    static let documentIDKey = "posey.unitEmbedding.documentID"
    static let totalChunksKey = "posey.unitEmbedding.totalChunks"
    static let processedChunksKey = "posey.unitEmbedding.processedChunks"

    /// 2026-06-19 (Mark) — chunking (string-split) stage, for the board pipeline
    /// view. A brief one-shot: didStart before the chunk-build, didFinish after.
    /// Only fires on the full-rebuild path (a resume skips re-chunking).
    static let chunkingDidStartNotification = Notification.Name("posey.unitEmbedding.chunkingDidStart")
    static let chunkingDidFinishNotification = Notification.Name("posey.unitEmbedding.chunkingDidFinish")

    /// Per-document in-flight marker. A second `enqueueIndexing`
    /// for the same documentID while the first is running short-
    /// circuits — the inflight worker re-snapshots units at start
    /// time anyway so a recent change is covered.
    private var inFlight: Set<UUID> = []

    private init() {}

    // MARK: - Public surface

    /// Rebuild the chunk set + embeddings for `documentID`. Returns
    /// after the chunk-table write commits; embedding fill happens
    /// asynchronously. Safe to call from importers, Tier 2 page
    /// swaps, Tier 3 token swaps, and re-import paths.
    ///
    /// `databaseManager` is expected to be the shared instance
    /// from `LibraryView`'s `AppEnvironment`; SQLite is single-
    /// threaded so all writes funnel through the same handle.
    func enqueueIndexing(documentID: UUID,
                         databaseManager: DatabaseManager,
                         forceRebuild: Bool = false) async {
        // 2026-06-18 — route into the single document-level serial queue so
        // concurrent imports can never stack heavy work on the device (the
        // 2026-06-17 thermal incident). The queue runs `indexAndWait` (below)
        // then RAPTOR for ONE document at a time. `databaseManager` is kept for
        // call-site compatibility; the queue uses the shared instance wired
        // into its `LiveDocumentIndexer` at launch.
        await DocumentIndexingQueue.shared.enqueue(documentID, forceRebuild: forceRebuild)
    }

    /// The awaitable embedding worker the `DocumentIndexingQueue` runs inside a
    /// document's serial slot. Builds the chunk set then embeds every leaf to
    /// completion, returning only when the fill finishes (or is cancelled).
    /// NOT for importers to call directly — they go through `enqueueIndexing`
    /// → the queue. Honors `Task` cancellation (the escape switch) at batch +
    /// chunk granularity inside `fillEmbeddings`.
    func indexAndWait(documentID: UUID,
                      databaseManager: DatabaseManager,
                      forceRebuild: Bool = false) async {
        // 2026-06-19 — RESUME-ON-PARTIAL. If chunk rows already exist and a
        // rebuild wasn't explicitly requested (REINDEX), DON'T re-chunk: the
        // re-chunk path (`replaceAllUnitEmbeddingChunks`) wipes ALL existing
        // embeddings and starts the fill from zero — which, for a large doc that
        // can't finish embedding in one foreground session (exactly the doc that
        // got interrupted), turns every relaunch into a from-scratch restart
        // that re-cooks the device and never completes. Instead we keep the
        // existing chunks/vectors and `fillEmbeddings` (which only touches NULL
        // rows) tops up the remainder, so progress accumulates across sessions.
        // Mark caught this: A Tale of Two Cities stalled at 116/2436 and read as
        // "ready". (Rule 10 — generalizes to ANY interrupted embed, not just the
        // launch sweep: a normal import killed mid-fill now also resumes.)
        let existingChunkCount = (try? await MainActor.run {
            try databaseManager.unitEmbeddingChunkCount(for: documentID)
        }) ?? 0
        let resume = !forceRebuild && existingChunkCount > 0

        let totalChunks: Int
        if resume {
            // Metadata extraction is idempotent (skips already-extracted); run it
            // in case the original pass was interrupted before it landed.
            Task { @MainActor in
                await DocumentMetadataExtractor.extractAndStoreIfNeeded(
                    documentID: documentID, databaseManager: databaseManager)
            }
            totalChunks = existingChunkCount
            dbgLog("UnitEmbeddingService: RESUME doc=%@ existingChunks=%d (skip re-chunk, fill NULLs only)",
                   documentID.uuidString, existingChunkCount)
        } else {
            // FULL (re)build — fresh import, or an explicit REINDEX/forceRebuild.
            // Snapshot units. This is a synchronous SQL read; the
            // DatabaseManager is currently main-actor-bound but the
            // actor hop is implicit at the call site.
            let units: [ContentUnit]
            let skipOffset: Int
            let skipSource: String
            do {
                (units, skipOffset, skipSource) = try await MainActor.run {
                    let u = try databaseManager.units(for: documentID)
                    let doc = (try? databaseManager.documents())?
                        .first(where: { $0.id == documentID })
                    return (u, doc?.playbackSkipUntilOffset ?? 0, doc?.skipSource ?? "")
                }
            } catch {
                return
            }

            guard !units.isEmpty else { return }

            // 2026-05-29 — Bibliographic metadata (author + publication year)
            // → structured `metadata_*` columns. Central import hook (every
            // format reaches here). Non-blocking + independent of embedding;
            // idempotent (skips already-extracted docs). Revives the
            // bibliographic half of the 8f-removed DocumentMetadataService so
            // metadata questions answer from structured fields rather than
            // front-matter retrieval (the prerequisite for excluding front
            // matter from RAG).
            Task { @MainActor in
                await DocumentMetadataExtractor.extractAndStoreIfNeeded(
                    documentID: documentID, databaseManager: databaseManager)
            }

            // 2026-05-29 — Front-matter exclusion (RAG). Drop editorial front
            // matter (prefaces, title pages) that falls before the confident
            // content-start so it can't be retrieved and served as if it were
            // the work — the Saintsbury-preface contamination caught by real
            // reading (#2 Finding 3). Safe NOW because author/year answer from
            // structured metadata (8015eb4), not front-matter prose. Only fires
            // on a positive content-start detection (gutenberg/heuristic).
            let chunkUnits = UnitEmbeddingChunker.excludingFrontMatter(
                units, skipOffset: skipOffset, skipSource: skipSource)

            // Chunking (string-split) stage — board pipeline view. Brief; clears
            // right after the atomic persist.
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Self.chunkingDidStartNotification, object: nil,
                    userInfo: [Self.documentIDKey: documentID])
            }

            // Build chunks (CPU-bound, but small).
            let chunks = UnitEmbeddingChunker.chunks(for: documentID, units: chunkUnits)

            // Persist atomically. The FTS5 triggers fire as part of
            // the same transaction so the mirror is consistent.
            do {
                try await MainActor.run {
                    try databaseManager.replaceAllUnitEmbeddingChunks(chunks, for: documentID)
                }
            } catch {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Self.chunkingDidFinishNotification, object: nil,
                        userInfo: [Self.documentIDKey: documentID])
                }
                return
            }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Self.chunkingDidFinishNotification, object: nil,
                    userInfo: [Self.documentIDKey: documentID])
            }
            totalChunks = chunks.count
        }

        // Post .didStart so the indexing banner can show. Total = chunk count
        // (resume: existing rows; rebuild: freshly-built); fillEmbeddings reports
        // `processed` against this denominator.
        await MainActor.run {
            NotificationCenter.default.post(
                name: Self.didStartNotification,
                object: nil,
                userInfo: [
                    Self.documentIDKey: documentID,
                    Self.totalChunksKey: totalChunks
                ]
            )
        }

        // Fill embeddings INLINE, awaiting completion — the queue serializes,
        // so exactly one fill runs at a time and `processedSoFar` is no longer
        // shared across concurrent fills (fixes the clobbered-counter bug that
        // showed "0% then 3%" during the 2026-06-17 incident).
        await fillEmbeddings(for: documentID, totalChunks: totalChunks, databaseManager: databaseManager)
    }

    // MARK: - Embedding fill loop

    /// Walk every NULL-embedding row for `documentID` and embed it
    /// under the active backend. Batched to keep memory bounded
    /// and allow other actor work to interleave.
    ///
    /// **Termination:** if the active backend can't produce a
    /// vector (asset still downloading, transient failure), the
    /// loop bails after `maxNullBatches` consecutive batches that
    /// produced zero successful embeddings. The leftover NULL rows
    /// stay NULL; the next enqueueIndexing call retries from
    /// where we stopped. Without this guard a perma-nil backend
    /// would spin the loop forever pulling the same NULL rows.
    private func fillEmbeddings(for documentID: UUID,
                                totalChunks: Int,
                                databaseManager: DatabaseManager) async {
        defer {
            inFlight.remove(documentID)
            // Always post a terminal .didComplete so any UI banner
            // subscribed via IndexingTracker can clear, even when
            // the empty-batch guard bailed early. Snapshot the
            // running `processed` count for the userInfo so the
            // last reported value matches the terminal one.
            let processed = processedSoFar
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: Self.didCompleteNotification,
                    object: nil,
                    userInfo: [
                        Self.documentIDKey: documentID,
                        Self.processedChunksKey: processed,
                        Self.totalChunksKey: totalChunks
                    ]
                )
            }
            // 2026-06-18 — RAPTOR is no longer triggered here. The
            // DocumentIndexingQueue's LiveDocumentIndexer builds the summary
            // tree right after this embed completes, INSIDE the same document's
            // serial slot, so embed+RAPTOR for one document finish before the
            // next document starts (this was a fire-and-forget `enqueue` that
            // let doc A's RAPTOR overlap doc B's embed — part of the 2026-06-17
            // interleaving). RaptorTreeService still self-gates on AFM + a
            // minimum leaf count, so the build stays a cheap no-op when unmet.
        }

        let batchSize = 32
        let maxNullBatches = 2
        var consecutiveEmptyBatches = 0
        // Running tally for progress posts. We can't trust
        // `total - nullCount` mid-loop because the same set of
        // NULL rows can include leftovers from a prior failed
        // pass; instead we count successful writes this run.
        processedSoFar = 0

        while true {
            // Cooperative cancellation (escape switch / per-doc cancel): the
            // queue cancels the in-flight document's Task; bail promptly.
            if Task.isCancelled { return }
            let batch: [DatabaseManager.UnitEmbeddingChunkNeedingEmbedding]
            do {
                // 2026-06-12 (Mark — background document processing must NEVER
                // touch the read-along's main thread): the per-batch READ had no
                // reason to hop MainActor either — same justification as the
                // 2026-05-28 write-fix below (DatabaseManager is @unchecked
                // Sendable; SQLite is SQLITE_THREADSAFE=1, serialized internally).
                // Reading directly from this actor's isolation removes the LAST
                // main-actor touch in the steady embedding loop, so background
                // indexing can no longer micro-stutter a reader's TTS highlight.
                batch = try databaseManager.unitEmbeddingChunksNeedingEmbedding(
                    for: documentID, limit: batchSize
                )
            } catch {
                return
            }
            if batch.isEmpty { return }

            // 2026-05-28 — Mark caught: indexing was blocking UI on
            // phone. Per-row `try await MainActor.run { db.update }`
            // hammered the main actor with 11K+ hops, queuing antenna
            // requests behind every chunk write.
            //
            // Real fix: DatabaseManager is `@unchecked Sendable`
            // (claims its own thread-safety; SQLite is configured
            // SQLITE_THREADSAFE=1 = serialized internally), and
            // UnitEmbeddingService is already an actor. There is
            // NO reason to hop to MainActor for the DB write — call
            // it directly from this actor's isolation. Main thread
            // stays completely free of indexer pressure, no batching
            // tricks needed.
            //
            // Embedding still runs off-actor (CPU-bound; Task.detached
            // priority utility), then the result is written from the
            // actor's context directly. SQLite serializes internally.
            var successesThisBatch = 0
            for row in batch {
                if Task.isCancelled { return }
                // Global serial lane — chunk embedding is heavy background
                // compute. Routing each embed through the lane (instead of a
                // free Task.detached) makes it serialize app-wide with OCR /
                // AFM / RAPTOR, so only one heavy op runs at a time. Still
                // off-main (the lane is a plain actor). DB write below stays
                // on this actor's isolation (off-main).
                let text = row.text
                let vector = await HeavyWorkLane.shared.run(label: "embed") {
                    EmbeddingProvider.shared.embed(text, as: .document)
                }
                guard let vector else { continue }
                do {
                    try databaseManager.updateUnitEmbeddingChunkEmbedding(
                        id: row.id, embedding: vector
                    )
                    successesThisBatch += 1
                    processedSoFar += 1
                } catch {
                    // Row stays NULL; continue.
                }
                // Pillar 2 — proactive thermal pacing. A small yield after each
                // heavy embed so the chip never runs at a 100% duty cycle (a
                // single long doc's ~hundreds of back-to-back embeds is what
                // cooks the device, even when serialized); the yield scales up
                // under thermal pressure and fully pauses at `.critical`. Honors
                // cancellation, so the escape switch isn't delayed.
                await ThermalGovernor.shared.pace()
            }

            // Post .didProgress per batch (not per row — would
            // flood the main queue on long docs).
            let snapshotProcessed = processedSoFar
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Self.didProgressNotification,
                    object: nil,
                    userInfo: [
                        Self.documentIDKey: documentID,
                        Self.processedChunksKey: snapshotProcessed,
                        Self.totalChunksKey: totalChunks
                    ]
                )
            }

            if successesThisBatch == 0 {
                consecutiveEmptyBatches += 1
                if consecutiveEmptyBatches >= maxNullBatches { return }
            } else {
                consecutiveEmptyBatches = 0
            }
        }
    }

    /// Per-document running tally of successful embedding writes
    /// in the current fill loop. Read by the terminal .didComplete
    /// post (defer block) so the final progress value reflects
    /// reality even when the loop bails on the empty-batch guard.
    /// Reset to 0 at the start of each fillEmbeddings call.
    private var processedSoFar: Int = 0
}

// ========== BLOCK 01: UNIT EMBEDDING SERVICE - END ==========
