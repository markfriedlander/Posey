import Foundation

// ========== BLOCK 01: SMALL-TO-BIG NEIGHBOR EXPANSION - START ==========

/// 2026-06-19 (Mark) — SMALL-TO-BIG retrieval config.
///
/// We retrieve with small, precise chunks (no diluted embeddings — the Darcy
/// "tolerable" finding) but the model needs the surrounding *passage* to answer
/// well, not a 400-char sliver. Rather than enlarge chunks (which re-introduces
/// dilution and spends context on every chunk), we expand ONLY the winners to
/// their neighbors at retrieval time — precision AND context.
///
/// Domain note (Mark): this matters for DOCUMENTS (continuous prose) far more
/// than for Hal's short conversational turns — which is exactly why the chunk
/// size inherited from Hal isn't right for us, and why this expansion is the
/// lever rather than a bigger chunk.
///
/// `radius` is a TUNABLE knob (in-memory; resets on relaunch) so the embedder
/// A/B/C can sweep it alongside chunk size. 0 disables expansion entirely.
nonisolated enum NeighborExpansion {
    /// Number of chunks to include on EACH side of a winner (0 = off).
    /// Default 2 ≈ a ~5-chunk / ~2k-char window — enough to restore a thought
    /// without bloating the prompt.
    @MainActor static var radius: Int = 2
    static let defaultRadius = 2

    /// Ceiling (estimated tokens) for the TOTAL expanded RAG block, so a hot
    /// multi-hit query can't blow the on-device model's context window. Lowest-
    /// relevance windows are dropped first; the top window is always kept.
    static let ragTokenBudget = 1800
}

/// Expands retrieved (small) chunks to their document neighbors and stitches
/// each neighborhood into one contiguous passage. Pure post-ranking step: the
/// winners are still chosen by small-chunk RRF, and each expanded block carries
/// the WINNER's attribution (chunkID/startOffset/relevance/semanticScore), so
/// ranking, jump-back, and the weak-retrieval gate are all unchanged.
nonisolated enum NeighborExpander {

    /// `winners` must already be the final, filtered, relevance-sorted set.
    /// Returns expanded blocks in relevance order, within the token budget.
    static func expand(
        winners: [RetrievedChunk],
        documentID: UUID,
        database: DatabaseManager,
        radius: Int,
        tokenBudget: Int = NeighborExpansion.ragTokenBudget
    ) -> [RetrievedChunk] {
        guard radius > 0, !winners.isEmpty else { return winners }

        let base = DatabaseManager.raptorSummaryIndexBase
        // Expandable = real leaf chunks (chunk_index in [0, base)). Anything else
        // (RAPTOR-summary winners, sentinels) passes through untouched.
        let expandable = winners.filter { $0.chunkID >= 0 && $0.chunkID < base }
        let passthrough = winners.filter { !($0.chunkID >= 0 && $0.chunkID < base) }

        // Merge overlapping/adjacent windows. Sort by chunk_index; a window
        // [lo,hi] merges with the running one when lo <= runningHi + 1. Keep the
        // highest-relevance winner as the merged block's attribution.
        struct Merged { var lo: Int; var hi: Int; var best: RetrievedChunk }
        var merged: [Merged] = []
        for w in expandable.sorted(by: { $0.chunkID < $1.chunkID }) {
            let lo = w.chunkID - radius
            let hi = w.chunkID + radius
            if !merged.isEmpty, lo <= merged[merged.count - 1].hi + 1 {
                merged[merged.count - 1].hi = max(merged[merged.count - 1].hi, hi)
                if w.relevance > merged[merged.count - 1].best.relevance {
                    merged[merged.count - 1].best = w
                }
            } else {
                merged.append(Merged(lo: lo, hi: hi, best: w))
            }
        }

        // Build the expanded block for each merged window.
        var blocks: [RetrievedChunk] = []
        for m in merged {
            let rows = (try? database.unitEmbeddingChunkTexts(
                documentID: documentID, fromIndex: m.lo, toIndex: m.hi)) ?? []
            // If the neighborhood came back empty (e.g. data gap), fall back to
            // the winner's own text so we never DROP a retrieved passage.
            let stitched = rows.isEmpty ? m.best.text : stitch(rows.map { $0.text })
            blocks.append(RetrievedChunk(
                chunkID: m.best.chunkID,
                startOffset: m.best.startOffset,
                text: stitched,
                relevance: m.best.relevance,
                semanticScore: m.best.semanticScore))
        }

        // Combine with non-expandable passthrough winners, relevance-sorted.
        let all = (blocks + passthrough).sorted { $0.relevance > $1.relevance }

        // Token budget: greedily keep highest-relevance blocks; always keep the
        // top one even if it alone exceeds the ceiling.
        var kept: [RetrievedChunk] = []
        var used = 0
        for b in all {
            let t = AskPoseyTokenEstimator.tokens(in: b.text)
            if kept.isEmpty || used + t <= tokenBudget {
                kept.append(b); used += t
            }
        }
        return kept
    }

    /// Stitch contiguous chunk texts into one passage, removing the chunker's
    /// sentence-overlap between adjacent chunks (longest suffix of the running
    /// text that is a prefix of the next chunk). When there's no overlap (the
    /// forward-progress guard can produce overlap-free boundaries), the chunks
    /// are still source-contiguous, so join with a single space.
    private static func stitch(_ texts: [String]) -> String {
        guard var acc = texts.first else { return "" }
        for next in texts.dropFirst() where !next.isEmpty {
            let maxOv = min(250, acc.count, next.count)
            var ov = 0
            if maxOv > 0 {
                for k in stride(from: maxOv, through: 1, by: -1) {
                    if acc.hasSuffix(String(next.prefix(k))) { ov = k; break }
                }
            }
            let addition = String(next.dropFirst(ov))
            if addition.isEmpty { continue }
            if ov == 0 { acc += " " }
            acc += addition
        }
        return acc
    }
}

// ========== BLOCK 01: SMALL-TO-BIG NEIGHBOR EXPANSION - END ==========
