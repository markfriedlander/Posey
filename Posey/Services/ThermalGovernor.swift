import Foundation

// ========== BLOCK 01: THERMAL GOVERNOR - START ==========

/// Proactive thermal pacing for background indexing — Pillar 2 of the
/// post-incident hardening.
///
/// **Why (2026-06-18).** `DocumentIndexingQueue` (Pillar 1) prevents *stacking*
/// — only one document-pass runs at a time. But that alone does NOT prevent the
/// burn: a single large document's embed pass is hundreds of back-to-back embed
/// ops (~565 chunks ≈ 2 minutes of near-continuous GPU/ANE), and sustained
/// 100%-duty compute is exactly what cooked the phone on 2026-06-17. A
/// *reactive* cutoff fires too late — by the time `ProcessInfo.thermalState`
/// reads `.serious` the device is already hot. So we pace **proactively**: a
/// small yield between every heavy work-unit even at `.nominal` (so the chip
/// never pegs at a 100% duty cycle), scaling up with thermal pressure, and a
/// full pause at `.critical` until it cools.
///
/// **Where it's called.** `pace()` is awaited at each heavy work-unit boundary —
/// per embedded chunk (`UnitEmbeddingService.fillEmbeddings`) and per RAPTOR
/// cluster (`RaptorTreeBuilder.buildLayer`). It honors `Task` cancellation so
/// the escape switch is never delayed behind a cooldown sleep.
///
/// **Testability.** A DEBUG-only injected state lets the `.serious` / `.critical`
/// backoff + pause paths be exercised off-device without ever heating real
/// hardware (you cannot, and must not, deliberately overheat the phone to test).
actor ThermalGovernor {

    static let shared = ThermalGovernor()

    /// Internal (not private) so `@testable` unit tests can construct a fresh,
    /// isolated instance. Production uses `.shared`.
    init() {}

    // MARK: Thermal source (+ test injection)

    #if DEBUG
    /// Test-only override of the OS thermal state. Actor-isolated (set via
    /// `setDebugThermalState`) so reads/writes serialize cleanly with `pace()`.
    private var debugThermalState: ProcessInfo.ThermalState?
    func setDebugThermalState(_ state: ProcessInfo.ThermalState?) {
        debugThermalState = state
    }
    #endif

    private func currentState() -> ProcessInfo.ThermalState {
        #if DEBUG
        if let injected = debugThermalState { return injected }
        #endif
        return ProcessInfo.processInfo.thermalState
    }

    /// Current thermal state, for the status surface (Pillar 4 "cooling down")
    /// and diagnostics.
    func snapshot() -> ProcessInfo.ThermalState { currentState() }

    // MARK: Pacing policy (tunable; device-tune later)

    /// Proactive yield at each state. `.nominal` is light insurance against a
    /// 100% duty cycle; the rest are real backoff. `.critical` doesn't sleep a
    /// fixed amount — it pauses and re-checks until the device drops to `.fair`.
    private static let nominalYieldNanos:    UInt64 =  15_000_000   // 15ms
    private static let fairYieldNanos:       UInt64 =  60_000_000   // 60ms
    private static let seriousCooldownNanos: UInt64 = 250_000_000   // 250ms
    private static let criticalRecheckNanos: UInt64 = 1_000_000_000 // 1s

    /// Pace one heavy work-unit boundary. Sleeps proportionally to thermal
    /// pressure; at `.critical`, loop-waits (re-checking) until the state drops
    /// back to `.nominal`/`.fair`. Returns promptly if the Task is cancelled
    /// (escape switch / per-doc cancel) so a halt is never stuck behind a
    /// cooldown.
    func pace() async {
        if Task.isCancelled { return }
        switch currentState() {
        case .nominal:
            try? await Task.sleep(nanoseconds: Self.nominalYieldNanos)
        case .fair:
            try? await Task.sleep(nanoseconds: Self.fairYieldNanos)
        case .serious:
            try? await Task.sleep(nanoseconds: Self.seriousCooldownNanos)
        case .critical:
            // Hold heavy work entirely until the device cools. Re-check on a
            // slow cadence; bail immediately if cancelled.
            while !Task.isCancelled {
                let state = currentState()
                if state == .nominal || state == .fair { break }
                try? await Task.sleep(nanoseconds: Self.criticalRecheckNanos)
            }
        @unknown default:
            try? await Task.sleep(nanoseconds: Self.fairYieldNanos)
        }
    }
}

// ========== BLOCK 01: THERMAL GOVERNOR - END ==========
