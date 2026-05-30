import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// ========== BLOCK 01: RAPTOR TREE BUILDER - START ==========

/// One node above the leaf layer of Posey's RAPTOR-style retrieval tree: a
/// verified abstractive summary of a cluster of lower-layer nodes. Built by
/// `RaptorTreeBuilder`. Leaves (layer 0) are the raw `unit_embedding_chunks`;
/// summary nodes (layer ≥ 1) join the SAME retrieval pool so the hybrid
/// retriever picks the right level of abstraction per question (RAPTOR's
/// "collapsed tree").
public struct RaptorSummaryNode: Sendable {
    /// Tree layer (1 = summary of leaves, 2 = summary of summaries, …).
    public let layer: Int
    /// The VERIFIED summary text (ungrounded sentences already dropped).
    public let text: String
    /// `chunk_index` of the member nodes this summary was built from.
    public let memberChunkIndices: [Int]
    /// Unit anchors spanning the members (first member's start, last member's
    /// end) — keeps summary nodes anchorable for future jump-back.
    public let startUnitID: UUID
    public let endUnitID: UUID
    /// Verifier accounting: sentences kept / dropped as ungrounded.
    public let verifyKept: Int
    public let verifyDropped: Int
}

/// Builds one layer of the RAPTOR tree: cluster the input nodes (cosine
/// k-means), summarize each cluster with the **active model** (AFM by
/// default), and **verify every summary against its own source** before it
/// is allowed into the pool. Verification is first-class and non-optional:
/// a hallucinated summary in the retrieval pool produces a confidently-wrong
/// answer with the same fluency as a correct one, so each summary's
/// ungrounded sentences are dropped (`AskPoseySummaryVerifier`).
///
/// **AFM pacing is designed in, not bolted on.** A large novel can need
/// 100+ summary calls; Apple Foundation Models enters a `Code=-1` failure
/// state under sustained pressure. The build loop is strictly sequential
/// (one `await`ed call at a time) AND inserts a cooldown between calls, and
/// it tolerates per-cluster failures (skips, never aborts the whole build) —
/// the same "usable immediately, improves in background" contract as the PDF
/// enhancement pipeline.
public actor RaptorTreeBuilder {

    public struct Config: Sendable {
        /// Target number of clusters for this layer. The builder clamps to
        /// the node count and aims for coherent, summarizable groups.
        public var clusterCount: Int
        /// Max source characters fed to one summary call (≈ the summarizer's
        /// input window). Oversized clusters are truncated for the slice;
        /// the production tree sub-summarizes recursively instead.
        public var maxCharsPerSummaryInput: Int
        /// Cooldown between AFM summary calls — the load-bearing pacing.
        public var afmCooldownSeconds: Double
        /// Extra backoff applied after a rate-limit/transient AFM error.
        public var afmBackoffSeconds: Double

        public init(clusterCount: Int,
                    maxCharsPerSummaryInput: Int = 8_000,
                    afmCooldownSeconds: Double = 1.5,
                    afmBackoffSeconds: Double = 6.0) {
            self.clusterCount = clusterCount
            self.maxCharsPerSummaryInput = maxCharsPerSummaryInput
            self.afmCooldownSeconds = afmCooldownSeconds
            self.afmBackoffSeconds = afmBackoffSeconds
        }
    }

    /// A node feeding into this layer (a leaf chunk, or a lower summary).
    public struct InputNode: Sendable {
        public let chunkIndex: Int
        public let text: String
        public let embedding: [Double]
        public let startUnitID: UUID
        public let endUnitID: UUID
        public init(chunkIndex: Int, text: String, embedding: [Double],
                    startUnitID: UUID, endUnitID: UUID) {
            self.chunkIndex = chunkIndex; self.text = text; self.embedding = embedding
            self.startUnitID = startUnitID; self.endUnitID = endUnitID
        }
    }

    public init() {}

    /// Build one summary layer from `nodes`. Returns the verified summary
    /// nodes (without embeddings — the caller fills those exactly like leaf
    /// chunks). `progress` is called after each cluster for observability.
    public func buildLayer(layer: Int,
                           nodes: [InputNode],
                           config: Config,
                           progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [RaptorSummaryNode] {
        guard nodes.count >= 2 else { return [] }

        // ── 1. CLUSTER (cosine k-means over the node embeddings).
        let vectors = nodes.map { $0.embedding }
        let result = KMeansClustering.cluster(vectors: vectors, k: config.clusterCount)
        var clusters: [Int: [Int]] = [:]   // clusterLabel -> node indices
        for (i, label) in result.labels.enumerated() { clusters[label, default: []].append(i) }
        let orderedClusters = clusters.values.sorted { $0.count > $1.count }

        // ── 2. SUMMARIZE + VERIFY each cluster, paced.
        let verifier = AskPoseySummaryVerifier()
        var out: [RaptorSummaryNode] = []
        var done = 0
        for memberIdxs in orderedClusters {
            defer { done += 1; progress?(done, orderedClusters.count) }
            guard memberIdxs.count >= 1 else { continue }
            let members = memberIdxs.map { nodes[$0] }
            let memberTexts = members.map { $0.text }

            // Concatenate cluster text up to the summary input budget.
            var source = ""
            for t in memberTexts {
                if source.count + t.count + 2 > config.maxCharsPerSummaryInput { break }
                source += (source.isEmpty ? "" : "\n\n") + t
            }
            guard !source.isEmpty else { continue }

            // Summarize (active model; AFM @Generable). Skip cluster on failure.
            guard let raw = await summarize(source: source) else {
                // Transient/guardrail — back off so a bad streak doesn't trip
                // AFM's sustained-pressure state, then continue.
                try? await Task.sleep(nanoseconds: UInt64(config.afmBackoffSeconds * 1_000_000_000))
                continue
            }

            // VERIFY against the cluster's own source (drop ungrounded sentences).
            let v = verifier.filteredSummary(raw, sources: memberTexts)
            let verified = v.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if verified.isEmpty { continue }

            out.append(RaptorSummaryNode(
                layer: layer,
                text: verified,
                memberChunkIndices: members.map { $0.chunkIndex },
                startUnitID: members.first!.startUnitID,
                endUnitID: members.last!.endUnitID,
                verifyKept: v.kept,
                verifyDropped: v.dropped
            ))

            // Pace the next AFM call.
            try? await Task.sleep(nanoseconds: UInt64(config.afmCooldownSeconds * 1_000_000_000))
        }
        return out
    }

    // MARK: - Summarization (active model; AFM guided generation)

    #if canImport(FoundationModels)
    private func summarize(source: String) async -> String? {
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.availability == .available else { return nil }
            let instructions = """
            You summarize a group of related passages from a book or document \
            so a reading companion can find them later. Write a faithful, \
            concise summary of what the passages actually say — the characters, \
            events, topics, and arguments present in them. Never invent details \
            not in the passages. Do not editorialize or add interpretation.
            """
            let session = LanguageModelSession(model: model, instructions: instructions)
            do {
                let response = try await session.respond(
                    to: "Passages:\n\n\(source)",
                    generating: ClusterSummaryPayload.self
                )
                let s = response.content.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : s
            } catch {
                dbgLog("RaptorTreeBuilder: AFM summarize failed: %@", "\(error)")
                return nil
            }
        }
        return nil
    }
    #else
    private func summarize(source: String) async -> String? { nil }
    #endif
}

#if canImport(FoundationModels)
/// Guided-generation payload — forces AFM to return a clean summary string
/// (free-text summarization on AFM rambles or refuses; @Generable doesn't).
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct ClusterSummaryPayload: Sendable {
    @Guide(description: "A faithful, concise summary (about 80-130 words) of what this group of passages is about — the characters, events, topics, and arguments actually present. Only what the passages say; invent nothing; no editorializing.")
    let summary: String
}
#endif
// ========== BLOCK 01: RAPTOR TREE BUILDER - END ==========
