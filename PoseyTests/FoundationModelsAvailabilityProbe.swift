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
    /// response. Skipped automatically when AFM is unavailable so the suite
    /// stays green on simulators / devices without Apple Intelligence.
    func testTinyPromptRoundTrip() async throws {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.availability == .available else {
                NSLog("[POSEY_AFM_PROBE] Skipping round-trip — AFM not available")
                print("[POSEY_AFM_PROBE] Skipping round-trip — AFM not available")
                return
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
                NSLog("[POSEY_AFM_PROBE] Round-trip FAILED — error=%@", "\(error)")
                print("[POSEY_AFM_PROBE] Round-trip FAILED — error=\(error)")
                throw error
            }
        }
        #endif
    }
}
// ========== BLOCK 01: AFM AVAILABILITY PROBE - END ==========
