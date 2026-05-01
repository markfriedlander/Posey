import XCTest
@testable import Posey

// ========== BLOCK 01: AVAILABILITY SMOKE TESTS - START ==========
/// Sanity tests for `AskPoseyAvailability`. The state value is determined by
/// the OS at runtime, so the tests can't assert a specific enum case — they
/// just confirm the API surface returns a consistent, non-throwing value
/// and that `isAvailable` agrees with `current`.
///
/// Real-world behavior is exercised by `FoundationModelsAvailabilityProbe`,
/// which calls into AFM directly and is the canonical source of "does AFM
/// work on this surface?"
final class AskPoseyAvailabilityTests: XCTestCase {

    func testCurrentReturnsAValueAndAgreesWithIsAvailable() {
        let state = AskPoseyAvailability.current
        let flag = AskPoseyAvailability.isAvailable

        if case .available = state {
            XCTAssertTrue(flag, "isAvailable must be true when state is .available")
        } else {
            XCTAssertFalse(flag, "isAvailable must be false for any non-.available state")
        }
    }

    func testDiagnosticDescriptionIsNonEmpty() {
        let description = AskPoseyAvailability.diagnosticDescription
        XCTAssertFalse(description.isEmpty, "diagnostic description should never be empty")
    }

    func testStateIsEquatableForObservation() {
        // `current` reads the live framework state, so we can't compare two
        // separate reads — the underlying state could theoretically change
        // between them. But we can confirm the type's Equatable conformance
        // works as expected, which matters for SwiftUI re-render avoidance.
        let a: AskPoseyAvailabilityState = .available
        let b: AskPoseyAvailabilityState = .available
        let c: AskPoseyAvailabilityState = .deviceNotEligible
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
// ========== BLOCK 01: AVAILABILITY SMOKE TESTS - END ==========
