import Foundation

// ========== BLOCK 01: HEAVY WORK EVENT - START ==========

/// One heavy-op lifecycle record, kept in the lane's ring buffer for the
/// sequential proof (the antenna `HEAVY_LANE_STATUS` verb surfaces these).
/// Because the lane is serial, the recorded `[startedAt, endedAt]`
/// intervals must NEVER overlap — that non-overlap is the on-device proof
/// that only one heavy op runs at a time.
struct HeavyWorkEvent: Sendable {
    let label: String
    let startedAt: Date
    let endedAt: Date
    var durationMs: Int { Int(endedAt.timeIntervalSince(startedAt) * 1000) }
}

// ========== BLOCK 01: HEAVY WORK EVENT - END ==========


// ========== BLOCK 02: HEAVY WORK LANE - START ==========

/// The single global serial lane for ALL heavy BACKGROUND compute —
/// Vision OCR, AFM fusion-split, embedding, RAPTOR summarization.
///
/// **Why (2026-06-09, Mark).** The four background services
/// (`PDFEnhancementService`, `UnitEmbeddingService`, `RaptorTreeService`)
/// are each serial *in isolation* but are independent actors that run in
/// PARALLEL across documents — the per-stage handoff frees each to grab
/// the next document, so up to three heavy pipelines (OCR + embed +
/// RAPTOR) overlap, stack memory, and iOS **system-pressure jetsams** the
/// app (confirmed: process terminated to Springboard while
/// `os_proc_available_memory` still read ~6 GB — system pressure, not
/// app-limit). Nothing serialized ACROSS the services. This lane does.
///
/// **Contract.** Every heavy op runs inside `run(label:) { … }`. The lane
/// admits exactly ONE at a time (FIFO hand-off), so only one heavy op
/// executes anywhere in the app at any instant. This makes the
/// cross-service overlap AND the relaunch-bootstrap stampede
/// **structurally impossible** — a bootstrap can spawn all its Tasks; they
/// simply queue here. Per-document stage order (OCR → AFM → embed →
/// RAPTOR) is preserved because each service's pipeline already awaits its
/// stages in order; the lane only interleaves at heavy-op granularity.
///
/// **Off the main thread by construction.** A plain `actor` (cooperative
/// pool), never `@MainActor`. Heavy work runs off-main, so reading and TTS
/// are never blocked. This is pure serialization — NOT a memory gate and
/// NOT an admission gate (both abandoned; `os_proc_available_memory` is
/// blind to the system-pressure jetsam this prevents structurally).
///
/// **Scope.** Background pipeline only. User-facing Ask Posey query
/// answering does NOT route through the lane — it must never wait behind
/// background work.
actor HeavyWorkLane {

    static let shared = HeavyWorkLane()
    private init() {}

    // MARK: Serialization (FIFO hand-off — one op in-flight)

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // MARK: Telemetry (HEAVY_LANE_STATUS verb + sequential proof)

    /// Label of the op currently executing, nil when idle.
    private(set) var currentLabel: String?
    /// Total heavy ops completed since launch (or last reset).
    private(set) var totalCompleted = 0
    /// Live count of ops between start and end. MUST never exceed 1 — the
    /// lane's own self-check that serialization holds.
    private(set) var concurrentNow = 0
    /// High-water mark of `concurrentNow`. If this is ever > 1 the lane
    /// FAILED to serialize. Expected to stay 1 forever.
    private(set) var maxConcurrentObserved = 0
    /// Completed-op ring (most recent last) for the non-overlap proof.
    private var ring: [HeavyWorkEvent] = []
    private let ringCap = 50

    /// Run `work` as the single in-flight heavy op. Serial across the app.
    /// `rethrows`: callers wrapping non-throwing work don't need `try`.
    func run<T>(label: String, _ work: () async throws -> T) async rethrows -> T {
        await acquireSlot()

        concurrentNow += 1
        maxConcurrentObserved = max(maxConcurrentObserved, concurrentNow)
        currentLabel = label
        let startedAt = Date()
        dbgLog("HeavyWorkLane: START %@ (concurrent=%d max=%d)",
               label, concurrentNow, maxConcurrentObserved)

        defer {
            let endedAt = Date()
            ring.append(HeavyWorkEvent(label: label, startedAt: startedAt, endedAt: endedAt))
            if ring.count > ringCap { ring.removeFirst(ring.count - ringCap) }
            concurrentNow -= 1
            totalCompleted += 1
            currentLabel = nil
            dbgLog("HeavyWorkLane: END   %@ (%dms, totalCompleted=%d)",
                   label, Int(endedAt.timeIntervalSince(startedAt) * 1000), totalCompleted)
            releaseSlot()
        }

        return try await work()
    }

    // FIFO hand-off: a releaser resumes the next waiter (handing it the
    // slot — `busy` stays true) or clears `busy`. A resumed waiter owns
    // the slot. Same proven pattern as the (reverted) admission gate, but
    // off-main and app-wide for compute.
    private func acquireSlot() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    // MARK: Status (diagnostic)

    struct Status: Sendable {
        let currentLabel: String?
        let queueDepth: Int
        let concurrentNow: Int
        let maxConcurrentObserved: Int
        let totalCompleted: Int
        /// Recent completed ops, oldest→newest. Intervals must not overlap.
        let recent: [HeavyWorkEvent]
    }

    func status() -> Status {
        Status(
            currentLabel: currentLabel,
            queueDepth: waiters.count,
            concurrentNow: concurrentNow,
            maxConcurrentObserved: maxConcurrentObserved,
            totalCompleted: totalCompleted,
            recent: ring
        )
    }

    /// Reset the telemetry counters (not the FIFO) — lets a verification
    /// run start the `maxConcurrentObserved` / `totalCompleted` tally from
    /// a clean baseline.
    func resetTelemetry() {
        totalCompleted = 0
        maxConcurrentObserved = max(concurrentNow, 0)
        ring.removeAll(keepingCapacity: true)
    }
}

// ========== BLOCK 02: HEAVY WORK LANE - END ==========
