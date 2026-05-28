import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// ========== BLOCK 01: GENERABLE SCHEMA - START ==========

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct FusionCorrectionVerdict: Sendable {

    @Guide(description: "If the input word is two or more words incorrectly joined together (a fusion error from PDF text extraction), output the corrected form with proper spaces between the words. If the input is a single legitimate word, a personal name, a place name, an acronym, a brand name, a programming identifier, or any other meaningful single token, output the input UNCHANGED. Match the case of the input — if the input is all uppercase, return uppercase; if mixed case, preserve the case structure where possible.")
    let corrected: String
}
#endif

// ========== BLOCK 01: GENERABLE SCHEMA - END ==========


// ========== BLOCK 02: FUSION CORRECTION CALL - START ==========

/// Phase 2.2 Step 6 — single-token fusion correction via AFM.
///
/// Per CLAUDE.md Rule 6 (local inference is free), we issue **one
/// AFM call per suspect token** rather than batching for batching's
/// sake. A focused prompt with one input gives AFM the clearest
/// possible signal; batching twenty tokens into one call risks
/// confused output and partial refusals. Sequential AFM calls also
/// give the actor isolation natural pacing — no explicit cooldown
/// needed (matches the existing `BackgroundEnhancementScheduler`
/// Phase B pattern).
///
/// Behavior:
///   - On AFM unavailable (iOS < 26, simulator missing models,
///     model gating): returns `nil` — caller treats as "keep
///     original token unchanged."
///   - On AFM refusal: returns `nil`. Silent fallback per Mark's
///     directive — refusals on fusion-repair candidates are
///     vanishingly rare anyway since the input is a single
///     short word.
///   - On success with `corrected == input`: AFM kept the token.
///     Caller still records the verdict in
///     `document_afm_corrections` (with `corrected = original`) so
///     the same token isn't re-evaluated on subsequent runs.
enum FusionCorrectionAFM {

    /// Returns the AFM verdict for `token`, or nil on any failure /
    /// AFM-unavailable path.
    static func correct(_ token: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return await Self.correctIfAvailable(token)
        }
        return nil
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private static func correctIfAvailable(_ token: String) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return nil
        }

        let instructions = """
        You correct PDF text-extraction errors where two or more \
        words have been incorrectly joined into a single token. For \
        each input word, decide:

        - If the word is a single legitimate word, name, place, \
          acronym, brand name, technical term, or programming \
          identifier, return it UNCHANGED.
        - If the word is two or more words incorrectly joined, return \
          the corrected form with proper spaces.

        **CamelCase tokens (a lowercase letter followed by an \
        uppercase letter within a single token, e.g. PowerPoint, \
        iPhone, DataVault, JavaScript) are almost always intentional \
        brand names or programming identifiers and should be returned \
        UNCHANGED.** Splitting a CamelCase brand into two words \
        damages the document. Only split a CamelCase token when you \
        are very confident it's a real fusion error (e.g. an all-caps \
        token that happens to contain a lowercase letter from an OCR \
        glitch).

        All-uppercase fused tokens (ANETERNAL, INTHESPIRIT) are the \
        common real fusion errors — those typically should be split. \
        A single uppercase word (HOFSTADTER, DIFFERENT) is a regular \
        word or proper noun and stays unchanged.

        Examples:
          ANETERNAL          → AN ETERNAL          (all-caps fusion, split)
          INTHESPIRIT        → IN THE SPIRIT       (all-caps fusion, split)
          HOFSTADTER         → HOFSTADTER          (legitimate surname)
          DIFFERENT          → DIFFERENT           (legitimate word)
          PowerPoint         → PowerPoint          (CamelCase brand — KEEP)
          iPhone             → iPhone              (CamelCase brand — KEEP)
          DataVault          → DataVault           (CamelCase brand — KEEP)
          KeyInfrastructure  → KeyInfrastructure   (CamelCase technical name — KEEP)
          JavaScript         → JavaScript          (CamelCase technical name — KEEP)
          cATclaW            → cATclaW             (stylized typography — KEEP)
          NSDictionary       → NSDictionary        (programming identifier — KEEP)

        Output only the corrected (or unchanged) word.
        """

        let prompt = """
        Word: \(token)
        """

        let session = LanguageModelSession(
            model: model,
            instructions: instructions
        )

        do {
            let response = try await session.respond(
                to: prompt,
                generating: FusionCorrectionVerdict.self
            )
            return response.content.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // Refusal or other error → silent skip.
            return nil
        }
    }
    #endif
}

// ========== BLOCK 02: FUSION CORRECTION CALL - END ==========
