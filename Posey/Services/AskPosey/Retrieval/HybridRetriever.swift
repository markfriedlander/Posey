import Foundation

// ========== BLOCK 01: HYBRID RETRIEVER TYPES - START ==========

/// One ranked result from `HybridRetriever.retrieve`. Mirrors the
/// existing `RetrievedChunk` shape (the prompt builder consumes
/// it unchanged) so the call sites in `AskPoseyChatViewModel`
/// don't need to learn a new type during the cutover.
///
/// For unit-anchored chunks `startOffset` is the sentinel `-2`.
/// Distinct from the legacy synthetic-metadata sentinel `-1`,
/// which means "phone verification can disambiguate which
/// retriever actually served the turn" — caught the hard way
/// in the 8h verification pass when -1 turned out to overlap.
/// Both negative values pass the `chunk.startOffset < 0` exempt-
/// from-filter test downstream, so behavior is preserved.
/// Jump-back wiring switches to unit_id + intra_offset in Step 9;
/// the prompt builder just renders the value in its diagnostic
/// header and AFM ignores it.
typealias HybridRetrievalResult = RetrievedChunk

/// Sentinel value for the `startOffset` field on chunks the new
/// RRF retriever returns. Distinct from the legacy synthetic-
/// metadata chunks' `-1` sentinel so verification can tell which
/// retriever served a given turn.
let kUnitAnchoredStartOffsetSentinel: Int = -2

// ========== BLOCK 01: HYBRID RETRIEVER TYPES - END ==========


// ========== BLOCK 02: HYBRID RETRIEVER - START ==========

/// Combines a semantic (cosine) pass with a BM25 (FTS5) pass via
/// **Reciprocal Rank Fusion**. Replaces the legacy
/// `DocumentEmbeddingIndex.searchHybrid` family.
///
/// The RRF formula (Cormack & Clarke, 2009):
/// ```
/// rrf(d) = Σ_L 1 / (k_L + rank_L(d))
/// ```
/// where `L` ranges over the contributing retrievers and `rank_L(d)`
/// is `d`'s 1-indexed rank in `L`. `k_semantic = 60` (canonical);
/// `k_bm25` is 10 when BM25 had a distinctively strong hit (rare
/// imported token that maps to specific content), else 60. Lower
/// `k` lets that retriever's rank-1 dominate.
///
/// **Two-stage BM25 quality gate** (Hal's pattern, see Hal's
/// retrieval pipeline notes). BM25 can return confident-but-wrong
/// results on common-word queries ("what kind of car?" → "have"
/// matches dozens of unrelated chunks). The gate computes the
/// median semantic rank of BM25's top-K (K=5); if it's > K, BM25
/// disagrees broadly with semantic and gets excluded from RRF
/// entirely. The gate is *itself* gated — it only fires when:
///   (a) semantic is confident (relative spread of top scores
///       above a threshold), AND
///   (b) BM25 top-1 is NOT distinctively strong (a rare-token hit
///       that semantic likely doesn't understand).
///
/// **Anti-confabulation signal.** `retrieve` exposes `topRelevance`
/// alongside the results so callers can detect "no high-confidence
/// hit" and inject the explicit system note that 8d's prompt
/// builder uses to ground the model.
///
/// 2026-05-23 — introduced as part of the Hal-based Ask Posey
/// rebuild (Step 8c).
struct HybridRetriever {

    // MARK: - Tunables

    /// Reciprocal Rank Fusion constants. Industry-standard for
    /// `k_semantic`; Hal's calibration for `k_bm25`.
    static let kSemantic: Double = 60
    static let kBM25Default: Double = 60
    static let kBM25Distinctive: Double = 10

    /// Quality-gate thresholds.
    static let semanticConfidenceSpread: Double = 0.15
    static let bm25DistinctiveAbsScore: Double = 1.5
    static let bm25GateMedianRankCheckK: Int = 5

    /// Stopwords stripped from the BM25 MATCH expression. Keeping
    /// these in would either no-op (single-letter words FTS5 ignores)
    /// or noise-rank (very common words match almost everything).
    static let lexicalStopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "is", "are", "was",
        "were", "be", "been", "being", "have", "has", "had", "do",
        "does", "did", "of", "to", "in", "for", "on", "with", "as",
        "at", "by", "from", "this", "that", "these", "those", "it",
        "its", "i", "you", "he", "she", "we", "they", "them", "us",
        "his", "her", "their", "what", "which", "who", "whom", "where",
        "when", "why", "how"
    ]

    // MARK: - Public surface

    struct RetrievalOutcome: Sendable {
        let results: [HybridRetrievalResult]
        /// Highest RRF score in the result set, in the natural RRF
        /// scale `[0, 2/k]`. Use against
        /// `HybridRetriever.confidenceFloor` to decide whether the
        /// anti-confabulation guard should fire.
        let topRelevance: Double
        /// True when BM25 was excluded from fusion by the quality
        /// gate. Diagnostic; surfaced through the API for tuning.
        let bm25Excluded: Bool
    }

    /// Roughly: "no chunk scored above this is high confidence."
    /// Picked at 1/(k_semantic + 5) ≈ 0.015, the score a chunk
    /// gets at semantic rank 5 from a single retriever. Below
    /// this, the model should be told "I didn't retrieve anything
    /// strong."
    static let confidenceFloor: Double = 1.0 / (kSemantic + 5)

    let database: DatabaseManager

    /// Run hybrid retrieval. Returns up to `limit` chunks, ranked
    /// by RRF score. Empty if the document has no chunks at all.
    func retrieve(documentID: UUID,
                  query: String,
                  limit: Int,
                  expansionTerms: [String] = []) -> RetrievalOutcome {
        let cleanedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedQuery.isEmpty else {
            return RetrievalOutcome(results: [], topRelevance: 0, bm25Excluded: false)
        }

        // ── Load every chunk for this document (text + possibly-nil
        //   embedding). This is the source of truth for both passes.
        let allChunks: [StoredUnitEmbeddingChunk]
        do {
            allChunks = try database.unitEmbeddingChunks(for: documentID)
        } catch {
            return RetrievalOutcome(results: [], topRelevance: 0, bm25Excluded: false)
        }
        guard !allChunks.isEmpty else {
            return RetrievalOutcome(results: [], topRelevance: 0, bm25Excluded: false)
        }
        let chunksByID = Dictionary(uniqueKeysWithValues: allChunks.map { ($0.id, $0) })

        // ── 1. SEMANTIC PASS.
        var semanticRanks: [UUID: Int] = [:]     // 1-indexed
        var semanticScores: [UUID: Double] = [:] // cosine
        if let queryVector = EmbeddingProvider.shared.embed(cleanedQuery, as: .query) {
            var scored: [(UUID, Double)] = []
            scored.reserveCapacity(allChunks.count)
            for chunk in allChunks {
                guard let emb = chunk.embedding, !emb.isEmpty else { continue }
                let s = EmbeddingProvider.cosine(queryVector, emb)
                if s > 0 { scored.append((chunk.id, s)) }
            }
            scored.sort { $0.1 > $1.1 }
            let cap = min(50, scored.count)
            for i in 0..<cap {
                semanticRanks[scored[i].0] = i + 1
                semanticScores[scored[i].0] = scored[i].1
            }
        }

        // ── 2. BM25 PASS. Sanitize the user's natural-language
        //   question into an FTS5 MATCH expression. `expansionTerms`
        //   (LLM-supplied bridging vocabulary, empty on the normal path)
        //   are OR'd in so a paraphrased question can reach a passage
        //   that uses different words than the reader did. The semantic
        //   pass above is intentionally NOT expanded.
        let matchExpr = Self.makeBM25MatchExpression(cleanedQuery, extraTerms: expansionTerms)
        var bm25Ranks: [UUID: Int] = [:]         // 1-indexed
        var bm25TopAbs: Double = 0
        if let matchExpr = matchExpr {
            let bm25Hits = (try? database.bm25Search(
                documentID: documentID, matchExpression: matchExpr, limit: 50
            )) ?? []
            for (i, hit) in bm25Hits.enumerated() {
                bm25Ranks[hit.chunkID] = i + 1
            }
            if let first = bm25Hits.first {
                // FTS5 bm25() returns negative values (lower = better).
                // Take absolute value so "distinctive hit" is a high
                // positive comparison.
                bm25TopAbs = abs(first.rawBM25)
            }
        }

        // ── 3. BM25 QUALITY GATE. Only consider excluding BM25
        //   when semantic is confident AND BM25 doesn't have a
        //   distinctively strong hit.
        var bm25Excluded = false
        if !bm25Ranks.isEmpty, !semanticScores.isEmpty {
            let topScores = semanticScores.values.sorted(by: >)
            let cap = min(10, topScores.count)
            let topMean = topScores.prefix(cap).reduce(0, +) / Double(cap)
            let topMax = topScores.first ?? 0
            let semanticConfident = topMean > 0
                && (topMax - topMean) / topMean >= Self.semanticConfidenceSpread
            let bm25Distinctive = bm25TopAbs >= Self.bm25DistinctiveAbsScore

            if semanticConfident && !bm25Distinctive {
                let bm25Top = bm25Ranks
                    .sorted { $0.value < $1.value }
                    .prefix(Self.bm25GateMedianRankCheckK)
                let semRanksOfBM25Top = bm25Top.compactMap { semanticRanks[$0.key] }
                if semRanksOfBM25Top.isEmpty {
                    // 2026-05-29 — ZERO-OVERLAP branch, ported from Hal
                    // (Hal.swift ~2806). NONE of BM25's top-K appear in
                    // semantic's top-50: the two retrievers are working
                    // on different universes, so BM25's hit is lexical
                    // noise with no semantic corroboration → exclude it.
                    //
                    // Posey previously OMITTED this branch (the original
                    // `if !semRanksOfBM25Top.isEmpty { median }` ran the
                    // median check only when overlap existed and did
                    // nothing on zero overlap), so a common-word lexical
                    // match with zero semantic agreement carried the
                    // answer — exactly the "who is telling this story"
                    // → chunk-that-merely-contains-'story' failure that
                    // produced a fabricated narrator on Frankenstein.
                    // Hal's "agreement between two independent retrievers"
                    // is the only constant; this restores it.
                    bm25Excluded = true
                } else {
                    let sorted = semRanksOfBM25Top.sorted()
                    let median = sorted[sorted.count / 2]
                    if median > Self.bm25GateMedianRankCheckK {
                        bm25Excluded = true
                    }
                }
            }
        }

        // ── 4. RECIPROCAL RANK FUSION.
        let kBM25 = bm25TopAbs >= Self.bm25DistinctiveAbsScore
            ? Self.kBM25Distinctive : Self.kBM25Default
        var rrfScore: [UUID: Double] = [:]
        for (id, rank) in semanticRanks {
            rrfScore[id, default: 0] += 1.0 / (Self.kSemantic + Double(rank))
        }
        if !bm25Excluded {
            for (id, rank) in bm25Ranks {
                rrfScore[id, default: 0] += 1.0 / (kBM25 + Double(rank))
            }
        }

        // ── 5. SORT + PACKAGE. Drop chunks we don't have the row
        //   for (shouldn't happen — defensive).
        let ranked = rrfScore
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { (id, score) -> HybridRetrievalResult? in
                guard let chunk = chunksByID[id] else { return nil }
                return HybridRetrievalResult(
                    chunkID: chunk.chunkIndex,
                    startOffset: kUnitAnchoredStartOffsetSentinel,
                    text: chunk.text,
                    relevance: score,
                    // Raw semantic cosine (nil ⇒ BM25-only, no semantic
                    // rank). The weak-retrieval gate reads this rather
                    // than the RRF `relevance`, because the strictness
                    // band is calibrated on the cosine scale.
                    semanticScore: semanticScores[id],
                    // Per-pass ranks for RAG_DEBUG observability. `bm25Rank`
                    // is nil when BM25 was gate-excluded (the chunk's BM25
                    // rank, if any, did not contribute to fusion).
                    semanticRank: semanticRanks[id],
                    bm25Rank: bm25Excluded ? nil : bm25Ranks[id]
                )
            }

        let topRelevance = ranked.first?.relevance ?? 0
        return RetrievalOutcome(
            results: Array(ranked),
            topRelevance: topRelevance,
            bm25Excluded: bm25Excluded
        )
    }

    // MARK: - FTS5 MATCH expression construction

    /// Turn a user's natural-language question into a sanitized
    /// FTS5 MATCH expression. Strategy:
    ///   1. Lowercase + split on non-alphanumeric.
    ///   2. Drop stopwords + tokens shorter than 2 characters.
    ///   3. OR the remaining tokens.
    /// Returns nil when no usable content tokens remain.
    static func makeBM25MatchExpression(_ query: String,
                                        extraTerms: [String] = []) -> String? {
        // Tokenize the question + any LLM expansion terms with the same
        // rules, then dedupe and OR. Expansion terms may be multi-word
        // phrases ("drizzly november"); we split them into their content
        // tokens too so FTS5 matches each word.
        let sources = [query] + extraTerms
        var seen = Set<String>()
        var tokens: [String] = []
        for source in sources {
            let lowered = source.lowercased()
            for token in lowered.components(separatedBy: CharacterSet.alphanumerics.inverted) {
                guard token.count >= 2, !lexicalStopwords.contains(token) else { continue }
                guard !seen.contains(token) else { continue }
                seen.insert(token)
                tokens.append(token)
            }
        }
        guard !tokens.isEmpty else { return nil }
        return tokens.joined(separator: " OR ")
    }
}

// ========== BLOCK 02: HYBRID RETRIEVER - END ==========
