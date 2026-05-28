import Foundation
import Combine

// ========== BLOCK 01: EMBEDDER MIGRATION COORDINATOR - START ==========

/// Orchestrates the swap between two embedding backends. The
/// invariant being enforced: at all times, every row in
/// `unit_embedding_chunks` is either embedded in the active
/// backend's vector space, or has `embedding = NULL` and is
/// awaiting refill by this coordinator.
///
/// Mirrors Hal Universal's `EmbedderMigrationCoordinator` shape:
/// one ObservableObject + one `Phase` enum + one `currentPhase`
/// publisher. SwiftUI re-renders the migration UI as the phase
/// changes.
///
/// The full swap is a three-step process:
///   1. **Download** (if the target backend needs an asset that
///      isn't on disk). NLContextual is OS-built-in and skips
///      this; Nomic requires a ~522 MB download.
///   2. **Switch + wipe.** Flip the UserDefaults key, NULL every
///      chunk's embedding, warm-load the new backend.
///   3. **Re-embed.** Walk every NULL chunk in `(document_id,
///      chunk_index)` order, embed the text under the new
///      backend, write the vector back.
///
/// Cancellation is supported between phases — the worker checks
/// `isCancelled` at every checkpoint and bails to `.cancelled`.
/// Mid-row failures land in `.error(String)` for the user to
/// dismiss; the coordinator leaves rows partially migrated
/// (some NULL, some embedded in the new space) and a subsequent
/// `retry` re-runs the re-embed phase from where it left off.
///
/// 2026-05-23 — introduced as part of the Hal-based Ask Posey
/// rebuild (Step 8a). Live behavior arrives once the chunker
/// (8b) populates `unit_embedding_chunks` with rows worth
/// migrating; until then the coordinator is wired but the
/// re-embed phase has zero work to do.
@MainActor
final class EmbedderMigrationCoordinator: ObservableObject {

    /// State machine for the swap. SwiftUI bindings drive the
    /// migration UI off this single enum.
    enum Phase: Equatable, Sendable {
        case idle
        case downloading(modelID: String, progressFraction: Double)
        case switching
        case migrating(processed: Int, total: Int)
        case done(reEmbedded: Int)
        case cancelled
        case error(String)
    }

    /// Process-wide singleton. The state machine is single-
    /// owner by construction (only one swap can be in flight at
    /// a time).
    static let shared = EmbedderMigrationCoordinator()

    @Published private(set) var currentPhase: Phase = .idle

    private var cancelRequested: Bool = false
    private var activeWorker: Task<Void, Never>?

    private init() {}

    // MARK: - Public surface

    /// Begin the swap to `target`. If already in flight, this
    /// call is a no-op. Returns immediately; SwiftUI observers
    /// see phase changes as the worker progresses.
    func beginSwitch(to target: EmbeddingBackend, database: DatabaseManager) {
        guard activeWorker == nil else { return }
        cancelRequested = false
        let worker = Task { [weak self] in
            await self?.runSwitch(to: target, database: database)
            await MainActor.run { self?.activeWorker = nil }
        }
        activeWorker = worker
    }

    /// Cancel the in-flight swap (if any). Safe to call at any
    /// time; transitions to `.cancelled` at the next checkpoint.
    func cancel() {
        cancelRequested = true
    }

    /// Reset the coordinator to `.idle` after the user dismisses
    /// a terminal phase (`.done`, `.cancelled`, `.error`). No-op
    /// in transient phases (the worker controls those).
    func acknowledge() {
        switch currentPhase {
        case .done, .cancelled, .error:
            currentPhase = .idle
        default:
            break
        }
    }

    // MARK: - Worker

    private func runSwitch(to target: EmbeddingBackend, database: DatabaseManager) async {
        // Phase 1 — Download.
        //
        // NLContextual: OS-built-in; the embedder framework
        // requests assets transparently on first use. No
        // orchestration needed here.
        //
        // Nomic (Step 8h, live): `EmbeddingProvider.shared.warmUp()`
        // below triggers `NomicBert.loadModelBundle(from: repoID)`
        // on a background task, which does the HuggingFace fetch
        // itself. We don't drive progress here — the picker UI
        // reports `.switching` until `isLoaded` flips. A polish
        // pass can wire HuggingFace's progress reporter into a
        // `.downloading` phase later.

        if cancelRequested { currentPhase = .cancelled; return }

        // Phase 2 — Switch + wipe. Atomic from the app's POV:
        // flip UserDefaults, NULL every row in one statement.
        currentPhase = .switching
        UserDefaults.standard.set(target.rawValue, forKey: EmbeddingBackend.defaultsKey)

        // Warm the new backend before we start the re-embed loop
        // so the first embed call doesn't pay the full load cost
        // serialized on the migration's critical path.
        EmbeddingProvider.shared.warmUp()

        do {
            try database.nullAllUnitEmbeddingChunkEmbeddings()
        } catch {
            currentPhase = .error("Failed to clear stale embeddings: \(error.localizedDescription)")
            return
        }

        if cancelRequested { currentPhase = .cancelled; return }

        // Phase 3 — Re-embed every NULL row under the new backend.
        await reEmbedAllNullRows(database: database)
    }

    /// Walk every chunk with `embedding IS NULL` and fill it in
    /// using the active backend (which by now is `target`). Posts
    /// `.migrating(processed, total)` updates as it goes. On any
    /// failure for a single row, the row is skipped (left NULL)
    /// and the migration continues — the next swap or re-run can
    /// pick it up. The final phase reflects only the count
    /// successfully re-embedded.
    private func reEmbedAllNullRows(database: DatabaseManager) async {
        let total: Int
        do {
            total = try database.unitEmbeddingChunkNullCount()
        } catch {
            currentPhase = .error("Failed to count chunks: \(error.localizedDescription)")
            return
        }

        guard total > 0 else {
            currentPhase = .done(reEmbedded: 0)
            return
        }

        currentPhase = .migrating(processed: 0, total: total)

        // Process in batches to keep memory bounded and to give
        // the cancel checkpoint a chance to fire on every batch.
        let batchSize = 64
        var processed = 0
        var successfullyEmbedded = 0

        // 2026-05-28 — Perma-nil guard. Surfaced live on phone:
        // when an embedder isn't producing vectors (Nomic's
        // asset still downloading, or any other "embed returns
        // nil" failure mode), the migration loops forever —
        // every batch refetches the same NULL chunks, processed
        // counter grows past total, no progress is ever made.
        // The architecture doc has always claimed this guard
        // existed; it didn't until now. After 2 consecutive
        // batches with zero successful embeds, abort with .error
        // so the user sees an honest failure rather than a stuck
        // progress bar.
        var consecutiveZeroSuccessBatches = 0
        let maxZeroSuccessBatches = 2

        while true {
            if cancelRequested { currentPhase = .cancelled; return }

            let batch: [DatabaseManager.UnitEmbeddingChunkNeedingEmbedding]
            do {
                batch = try database.unitEmbeddingChunksNeedingEmbedding(limit: batchSize)
            } catch {
                currentPhase = .error("Failed to fetch chunk batch: \(error.localizedDescription)")
                return
            }
            if batch.isEmpty { break }

            // 2026-05-28 — Mark caught: this loop was blocking UI on
            // phone. Per-row main-actor DB writes hammered the queue
            // with 11K hops, queuing antenna requests behind every
            // chunk write. Two-part fix:
            //   (1) Embed off-main, COLLECT (id, vector) pairs, then
            //       run ONE DB-write loop per batch. SQLite writes
            //       are fast in-process; the batch is bounded at 64
            //       rows so each chunk of work is small.
            //   (2) `await Task.yield()` between batches gives the
            //       main actor a chance to drain UI work before the
            //       next batch claims it.
            var batchSuccesses = 0
            var batchVectors: [(id: UUID, vector: [Double])] = []
            batchVectors.reserveCapacity(batch.count)
            for row in batch {
                if cancelRequested { currentPhase = .cancelled; return }
                let vector = await Task.detached(priority: .userInitiated) {
                    EmbeddingProvider.shared.embed(row.text, as: .document)
                }.value
                processed += 1
                if let vector { batchVectors.append((row.id, vector)) }
                if processed % 8 == 0 || processed == total {
                    currentPhase = .migrating(processed: processed, total: total)
                }
            }
            for (id, vec) in batchVectors {
                do {
                    try database.updateUnitEmbeddingChunkEmbedding(id: id, embedding: vec)
                    successfullyEmbedded += 1
                    batchSuccesses += 1
                } catch {
                    // Skip + continue; row stays NULL.
                }
            }
            await Task.yield()

            if batchSuccesses == 0 {
                consecutiveZeroSuccessBatches += 1
                if consecutiveZeroSuccessBatches >= maxZeroSuccessBatches {
                    currentPhase = .error(
                        "Embedder returned nil for \(maxZeroSuccessBatches * batchSize) consecutive chunks. The model may still be downloading. Try again in a moment."
                    )
                    return
                }
            } else {
                consecutiveZeroSuccessBatches = 0
            }
        }

        currentPhase = .done(reEmbedded: successfullyEmbedded)
    }
}

// ========== BLOCK 01: EMBEDDER MIGRATION COORDINATOR - END ==========
