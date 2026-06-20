import Foundation

// ========== BLOCK 01: ASK POSEY TURN EMBEDDER - START ==========

/// 2026-06-20 — CONVERSATION-MEMORY FIX (spec line 95: "Index conversation
/// turns at save time"). Embeds a single user/assistant turn when it is saved
/// and writes the vector into `ask_posey_conversations.embedding`, so a turn
/// that later ages out of the verbatim STM window remains **semantically
/// recallable** instead of surviving only as the lossy rolling summary.
///
/// **Ported from Hal's `storeUnifiedContentWithEntities`** (Hal.swift:1868) —
/// Hal computes the embedding at save and stores it as a `Double` BLOB. We do
/// the same, with three deliberate Posey divergences (see HISTORY 2026-06-20 /
/// the conversation-memory design):
///   - **Turns only, not documents.** Posey keeps doc chunks in their own table
///     with a specialized small-to-big pipeline; this embedder is just for
///     dialogue turns (the conversation-recall pass is separate from doc-RAG).
///   - **`.document` purpose for the stored turn**, `.query` for the question at
///     retrieval time — Hal's asymmetric convention (better recall on the
///     asymmetric Nomic/mxbai backends; a no-op on NLContextual).
///   - **Active backend, tagged in `embedding_kind`.** If the active backend is
///     swapped later, stale-kind rows can be re-embedded; for now a kind
///     mismatch simply isn't eligible (handled by the retrieval pass).
///
/// **Graceful fallback (also Hal's behavior):** if the model isn't loaded the
/// embed returns nil → the row's `embedding` stays NULL → the turn still lives
/// in STM + summary, just isn't semantically recallable. Never fatal.
///
/// Fire-and-forget off the calling actor: the turn is already persisted; this
/// only enriches it. One short-string embed — the same cost as the per-turn
/// query embed that already happens — so it adds no saturation risk.
nonisolated enum AskPoseyTurnEmbedder {

    /// Embed `turn` with the active backend and store the vector. No-op for
    /// summaries, anchors, and empty content (only real user/assistant turns
    /// are recallable dialogue).
    static func embedAndStore(_ turn: StoredAskPoseyTurn, database: DatabaseManager) async {
        guard !turn.isSummary,
              turn.role == "user" || turn.role == "assistant",
              !turn.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let backend = EmbeddingBackend.current()
        let content = turn.content
        // Embed off the calling actor (model inference is heavier than a DB write).
        let vector: [Double]? = await Task.detached(priority: .utility) {
            EmbeddingProvider.shared.embed(content, as: .document, in: backend)
        }.value
        guard let vector else { return }   // model not loaded → leave NULL (graceful)
        try? database.updateAskPoseyTurnEmbedding(
            id: turn.id, embedding: vector, kind: backend.rawValue)
    }
}

// ========== BLOCK 01: ASK POSEY TURN EMBEDDER - END ==========
