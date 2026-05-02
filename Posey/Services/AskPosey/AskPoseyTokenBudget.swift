import Foundation

// ========== BLOCK 01: TOKEN ESTIMATOR - START ==========
/// Cheap, dependency-free token-count estimator. Apple Foundation
/// Models doesn't expose a public tokenizer at iOS 26.4, so the prompt
/// builder needs a portable approximation to enforce per-section
/// budgets before paying the cost of a real call.
///
/// The 3.5 chars/token ratio matches Hal's empirical default for
/// English prose; AFM's actual tokenizer is roughly comparable for the
/// kinds of inputs Posey produces (system framing + short anchor
/// passages + short conversational turns + occasional document chunks).
/// This is a starting point — if the local-API tuning loop shows the
/// budget consistently under- or over-shooting, the constant is a
/// single line to change.
///
/// `nonisolated` because the estimator is consumed by the prompt
/// builder (which is `nonisolated`), tests, and a future Generable
/// streamer that may run off the main actor.
nonisolated enum AskPoseyTokenEstimator {
    /// Empirical chars-per-token ratio for English prose. Tune via
    /// the local-API loop; do not bake other constants in terms of
    /// this number — if the ratio changes, only this line should change.
    ///
    /// **2026-05-02 tuning.** AFM's actual tokenizer counts more
    /// densely than our 3.5 estimate suggested — real Q&A overflowed
    /// the 4096 context window even when we measured well under
    /// budget (e.g. 4091 actual tokens vs ~3584 estimated). Tightening
    /// to 3.0 chars/token gives a more pessimistic estimate, so the
    /// drop logic kicks in earlier and we stay under AFM's actual
    /// limit. Combined with the larger response reserve (1024) below,
    /// this gives ~25% headroom for tokenizer disagreement.
    static let charsPerToken: Double = 3.0

    /// Approximate token count for a string. Floors at 1 for any
    /// non-empty input so a single-character section still costs
    /// something against budget; returns 0 for the empty string so
    /// "is this section worth including" gates can early-exit.
    static func tokens(in text: String) -> Int {
        if text.isEmpty { return 0 }
        let raw = Double(text.count) / charsPerToken
        return max(1, Int(raw.rounded()))
    }

    /// Approximate character budget for a token target. Used when the
    /// builder needs to truncate a section to fit a remaining budget
    /// (e.g. last-resort user-input truncation).
    static func chars(in tokens: Int) -> Int {
        max(0, Int((Double(tokens) * charsPerToken).rounded()))
    }
}
// ========== BLOCK 01: TOKEN ESTIMATOR - END ==========


// ========== BLOCK 02: TOKEN BUDGET - START ==========
/// Per-section token allocations for the Ask Posey prompt builder.
/// Every value is a named, documented property — there are no magic
/// numbers buried inside the builder's logic. This is the single place
/// to tune the architecture once the local-API loop reveals what the
/// model actually does with real documents and real conversations.
///
/// **Starting values for AFM (4096-token context window):**
///
/// - 512 tokens reserved for the response (~5–8 sentences of prose,
///   tight but adequate for focused reading-companion answers; tune
///   up if responses get truncated mid-sentence in practice).
/// - Remaining 3584 tokens make up the prompt ceiling, allocated by
///   rough percentages:
///   - 5%  (~180) — system + instructions; never dropped
///   - 10% (~360) — anchor + immediate surrounding; never dropped
///   - 20% (~720) — recent verbatim conversation history (~3–4 turns)
///   - 10% (~360) — compressed older-turn summary (M6 fills; M5 nil)
///   - 50% (~1800) — document RAG chunks (M6 fills; M5 empty)
///   - User question gets the remainder, protected, truncated only
///     as a last resort.
///
/// Sum of the section budgets is intentionally below the prompt
/// ceiling so the builder has slack for the user question and for
/// HelPML scaffolding overhead.
nonisolated struct AskPoseyTokenBudget: Sendable, Equatable {

    // MARK: - Hard limits

    /// AFM context window — model rejects anything over this. Hard
    /// ceiling shared by every Ask Posey request.
    var contextWindowTokens: Int = 4096

    /// Tokens reserved for the model's response. Bumped from 512 →
    /// 1024 on 2026-05-02 after real Q&A revealed AFM's actual token
    /// count exceeded our estimate by ~14% — even with the prompt
    /// builder reporting "well under budget" we were hitting AFM's
    /// 4096 context window with `exceededContextWindowSize` errors.
    /// 1024-token reserve plus the tightened chars-per-token estimate
    /// (3.0 instead of 3.5) gives ~25% headroom for tokenizer
    /// disagreement.
    var responseReserveTokens: Int = 1024

    // MARK: - Section sub-budgets (sum ≈ prompt ceiling)

    /// System framing + per-call instructions. Never dropped; if a
    /// future Posey identity grows beyond this budget, raise the cap
    /// here rather than special-casing in the builder.
    /// 2026-05-02: still 180 — system instructions stayed under
    /// budget despite the rewrites.
    var systemBudgetTokens: Int = 180

    /// Anchor passage + immediate surrounding context. Non-droppable
    /// in passage-scoped invocation — the entire point is grounding
    /// the answer in this specific passage. The "surrounding" portion
    /// is sized by intent (`AskPoseyPromptBuilder.surroundingWindowTokens`)
    /// inside this allocation.
    /// 2026-05-02: 360 → 300 to fit the tightened response-reserve.
    var anchorBudgetTokens: Int = 300

    /// Recent verbatim conversation history (most recent ~3–4 turns).
    /// Highest-priority droppable section: budget overflow drops
    /// older STM turns one at a time, preserving the most recent.
    /// 2026-05-02: 720 → 600. Narrative-summary format compresses
    /// well; ~3 turns still fit.
    var stmBudgetTokens: Int = 600

    /// Compressed older-turn summary. M6's background summarizer
    /// populates this. 2026-05-02: 360 → 300 to fit budget.
    var summaryBudgetTokens: Int = 300

    /// Retrieved document chunks (RAG). 2026-05-02: 1800 → 1400 to
    /// fit the tightened response-reserve. Front-matter chunks
    /// (relevance 1.0) still survive; cosine-ranked chunks lower in
    /// the list drop sooner under the smaller cap.
    var ragBudgetTokens: Int = 1400

    // MARK: - Derived

    /// Total tokens available for prompt content. Anything above this
    /// cuts into the response reserve and risks AFM truncating its
    /// own reply.
    var promptCeilingTokens: Int { contextWindowTokens - responseReserveTokens }

    /// Sum of the explicit section budgets. Useful for diagnostics
    /// — the difference between this and `promptCeilingTokens` is
    /// the slack the builder has for the user question and HelPML
    /// scaffolding overhead.
    var allocatedSectionBudget: Int {
        systemBudgetTokens
            + anchorBudgetTokens
            + stmBudgetTokens
            + summaryBudgetTokens
            + ragBudgetTokens
    }

    /// Whatever remains for the current user question after the other
    /// sections claim their allocations. Always non-negative — clamps
    /// at 0 if the section budgets are mis-tuned to overflow.
    var userQuestionBudgetTokens: Int {
        max(0, promptCeilingTokens - allocatedSectionBudget)
    }

    /// Standard configuration for AFM. The single source the rest of
    /// Posey reaches for; explicit `AskPoseyTokenBudget(...)` calls
    /// stay rare (mostly tests that want to force overflow paths).
    static let afmDefault = AskPoseyTokenBudget()
}
// ========== BLOCK 02: TOKEN BUDGET - END ==========
