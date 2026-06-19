import Foundation

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
/// k-means), summarize each cluster with the **active model** (the downloaded
/// MLX model when present, else AFM — via `ModelCatalog.answerModel()`), and
/// **verify every summary against its own source** before it
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
        /// Clusters with fewer members than this are skipped — too small to
        /// need an abstraction (the member leaves are already in the pool),
        /// and tiny clusters produce weak, fragmentary summaries.
        public var minClusterSize: Int

        public init(clusterCount: Int,
                    maxCharsPerSummaryInput: Int = 5_000,
                    afmCooldownSeconds: Double = 1.5,
                    afmBackoffSeconds: Double = 6.0,
                    minClusterSize: Int = 3) {
            self.clusterCount = clusterCount
            self.maxCharsPerSummaryInput = maxCharsPerSummaryInput
            self.afmCooldownSeconds = afmCooldownSeconds
            self.afmBackoffSeconds = afmBackoffSeconds
            self.minClusterSize = minClusterSize
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
    /// - Parameter documentText: the full document plainText, used as the
    ///   entity-grounding haystack. Entity-grounding checks fabricated names
    ///   against the WHOLE document (not just the cluster source): a name in
    ///   the book elsewhere — "Moby-Dick", "Massachusetts" — is legitimate
    ///   document-wide reference; a name found NOWHERE in the book — "Sethe",
    ///   "Toni Morrison" — is cross-work fabrication and gets the summary
    ///   rejected. Topical (cluster-level) grounding is the cosine gate's job.
    public func buildLayer(layer: Int,
                           nodes: [InputNode],
                           documentText: String,
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
            // Skip tiny clusters — their leaves are already retrievable, and
            // a 1–2 chunk "summary" is fragmentary noise.
            guard memberIdxs.count >= config.minClusterSize else { continue }
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
            // Global serial lane — the RAPTOR summary AFM call is heavy
            // background compute; only one heavy op runs app-wide at a time.
            guard let raw = await HeavyWorkLane.shared.run(
                label: "RAPTOR-summary",
                { await self.summarize(source: source) }
            ) else {
                // Transient/guardrail — back off so a bad streak doesn't trip
                // AFM's sustained-pressure state, then continue.
                try? await Task.sleep(nanoseconds: UInt64(config.afmBackoffSeconds * 1_000_000_000))
                continue
            }

            // VERIFY — two complementary gates.
            // (1) Embedding-cosine: drop topically-ungrounded sentences.
            //     filteredSummary embeds the source + summary sentences, so
            //     it's heavy background compute — route it through the global
            //     serial lane too (auditor catch, 2026-06-09: it fired outside
            //     the summarize() slot). Entity-grounding (gate 2 below) does
            //     NOT embed (string/NER), so it stays off the lane.
            let v = await HeavyWorkLane.shared.run(
                label: "RAPTOR-verify",
                { verifier.filteredSummary(raw, sources: memberTexts) }
            )
            let verified = v.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if verified.isEmpty { continue }
            // (2) Entity-grounding: reject a summary that NAMES a person/
            // place/org absent from its source — catches confident on-topic
            // fabrication (the "Beloved by Toni Morrison" failure the cosine
            // gate passed). Load-bearing; reject wholesale on any fabrication.
            let grounding = SummaryEntityGrounding.check(summary: verified, source: documentText)
            if !grounding.grounded {
                dbgLog("RaptorTreeBuilder: rejected summary — fabricated entities [%@]",
                       grounding.fabricatedEntities.joined(separator: ", ") as NSString)
                try? await Task.sleep(nanoseconds: UInt64(config.afmCooldownSeconds * 1_000_000_000))
                continue
            }

            out.append(RaptorSummaryNode(
                layer: layer,
                text: verified,
                memberChunkIndices: members.map { $0.chunkIndex },
                startUnitID: members.first!.startUnitID,
                endUnitID: members.last!.endUnitID,
                verifyKept: v.kept,
                verifyDropped: v.dropped
            ))

            // Pace the next summary call (model-pressure cooldown) + proactive
            // thermal pacing (Pillar 2): pause/back off the cluster loop under
            // thermal pressure, like the embed loop.
            try? await Task.sleep(nanoseconds: UInt64(config.afmCooldownSeconds * 1_000_000_000))
            await ThermalGovernor.shared.pace()
        }
        return out
    }

    // MARK: - Summarization (active model via LLMService: MLX-first, AFM fallback)

    /// Summarize a cluster's concatenated source into a faithful ~80–130 word
    /// abstract, using the ACTIVE model (`ModelCatalog.answerModel()` → the
    /// downloaded MLX model when present, else AFM). Free-text + trim; the caller
    /// verifies the result (cosine + entity grounding), so output hygiene is
    /// backstopped and `@Generable`'s only real benefit here (a clean single
    /// string) isn't needed.
    ///
    /// **Why route through `answerModel()` (2026-06-18, Mark).** RAPTOR was the
    /// lone summarizer still hardcoded to AFM via `@Generable`; AFM refused
    /// benign literary/poetry passages as "sensitive content" (Dickinson), and
    /// silently summarizing an MLX-for-privacy user's document through AFM (→
    /// possibly Apple PCC) contradicted the 2026-05-29 privacy decision that
    /// moved conversation summaries to the active model. Now:
    ///   - MLX users → private, on-device summaries, no AFM content refusals;
    ///   - no-MLX users → AFM, so RAPTOR still works pre-model-download.
    private func summarize(source: String) async -> String? {
        let model = ModelCatalog.answerModel()
        let instructions = """
        You summarize a group of related passages from a book or document so a \
        reading companion can find them later. Write a faithful, concise summary \
        (about 80–130 words) of what the passages actually say — the characters, \
        events, topics, and arguments present in them. Never invent details not \
        in the passages. Do not editorialize or add interpretation. Output only \
        the summary itself, with no preamble or labels.
        """
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: instructions),
            ChatMessage(role: .user, content: "Passages:\n\n\(source)")
        ]
        var accumulated = ""
        do {
            let stream = LLMService.shared.streamChat(
                messages: messages,
                model: model,
                options: LLMGenerationOptions(temperature: 0.2)
            )
            for try await snapshot in stream { accumulated = snapshot }
        } catch {
            dbgLog("RaptorTreeBuilder: summarize failed (model=%@): %@",
                   model.id as NSString, "\(error)")
            return nil
        }
        let s = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

// ========== BLOCK 01: RAPTOR TREE BUILDER - END ==========
