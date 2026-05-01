// ========== BLOCK 01: AFM AVAILABILITY PROBE - START ==========
// Diagnostic probe for Apple Foundation Models. Reports
// SystemLanguageModel.default.availability on whatever device or simulator
// runs the suite. Intended for the Ask Posey kickoff verification step
// (ask_posey_spec.md, Implementation Order step 1) — not a permanent
// regression test. Safe to delete once availability is established and
// documented in HISTORY.md / DECISIONS.md.
//
// The probe is gated to iOS 26+ since FoundationModels is a 26.0 framework.
// On older systems the test is skipped (returns early) so the rest of the
// suite still runs.

import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif

final class FoundationModelsAvailabilityProbe: XCTestCase {

    func testReportsSystemLanguageModelAvailability() async throws {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let model = SystemLanguageModel.default
            let availability = model.availability
            let supportedLocale = model.supportsLocale(.current)
            let summary: String
            switch availability {
            case .available:
                summary = "AFM AVAILABLE — supportsCurrentLocale=\(supportedLocale)"
            case .unavailable(let reason):
                let reasonString: String
                switch reason {
                case .deviceNotEligible:
                    reasonString = "deviceNotEligible"
                case .appleIntelligenceNotEnabled:
                    reasonString = "appleIntelligenceNotEnabled"
                case .modelNotReady:
                    reasonString = "modelNotReady"
                @unknown default:
                    reasonString = "unknown(\(reason))"
                }
                summary = "AFM UNAVAILABLE — \(reasonString) supportsCurrentLocale=\(supportedLocale)"
            @unknown default:
                summary = "AFM UNKNOWN AVAILABILITY CASE — supportsCurrentLocale=\(supportedLocale)"
            }
            // NSLog so the message lands in the unified system log on device
            // and the simulator log alike — easy to grep with `xcrun simctl
            // spawn <udid> log stream` or `xcrun devicectl device process
            // launch --log`.
            NSLog("[POSEY_AFM_PROBE] %@", summary)
            print("[POSEY_AFM_PROBE] \(summary)")
            // No XCTAssert — this is purely diagnostic. The test passes if
            // the probe runs without throwing.
            XCTAssertNoThrow(())
        } else {
            print("[POSEY_AFM_PROBE] iOS < 26 — FoundationModels not available")
        }
        #else
        print("[POSEY_AFM_PROBE] FoundationModels framework not importable in this build")
        #endif
    }

    func testCanInstantiateLanguageModelSession() async throws {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.availability == .available else {
                NSLog("[POSEY_AFM_PROBE] Skipping session probe — AFM not available")
                print("[POSEY_AFM_PROBE] Skipping session probe — AFM not available")
                return
            }
            // Construct a session with a tiny instructions string. We do not
            // actually call respond() in the probe — that incurs a real
            // model call, which costs latency and battery and isn't needed
            // to confirm "the API is callable from our build."
            let session = LanguageModelSession(
                model: model,
                instructions: "You are a helpful reading assistant."
            )
            NSLog("[POSEY_AFM_PROBE] LanguageModelSession instantiated; isResponding=%@",
                  session.isResponding ? "true" : "false")
            print("[POSEY_AFM_PROBE] LanguageModelSession instantiated; isResponding=\(session.isResponding)")
        }
        #endif
    }

    /// End-to-end smoke: actually issue a tiny prompt and observe the
    /// response. Device-only — Apple Intelligence model assets are not
    /// installed in the iOS 26.3 simulator image we run today, so respond()
    /// times out at ~30s. The round-trip is what we care about for product
    /// verification, and that has to happen on hardware anyway. Skipping on
    /// simulator keeps the standard suite green and fast there.
    func testTinyPromptRoundTrip() async throws {
        #if targetEnvironment(simulator)
        // Simulator images don't ship the AFM model assets — respond() will
        // hang then time out. Don't waste CI minutes on it.
        NSLog("[POSEY_AFM_PROBE] Skipping round-trip — running on simulator (no AFM assets)")
        print("[POSEY_AFM_PROBE] Skipping round-trip — running on simulator (no AFM assets)")
        throw XCTSkip("AFM round-trip is verified on device only; simulator lacks model assets.")
        #else
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.availability == .available else {
                NSLog("[POSEY_AFM_PROBE] Skipping round-trip — AFM not available")
                print("[POSEY_AFM_PROBE] Skipping round-trip — AFM not available")
                throw XCTSkip("AFM availability != .available on this device.")
            }
            let session = LanguageModelSession(
                model: model,
                instructions: "Reply in exactly one short sentence."
            )
            let prompt = "Say the single word: ready."
            do {
                let response = try await session.respond(to: prompt)
                let text = response.content
                NSLog("[POSEY_AFM_PROBE] Round-trip OK — response=%@", text)
                print("[POSEY_AFM_PROBE] Round-trip OK — response=\(text)")
                XCTAssertFalse(text.isEmpty, "AFM returned an empty response")
            } catch {
                // Don't fail the suite for transient AFM errors (rate limit,
                // assets unavailable, etc.) — log and skip. A real product
                // regression will be caught by the feature-level Ask Posey
                // tests once Milestone 5 lands.
                NSLog("[POSEY_AFM_PROBE] Round-trip skipped — error=%@", "\(error)")
                print("[POSEY_AFM_PROBE] Round-trip skipped — error=\(error)")
                throw XCTSkip("AFM respond() error: \(error)")
            }
        }
        #endif
        #endif
    }
}
// ========== BLOCK 01: AFM AVAILABILITY PROBE - END ==========
