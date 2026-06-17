import Foundation

// ========== BLOCK 01: SPOILER CATCHER (Layer 2) - START ==========

/// Layer 2 of the spoiler firewall — the post-generation catcher. In the magic
/// version (full RAG hands Posey the whole book; the Layer-1 prompt asks her to
/// withhold) THIS is the primary guard: it deterministically verifies she
/// actually withheld, and rewrites the answer in character when she didn't.
///
/// Per sentence of a drafted answer:
///   1. **Locate** where the sentence's content FIRST occurs in the document —
///      earliest-occurrence via hybrid retrieval, mapped to a plainText offset.
///   2. **Position gate.** If that offset is at/before the reader's furthest-
///      read position → SAFE (they've already read it). This single gate also
///      handles the non-narrative / Heather's-RFP case for free: a fact that
///      first appears early is answered; one that appears later still must pass
///      the judge, which says "not a narrative event" → answered.
///   3. **Judge.** Only for content that first appears AFTER the position: ask
///      the pluggable engine whether the sentence is a plot-concrete NARRATIVE
///      EVENT (something that HAPPENS — death, betrayal, reveal, outcome) vs a
///      theme/fact/description. Only a YES is a spoiler.
/// Any spoiler → regenerate the whole answer in character, withholding those
/// events; re-check once; fall back to a safe in-character deflection if the
/// rewrite still leaks.
///
/// **Pluggable judge engine (A/B — Mark: do NOT presume AFM).** The judge runs
/// through `LLMService` with an explicitly chosen `ModelConfiguration`, so the
/// engine is just MLX-answer-model vs AFM — selected by `engine` (default MLX;
/// the A/B test on real Frankenstein/Alice probes decides which ships).
///
/// See `docs-internal/ASK_POSEY_V1_RELEASE_PLAN.md` § 🔒.
@MainActor
final class SpoilerCatcher {

    // ===== BLOCK 01a: ENGINE SELECTION (A/B) - START =====

    /// Which model judges narrative-event-ness. Pluggable so the A/B test can
    /// measure MLX vs AFM leak rates and ship the better one.
    enum Engine: String, CaseIterable, Sendable {
        case mlx
        case afm

        /// The model the judge call routes through. MLX → the active answer
        /// model (a downloaded MLX model, guaranteed present when Ask Posey is
        /// reachable). AFM → Apple Foundation Models.
        var model: ModelConfiguration {
            switch self {
            case .mlx: return ModelCatalog.answerModel()
            case .afm: return ModelCatalog.appleFoundation
            }
        }
    }

    static let engineDefaultsKey = "Posey.SpoilerCatcher.engine"

    /// Active judge engine. Default MLX — Mark is skeptical AFM's judgment is
    /// better; the A/B test measures it. Set by the antenna A/B verb.
    static var engine: Engine {
        get { Engine(rawValue: UserDefaults.standard.string(forKey: engineDefaultsKey) ?? "") ?? .mlx }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: engineDefaultsKey) }
    }

    // ===== BLOCK 01a: ENGINE SELECTION (A/B) - END =====

    // ===== BLOCK 01b: RESULT TYPES - START =====

    struct FlaggedSentence: Sendable, Equatable {
        let sentence: String
        /// Earliest plainText offset where this sentence's content occurs —
        /// proven to be past the reader's furthest position.
        let earliestOffset: Int
    }

    struct CatchResult: Sendable, Equatable {
        /// Sentences in the ORIGINAL draft judged to be spoilers. Empty → clean.
        let flagged: [FlaggedSentence]
        /// The answer to show the reader: the original draft when nothing was
        /// flagged, otherwise the in-character rewrite (or the safe fallback).
        let safeAnswer: String
        /// Which engine judged this pass — recorded for the A/B test.
        let engine: Engine
        var caughtSpoiler: Bool { !flagged.isEmpty }
    }

    // ===== BLOCK 01b: RESULT TYPES - END =====

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    /// A safe, in-character deflection used when regeneration itself still leaks
    /// (or fails). Never reveals anything — pure anticipation.
    static let fallbackDeflection =
        "Ah — now that would be telling. You're not there yet, and I'm not about to rob you of getting there yourself. Keep reading; trust me, it's worth it."

    // ===== BLOCK 02: PUBLIC ENTRY - START =====

    /// Run the full catch: detect spoilers in `answer`; if any, regenerate in
    /// character and re-check once. Returns the answer safe to show + which
    /// sentences were caught (for diagnostics / the A/B test). Pure read of the
    /// document; the only writes are model calls (free, on-device).
    func process(
        answer: String,
        question: String,
        documentID: UUID,
        furthestOffset: Int,
        plainText: String
    ) async -> CatchResult {
        let engine = Self.engine
        let ctx = buildLocatorContext(documentID: documentID)

        let flagged = await detect(
            answer: answer,
            documentID: documentID,
            furthestOffset: furthestOffset,
            ctx: ctx,
            engine: engine
        )
        guard !flagged.isEmpty else {
            return CatchResult(flagged: [], safeAnswer: answer, engine: engine)
        }

        // Regenerate in character, then verify the rewrite didn't re-leak.
        let rewritten = await regenerate(question: question, draft: answer, flagged: flagged)
        let recheck = await detect(
            answer: rewritten,
            documentID: documentID,
            furthestOffset: furthestOffset,
            ctx: ctx,
            engine: engine
        )
        let safe = recheck.isEmpty ? rewritten : Self.fallbackDeflection
        return CatchResult(flagged: flagged, safeAnswer: safe, engine: engine)
    }

    // ===== BLOCK 02: PUBLIC ENTRY - END =====

    // ===== BLOCK 03: DETECTION - START =====

    /// Chunk-index → earliest plainText offset, precomputed once per document so
    /// the two detect() passes don't rebuild it.
    private struct LocatorContext {
        let offsetByChunkIndex: [Int: Int]
    }

    /// Build the chunk→plainText-offset map. Chunks are unit-anchored
    /// (`start_unit_id` + `start_intra_offset`); plainText is prose-carrying
    /// units joined by "\n\n" (see `DatabaseManager.plainText(for:)`), so a
    /// prose unit's start offset is the running sum of (text.count + 2) over the
    /// preceding prose units. A chunk anchored to a non-prose unit (image/table)
    /// has no plainText offset and is simply absent from the map → unlocatable →
    /// not flaggable (we never deflect on content we can't position).
    private func buildLocatorContext(documentID: UUID) -> LocatorContext {
        let units = (try? database.units(for: documentID)) ?? []
        var offsetByUnit: [UUID: Int] = [:]
        var cum = 0
        for u in units where u.kind.carriesProseText {
            offsetByUnit[u.id] = cum
            cum += u.text.count + 2   // "\n\n" join separator
        }
        let chunks = (try? database.unitEmbeddingChunks(for: documentID)) ?? []
        var offsetByChunkIndex: [Int: Int] = [:]
        for c in chunks {
            if let base = offsetByUnit[c.startUnitID] {
                offsetByChunkIndex[c.chunkIndex] = base + c.startIntraOffset
            }
        }
        return LocatorContext(offsetByChunkIndex: offsetByChunkIndex)
    }

    /// Detect spoiler sentences in `answer`: per sentence, locate earliest
    /// occurrence; if past the reader's position, ask the judge if it's a
    /// narrative event. Returns the flagged sentences (empty → clean).
    private func detect(
        answer: String,
        documentID: UUID,
        furthestOffset: Int,
        ctx: LocatorContext,
        engine: Engine
    ) async -> [FlaggedSentence] {
        let sentences = AskPoseyPromptBuilder.splitIntoSentences(answer)
        guard !sentences.isEmpty else { return [] }
        let retriever = HybridRetriever(database: database)

        var flagged: [FlaggedSentence] = []
        for sentence in sentences {
            // Skip trivially short fragments — too little signal to locate or
            // judge, and almost never a standalone plot reveal.
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count < 25 { continue }

            // 1+2. Earliest occurrence + position gate.
            guard let earliest = earliestOccurrence(
                of: trimmed, documentID: documentID, retriever: retriever, ctx: ctx
            ) else { continue }                       // unlocatable → don't flag
            if earliest <= furthestOffset { continue } // already read → safe

            // 3. Judge: is it a plot-concrete narrative event?
            if await isNarrativeEvent(trimmed, engine: engine) {
                flagged.append(FlaggedSentence(sentence: trimmed, earliestOffset: earliest))
            }
        }
        return flagged
    }

    /// Earliest plainText offset where the sentence's content appears, via
    /// hybrid retrieval. Takes the minimum mapped offset among the top matches
    /// that clear the retrieval confidence floor — "where in the book does this
    /// first show up." nil when nothing maps (content not strongly present in
    /// the document → not a position-spoiler).
    private func earliestOccurrence(
        of sentence: String,
        documentID: UUID,
        retriever: HybridRetriever,
        ctx: LocatorContext
    ) -> Int? {
        let outcome = retriever.retrieve(documentID: documentID, query: sentence, limit: 5)
        // Require some grounding — a sentence Posey invented (no real match)
        // shouldn't be positioned at a spurious chunk and falsely flagged.
        guard outcome.topRelevance >= HybridRetriever.confidenceFloor else { return nil }
        var earliest: Int? = nil
        for chunk in outcome.results {
            guard let off = ctx.offsetByChunkIndex[chunk.chunkID] else { continue }
            if earliest == nil || off < earliest! { earliest = off }
        }
        return earliest
    }

    // ===== BLOCK 03: DETECTION - END =====

    // ===== BLOCK 04: JUDGE (pluggable engine) - START =====

    /// Ask the active engine whether a sentence reveals a plot-concrete
    /// NARRATIVE EVENT (vs a theme/fact/description). One-shot, temperature 0,
    /// parsed as YES/NO. On any failure returns false (fail-open on the judge so
    /// a model hiccup never deflects a safe answer — the position gate already
    /// established this content is past the line, so a missed judge is a missed
    /// catch, the less-bad direction for trust).
    private func isNarrativeEvent(_ sentence: String, engine: Engine) async -> Bool {
        let system = "You are a precise literary classifier. Reply with exactly one word: YES or NO. No explanation."
        let user = """
        Does the following sentence reveal a plot-concrete NARRATIVE EVENT — something that HAPPENS in the story (an action, death, betrayal, reveal, twist, escape, reunion, or outcome; who does what to whom)?

        Answer NO if it is instead a theme, an idea, a description of a setting or character, a definition, a character's introduction, or a general fact rather than an event.

        Sentence: "\(sentence)"

        Answer YES or NO only.
        """
        let raw = await complete(system: system, user: user, model: engine.model, temperature: 0.0)
        let upper = raw.uppercased()
        // Take the first YES/NO token to appear; default NO (fail-open).
        if let yes = upper.range(of: "YES"), let no = upper.range(of: "NO") {
            return yes.lowerBound < no.lowerBound
        }
        return upper.contains("YES")
    }

    // ===== BLOCK 04: JUDGE - END =====

    // ===== BLOCK 05: REGENERATION - START =====

    /// Rewrite the draft in character, withholding the flagged events. Always
    /// uses the ANSWER model (MLX) — voice matters here, and this is the text
    /// the reader sees. Returns the safe fallback deflection if the model
    /// returns nothing usable.
    private func regenerate(question: String, draft: String, flagged: [FlaggedSentence]) async -> String {
        let forbidden = flagged.map { "- \"\($0.sentence)\"" }.joined(separator: "\n")
        let system = """
        You are Posey, the reader's knowing companion. You have read this entire \
        book; the reader has not. Your previous draft gave away plot events the \
        reader hasn't reached yet. Rewrite it: answer what you safely can, and \
        withhold the off-limits events — be coy and warm, build anticipation, \
        never a flat refusal. Do NOT restate, confirm, paraphrase, or hint \
        specifically at any off-limits event. Keep your voice. No preamble, no \
        meta-commentary about spoilers.
        """
        let user = """
        READER'S QUESTION:
        \(question)

        YOUR DRAFT (it leaks spoilers):
        \(draft)

        OFF-LIMITS — events past the reader's position; do not reveal, confirm, or hint at:
        \(forbidden)

        Rewrite your answer now, withholding the off-limits events, in character.
        """
        let raw = await complete(system: system, user: user,
                                 model: ModelCatalog.answerModel(), temperature: 0.5)
        let cleaned = AskPoseyPromptBuilder.stripPolishPreamble(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? Self.fallbackDeflection : cleaned
    }

    // ===== BLOCK 05: REGENERATION - END =====

    // ===== BLOCK 06: ONE-SHOT COMPLETION - START =====

    /// One-shot (non-streaming) completion through `LLMService`. The facade
    /// dispatches on `model.source`, so the SAME call drives MLX or AFM — that's
    /// what makes the judge engine a one-line A/B swap. Accumulates the
    /// cumulative snapshots and returns the final text; "" on error.
    private func complete(system: String, user: String,
                          model: ModelConfiguration, temperature: Double) async -> String {
        var accumulated = ""
        do {
            for try await snapshot in LLMService.shared.streamChat(
                messages: [
                    ChatMessage(role: .system, content: system),
                    ChatMessage(role: .user, content: user)
                ],
                model: model,
                options: LLMGenerationOptions(temperature: temperature)
            ) {
                accumulated = snapshot
            }
        } catch {
            return ""
        }
        return accumulated
    }

    // ===== BLOCK 06: ONE-SHOT COMPLETION - END =====
}

// ========== BLOCK 01: SPOILER CATCHER (Layer 2) - END ==========
