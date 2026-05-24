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
/// **No notifications yet.** The legacy `DocumentEmbeddingIndex`
/// posts `.documentIndexingDidStart/Progress/Complete`
/// notifications that the IndexingTracker / UI consume. During the
/// 8b-8e rollout the legacy path keeps posting those, and the new
/// service runs silently. 8e wires the new service to the UI;
/// 8f tears the legacy notifications down.
///
/// 2026-05-23 — introduced as part of the Hal-based Ask Posey
/// rebuild (Step 8b).
actor UnitEmbeddingService {

    static let shared = UnitEmbeddingService()

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
                         databaseManager: DatabaseManager) async {
        // Snapshot units. This is a synchronous SQL read; the
        // DatabaseManager is currently main-actor-bound but the
        // actor hop is implicit at the call site.
        let units: [ContentUnit]
        do {
            units = try await MainActor.run {
                try databaseManager.units(for: documentID)
            }
        } catch {
            return
        }

        guard !units.isEmpty else { return }

        // Build chunks (CPU-bound, but small).
        let chunks = UnitEmbeddingChunker.chunks(for: documentID, units: units)

        // Persist atomically. The FTS5 triggers fire as part of
        // the same transaction so the mirror is consistent.
        do {
            try await MainActor.run {
                try databaseManager.replaceAllUnitEmbeddingChunks(chunks, for: documentID)
            }
        } catch {
            return
        }

        // Drop the in-flight marker if any, then start the embed
        // fill. The fill is its own actor-isolated method so a
        // second enqueue won't double-start it.
        if inFlight.contains(documentID) { return }
        inFlight.insert(documentID)
        Task { await self.fillEmbeddings(for: documentID, databaseManager: databaseManager) }
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
                                databaseManager: DatabaseManager) async {
        defer { inFlight.remove(documentID) }

        let batchSize = 32
        let maxNullBatches = 2
        var consecutiveEmptyBatches = 0

        while true {
            let batch: [DatabaseManager.UnitEmbeddingChunkNeedingEmbedding]
            do {
                batch = try await MainActor.run {
                    try databaseManager.unitEmbeddingChunksNeedingEmbedding(
                        for: documentID, limit: batchSize
                    )
                }
            } catch {
                return
            }
            if batch.isEmpty { return }

            // Embed off the main actor; write back on main.
            var successesThisBatch = 0
            for row in batch {
                let vector = await Task.detached(priority: .utility) {
                    EmbeddingProvider.shared.embed(row.text, as: .document)
                }.value

                if let vector = vector {
                    do {
                        try await MainActor.run {
                            try databaseManager.updateUnitEmbeddingChunkEmbedding(
                                id: row.id, embedding: vector
                            )
                        }
                        successesThisBatch += 1
                    } catch {
                        // Row stays NULL; continue.
                    }
                }
            }

            if successesThisBatch == 0 {
                consecutiveEmptyBatches += 1
                if consecutiveEmptyBatches >= maxNullBatches { return }
            } else {
                consecutiveEmptyBatches = 0
            }
        }
    }
}

// ========== BLOCK 01: UNIT EMBEDDING SERVICE - END ==========
