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

    @Guide(description: "A short subject heading — like a library catalog descriptor — for this passage. One sentence, naming the topic and any specific subjects, people, places, or concepts the passage covers. Use plain bibliographic language. Do not paraphrase the passage's prose. Examples of good output: 'Discussion of mp3.com's role in early Internet music distribution.' or 'Constitutional basis for U.S. copyright law.' or 'Comparison of mediation and arbitration as ADR methods.'")
    let contextNote: String
}
#endif

// ========== BLOCK 02: GENERABLE SCHEMA - END ==========


// ========== BLOCK 02b: DETERMINISTIC FALLBACK - START ==========

import NaturalLanguage

/// When AFM refuses to write a context note for a chunk, we fall back
/// to a deterministically-generated note built from:
///   - the document's title, author, year, and summary (already
///     extracted in Phase A)
///   - the chunk's relative position in the document (early / mid /
///     late)
///   - named entities extracted from the chunk via NLTagger.nameType
///   - significant content tokens (stopword-filtered, length ≥ 4)
///
/// The fallback note isn't as targeted as AFM's would be, but it gives
/// the embedder more signal than the raw chunk text alone — entity
/// names + topic words land cleanly in the embedding space. And
/// crucially, it's guaranteed: no AFM call means no refusal.
nonisolated enum FallbackChunkContextSynthesizer {

    /// Generate a deterministic context note for a chunk.
    ///
    /// `relativePosition` is `chunkIndex / totalChunks` in [0, 1].
    /// Used to add positional language ("near the start of the book",
    /// "midway through", "in the closing portion") which the embedder
    /// can match against questions like "what's in the first chapter."
    static func synthesize(
        chunkText: String,
        documentTitle: String,
        documentAuthors: [String],
        documentYear: String?,
        documentSummary: String?,
        relativePosition: Double
    ) -> String {

        var pieces: [String] = []

        // Position language.
        let positionPhrase: String
        if relativePosition < 0.20 {
            positionPhrase = "the early portion"
        } else if relativePosition < 0.50 {
            positionPhrase = "the first half"
        } else if relativePosition < 0.80 {
            positionPhrase = "the second half"
        } else {
            positionPhrase = "the closing portion"
        }

        // Document attribution.
        let attribution: String
        if documentAuthors.isEmpty {
            attribution = "of \"\(documentTitle)\""
        } else if documentAuthors.count == 1 {
            attribution = "of \"\(documentTitle)\" by \(documentAuthors[0])"
        } else {
            let last = documentAuthors.last ?? ""
            let head = documentAuthors.dropLast().joined(separator: ", ")
            attribution = "of \"\(documentTitle)\" by \(head), and \(last)"
        }
        let yearClause = documentYear.map { " (\($0))" } ?? ""

        pieces.append("This passage is from \(positionPhrase) \(attribution)\(yearClause).")

        // Named entities — gives the embedder concrete proper-noun
        // signal that's strongly indicative of what the chunk covers.
        let entities = extractEntities(from: chunkText)
        if !entities.isEmpty {
            let cap = min(entities.count, 8)
            let list = Array(entities.prefix(cap)).joined(separator: ", ")
            pieces.append("Mentions: \(list).")
        }

        // Document overview — helps the embedder match the chunk
        // against questions about the document's overall topic when
        // the chunk's specific terminology doesn't.
        if let summary = documentSummary, !summary.isEmpty {
            pieces.append("The document overall: \(summary)")
        }

        return pieces.joined(separator: " ")
    }

    /// Extract proper nouns + organization names + place names via
    /// NLTagger. Returns deduplicated, original-case strings, in
    /// document order. Cap at 12 to keep notes from becoming entity
    /// dumps on entity-heavy chunks.
    private static func extractEntities(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var seen = Set<String>()
        var ordered: [String] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            guard let tag = tag else { return true }
            switch tag {
            case .personalName, .placeName, .organizationName:
                let span = String(text[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let key = span.lowercased()
                // Filter junk: must contain at least one letter and
                // have minimum length 2 letters total. Filters out
                // Roman numeral headers ("III.", "VI."), bare
                // punctuation, and other NLTagger false positives.
                let letterCount = span.filter { $0.isLetter }.count
                let isRomanLike = span.allSatisfy {
                    "IVXLCDMivxlcdm.".contains($0)
                }
                if letterCount >= 2,
                   !isRomanLike,
                   !seen.contains(key) {
                    seen.insert(key)
                    ordered.append(span)
                }
            default:
                break
            }
            if ordered.count >= 12 { return false }
            return true
        }
        return ordered
    }
}

// ========== BLOCK 02b: DETERMINISTIC FALLBACK - END ==========


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

        let summaryLine = documentSummary.map { "Document overview: \($0)\n" } ?? ""

        // Librarian-cataloging frame. The earlier "search-relevance
        // assistant" / "search index" framing tripped AFM's moderation
        // gate even on completely benign chunks (title pages, brief
        // historical narratives, definitions of legal terms). This
        // framing instead asks AFM to write a library subject heading
        // for the passage — a task AFM understands as cataloging
        // work, completely outside the categories its safety system
        // tries to gate. Refusal rate on the same content drops from
        // ~30% to near zero with this prompt.
        let instructions = """
        You are a librarian writing brief subject headings to help a \
        reader locate passages in a book. Read the passage and write \
        a one-sentence subject heading describing what the passage is \
        about. Mention specific people, places, concepts, or topics \
        the passage covers. Use plain library-catalog language. Do \
        not summarize or paraphrase the passage's prose; describe its \
        topic, not its argument. Output only the subject heading.
        """

        let prompt = """
        Book title: \(documentTitle)
        \(summaryLine)
        Passage from the book:
        ----- BEGIN PASSAGE -----
        \(chunkSnippet)
        ----- END PASSAGE -----

        Write a one-sentence subject heading for this passage.
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
                // Even more conservative retry: drop ALL framing,
                // ask only for a topic phrase. Sometimes the document
                // overview / title context is what AFM is reacting
                // to (e.g., "copyright disputes" sounds adversarial
                // to the model even though the actual passage is
                // benign).
                let neutralPrompt = """
                What is the topic of this short text? Reply with one \
                sentence naming the subject.

                \(String(chunkSnippet.prefix(800)))
                """
                let neutralInstructions = """
                You write one-sentence topic descriptions for short \
                text excerpts. Output a single descriptive sentence \
                naming what the text is about.
                """
                let neutralSession = LanguageModelSession(
                    model: model,
                    instructions: neutralInstructions
                )
                do {
                    let retry = try await neutralSession.respond(
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
