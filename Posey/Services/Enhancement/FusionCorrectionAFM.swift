import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// ========== BLOCK 01: GENERABLE SCHEMA - START ==========

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct FusionCorrectionVerdict: Sendable {

    @Guide(description: "The single TOKEN you were given, judged using the LINE it appears in. If the token is a clear OCR fusion of two or more ordinary words (e.g. ANETERNAL, WellTempered), output it split into those words with spaces. If the token is a mathematical or logical formula, an equation, source code, a programming identifier, an acronym, a brand name, or a personal/place name, output it UNCHANGED. Output ONLY the token (corrected or unchanged) — NEVER the surrounding line. Match the case of the input — all uppercase stays uppercase; mixed case preserved where possible.")
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

    /// Returns the AFM verdict for `token`, judged in the context of
    /// `context` (the line/sentence the token appeared in), or nil on
    /// any failure / AFM-unavailable path.
    ///
    /// 2026-06-09 (Mark) — context added to stop catastrophic formula
    /// mangling. Without surrounding text AFM saw a bare token like
    /// `Va:(atO)=a` and "split" the OCR-garbled TNT formula ∀a:(a+0)=a
    /// into the nonsense words "VA AT O". Given the line, AFM can tell a
    /// formula / equation / code / notation from a real word-fusion and
    /// leave the former UNCHANGED. The context is used ONLY to judge the
    /// one token — AFM never rewrites the surrounding text.
    static func correct(_ token: String, context: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return await Self.correctIfAvailable(token, context: context)
        }
        return nil
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private static func correctIfAvailable(_ token: String, context: String) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return nil
        }

        let instructions = """
        You repair PDF text-extraction errors where two or more ordinary \
        words got incorrectly joined into ONE token. You are given a TOKEN \
        and the LINE it appears in. Use the line ONLY to judge that one \
        token. Decide:

        - If the token is a clear fusion of two or more ordinary words, \
          output it split into those words with spaces (use a hyphen \
          instead only when that is the conventional written form, e.g. \
          "WellTempered" → "Well-Tempered").
        - Otherwise output the token UNCHANGED.

        **Leave the token UNCHANGED when the line shows it is:**
        - a mathematical or logical FORMULA / equation / notation (it sits \
          among symbols like = + : ( ) and digits, or near words like \
          "axiom", "theorem", "proof", "specification") — e.g. \
          `Va:(atO)=a`, `S(SO+O)`, `(x→y)`. Mangling a formula is the \
          WORST possible error; when in doubt about notation, KEEP IT.
        - source code or a programming identifier (NSDictionary, getValue).
        - an acronym, brand name, or a personal / place name.

        **CamelCase tokens** (a lowercase letter directly followed by an \
        uppercase one, e.g. PowerPoint, iPhone, JavaScript) are usually \
        intentional brands/identifiers — KEEP unless the line makes a real \
        word-fusion obvious.

        Critical: output ONLY the token — corrected or unchanged. NEVER \
        output any of the surrounding line.

        Examples (token | line → output):
          ANETERNAL | "Godel Escher Bach ANETERNAL GOLDEN BRAID"        → AN ETERNAL   (word fusion, split)
          WellTempered | "fugues from Bach's WellTempered Clavier"      → Well-Tempered (word fusion)
          AddisonWesley | "published by AddisonWesley in 1979"          → Addison Wesley (word fusion)
          Va:(atO)=a | "(4) Va:(atO)=a axiom 2  (5) (SO+O)=SO"          → Va:(atO)=a   (FORMULA — keep)
          HOFSTADTER | "by Douglas HOFSTADTER, a professor"             → HOFSTADTER   (surname — keep)
          NSDictionary | "store it in an NSDictionary keyed by id"      → NSDictionary (identifier — keep)
        """

        let prompt = """
        Line: \(context)
        Token: \(token)
        """

        let session = LanguageModelSession(
            model: model,
            instructions: instructions
        )

        do {
            // 2026-06-09 (Mark) — greedy (argmax) sampling. Fusion split-vs-keep
            // is a near-deterministic CLASSIFICATION, not creative generation:
            // we want the single most-confident answer, and we want it to be the
            // SAME on every import (the prior default sampling made the per-token
            // verdict vary run to run — 15/12/11 changes across three GEB runs).
            // Greedy removes that variance entirely (same token+line → same
            // verdict) with no downside for this task; the output-resegmentation
            // invariant still backstops. Mirrors the temperature:0.0 Posey
            // already uses for query expansion (another classification task).
            let response = try await session.respond(
                to: prompt,
                generating: FusionCorrectionVerdict.self,
                options: GenerationOptions(sampling: .greedy)
            )
            let corrected = response.content.corrected
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Output invariant (Mark, 2026-06-09): a fusion correction may
            // only RE-SEGMENT the token — insert spaces/hyphens between its
            // existing characters — never add or remove letters. With the
            // line now in the prompt, AFM occasionally "completes" a token
            // from context (e.g. token "FREDERICK" in "…FREDERICK THE GREAT…"
            // → "FREDERICK THE GREAT"), which the whole-document swap then
            // DUPLICATES into "FREDERICK THE GREAT THE GREAT". Reject any
            // output whose alphanumeric content differs from the input and
            // keep the token unchanged. This is an OUTPUT correctness check
            // (what "fusion repair" means), NOT an input-class skip — it
            // passes every genuine split (WellTempered→Well-Tempered,
            // ANETERNAL→AN ETERNAL) and also backstops formula hallucination.
            guard isPureResegmentation(of: token, into: corrected) else {
                return token   // keep original; recorded as a "kept" verdict
            }
            return corrected
        } catch {
            // Refusal or other error → silent skip.
            return nil
        }
    }

    /// True iff `corrected` is `token` with only separators (whitespace /
    /// hyphens / punctuation) re-arranged — i.e. identical alphanumeric
    /// content, case-insensitive. Guarantees a correction never adds or
    /// drops letters/words.
    fileprivate static func isPureResegmentation(of token: String, into corrected: String) -> Bool {
        func core(_ s: String) -> String {
            String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        let a = core(token)
        return !a.isEmpty && a == core(corrected)
    }
    #endif
}

// ========== BLOCK 02: FUSION CORRECTION CALL - END ==========
