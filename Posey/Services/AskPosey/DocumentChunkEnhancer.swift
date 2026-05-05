// DocumentChunkEnhancer.swift
//
// Phase B — Per-chunk contextual retrieval (Anthropic-pattern).
//
// For each content chunk in a document, ask AFM to generate a 1-2
// sentence "context note" describing what the chunk is about and
// where it sits in the document. Prepend the note to the chunk text
// before embedding. Reported gain on Anthropic's benchmarks: ~50%
// retrieval-failure reduction, because the embedder now sees a
// chunk that's been explicitly oriented within the document rather
// than a raw text fragment whose topic relevance has to be inferred.
//
// Cost shape on Posey's on-device AFM: ~1-2s per chunk. Background
// only — must yield to user-facing AFM calls. Library-wide traversal
// after the current document finishes. See HISTORY 2026-05-05 for
// Mark's progressive-enhancement design.

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// ========== BLOCK 01: PROTOCOL - START ==========

/// Async closure type for chunk-context generation. Centralized in
/// DocumentEmbeddingIndex (alongside MetadataExtractorClosure) so the
/// scheduler can take a single closure instead of a protocol
/// existential — same Swift 6 actor-isolation reasoning that drove
/// the metadata-extractor switch from protocol to closure.
typealias DocumentChunkContextClosure =
    @MainActor (_ chunkText: String, _ documentSummary: String?, _ documentTitle: String) async -> String?

// ========== BLOCK 01: PROTOCOL - END ==========


// ========== BLOCK 02: GENERABLE SCHEMA - START ==========

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct DocumentChunkContextPayload: Sendable {

    @Guide(description: "One to two sentences that orient this passage within the document. Specify what the passage is about and where it fits in the broader argument or narrative. Use words and phrases someone searching for this passage's topic would actually type. Be specific — avoid filler like 'this passage discusses' without saying what it discusses. Never paraphrase the passage itself; this is meta-context, not a summary.")
    let contextNote: String
}
#endif

// ========== BLOCK 02: GENERABLE SCHEMA - END ==========


// ========== BLOCK 03: LIVE IMPLEMENTATION - START ==========

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@MainActor
final class DocumentChunkEnhancer {

    private let model: SystemLanguageModel

    /// Last failure reason, exposed via the local API for diagnostics.
    static var lastFailureReason: String = ""

    init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    /// Generate a context note for a chunk. Returns nil on AFM
    /// unavailable / refusal / error. Caller proceeds without the
    /// enhancement (chunk stays at its current `embedding_kind` and
    /// the scheduler can retry it later).
    func contextNote(forChunk chunkText: String,
                     documentSummary: String?,
                     documentTitle: String) async -> String? {
        guard model.availability == .available else {
            Self.lastFailureReason = "AFM unavailable"
            return nil
        }

        // Truncate the chunk fed to AFM. The prompt shouldn't exceed
        // a few hundred tokens — context-note generation needs the
        // chunk's gist, not its full text. Most chunks at the 500-1000
        // char target already fit comfortably; this guards against
        // pathological multi-paragraph chunks.
        let chunkSnippet = chunkText.count <= 1500
            ? chunkText
            : String(chunkText.prefix(1500))

        let summaryLine = documentSummary.map { "Document summary: \($0)\n" } ?? ""

        let instructions = """
        You write 1-2 sentence search-relevance "context notes" that get \
        prepended to passages in a search index. Your job is to make a \
        passage easy to retrieve when a reader asks about its topic. \
        Specify what the passage is about and where it fits within the \
        document. Use the words a reader would actually search with. \
        Never paraphrase or repeat the passage's prose — this is meta- \
        context, not a summary. No editorial comments. No recommendations.
        """

        let prompt = """
        Document title: \(documentTitle)
        \(summaryLine)
        Passage:
        ----- BEGIN PASSAGE -----
        \(chunkSnippet)
        ----- END PASSAGE -----

        Write a 1-2 sentence context note for this passage.
        """

        let session = LanguageModelSession(
            model: model,
            instructions: instructions
        )

        // Refusal-retry: Phase A's metadata extractor showed AFM can
        // refuse on benign content (Napster / mp3.com / "copyright
        // disputes" tripped a "May contain sensitive content" gate).
        // Same pattern here — try once, retry with a more neutral
        // prompt if refused.
        do {
            Self.lastFailureReason = ""
            let response = try await session.respond(
                to: prompt,
                generating: DocumentChunkContextPayload.self
            )
            return response.content.contextNote.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            let isRefusal = "\(error)".lowercased().contains("refusal")
            if isRefusal {
                let neutralPrompt = """
                Document title: \(documentTitle)
                Passage (excerpt):
                \(String(chunkSnippet.prefix(800)))

                Write a brief, neutral 1-2 sentence note describing the topic \
                of this passage. Use plain bibliographic language. Do not \
                quote or paraphrase the passage.
                """
                do {
                    let retry = try await session.respond(
                        to: neutralPrompt,
                        generating: DocumentChunkContextPayload.self
                    )
                    return retry.content.contextNote
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    Self.lastFailureReason = "respond failed (after refusal retry): \(error)"
                    return nil
                }
            }
            Self.lastFailureReason = "respond failed: \(type(of: error)) — \(error)"
            return nil
        }
    }
}
#endif

// ========== BLOCK 03: LIVE IMPLEMENTATION - END ==========
