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
    static let verificationThreshold: Double = AskPoseySummaryVerifier.defaultThreshold

    /// Per-tier summary length targets (sentences). Index 0 = most
    /// recent pair gets the fullest summary; later indices clamp to
    /// the trailing value.
    static let tierSentenceTargets: [Int] = [4, 2, 1]

    private let summarizer: AskPoseySummarizing
    /// Shared embedding-cosine verifier — the single verification
    /// implementation used by both this pairwise path and the live
    /// rolling-summary path (`AskPoseyService.summarizeConversation`).
    private let verifier: AskPoseySummaryVerifier

    /// Cache keyed by `AskPoseyConversationPair.key`. Stable pairs
    /// (older history that won't change) hit the cache; only the
    /// most recent pair (whose tier may shift as the conversation
    /// grows) is recomputed often.
    private var cache: [String: String] = [:]

    init(summarizer: AskPoseySummarizing, language: NLLanguage = .english) {
        self.summarizer = summarizer
        self.verifier = AskPoseySummaryVerifier(language: language)
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
        let referenceVectors = verifier.referenceVectors(question: pair.question, answer: pair.answer)

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

        let firstResult = verifier.verify(summary: firstAttempt, againstReferenceVectors: referenceVectors)
        stats.sentencesProduced += firstResult.scored.count
        stats.sentencesFlagged += firstResult.failing.count

        if firstResult.failing.isEmpty {
            return firstResult.kept.joined(separator: " ")
        }

        // Rewrite attempt — quote the worst-failing sentence back to
        // the model so it knows what shape of claim to avoid.
        stats.pairsRewritten += 1
        let worstFailing = firstResult.failing.first?.text
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
            stats.sentencesDropped += firstResult.failing.count
            if firstResult.kept.isEmpty {
                return Self.fallbackSummary(question: pair.question, answer: pair.answer)
            }
            return firstResult.kept.joined(separator: " ")
        }

        let secondResult = verifier.verify(summary: secondAttempt, againstReferenceVectors: referenceVectors)
        if secondResult.failing.isEmpty {
            return secondResult.kept.joined(separator: " ")
        }

        // Second attempt still has failures. Drop the failing
        // sentences and ship the verified remainder (or the
        // fallback when nothing survives).
        stats.sentencesDropped += secondResult.failing.count
        if secondResult.kept.isEmpty {
            return Self.fallbackSummary(question: pair.question, answer: pair.answer)
        }
        return secondResult.kept.joined(separator: " ")
    }

    // MARK: - Sentence count

    /// Sentence count via the shared verifier's tokenizer split, so
    /// tier-target accounting matches the verification split exactly.
    static func sentenceCount(in text: String) -> Int {
        AskPoseySummaryVerifier.splitSentences(text).count
    }

    /// Deterministic, content-derived fallback used when AFM
    /// summarization fails outright OR when verification kills every
    /// generated sentence. Not a great summary but honest about what
    /// it covers — clipped verbatim is better than fabricated prose.
    static func fallbackSummary(question: String, answer: String) -> String {
        let q = compactClip(question, maxChars: 120)
        let a = compactClip(answer, maxChars: 200)
        return "You asked: \"\(q)\". I answered: \"\(a)\"."
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
