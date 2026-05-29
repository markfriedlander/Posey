import Foundation
import NaturalLanguage

// ========== BLOCK 01: SHARED SUMMARY VERIFIER - START ==========
/// Embedding-cosine fact-checker for Ask Posey conversation summaries.
///
/// **Why this exists (DECISION 2, 2026-05-29 "Memory architecture:
/// Posey is not Hal").** Hallucination can enter at *any* generative
/// step — the initial rolling summary AND any later re-compression. So
/// verification is bound to the summarizer/compressor itself: every
/// time a summary is produced, it is fact-checked against its verbatim
/// source *before* it is used. There is no single "verify at moment X";
/// whatever was just generated gets checked, once, where it is
/// produced. Verification is on-device embedding math (no network,
/// cheap), so running it every time is free; only the generation is
/// costly.
///
/// **Mechanism.** Split the summary into sentences. Embed each. Take
/// its maximum cosine similarity against the embedded source sentences.
/// DROP any summary sentence whose max cosine is below `threshold`.
/// Posey drops the ungrounded sentence rather than Hal's
/// splice-the-source-sentence repair, because Posey's summary is a
/// third-person narrative ("the user asked…", "Posey explained…") and
/// grafting verbatim first/second-person source lines into it breaks
/// voice.
///
/// **Conservative by construction.** The rule is "drop what we KNOW is
/// ungrounded," never "drop what we merely cannot measure." So:
/// - No embedder available → keep everything (no-op).
/// - No reference vectors (empty source) → keep everything.
/// - Filtering would empty the summary → keep the original unchanged
///   (an empty summary destroys all conversational continuity; a
///   wholesale-empty result almost always means the summary was more
///   abstractive than any single source sentence, not that every
///   sentence is fabricated — the summary was generated at temp 0.2
///   from the verbatim transcript with explicit "never invent" rules,
///   so isolated drift is the realistic failure, not total invention).
///
/// This is the single verification implementation. Both the live
/// rolling-summary path (`AskPoseyService.summarizeConversation`) and
/// the gated pairwise path (`AskPoseyPairwiseSummarizer`) use it, so
/// there is one cosine threshold and one sentence-split everywhere.
struct AskPoseySummaryVerifier {

    /// Cosine threshold a summary sentence must clear against the
    /// closest source sentence. 0.45 ≈ "same topic in similar
    /// vocabulary." Deliberately below the citation threshold (0.50)
    /// because summaries paraphrase more than answer text quotes do;
    /// tightening it triggers excessive drops without buying fidelity.
    /// VALUE is testing-pending per the memory-architecture decision —
    /// every drop is logged with its cosine + sentence so the
    /// unscripted conversational testing can reveal over/under-dropping
    /// before this is treated as final.
    static let defaultThreshold: Double = 0.45

    struct ScoredSentence: Equatable {
        let text: String
        let maxCosine: Double
    }

    struct Result {
        /// Every summary sentence with its computed max cosine.
        let scored: [ScoredSentence]
        /// Sentences that cleared the threshold, in original order.
        let kept: [String]
        /// Sentences below threshold, sorted ascending cosine (worst
        /// first) so the caller can quote the worst offender back to
        /// the model on a rewrite attempt.
        let failing: [ScoredSentence]
    }

    let threshold: Double
    private let embedder: NLEmbedding?

    init(threshold: Double = AskPoseySummaryVerifier.defaultThreshold,
         language: NLLanguage = .english) {
        self.threshold = threshold
        self.embedder = NLEmbedding.sentenceEmbedding(for: language)
    }

    /// True when an embedder loaded. When false, all verification is a
    /// keep-all no-op (the conservative contract).
    var canVerify: Bool { embedder != nil }

    // MARK: - Structured verify (pairwise rewrite path)

    /// Score each summary sentence against pre-computed reference
    /// vectors. Returns kept / failing partition. Keep-all when there
    /// are no references (can't measure → don't drop).
    func verify(summary: String, againstReferenceVectors references: [[Double]]) -> Result {
        let sentences = Self.splitSentences(summary)
        guard !sentences.isEmpty else {
            return Result(scored: [], kept: [], failing: [])
        }
        guard !references.isEmpty else {
            let all = sentences.map { ScoredSentence(text: $0, maxCosine: 1.0) }
            return Result(scored: all, kept: sentences, failing: [])
        }

        var scored: [ScoredSentence] = []
        var kept: [String] = []
        var failing: [ScoredSentence] = []
        for sentence in sentences {
            guard let v = vector(for: sentence) else {
                // Embedding lookup failed (rare; usually all-punctuation).
                // Treat as kept — retain what we can't measure.
                let s = ScoredSentence(text: sentence, maxCosine: 1.0)
                scored.append(s)
                kept.append(sentence)
                continue
            }
            var maxCos = 0.0
            for ref in references {
                let c = EmbeddingProvider.cosine(v, ref)
                if c > maxCos { maxCos = c }
            }
            let s = ScoredSentence(text: sentence, maxCosine: maxCos)
            scored.append(s)
            if maxCos < threshold {
                failing.append(s)
            } else {
                kept.append(sentence)
            }
        }
        let failingSorted = failing.sorted { $0.maxCosine < $1.maxCosine }
        return Result(scored: scored, kept: kept, failing: failingSorted)
    }

    /// Convenience for the simple "verify a summary against source
    /// strings and return the filtered text" case (the live rolling
    /// summary). Builds reference vectors from the sources, verifies,
    /// and applies the conservative keep-all-when-would-empty guard.
    ///
    /// Returns the filtered summary plus a stats tuple for logging.
    func filteredSummary(
        _ summary: String,
        sources: [String]
    ) -> (text: String, total: Int, kept: Int, dropped: Int, droppedSentences: [ScoredSentence]) {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let references = referenceVectors(forSources: sources)
        let result = verify(summary: trimmedSummary, againstReferenceVectors: references)
        let total = result.scored.count

        // Conservative keep-all when filtering would empty the summary
        // (or there was nothing to verify).
        if result.kept.isEmpty {
            return (trimmedSummary, total, total, 0, [])
        }
        return (result.kept.joined(separator: " "),
                total,
                result.kept.count,
                result.failing.count,
                result.failing)
    }

    // MARK: - Reference building

    /// Embed source strings into reference vectors. Each source is
    /// split into sentences AND embedded whole — short single-sentence
    /// answers still need a reference, and the whole-string embedding
    /// catches paraphrases that span the source's sentence boundaries.
    func referenceVectors(forSources sources: [String]) -> [[Double]] {
        var refs: [[Double]] = []
        for source in sources {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            for sentence in Self.splitSentences(trimmed) {
                if let v = vector(for: sentence) { refs.append(v) }
            }
            if let whole = vector(for: trimmed) { refs.append(whole) }
        }
        return refs
    }

    /// Build references from a question + answer pair (pairwise path).
    func referenceVectors(question: String, answer: String) -> [[Double]] {
        referenceVectors(forSources: [question + "\n" + answer, question, answer])
    }

    // MARK: - Primitives

    func vector(for text: String) -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let embedder else { return nil }
        return embedder.vector(for: trimmed)
    }

    /// Split text into sentences via NLTokenizer; trims and drops empty
    /// fragments.
    static func splitSentences(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        var out: [String] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let s = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out
    }
}
// ========== BLOCK 01: SHARED SUMMARY VERIFIER - END ==========
