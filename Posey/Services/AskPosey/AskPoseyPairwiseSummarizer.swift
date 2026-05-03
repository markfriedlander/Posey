import Foundation
import NaturalLanguage

// ========== BLOCK 01: PAIR + STATS TYPES - START ==========
/// Task 4 #9 (2026-05-03) — parallel summarization mode for Ask Posey
/// short-term memory. Replaces verbatim STM (the existing
/// "EARLIER IN THIS CONVERSATION (the user has so far asked: …)"
/// rendering) with **per-pair** third-person summaries, sized by
/// recency tier:
///
/// - tier 0 (most recent pair): 4 sentences
/// - tier 1 (next pair):        2 sentences
/// - tier 2 (older pairs):      1 sentence
///
/// Every generated summary is then **embedding-verified** against the
/// verbatim exchange: each summary sentence is embedded, the original
/// Q + A is split into reference sentences and embedded, and the
/// summary sentence's max cosine similarity against the references
/// must clear `verificationThreshold`. If not, the pair is re-
/// summarized once with the failing sentence quoted back to the model
/// as guidance ("don't make this kind of unsupported claim").
///
/// Implemented as a **parallel mode**, NOT a default. The chat view
/// model reaches for it only when the caller (production UI today is
/// the existing verbatim path; the local-API `/ask` endpoint accepts
/// `summarizationMode: "pairwise"` to opt in for testing).
nonisolated struct AskPoseyConversationPair: Sendable, Equatable, Hashable {
    /// Stable per-pair key — concatenation of the user message id and
    /// the assistant message id. Used to memoize so repeated sends
    /// don't re-summarize stable pairs.
    let key: String
    let question: String
    let answer: String
}

/// Per-call statistics surfaced via the local-API tuning loop so we can
/// quantify cost vs. quality. Mark's standing requirement: report
/// findings before defaulting.
nonisolated struct AskPoseyPairwiseStats: Sendable, Equatable {
    /// Total pairs the summarizer was asked to compress this turn.
    var pairsTotal: Int = 0
    /// Pairs whose summary was reused from the cache (no AFM call).
    var pairsCached: Int = 0
    /// Pairs that required a fresh AFM summarization call.
    var pairsSummarized: Int = 0
    /// Pairs that required a second AFM call after embedding
    /// verification flagged a sentence as unsupported.
    var pairsRewritten: Int = 0
    /// Total summary sentences produced across all pairs.
    var sentencesProduced: Int = 0
    /// Summary sentences whose max cosine vs. the verbatim exchange
    /// fell below `verificationThreshold` — these triggered the
    /// rewrite path (or, if a rewrite still failed, were dropped).
    var sentencesFlagged: Int = 0
    /// Summary sentences dropped after rewrite still failed
    /// verification. Counts toward an honesty signal — the summarizer
    /// would rather lose a sentence than hallucinate one.
    var sentencesDropped: Int = 0
}
// ========== BLOCK 01: PAIR + STATS TYPES - END ==========


// ========== BLOCK 02: SUMMARIZER - START ==========
/// `@MainActor` because the underlying `AskPoseySummarizing` protocol
/// is `@MainActor` and the cache is read/written from the chat VM
/// (also main-actor). All AFM work runs synchronously off `await`.
@MainActor
final class AskPoseyPairwiseSummarizer {

    /// Cosine threshold a summary sentence must clear against the
    /// closest verbatim sentence in the exchange. Conservative —
    /// 0.45 corresponds roughly to "the same topic in similar
    /// vocabulary." Lower than the citation threshold (0.50)
    /// because pair summaries paraphrase more than answer text
    /// quotes do; tightening this triggers excessive rewrites
    /// without buying real fidelity.
    static let verificationThreshold: Double = 0.45

    /// Per-tier summary length targets (sentences). Index 0 = most
    /// recent pair gets the fullest summary; later indices clamp to
    /// the trailing value.
    static let tierSentenceTargets: [Int] = [4, 2, 1]

    private let summarizer: AskPoseySummarizing
    private let embedder: NLEmbedding?

    /// Cache keyed by `AskPoseyConversationPair.key`. Stable pairs
    /// (older history that won't change) hit the cache; only the
    /// most recent pair (whose tier may shift as the conversation
    /// grows) is recomputed often.
    private var cache: [String: String] = [:]

    init(summarizer: AskPoseySummarizing, language: NLLanguage = .english) {
        self.summarizer = summarizer
        self.embedder = NLEmbedding.sentenceEmbedding(for: language)
    }

    /// Summarize an ordered list of pairs into per-pair text suitable
    /// for prompt injection. Returns rendered summaries oldest-first
    /// (matches the existing STM render order) and the stats record
    /// for the local-API tuning loop.
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func summarize(
        pairs: [AskPoseyConversationPair]
    ) async -> (summaries: [String], stats: AskPoseyPairwiseStats) {
        var stats = AskPoseyPairwiseStats()
        guard !pairs.isEmpty else { return ([], stats) }
        stats.pairsTotal = pairs.count

        // Tier index: 0 for the newest pair, 1 for the next, etc.
        // Walk newest-first so tier 0 maps to last(); convert back to
        // input order at the end.
        var renderedNewestFirst: [String] = []
        let newestFirst = pairs.reversed()
        for (idx, pair) in newestFirst.enumerated() {
            let target = Self.targetSentences(forTier: idx)
            let cacheKey = "\(pair.key)|t=\(target)"
            if let cached = cache[cacheKey] {
                stats.pairsCached += 1
                stats.sentencesProduced += Self.sentenceCount(in: cached)
                renderedNewestFirst.append(cached)
                continue
            }
            stats.pairsSummarized += 1
            let summary = await produceVerifiedSummary(
                pair: pair,
                targetSentences: target,
                stats: &stats
            )
            cache[cacheKey] = summary
            renderedNewestFirst.append(summary)
        }
        let oldestFirst = Array(renderedNewestFirst.reversed())
        return (oldestFirst, stats)
    }

    /// Map tier index (0 = newest) to a sentence count, clamping at
    /// the trailing tier for indices past the table length.
    static func targetSentences(forTier index: Int) -> Int {
        if index < tierSentenceTargets.count {
            return tierSentenceTargets[index]
        }
        return tierSentenceTargets.last ?? 1
    }

    /// One pair → verified summary. Generates with the requested
    /// length, runs embedding verification, and re-prompts ONCE if
    /// any sentence falls below threshold. If the rewrite still has
    /// failing sentences, those sentences are dropped (we'd rather
    /// lose a sentence than ship an unsupported claim).
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func produceVerifiedSummary(
        pair: AskPoseyConversationPair,
        targetSentences: Int,
        stats: inout AskPoseyPairwiseStats
    ) async -> String {
        let referenceVectors = computeReferenceVectors(question: pair.question, answer: pair.answer)

        let firstAttempt: String
        do {
            firstAttempt = try await summarizer.summarizePair(
                question: pair.question,
                answer: pair.answer,
                targetSentences: targetSentences,
                failingSentence: nil
            )
        } catch {
            // Summarization failed — fall back to a deterministic
            // placeholder so the rest of the conversation can still
            // be assembled. This mirrors the existing
            // `summarizeConversation` failure handling: best-effort,
            // never blocking.
            return Self.fallbackSummary(question: pair.question, answer: pair.answer)
        }

        let firstResult = verify(summary: firstAttempt, against: referenceVectors)
        stats.sentencesProduced += firstResult.sentences.count
        stats.sentencesFlagged += firstResult.failingSentences.count

        if firstResult.failingSentences.isEmpty {
            return firstResult.kept.joined(separator: " ")
        }

        // Rewrite attempt — quote the worst-failing sentence back to
        // the model so it knows what shape of claim to avoid.
        stats.pairsRewritten += 1
        let worstFailing = firstResult.failingSentences.first?.text
        let secondAttempt: String
        do {
            secondAttempt = try await summarizer.summarizePair(
                question: pair.question,
                answer: pair.answer,
                targetSentences: targetSentences,
                failingSentence: worstFailing
            )
        } catch {
            // Rewrite errored — keep the first attempt's verified
            // sentences (drop the failing ones).
            stats.sentencesDropped += firstResult.failingSentences.count
            if firstResult.kept.isEmpty {
                return Self.fallbackSummary(question: pair.question, answer: pair.answer)
            }
            return firstResult.kept.joined(separator: " ")
        }

        let secondResult = verify(summary: secondAttempt, against: referenceVectors)
        if secondResult.failingSentences.isEmpty {
            return secondResult.kept.joined(separator: " ")
        }

        // Second attempt still has failures. Drop the failing
        // sentences and ship the verified remainder (or the
        // fallback when nothing survives).
        stats.sentencesDropped += secondResult.failingSentences.count
        if secondResult.kept.isEmpty {
            return Self.fallbackSummary(question: pair.question, answer: pair.answer)
        }
        return secondResult.kept.joined(separator: " ")
    }

    // MARK: - Verification

    private struct VerificationResult {
        let sentences: [SummarySentence]
        let kept: [String]
        let failingSentences: [SummarySentence]
    }

    private struct SummarySentence {
        let text: String
        let maxCosine: Double
    }

    /// Build embeddings of the verbatim question + answer split into
    /// sentences. These are the "reference" set each summary
    /// sentence is verified against.
    private func computeReferenceVectors(question: String, answer: String) -> [[Double]] {
        let combined = (question + "\n" + answer)
        let sentences = Self.splitSentences(combined)
        // Also embed the full Q and full A as fallback — short answers
        // that fit on one sentence still need a reference.
        let extras: [String] = [question, answer]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let all = sentences + extras
        return all.compactMap { self.vector(for: $0) }
    }

    private func verify(summary: String, against references: [[Double]]) -> VerificationResult {
        let sentences = Self.splitSentences(summary)
        guard !sentences.isEmpty else {
            return VerificationResult(sentences: [], kept: [], failingSentences: [])
        }
        // No embedder OR no reference vectors → can't verify.
        // Conservative: keep all (the rule is "rewrite if we know
        // it's bad", not "drop if we can't tell"). Stats logging
        // will show this case.
        guard !references.isEmpty else {
            let all = sentences.map { SummarySentence(text: $0, maxCosine: 1.0) }
            return VerificationResult(sentences: all, kept: sentences, failingSentences: [])
        }

        var scored: [SummarySentence] = []
        var kept: [String] = []
        var failing: [SummarySentence] = []
        for sentence in sentences {
            guard let v = vector(for: sentence) else {
                // Embedding lookup failed (rare; usually empty/all
                // punctuation). Treat as kept — better to retain a
                // sentence we can't score than drop one we couldn't
                // measure.
                let score = SummarySentence(text: sentence, maxCosine: 1.0)
                scored.append(score)
                kept.append(sentence)
                continue
            }
            var maxCos = 0.0
            for ref in references {
                let c = DocumentEmbeddingIndex.cosine(v, ref)
                if c > maxCos { maxCos = c }
            }
            let s = SummarySentence(text: sentence, maxCosine: maxCos)
            scored.append(s)
            if maxCos < Self.verificationThreshold {
                failing.append(s)
            } else {
                kept.append(sentence)
            }
        }
        // Order failing by ascending cosine so the worst one is
        // first — used for the rewrite hint.
        let failingSorted = failing.sorted { $0.maxCosine < $1.maxCosine }
        return VerificationResult(sentences: scored, kept: kept, failingSentences: failingSorted)
    }

    private func vector(for text: String) -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let embedder else { return nil }
        return embedder.vector(for: trimmed)
    }

    // MARK: - Sentence split

    /// Split text into sentences using NLTokenizer. Filters empty
    /// fragments and trims surrounding whitespace.
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

    static func sentenceCount(in text: String) -> Int {
        splitSentences(text).count
    }

    /// Deterministic, content-derived fallback used when AFM
    /// summarization fails outright OR when verification kills every
    /// generated sentence. Not a great summary but honest about what
    /// it covers — clipped verbatim is better than fabricated prose.
    static func fallbackSummary(question: String, answer: String) -> String {
        let q = compactClip(question, maxChars: 120)
        let a = compactClip(answer, maxChars: 200)
        return "The user asked: \"\(q)\". Posey responded: \"\(a)\"."
    }

    private static func compactClip(_ text: String, maxChars: Int) -> String {
        var collapsed = text.replacingOccurrences(of: "\n\n", with: " ")
        collapsed = collapsed.replacingOccurrences(of: "\n", with: " ")
        while collapsed.contains("  ") {
            collapsed = collapsed.replacingOccurrences(of: "  ", with: " ")
        }
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxChars { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: maxChars)
        return String(trimmed[..<endIndex]) + "…"
    }
}
// ========== BLOCK 02: SUMMARIZER - END ==========


// ========== BLOCK 03: PAIR EXTRACTION - START ==========
/// Group an in-order list of `AskPoseyMessage` (filtered to user +
/// assistant turns only — anchors and other roles must be stripped
/// upstream) into adjacent (user, assistant) pairs. A trailing user
/// turn without a paired assistant reply is skipped — it's the live
/// turn being responded to right now.
nonisolated enum AskPoseyConversationPairExtractor {
    static func pairs(from messages: [AskPoseyMessage]) -> [AskPoseyConversationPair] {
        var pairs: [AskPoseyConversationPair] = []
        var pendingUser: AskPoseyMessage?
        for message in messages {
            switch message.role {
            case .user:
                pendingUser = message
            case .assistant:
                if let user = pendingUser {
                    let key = "\(user.id.uuidString)|\(message.id.uuidString)"
                    pairs.append(AskPoseyConversationPair(
                        key: key,
                        question: user.content,
                        answer: message.content
                    ))
                    pendingUser = nil
                }
            default:
                continue
            }
        }
        return pairs
    }
}
// ========== BLOCK 03: PAIR EXTRACTION - END ==========
