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
        // PER-BACKEND-COLUMN SWAP (2026-06-17 — Mark's final design). Replaces
        // the destructive flip-then-wipe-then-refill flow. The invariants:
        //
        //   Rule 1 — never destroy the old set. We BUILD the target backend's
        //     own column (NULL rows only); the active backend's column stays
        //     fully intact. No `nullAll`. The retriever keeps reading the active
        //     (complete) column the whole time.
        //   Rule 2 — Ask Posey unreachable until the new set is 100% ready. The
        //     swap marker (set below) drives `AskPoseyAvailability.isSwapInProgress`,
        //     so the reader surfaces hide for the whole window — no query races
        //     the half-built column, and we never need two backends loaded for
        //     querying.
        //   Rule 3 — resume an interrupted swap. The marker persists in
        //     UserDefaults; `resumeInterruptedSwapIfNeeded` re-enters this path
        //     at launch and continues filling still-NULL target rows.
        //
        // The active-backend flag (`defaultsKey`) flips ONLY at completion
        // ("flip the pointer"), so a crash / cancel / load-failure mid-swap
        // leaves the prior working state perfectly intact: active backend
        // unchanged, both columns intact, marker cleared (or left for resume).
        //
        // Decoupling that makes this work: setting the swap marker makes
        // `EmbeddingBackend.writeBackend()` resolve to `target`, so the provider
        // embeds in the target space and `isLoaded` reports the target's load
        // state — WITHOUT moving the active/read pointer. (D6 invariant kept:
        // never run the embed loop against an unloaded model; never destroy the
        // old vectors until the new backend is proven loadable.)

        if Task.isCancelled {
            await MainActor.run { self.publish(.cancelled) }
            return
        }

        // Mark the swap in flight: locks Ask Posey AND routes new embeds to the
        // target space. Persisted → resumes at next launch if interrupted.
        EmbeddingBackend.beginSwapMarker(target: target)
        await MainActor.run { self.publish(.switching) }

        // Warm-load the TARGET off-main (warmUp now keys on writeBackend == target).
        // NLContextual is OS-built-in; Nomic's first-time load performs the
        // ~522 MB HuggingFace fetch. We touch NO stored vector until the target
        // is proven loadable.
        EmbeddingProvider.shared.warmUp()

        // Wait for the target bundle to be ready. Generous + cancellable (the
        // first-time Nomic switch includes the download on this path). On
        // timeout / cancel: clear the marker (writeBackend reverts to the active
        // backend), leave EVERY vector intact, never reach the build loop.
        let loadDeadline = Date().addingTimeInterval(target == .nlContextual ? 60 : 600)
        while !EmbeddingProvider.shared.isLoaded {
            if Task.isCancelled {
                EmbeddingBackend.clearSwapMarker()
                await MainActor.run { self.publish(.cancelled) }
                return
            }
            if Date() > loadDeadline {
                let stayingOn = EmbeddingBackend.current().rawValue
                EmbeddingBackend.clearSwapMarker()
                await MainActor.run {
                    self.publish(.error(
                        "\(target.rawValue) didn't finish loading in time. No embeddings were changed — still using \(stayingOn). Check your connection and try again."
                    ))
                }
                return
            }
            await MainActor.run {
                self.publish(.downloading(modelID: target.rawValue, progressFraction: 0))
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Target loaded — BUILD its column (NULL rows only). No wipe.
        guard let reEmbedded = await reEmbedTargetNullRows(target: target, database: database) else {
            return   // terminal phase published + marker handled inside
        }

        // COMPLETION — flip the pointer. Set active = target FIRST (reads move to
        // the now-complete target column), THEN clear the marker (unlock). After
        // both, current() == writeBackend() == target and isSwapInProgress == false.
        UserDefaults.standard.set(target.rawValue, forKey: EmbeddingBackend.defaultsKey)
        EmbeddingBackend.clearSwapMarker()

        // Ask Posey unlock signal — a completed Nomic build marks it provisioned
        // (sticky; persists even if the user later reverts the active embedder).
        if target == .nomic {
            AskPoseyAvailability.markNomicProvisioned()
        }

        await MainActor.run { self.publish(.done(reEmbedded: reEmbedded)) }
    }

    /// Resume an interrupted swap at launch (Rule 3). If a swap marker is set
    /// (the app died or was backgrounded mid-swap), re-enter the swap for that
    /// target — `runSwitch` warm-loads it and continues filling its still-NULL
    /// rows from where it left off, staying locked until complete. No-op when no
    /// swap is pending. Idempotent: `beginSwitch`'s in-flight guard prevents a
    /// double run if a swap is already active this launch.
    func resumeInterruptedSwapIfNeeded(database: DatabaseManager) {
        guard let target = EmbeddingBackend.swapTarget() else { return }
        beginSwitch(to: target, database: database)
    }

    /// Fill every row whose TARGET backend column is NULL, embedding under the
    /// target backend (which `writeBackend()` now resolves to, so the provider
    /// produces target-space vectors). Posts `.migrating(processed, total)` as
    /// it goes. A single-row failure leaves that row NULL and continues — a
    /// later resume/run picks it up. Re-fetches the NULL set each batch, so
    /// rows imported MID-SWAP (their target column NULL) are drained too.
    ///
    /// Returns the count embedded on SUCCESS (the caller then flips the pointer
    /// + publishes `.done`), or `nil` on early termination (cancel/error — this
    /// method has already published the terminal phase AND cleared the swap
    /// marker, so the caller just returns).
    nonisolated private func reEmbedTargetNullRows(
        target: EmbeddingBackend,
        database: DatabaseManager
    ) async -> Int? {
        let total: Int
        do {
            total = try database.unitEmbeddingChunkNullCount(backend: target)
        } catch {
            EmbeddingBackend.clearSwapMarker()
            let msg = error.localizedDescription
            await MainActor.run {
                self.publish(.error("Failed to count chunks: \(msg)"))
            }
            return nil
        }

        // Target column already complete (e.g. a resume that finished, or a
        // no-op re-target). Caller flips the pointer + publishes .done.
        guard total > 0 else { return 0 }

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
                EmbeddingBackend.clearSwapMarker()
                await MainActor.run { self.publish(.cancelled) }
                return nil
            }

            let batch: [DatabaseManager.UnitEmbeddingChunkNeedingEmbedding]
            do {
                batch = try database.unitEmbeddingChunksNeedingEmbedding(limit: batchSize, backend: target)
            } catch {
                EmbeddingBackend.clearSwapMarker()
                let msg = error.localizedDescription
                await MainActor.run {
                    self.publish(.error("Failed to fetch chunk batch: \(msg)"))
                }
                return nil
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
                    EmbeddingBackend.clearSwapMarker()
                    await MainActor.run { self.publish(.cancelled) }
                    return nil
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
                        try database.updateUnitEmbeddingChunkEmbedding(id: row.id, embedding: vector, backend: target)
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
                    EmbeddingBackend.clearSwapMarker()
                    await MainActor.run {
                        self.publish(.error(
                            "Embedder returned nil for \(maxZeroSuccessBatches * batchSize) consecutive chunks. The model may still be downloading. Try again in a moment."
                        ))
                    }
                    return nil
                }
            } else {
                consecutiveZeroSuccessBatches = 0
            }
        }

        // Target column fully built — caller flips the pointer + publishes .done.
        return successfullyEmbedded
    }
}

// ========== BLOCK 01: EMBEDDER MIGRATION COORDINATOR - END ==========
