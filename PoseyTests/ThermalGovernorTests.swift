import XCTest
@testable import Posey

/// Pillar 2 proof: the thermal governor backs off and PAUSES under thermal
/// pressure, and never delays a cancel (the escape switch). The `.serious` /
/// `.critical` paths are exercised via the DEBUG-injected state, so the
/// safety-critical pause path is verified off-device without ever overheating
/// real hardware.
final class ThermalGovernorTests: XCTestCase {

    actor Flag {
        private(set) var value = false
        func set() { value = true }
    }

    /// `.critical` holds heavy work entirely, then releases once the device
    /// cools back to `.fair`/`.nominal`.
    func testCriticalPausesUntilCooled() async {
        let gov = ThermalGovernor()
        await gov.setDebugThermalState(.critical)

        let done = Flag()
        let task = Task { await gov.pace(); await done.set() }

        // Long enough to span at least one critical re-check (1s cadence).
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let stillPaused = await (done.value == false)
        XCTAssertTrue(stillPaused, "pace() must hold while thermal state is .critical")

        // Cool it — pace() should release on its next re-check.
        await gov.setDebugThermalState(.nominal)
        await task.value
        let finished = await done.value
        XCTAssertTrue(finished, "pace() must return once the device cools")
    }

    /// A cancel (escape switch) is never stuck behind a thermal pause: even at
    /// `.critical`, pace() returns promptly when the Task is cancelled.
    func testCriticalReturnsPromptlyOnCancel() async {
        let gov = ThermalGovernor()
        await gov.setDebugThermalState(.critical)

        let done = Flag()
        let task = Task { await gov.pace(); await done.set() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        await task.value
        let finished = await done.value
        XCTAssertTrue(finished, "pace() must return on cancel even at .critical")
    }

    /// The non-pressure states just yield briefly and return (no hang).
    func testNominalAndFairReturn() async {
        let gov = ThermalGovernor()
        for state in [ProcessInfo.ThermalState.nominal, .fair, .serious] {
            await gov.setDebugThermalState(state)
            await gov.pace()   // completes (test would hang otherwise)
        }
        let snap = await gov.snapshot()
        XCTAssertEqual(snap, .serious, "snapshot reflects the injected state")
    }
}
