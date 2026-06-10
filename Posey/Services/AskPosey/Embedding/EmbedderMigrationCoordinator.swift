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
/// `Task.isCancelled` at every checkpoint and bails to `.cancelled`.
/// Mid-row failures land in `.error(String)` for the user to
/// dismiss; the coordinator leaves rows partially migrated
/// (some NULL, some embedded in the new space) and a subsequent
/// `retry` re-runs the re-embed phase from where it left off.
///
/// **N1 architecture note (2026-05-28).** The class is `@MainActor`
/// so SwiftUI can observe `@Published currentPhase` directly, but
/// the worker (`runSwitch` + `reEmbedAllNullRows`) is `nonisolated`
/// and runs in a `Task.detached`. All embed calls + DB writes
/// execute off-main — `EmbeddingProvider` is NSLock-serialized,
/// `DatabaseManager` is `@unchecked Sendable` (SQLite configured
/// with `SQLITE_THREADSAFE=1`, serializes internally). Phase
/// updates marshal back to main via `await MainActor.run`.
/// Eliminates the per-batch UI stutter that the prior `@MainActor`-
/// bound worker introduced even with `Task.yield()` between
/// batches: the main thread is genuinely free of migration work
/// for the entire duration, not just between yields.
///
/// 2026-05-23 — introduced as part of the Hal-based Ask Posey
/// rebuild (Step 8a).
/// 2026-05-28 (N1) — worker moved off-main per architectural
/// follow-up filed in `d159909`'s commit message.
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

    private var activeWorker: Task<Void, Never>?

    private init() {}

    // MARK: - Public surface

    /// Begin the swap to `target`. If already in flight, this
    /// call is a no-op. Returns immediately; SwiftUI observers
    /// see phase changes as the worker progresses.
    func beginSwitch(to target: EmbeddingBackend, database: DatabaseManager) {
        guard activeWorker == nil else { return }
        // Detached so the worker runs OFF-main. `runSwitch` is
        // nonisolated; calling it from a detached Task keeps the
        // whole embed-+-DB-write loop off the main actor. Phase
        // updates marshal back via `await MainActor.run`.
        let worker = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runSwitch(to: target, database: database)
            await MainActor.run { self.activeWorker = nil }
        }
        activeWorker = worker
    }

    /// Cancel the in-flight swap (if any). Uses Swift's standard
    /// Task cancellation — the worker's checkpoints poll
    /// `Task.isCancelled` and bail to `.cancelled`. Safe to call
    /// at any time.
    func cancel() {
        activeWorker?.cancel()
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

    // MARK: - Phase publisher

    /// Hop back to MainActor to set the published phase. Called
    /// from the nonisolated worker. The closure pattern keeps the
    /// hop a single round-trip per call.
    private func publish(_ phase: Phase) {
        currentPhase = phase
    }

    // MARK: - Worker (nonisolated — runs off-main)

    /// Runs the full three-phase swap. Nonisolated so the embed
    /// loop + DB writes execute off the main actor. Phase updates
    /// publish back via `MainActor.run`.
    nonisolated private func runSwitch(
        to target: EmbeddingBackend,
        database: DatabaseManager
    ) async {
        // Phase 1 — Switch the flag + LOAD the target backend BEFORE
        // touching any stored embedding. (D6 fix, 2026-05-31 — Rule 9A port
        // of Hal's wait-for-isLoaded gate; full diff in
        // docs-internal/EMBEDDER-MIGRATION-D6-HAL-DIFF-2026-05-31.md.)
        //
        // The defect this replaces: the old order wiped every embedding to
        // NULL, flipped the backend, then raced the re-embed loop against a
        // still-downloading Nomic asset — `embed()` returned nil for every
        // chunk (warmUp had already set `nomicLoadAttempted`, so the per-chunk
        // load short-circuited instead of waiting), 128 nils tripped the
        // perma-nil guard → `.error`, and the store was left fully
        // semantic-dark (backend = nomic, every row NULL, retrieval silently
        // BM25-only). Reproduced live on the phone during the item-5 switch.
        //
        // Hal's invariant: NEVER run the re-embed loop against an unloaded
        // model, and NEVER destroy the old embeddings until the new backend is
        // proven loadable. So: flip the flag, warm-load the target (first-time
        // Nomic downloads ~522 MB implicitly inside the load), and WAIT for
        // `isLoaded` BEFORE wiping. On timeout / cancel / load failure, revert
        // the flag and leave every embedding intact → prior working state
        // preserved, zero semantic-dark window.

        if Task.isCancelled {
            await MainActor.run { self.publish(.cancelled) }
            return
        }

        let previousBackend = EmbeddingBackend.current()
        await MainActor.run { self.publish(.switching) }
        UserDefaults.standard.set(target.rawValue, forKey: EmbeddingBackend.defaultsKey)

        // Warm-load the now-active backend off-main. NLContextual is
        // OS-built-in (loads near-instantly); Nomic's first-time load performs
        // the HuggingFace fetch itself.
        EmbeddingProvider.shared.warmUp()

        // Wait for the bundle to be ready. Generous + cancellable because the
        // first-time Nomic switch includes the ~522 MB download on this path
        // (Hal's 60s cap assumes a pre-downloaded model — disk load only). A
        // timeout or cancel reverts the flag so we stay on the prior working
        // backend and NEVER reach the wipe.
        let loadDeadline = Date().addingTimeInterval(target == .nlContextual ? 60 : 600)
        while !EmbeddingProvider.shared.isLoaded {
            if Task.isCancelled {
                UserDefaults.standard.set(previousBackend.rawValue, forKey: EmbeddingBackend.defaultsKey)
                await MainActor.run { self.publish(.cancelled) }
                return
            }
            if Date() > loadDeadline {
                UserDefaults.standard.set(previousBackend.rawValue, forKey: EmbeddingBackend.defaultsKey)
                await MainActor.run {
                    self.publish(.error(
                        "\(target.rawValue) didn't finish loading in time. No embeddings were changed — still using \(previousBackend.rawValue). Check your connection and try again."
                    ))
                }
                return
            }
            // Surface a real loading/downloading phase. No fine-grained
            // progress hook exists on the swift-embeddings load path, so the
            // fraction is indeterminate (the UI renders a spinner/indeterminate
            // bar for .downloading). Wiring HuggingFace's progress reporter in
            // is a future polish.
            await MainActor.run {
                self.publish(.downloading(modelID: target.rawValue, progressFraction: 0))
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Phase 2 — Bundle is loaded. NOW it is safe to wipe. Atomic NULL of
        // every row in one statement.
        await MainActor.run { self.publish(.switching) }
        do {
            try database.nullAllUnitEmbeddingChunkEmbeddings()
        } catch {
            let msg = error.localizedDescription
            await MainActor.run {
                self.publish(.error("Failed to clear stale embeddings: \(msg)"))
            }
            return
        }

        if Task.isCancelled {
            await MainActor.run { self.publish(.cancelled) }
            return
        }

        // Phase 3 — Re-embed every NULL row under the new (loaded) backend.
        await reEmbedAllNullRows(database: database)

        // 2026-05-31 — Ask Posey unlock signal. A successful switch to Nomic
        // (the bundle actually loaded — `isLoaded` guards against a failed
        // download falsely unlocking) marks Nomic provisioned. Sticky: drives
        // `AskPoseyAvailability.isUnlocked` and persists even if the user later
        // switches the active embedder back to NLContextual.
        if target == .nomic, EmbeddingProvider.shared.isLoaded {
            AskPoseyAvailability.markNomicProvisioned()
        }
    }

    /// Walk every chunk with `embedding IS NULL` and fill it in
    /// using the active backend (which by now is `target`). Posts
    /// `.migrating(processed, total)` updates as it goes. On any
    /// failure for a single row, the row is skipped (left NULL)
    /// and the migration continues — the next swap or re-run can
    /// pick it up. The final phase reflects only the count
    /// successfully re-embedded.
    nonisolated private func reEmbedAllNullRows(database: DatabaseManager) async {
        let total: Int
        do {
            total = try database.unitEmbeddingChunkNullCount()
        } catch {
            let msg = error.localizedDescription
            await MainActor.run {
                self.publish(.error("Failed to count chunks: \(msg)"))
            }
            return
        }

        guard total > 0 else {
            await MainActor.run { self.publish(.done(reEmbedded: 0)) }
            return
        }

        await MainActor.run { self.publish(.migrating(processed: 0, total: total)) }

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
        // After 2 consecutive batches with zero successful embeds,
        // abort with .error so the user sees an honest failure
        // rather than a stuck progress bar.
        var consecutiveZeroSuccessBatches = 0
        let maxZeroSuccessBatches = 2

        while true {
            if Task.isCancelled {
                await MainActor.run { self.publish(.cancelled) }
                return
            }

            let batch: [DatabaseManager.UnitEmbeddingChunkNeedingEmbedding]
            do {
                batch = try database.unitEmbeddingChunksNeedingEmbedding(limit: batchSize)
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    self.publish(.error("Failed to fetch chunk batch: \(msg)"))
                }
                return
            }
            if batch.isEmpty { break }

            // N1 (2026-05-28): the loop runs on a detached Task, so
            // both the embed call and the DB write execute off-main
            // directly — no `Task.detached` wrapper per row, no
            // `MainActor.run` per row, no `Task.yield()` between
            // batches. Main thread stays completely free of migration
            // work; UI + antenna requests run at full responsiveness.
            // EmbeddingProvider is NSLock-serialized (safe from any
            // thread), DatabaseManager is @unchecked Sendable (SQLite
            // serializes internally via SQLITE_THREADSAFE=1).
            var batchSuccesses = 0
            for row in batch {
                if Task.isCancelled {
                    await MainActor.run { self.publish(.cancelled) }
                    return
                }
                // Global serial lane — embedder migration re-embeds the whole
                // library; route each embed through the one lane so it
                // serializes app-wide with OCR / AFM / RAPTOR / indexing
                // embeds (no overlap, no stacked memory). Still off-main.
                let text = row.text
                let vector = await HeavyWorkLane.shared.run(label: "embed-migration") {
                    EmbeddingProvider.shared.embed(text, as: .document)
                }
                processed += 1
                if let vector {
                    do {
                        try database.updateUnitEmbeddingChunkEmbedding(id: row.id, embedding: vector)
                        successfullyEmbedded += 1
                        batchSuccesses += 1
                    } catch {
                        // Row stays NULL; continue.
                    }
                }
                // Publish progress every 8 rows OR on the last row of
                // the document so the UI's progress meter advances
                // smoothly without flooding MainActor.
                if processed % 8 == 0 || processed == total {
                    let snapshot = processed
                    await MainActor.run {
                        self.publish(.migrating(processed: snapshot, total: total))
                    }
                }
            }

            if batchSuccesses == 0 {
                consecutiveZeroSuccessBatches += 1
                if consecutiveZeroSuccessBatches >= maxZeroSuccessBatches {
                    await MainActor.run {
                        self.publish(.error(
                            "Embedder returned nil for \(maxZeroSuccessBatches * batchSize) consecutive chunks. The model may still be downloading. Try again in a moment."
                        ))
                    }
                    return
                }
            } else {
                consecutiveZeroSuccessBatches = 0
            }
        }

        let finalCount = successfullyEmbedded
        await MainActor.run { self.publish(.done(reEmbedded: finalCount)) }
    }
}

// ========== BLOCK 01: EMBEDDER MIGRATION COORDINATOR - END ==========
