import Foundation
import Combine

// ========== BLOCK 01: EMBEDDING BACKFILL COORDINATOR - START ==========

/// 2026-06-19 (Mark) — fills an **inactive** embedding backend's column for the
/// whole corpus, in the background, WITHOUT locking Ask Posey or changing which
/// backend the reader is on. This is the tool Mark asked for: "cause all already-
/// embedded documents to be embedded by the OTHER embedders" — e.g. a library
/// embedded under Nomic but with an empty `embedding_nl` column. It's the
/// prerequisite for the embedder A/B/C comparison (you can't compare backends
/// whose columns are empty), and it'll be needed ×N as backends are added.
///
/// **How it differs from `EmbedderMigrationCoordinator` (a SWAP):**
///   - A swap sets the swap marker → **locks Ask Posey** and **flips the active
///     backend** at the end. Correct for "switch the reader to a new backend."
///   - A backfill does **neither**. It fills the target column while the active
///     backend stays the live reader. Made possible by
///     `EmbeddingProvider.embed(_:as:in:)` (the explicit-backend primitive),
///     which embeds in a NAMED backend without consulting the swap marker.
///
/// **The active backend is NOT this tool's job.** Its NULL rows are filled by
/// the normal indexing queue + the launch resume (see `PoseyApp` / interrupted-
/// embed resume). This worker targets INACTIVE backends; targeting the active
/// one is allowed but redundant (the queue already owns it), so `.all` skips it.
///
/// **Safety (mirrors the migration worker's hard-won lessons):**
///   - Routes every embed through `HeavyWorkLane` (app-wide serial — no GPU/ANE
///     overlap with OCR/RAPTOR/indexing) and paces with `ThermalGovernor` after
///     each embed (never a 100% duty cycle; pauses at `.critical`). Obeys the
///     phone-saturation rule by construction — one chunk at a time.
///   - **Swap-mutual-exclusion:** refuses to start while a swap is in progress,
///     and bails mid-run if one starts (both write columns; don't race).
///   - **Perma-nil guard:** bails a target after 2 consecutive zero-success
///     batches (model can't load / returns nil) rather than spinning forever.
///   - Cancellable; resumable (it only ever fills still-NULL rows, so a re-run
///     picks up where it left off — no marker needed).
///
/// Progress is observable two ways: the published `phase` (for `BACKFILL_STATUS`)
/// and, naturally, `EMBEDDING_COVERAGE` (the target column's `filled` climbs).
@MainActor
final class EmbeddingBackfillCoordinator: ObservableObject {

    enum Phase: Equatable, Sendable {
        case idle
        case running(backend: String, processed: Int, total: Int)
        case done(filledByBackend: [String: Int])
        case refusedSwapInProgress
        case error(String)
    }

    static let shared = EmbeddingBackfillCoordinator()

    @Published private(set) var phase: Phase = .idle

    private var activeWorker: Task<Void, Never>?

    private init() {}

    /// True while a backfill is running (drives `BACKFILL_STATUS` + the start
    /// guard so two backfills can't overlap).
    var isRunning: Bool { activeWorker != nil }

    // MARK: - Public surface

    /// Begin backfilling `targets` (in order). No-op if one is already running.
    /// Returns immediately; observe `phase` / `EMBEDDING_COVERAGE` for progress.
    func begin(targets: [EmbeddingBackend], database: DatabaseManager) {
        guard activeWorker == nil else { return }
        // Don't fight a swap — it owns the write backend + flips active.
        guard !EmbeddingBackend.isSwapInProgress else {
            phase = .refusedSwapInProgress
            return
        }
        let worker = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.run(targets: targets, database: database)
            await MainActor.run { self.activeWorker = nil }
        }
        activeWorker = worker
    }

    /// Cancel the in-flight backfill (if any). Still-NULL rows stay NULL; a later
    /// `begin` resumes them. Resets `phase` to `.idle` IMMEDIATELY so the UI
    /// reflects "stopped" the instant Stop is tapped — without this, the phase
    /// stayed frozen on the last `.running(...)`, so the board kept showing
    /// "Backfilling N" with a rate that decayed toward zero and an ETA that
    /// ballooned (51,889h) until `Int(remaining/rate)` overflowed and CRASHED
    /// (Mark, 2026-06-19). The worker bails at its next cancellation checkpoint.
    func cancel() {
        activeWorker?.cancel()
        phase = .idle
    }

    /// Reset to `.idle` after a terminal phase is acknowledged (for the verb).
    func acknowledge() {
        switch phase {
        case .done, .error, .refusedSwapInProgress: phase = .idle
        default: break
        }
    }

    // MARK: - Worker (nonisolated — runs off-main)

    nonisolated private func run(targets: [EmbeddingBackend], database: DatabaseManager) async {
        var filledByBackend: [String: Int] = [:]
        for target in targets {
            if Task.isCancelled { break }
            // Re-check the swap mutex per target (a swap could start between
            // targets); bail cleanly if so.
            if EmbeddingBackend.isSwapInProgress {
                await MainActor.run { self.publish(.refusedSwapInProgress) }
                return
            }
            let filled = await backfillOne(target: target, database: database)
            if let filled { filledByBackend[target.rawValue] = filled } else { return }
        }
        let finalFilled = filledByBackend   // snapshot before the actor hop (Swift 6)
        await MainActor.run { self.publish(.done(filledByBackend: finalFilled)) }
    }

    /// Fill one backend's NULL column. Returns the count embedded, or nil on
    /// early termination (cancel / load-failure / swap-started — the terminal
    /// phase is already published).
    nonisolated private func backfillOne(target: EmbeddingBackend, database: DatabaseManager) async -> Int? {
        let total: Int
        do {
            total = try database.unitEmbeddingChunkNullCount(backend: target)
        } catch {
            await MainActor.run { self.publish(.error("count failed: \(error.localizedDescription)")) }
            return nil
        }
        guard total > 0 else { return 0 }   // already complete — nothing to do

        await MainActor.run { self.publish(.running(backend: target.rawValue, processed: 0, total: total)) }

        // Warm-load the TARGET (independent of the active backend). NLContextual
        // is OS-built-in; Nomic's first use may fetch ~522 MB. We touch no stored
        // vector until the target is proven loadable.
        EmbeddingProvider.shared.warmUp(target)
        let loadDeadline = Date().addingTimeInterval(target == .nlContextual ? 60 : 600)
        while !EmbeddingProvider.shared.isLoaded(target) {
            if Task.isCancelled { return nil }
            if Date() > loadDeadline {
                await MainActor.run { self.publish(.error("\(target.rawValue) didn't load in time")) }
                return nil
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let batchSize = 32
        let maxZeroSuccessBatches = 2
        var processed = 0
        var successes = 0
        var consecutiveZeroSuccess = 0

        while true {
            if Task.isCancelled { return nil }
            if EmbeddingBackend.isSwapInProgress {
                await MainActor.run { self.publish(.refusedSwapInProgress) }
                return nil
            }
            let batch: [DatabaseManager.UnitEmbeddingChunkNeedingEmbedding]
            do {
                batch = try database.unitEmbeddingChunksNeedingEmbedding(limit: batchSize, backend: target)
            } catch {
                await MainActor.run { self.publish(.error("fetch failed: \(error.localizedDescription)")) }
                return nil
            }
            if batch.isEmpty { break }

            var batchSuccesses = 0
            for row in batch {
                if Task.isCancelled { return nil }
                let text = row.text
                // Explicit-backend embed (does NOT consult the swap marker), via
                // the app-wide serial lane so it never overlaps other heavy work.
                let vector = await HeavyWorkLane.shared.run(label: "embed-backfill") {
                    EmbeddingProvider.shared.embed(text, as: .document, in: target)
                }
                processed += 1
                if let vector {
                    do {
                        try database.updateUnitEmbeddingChunkEmbedding(id: row.id, embedding: vector, backend: target)
                        successes += 1
                        batchSuccesses += 1
                    } catch {
                        // Row stays NULL; continue.
                    }
                }
                // Proactive thermal pacing after each heavy embed (scales up under
                // pressure, pauses at .critical). Same discipline as indexing.
                await ThermalGovernor.shared.pace()
                if (processed % 8 == 0 || processed == total) && !Task.isCancelled {
                    let snap = processed
                    await MainActor.run {
                        // Don't resurrect a `.running` over an `.idle` that cancel()
                        // just published (the worker is bailing this checkpoint).
                        if !Task.isCancelled { self.publish(.running(backend: target.rawValue, processed: snap, total: total)) }
                    }
                }
            }

            if batchSuccesses == 0 {
                consecutiveZeroSuccess += 1
                if consecutiveZeroSuccess >= maxZeroSuccessBatches {
                    await MainActor.run {
                        self.publish(.error("\(target.rawValue) returned nil for \(maxZeroSuccessBatches * batchSize) consecutive chunks (model may still be downloading)"))
                    }
                    return nil
                }
            } else {
                consecutiveZeroSuccess = 0
            }
        }

        return successes
    }

    private func publish(_ p: Phase) { phase = p }
}

// ========== BLOCK 01: EMBEDDING BACKFILL COORDINATOR - END ==========
