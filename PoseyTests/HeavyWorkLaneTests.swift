import XCTest
@testable import Posey

/// Block B proof: the global serial lane runs exactly ONE heavy op at a
/// time even under many concurrent submissions. An independent tracker
/// measures actual body overlap; the lane's own `maxConcurrentObserved`
/// and the non-overlapping event ring are cross-checked.
final class HeavyWorkLaneTests: XCTestCase {

    actor ConcurrencyTracker {
        private(set) var current = 0
        private(set) var maxConcurrent = 0
        func enter() { current += 1; maxConcurrent = max(maxConcurrent, current) }
        func exit() { current -= 1 }
    }

    func testRunsExactlyOneOpAtATime() async {
        let lane = HeavyWorkLane.shared
        await lane.resetTelemetry()
        let tracker = ConcurrencyTracker()

        // Submit 24 ops concurrently; each marks enter/exit around a short
        // sleep. If the lane serializes, the tracker never sees 2 inside.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<24 {
                group.addTask {
                    await lane.run(label: "op\(i)") {
                        await tracker.enter()
                        try? await Task.sleep(nanoseconds: 3_000_000) // 3ms "heavy work"
                        await tracker.exit()
                    }
                }
            }
        }

        let trackedMax = await tracker.maxConcurrent
        XCTAssertEqual(trackedMax, 1, "lane must execute exactly one op body at a time")

        let status = await lane.status()
        XCTAssertEqual(status.maxConcurrentObserved, 1, "lane self-check: maxConcurrentObserved must be 1")
        XCTAssertEqual(status.totalCompleted, 24, "all 24 ops completed")
        XCTAssertNil(status.currentLabel, "lane idle after all complete")

        // Recorded START/END intervals must not overlap (the sequential proof).
        let sorted = status.recent.sorted { $0.startedAt < $1.startedAt }
        for i in 1..<sorted.count {
            XCTAssertGreaterThanOrEqual(
                sorted[i].startedAt, sorted[i - 1].endedAt,
                "heavy-op intervals must never overlap")
        }
    }

    func testPropagatesResultAndThrows() async throws {
        let lane = HeavyWorkLane.shared
        // Returns a value.
        let v = await lane.run(label: "value") { 41 + 1 }
        XCTAssertEqual(v, 42)
        // Propagates a throw (rethrows).
        struct Boom: Error {}
        do {
            _ = try await lane.run(label: "throws") { () throws -> Int in throw Boom() }
            XCTFail("should have rethrown")
        } catch is Boom {
            // expected
        }
    }
}
