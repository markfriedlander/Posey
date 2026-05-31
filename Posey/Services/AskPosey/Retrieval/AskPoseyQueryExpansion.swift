import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// Guided-generation payload for AFM query expansion. `@Generable` forces
/// AFM to return a string array — it CANNOT ramble into a prose answer or
/// echo the question as a sentence (both observed on the free-text path
/// 2026-05-30). The `@Guide` carries the "answer-passage vocabulary, not
/// the question's words" intent that the free-text prompt couldn't enforce.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct ExpansionTermsPayload: Sendable {
    @Guide(description: "5 to 10 short search keywords or phrases that would LITERALLY appear in the passage of the book that answers the reader's question — synonyms, character names, concrete physical or emotional details, and distinctive phrasings the author would actually use. Do NOT include words that are already in the question (those are already searched). Each entry lowercase, 1-3 words. Never answer the question.")
    let terms: [String]
}
#endif

// ========== BLOCK 01: QUERY EXPANSION - START ==========
/// LLM-driven query expansion for weak / lexically-mismatched RAG
/// retrieval. Ported from Hal Universal's `QueryExpansion` (Rule 9A diff:
/// `docs-internal/QUERY-EXPANSION-HAL-DIFF-2026-05-30.md`).
///
/// **The premise (measured on Posey, 2026-05-30 via RAG_DEBUG).** Hybrid
/// retrieval (semantic + BM25 + RRF) does well when the reader's question
/// shares either content words or concept-level meaning with the passage
/// that answers it. It fails when both are weak — the *natural-question-
/// vs-passage vocabulary gap*. On Pride & Prejudice, "what did Darcy say
/// about Elizabeth at the assembly" never retrieves the *"tolerable, but
/// not handsome enough to tempt me"* passage (absent from the top 25):
/// BM25 surface-matches "Darcy/Elizabeth/Meryton" in dozens of chunks,
/// and the NLContextual semantic cosines all cluster ~0.92 with no
/// separation. Query by the passage's OWN words and it ranks #1. The
/// bridge between those two queries is exactly what the LLM supplies here.
///
/// **Fix.** When the initial retrieval is weak, ask the active LLM for
/// 5–10 related concept terms, then re-run the BM25 side of the hybrid
/// pipeline with `(original tokens) OR (expansion tokens)`. The semantic
/// pass is left unchanged — embeddings don't benefit from word expansion.
/// Keep-if-better: the caller keeps the expanded result only when it
/// improves the fused top-1, so expansion can only help.
///
/// **First cut: no SQLite cache** (Hal caches per query+model). Expansion
/// fires only on weak retrieval, the call is the active model at <100
/// tokens, and local inference is effectively free (Rule 6). Add the
/// cache later if latency on weak turns warrants it.
enum AskPoseyQueryExpansion {

    // MARK: - Enablement (default OFF — value unproven, 2026-05-30)

    /// Production gate. **Default OFF.** Measured on Pride & Prejudice
    /// (every test): expansion produced only TIES (`expandedTop ==
    /// baseTop`), never a strict improvement — a novel's recurring proper
    /// nouns keep base retrieval at the BM25-distinctive ~0.09, above the
    /// weak band expansion is designed to rescue; and AFM can't predict
    /// counterintuitive answer vocabulary (it expanded the Darcy-insult
    /// question to "beautiful, lovely" — the opposite of "tolerable, not
    /// handsome enough"). keep-if-better makes it harmless, but it adds a
    /// 1-2s LLM call on weak turns for no measured benefit on the corpus
    /// tested. Left wired + measurable (RAG_DEBUG_EXPANDED bypasses this
    /// gate) pending evaluation on sparse / technical / topic-predictable
    /// docs where the Hal trigger (<0.020) actually fires. Flip on via
    /// `SET_QUERY_EXPANSION:on` once value is demonstrated.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "askPoseyQueryExpansionEnabled")
    }

    // MARK: - Trigger

    /// Classic-weak threshold (Hal's calibrated value). RRF's max single-
    /// list score is 1/(60+1) ≈ 0.0164; both lists agreeing ≈ 0.0328.
    /// Below ~0.020 the fused top-1 is a single weak list.
    static let triggerRRFScoreUpperBound: Double = 0.020

    /// How many of the top fused results to inspect for the "no semantic
    /// corroboration" signal (Posey's evidence-backed extension below).
    static let bm25OnlyHeadCount: Int = 2

    /// Decide whether to expand. Two triggers:
    ///
    /// 1. **Classic weak** (Hal): fused top-1 RRF below the floor — the
    ///    retrieval is thin on every list.
    /// 2. **No semantic corroboration** (Posey extension, measured): the
    ///    top results that would actually reach the model are all
    ///    BM25-only (`semanticScore == nil`) — pure lexical surface-match
    ///    with no semantic support. This is the Darcy case: `topRelevance`
    ///    was 0.091 (ABOVE the floor, so Hal's trigger alone would NOT
    ///    fire) yet the answer was wrong because the injected chunks were
    ///    surface-noise. RAG_DEBUG made this visible across 3+ instances
    ///    this session. keep-if-better guards the extra aggressiveness.
    ///
    /// Returns the trigger reason for logging, or nil if no expansion.
    static func triggerReason(topRelevance: Double, topChunks: [RetrievedChunk]) -> String? {
        if topRelevance < triggerRRFScoreUpperBound {
            return "weak-score(\(String(format: "%.4f", topRelevance)))"
        }
        let head = topChunks.prefix(bm25OnlyHeadCount)
        if !head.isEmpty && head.allSatisfy({ $0.semanticScore == nil }) {
            return "no-semantic-corroboration(top\(head.count) BM25-only)"
        }
        return nil
    }

    // MARK: - LLM prompt (kept compact; <100 tokens incl. response)

    /// One system prompt for all backends. Reworded from Hal's
    /// "stored memories" → "the document passage" (Posey searches a
    /// document, not assistant memories), then hardened with a few-shot
    /// example after on-device measurement: AFM *ignored* a bare
    /// "list terms" instruction and answered the question instead
    /// ("Mr. Darcy said Elizabeth was handsome"). The example + explicit
    /// "you do NOT answer" prohibition forces keyword-extraction format on
    /// AFM and the smaller MLX models alike. The example is neutral-domain
    /// so it doesn't leak literary content into the terms.
    static let systemPrompt: String = """
    You help search a book for the passage that answers a reader's question. Output the words and short phrases the ANSWERING PASSAGE itself most likely contains: synonyms, character names, concrete physical or emotional details, and distinctive phrasings the author would actually use. Do NOT repeat words that are already in the question — those are already searched. You do NOT answer the question.

    Example:
    Question: "Why was the soldier afraid the night before the battle?"
    trembling
    cold sweat
    drums in the distance
    dread
    boyhood home
    deserter
    musket

    Notice the keywords are the DIFFERENT words the passage would use — not "soldier", "afraid", or "battle" from the question. Do the same: output 6-10 such lines, lowercase, one per line, no numbering, no commentary, no answer.
    """

    // MARK: - Entry point

    /// Ask the active LLM for expansion terms. Returns `[]` on any failure
    /// or empty output — the caller treats that as "no expansion" and
    /// keeps the original retrieval. Awaits one stream-accumulated LLM
    /// round-trip (~0.5–2s on AFM for a sub-100-token prompt).
    static func expand(query: String,
                       model: ModelConfiguration = ModelCatalog.auxModel()) async -> [String] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        // AFM: guided generation (forces the format — the free-text path
        // either echoed the question's nouns or rambled to a context
        // overflow). MLX: free-text + parseTerms (no @Generable on MLX).
        #if canImport(FoundationModels)
        if model.source == .appleFoundation {
            if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                return await expandViaAFM(question: normalized)
            }
        }
        #endif
        return await expandViaFreeText(query: normalized, model: model)
    }

    #if canImport(FoundationModels)
    /// AFM guided-generation expansion. Returns the terms array directly —
    /// no parsing, no rambling. Filters out any term that just echoes a
    /// question word (defensive; the @Guide already forbids it).
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private static func expandViaAFM(question: String) async -> [String] {
        let model = SystemLanguageModel.default
        guard model.availability == .available else { return [] }
        let instructions = """
        You generate search keywords to locate the passage in a book that \
        answers a reader's question. Output the distinctive words that \
        answering passage itself would contain — synonyms, character names, \
        concrete physical or emotional details — NOT the words already in \
        the question. You never answer the question itself.
        """
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let response = try await session.respond(
                to: "Question: \(question)",
                generating: ExpansionTermsPayload.self
            )
            let questionWords = Set(
                question.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count >= 2 }
            )
            let cleaned = response.content.terms
                .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 && $0.count <= 30 }
                // Drop pure question-word echoes (single tokens already searched).
                .filter { term in
                    let toks = term.components(separatedBy: " ")
                    return !(toks.count == 1 && questionWords.contains(term))
                }
            var seen = Set<String>(); var out: [String] = []
            for t in cleaned where !seen.contains(t) { seen.insert(t); out.append(t); if out.count >= 10 { break } }
            dbgLog("AskPosey expansion AFM: q='%@' terms=%d [%@]",
                   question.prefix(48) as CVarArg, out.count, out.joined(separator: ",") as NSString)
            return out
        } catch {
            dbgLog("AskPosey expansion AFM failed: %@", "\(error)")
            return []
        }
    }
    #endif

    /// MLX (and AFM-unavailable fallback) free-text expansion: stream the
    /// model's response and parse lines into terms.
    private static func expandViaFreeText(query: String,
                                          model: ModelConfiguration) async -> [String] {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: systemPrompt),
            ChatMessage(role: .user, content: "Question: \"\(query)\"")
        ]
        do {
            var accumulated = ""
            for try await snapshot in LLMService.shared.streamChat(
                messages: messages,
                model: model,
                options: LLMGenerationOptions(temperature: 0.0)
            ) {
                accumulated = snapshot
            }
            let parsed = parseTerms(from: accumulated)
            dbgLog("AskPosey expansion MLX: model=%@ parsed=%d", model.id, parsed.count)
            return parsed
        } catch {
            dbgLog("AskPosey expansion MLX failed: %@", "\(error)")
            return []
        }
    }

    // MARK: - Parse (ported verbatim from Hal — robust, model-agnostic)

    /// Parse the LLM's free-form text into clean terms. Tolerant of
    /// bullets, numbering, mixed case, trailing punctuation, incidental
    /// commentary. Caps at 10 terms.
    static func parseTerms(from response: String) -> [String] {
        let lines = response.components(separatedBy: .newlines)
        var terms: [String] = []
        var seen = Set<String>()
        for line in lines {
            var s = line.trimmingCharacters(in: .whitespaces)
            // Strip leading bullets / numbering / dashes.
            while let first = s.first, first.isPunctuation || first.isNumber || first == "•" {
                s.removeFirst()
                s = s.trimmingCharacters(in: .whitespaces)
            }
            let clean = s.lowercased().filter { c in
                c.isLetter || c.isNumber || c == " " || c == "-"
            }.trimmingCharacters(in: .whitespaces)
            guard clean.count >= 2 && clean.count <= 30 else { continue }
            guard !clean.contains("  ") else { continue }   // skip sentence fragments
            guard !seen.contains(clean) else { continue }
            seen.insert(clean)
            terms.append(clean)
            if terms.count >= 10 { break }
        }
        return terms
    }
}
// ========== BLOCK 01: QUERY EXPANSION - END ==========
