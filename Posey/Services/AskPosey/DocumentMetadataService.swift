// DocumentMetadataService.swift
//
// Extracts clean structured metadata from a document via a single AFM
// `@Generable` call at index time. The extracted facts (title, authors,
// year, document type, one-sentence summary) are stored on the
// `documents` table for future library-wide queries (e.g., "show me
// all law review articles by this author"), AND are synthesized into a
// natural-prose chunk that lives in `document_chunks` as a
// retrievable RAG candidate.
//
// Why this exists. Position-based front-matter prepend (forcing the
// first N chunks of a document into every prompt) was carrying TWO
// jobs at once:
//   (a) Structural orientation — "this is a 2001 law review article
//       by Mark Friedlander, about Internet copyright disputes"
//   (b) A crutch for weak retrieval — when cosine fails on
//       metadata-flavored questions, force the title page in
// Both jobs paid for themselves with ~800 tokens of budget consumed
// by content that includes archive headers, copyright boilerplate,
// pagination noise, and other artifacts that aren't load-bearing.
//
// This service replaces both jobs more cleanly. Job (a) becomes a
// single ~50-token natural-prose summary chunk that competes fairly
// in the RAG via cosine — when a question is metadata-flavored, the
// synthesized chunk wins because it cleanly says what the document
// is. When a question is content-flavored, the synthesized chunk
// loses to actual content chunks and stays out of the prompt entirely.
//
// Threading. The extraction call itself is async (AFM round-trip).
// The caller (`DocumentEmbeddingIndex.enqueueIndexing`) handles
// background-thread dispatch; this service just owns the AFM session
// lifecycle and the prompt/schema.
//
// Failure modes. AFM unavailable → return nil, log, move on. The
// document still works without metadata; retrieval degrades back to
// content-only. AFM refusal on the metadata prompt → same. Refusals
// on a "summarize this document" prompt should be vanishingly rare
// but the code handles them.

import Foundation
import NaturalLanguage

#if canImport(FoundationModels)
import FoundationModels
#endif

// ========== BLOCK 01: METADATA TYPE - START ==========

/// Plain-Swift representation of extracted document metadata.
/// Sendable + Codable so it can cross actor boundaries and be
/// serialized into the documents table.
nonisolated struct DocumentMetadata: Sendable, Codable, Equatable {
    /// Document title as the AFM extracted it. May differ from the
    /// filename-derived title we store on `documents.title`. nil when
    /// the document has no clear title (a draft, a personal note).
    let title: String?

    /// Authors / contributors. Empty array when none found. We use
    /// an array (not single string) so collaborative documents like
    /// "AI Book Collaboration Project" with four AI co-authors
    /// can be represented faithfully.
    let authors: [String]

    /// Publication / creation year as a string (not Int) so AFM can
    /// return "2001", "circa 2010", "n.d.", etc. without forcing a
    /// false precision. nil when no year is determinable.
    let year: String?

    /// Document type — short descriptor like "law review article",
    /// "novel", "research paper", "personal note", "email", "draft",
    /// "technical specification". Free-form because the taxonomy is
    /// open-ended; users searching for "all my novels" or "all my
    /// papers" can match this fuzzy text.
    let documentType: String

    /// One- to two-sentence summary giving the gestalt: what this
    /// document is, what it's about, who it's by, when. The summary
    /// is the most universally useful synthesized fact; if any other
    /// field is unreliable, the summary alone usually answers
    /// "what is this document."
    let summary: String

    /// True when extraction was attempted but the document was
    /// detected as non-English. We still attempt extraction (AFM
    /// handles many languages, just less reliably than English) but
    /// surface this so the UI can hint "Posey is still studying
    /// [language] and isn't yet totally conversant."
    let detectedNonEnglish: Bool
}

// ========== BLOCK 01: METADATA TYPE - END ==========


// ========== BLOCK 02: GENERABLE SCHEMA - START ==========

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct DocumentMetadataPayload: Sendable {

    @Guide(description: "The document's title as printed on the title page or first heading. Use the natural-language title — not the filename. Empty string if the document has no clear title (a draft, a personal note, an untitled fragment).")
    let title: String

    @Guide(description: "List of authors / contributors — the people who WROTE the document. Important disambiguation: in academic / student papers the student is the author, NOT the professor or course instructor. Names like 'Professor X' or 'Dr. X' that appear next to a course name, ID number, or 'Submitted by' phrasing are usually the instructor and should NOT be listed as authors. The author is the person whose name appears as the byline, usually first in the heading block. For collaborative documents, list every contributor. Empty array only if no author is genuinely named.")
    let authors: [String]

    @Guide(description: "Publication or creation year. Free-form — '2001', 'circa 2010', 'n.d.' are all acceptable. Empty string if no year is determinable.")
    let year: String

    @Guide(description: "Short descriptor of the document type. Examples: 'law review article', 'student paper', 'novel', 'short story', 'research paper', 'technical specification', 'personal note', 'email', 'draft', 'blog post', 'letter'. One to four words. Always provide a best-effort guess — never empty.")
    let documentType: String

    @Guide(description: "One to two sentences giving the gestalt of what this document is. Include topic, central thesis or subject, and any defining context. Write as a complete prose sentence, not a fragment. This summary is the most-quoted field — make it useful and precise.")
    let summary: String
}
#endif

// ========== BLOCK 02: GENERABLE SCHEMA - END ==========


// ========== BLOCK 03: PROTOCOL - START ==========

/// Async protocol for extracting metadata from a document. Wrapping
/// behind a protocol lets tests inject deterministic substitutes so
/// chunking + synthesis logic can be exercised without AFM.
@MainActor
protocol DocumentMetadataExtracting: Sendable {
    /// Extract metadata from `document.plainText` (truncated to the
    /// first ~4,000 characters — the AFM call doesn't need the whole
    /// thing to identify title/author/year, and the prompt budget
    /// stays predictable across short and long docs).
    ///
    /// Returns nil on AFM unavailable or refusal. Caller treats nil
    /// as "no metadata available; degrade gracefully."
    func extractMetadata(from document: Document) async -> DocumentMetadata?
}

// ========== BLOCK 03: PROTOCOL - END ==========


// ========== BLOCK 04: LIVE IMPLEMENTATION - START ==========

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@MainActor
final class DocumentMetadataService: DocumentMetadataExtracting {

    private let model: SystemLanguageModel

    /// Last failure diagnostic — set whenever extractMetadata returns
    /// nil so the caller (and the local-API diagnostic verbs) can see
    /// WHY the extraction failed without grepping the device console.
    /// "" on success.
    static var lastFailureReason: String = ""

    init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    func extractMetadata(from document: Document) async -> DocumentMetadata? {
        // AFM availability check — same pattern as AskPoseyService.
        // Returning nil signals "couldn't extract; document still
        // works without metadata."
        guard model.availability == .available else {
            let reason = "AFM unavailable: \(model.availability)"
            Self.lastFailureReason = reason
            dbgLog("DocumentMetadataService: %@ for %@", reason, document.title)
            return nil
        }

        // Truncate input — the title/author/year live in the first
        // ~1,500 characters of every well-formed document (title
        // page + first paragraph). Going further pulls in body text
        // that more easily trips AFM's content-moderation refusals
        // without adding signal for metadata extraction. For
        // documents shorter than the limit, use the full text.
        // 2026-05-05 — Reduced from 4,000 to 1,500 after the
        // copyright-law article ("Napster", "mp3.com", "copyright
        // disputes" in the introduction) consistently tripped a
        // "May contain sensitive content" refusal at 4K chars but
        // succeeds at 1.5K chars.
        let inputCharLimit = 1_500
        let snippet = document.plainText.count <= inputCharLimit
            ? document.plainText
            : String(document.plainText.prefix(inputCharLimit))

        // Detect non-English. We still attempt extraction (AFM
        // handles non-English to a degree) but surface the flag so
        // the UI can warn the user.
        let language = NLLanguageDetector.detect(snippet)
        let isNonEnglish = !(language == .english || language == .undetermined)

        let instructions = """
        You extract structured metadata from documents for a personal \
        reading companion app. Return concise, factual fields. Do not \
        invent authors, dates, or titles — when a field isn't \
        determinable from the input, use an empty string (or empty \
        array for authors). The summary should be one or two complete \
        sentences in clear English, capturing what the document is and \
        what it's about. Never editorialize, recommend, or rate the \
        document.
        """

        let prompt = """
        Below is the opening passage of a document. Extract the \
        document's metadata.

        ----- DOCUMENT OPENING -----
        \(snippet)
        ----- END DOCUMENT OPENING -----
        """

        let session = LanguageModelSession(
            model: model,
            instructions: instructions
        )

        // Helper: invoke AFM and return either the payload or the
        // raw error so we can branch on refusal vs other failures.
        func attempt(prompt: String) async -> Result<DocumentMetadataPayload, Error> {
            do {
                let response = try await session.respond(
                    to: prompt,
                    generating: DocumentMetadataPayload.self
                )
                return .success(response.content)
            } catch {
                return .failure(error)
            }
        }

        Self.lastFailureReason = ""
        var payload: DocumentMetadataPayload
        let firstAttempt = await attempt(prompt: prompt)
        switch firstAttempt {
        case .success(let p):
            payload = p
        case .failure(let error):
            // Detect refusal and retry with a more neutral prompt
            // that asks only for bibliographic facts (title / author /
            // year), avoiding any framing that might trip AFM's
            // content-moderation gate. Same pattern AskPoseyService
            // uses for the grounded call.
            let isRefusal = "\(error)".lowercased().contains("refusal")
            if isRefusal {
                let neutralPrompt = """
                The text below is the opening of a document. Identify \
                the bibliographic facts only: the document's title, \
                its author or authors, the year of publication or \
                creation, and what type of document it is (e.g., \
                article, book, paper, note). Provide a one-sentence \
                neutral description of what the document covers. Do \
                not summarize content, do not characterize claims, do \
                not reproduce passages.

                ----- DOCUMENT OPENING -----
                \(snippet)
                ----- END DOCUMENT OPENING -----
                """
                let retry = await attempt(prompt: neutralPrompt)
                switch retry {
                case .success(let p):
                    payload = p
                case .failure(let retryError):
                    let reason = "respond failed (after refusal retry): \(retryError)"
                    Self.lastFailureReason = reason
                    dbgLog("DocumentMetadataService: %@", reason)
                    return nil
                }
            } else {
                let reason = "respond failed: \(type(of: error)) — \(error)"
                Self.lastFailureReason = reason
                dbgLog("DocumentMetadataService: %@ for %@",
                       reason, document.title)
                return nil
            }
        }

        // Map @Generable payload (which uses empty strings for
        // optional fields per `@Generable` ergonomics) back to our
        // domain model where missing fields are nil.
        let title    = payload.title.trimmed.nonEmpty
        let year     = payload.year.trimmed.nonEmpty
        let authors  = payload.authors
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
        let docType  = payload.documentType.trimmed.nonEmpty
            ?? "document"
        let summary  = payload.summary.trimmed

        return DocumentMetadata(
            title: title,
            authors: authors,
            year: year,
            documentType: docType,
            summary: summary,
            detectedNonEnglish: isNonEnglish
        )
    }
}
#endif

// ========== BLOCK 04: LIVE IMPLEMENTATION - END ==========


// ========== BLOCK 05: PROSE SYNTHESIZER - START ==========

/// Builds a natural-prose chunk from extracted metadata + (optional)
/// TOC entries. The output is a single coherent paragraph that
/// embeds well via cosine — short fragments like "Author: X" embed
/// poorly because there's no context for the embedder to anchor on.
/// A complete prose paragraph is the right granularity.
///
/// The synthesized chunk is then embedded and stored in
/// `document_chunks` with a distinguishing `embeddingKind` tag so
/// it can be identified for re-extraction if quality issues surface.
///
/// Output example:
///   "This document is titled 'The Clouds of High-Tech Copyright
///   Law,' written by Mark Friedlander in 2001. It is a law review
///   article. Discusses how Alternative Dispute Resolution can
///   address Internet copyright disputes, focusing on the cases of
///   mp3.com, Napster, and Scour. The document includes the following
///   sections: Introduction, Background on Copyright Law, ADR as a
///   Solution, Case Studies, Conclusion."
nonisolated enum DocumentMetadataChunkSynthesizer {

    /// Build the synthesized prose chunk text. `tocEntries` may be
    /// empty (most documents don't have a clean TOC, and even the
    /// ones that do, may be parsed as separate entries elsewhere).
    /// Returns nil when no metadata is meaningful enough to bother
    /// synthesizing — pure-empty extraction (no title, no authors,
    /// no year, empty summary) means we have nothing useful to add
    /// to the RAG.
    static func synthesize(
        metadata: DocumentMetadata,
        documentTitle: String,
        tocEntries: [String] = []
    ) -> String? {

        // Build sentence by sentence so the prose flows naturally
        // even when some fields are missing.
        var sentences: [String] = []

        // Sentence 1: identification — title + authors + year.
        // Always include this if we have anything — falls back to
        // "This document" when title is unknown.
        let displayTitle = metadata.title ?? documentTitle
        var s1 = "This document is titled \"\(displayTitle)\""
        if !metadata.authors.isEmpty {
            let authorList: String
            switch metadata.authors.count {
            case 1: authorList = metadata.authors[0]
            case 2: authorList = "\(metadata.authors[0]) and \(metadata.authors[1])"
            default:
                let allButLast = metadata.authors.dropLast().joined(separator: ", ")
                authorList = "\(allButLast), and \(metadata.authors.last!)"
            }
            s1 += ", written by \(authorList)"
        }
        if let year = metadata.year {
            s1 += ", in \(year)"
        }
        s1 += "."
        sentences.append(s1)

        // Sentence 2: document type. Always include — even
        // "document" alone is a useful prior.
        sentences.append("It is a \(metadata.documentType).")

        // Sentence 3: summary. Skip when empty (extraction didn't
        // find enough content to summarize).
        if !metadata.summary.isEmpty {
            // Defensive: ensure summary ends with a period so the
            // joined output reads naturally.
            let trimmed = metadata.summary.trimmed
            let punctuated = trimmed.last.map { ".!?".contains($0) } ?? false
                ? trimmed
                : trimmed + "."
            sentences.append(punctuated)
        }

        // Sentence 4 (optional): TOC overview. Only include when
        // we have entries AND they fit comfortably (avoid blowing
        // out chunk size with a 200-section book TOC).
        if !tocEntries.isEmpty {
            let tocText = formatTOC(entries: tocEntries)
            if !tocText.isEmpty {
                sentences.append(tocText)
            }
        }

        // If we ended up with only the boilerplate "This document is
        // titled..." sentence and "It is a document." (both fallbacks),
        // skip synthesis entirely. The RAG isn't helped by a chunk
        // that's purely structural placeholders.
        let meaningfulFields = (metadata.title != nil ? 1 : 0)
            + (metadata.authors.isEmpty ? 0 : 1)
            + (metadata.year != nil ? 1 : 0)
            + (metadata.summary.isEmpty ? 0 : 1)
            + (tocEntries.isEmpty ? 0 : 1)
        guard meaningfulFields >= 1 else { return nil }

        return sentences.joined(separator: " ")
    }

    /// Format a TOC into a single sentence. Truncates aggressively
    /// to avoid a 200-section book overflowing the chunk; lists the
    /// first ~12 entries with an ellipsis when there are more.
    private static func formatTOC(entries: [String]) -> String {
        let cleaned = entries
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "" }

        let maxEntries = 12
        let displayed: [String]
        let suffix: String
        if cleaned.count > maxEntries {
            displayed = Array(cleaned.prefix(maxEntries))
            suffix = ", among others"
        } else {
            displayed = cleaned
            suffix = ""
        }
        let joined: String
        switch displayed.count {
        case 1: joined = displayed[0]
        case 2: joined = "\(displayed[0]) and \(displayed[1])"
        default:
            let allButLast = displayed.dropLast().joined(separator: ", ")
            joined = "\(allButLast), and \(displayed.last!)"
        }
        return "The document includes the following sections: \(joined)\(suffix)."
    }
}

// ========== BLOCK 05: PROSE SYNTHESIZER - END ==========


// ========== BLOCK 06: HELPERS - START ==========

/// Lightweight language detection wrapper. Reuses NLLanguageRecognizer
/// in the same pattern the embedder selection uses, but exposed at
/// the file scope so the metadata service can call it without
/// reaching into DocumentEmbeddingIndex's private surface.
nonisolated enum NLLanguageDetector {
    /// Detect dominant language of `text`. Returns `.english` very
    /// liberally — the non-English banner shouldn't fire unless we
    /// have STRONG evidence the document isn't in English.
    ///
    /// Why so liberal: real-world English documents contain proper
    /// nouns, scientific Latin, place names, technical terms, and
    /// quotations from other languages. NLLanguageRecognizer can
    /// trip into a non-English classification on benign English
    /// content (e.g., the Field Notes on Estuaries article got
    /// flagged as non-English on first ship). The cost of a false
    /// non-English banner is real (visible to the user, undermines
    /// trust). The cost of a false English classification is small
    /// (just no banner; the user reads what they imported).
    ///
    /// Algorithm:
    ///   1. If NLLanguageRecognizer's TOP hypothesis is English, the
    ///      doc is English regardless of confidence.
    ///   2. If the top hypothesis is non-English, require >= 0.85
    ///      confidence AND that English not appear in the top-3 with
    ///      >= 0.10 confidence. Otherwise default to English.
    ///   3. If empty/short input, return English (no banner).
    static func detect(_ text: String) -> NLLanguage {
        guard !text.isEmpty else { return .english }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else {
            return .english
        }
        if dominant == .english { return .english }

        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        let dominantConfidence = hypotheses[dominant] ?? 0
        let englishConfidence = hypotheses[.english] ?? 0

        // Strong-evidence threshold: dominant non-English language
        // must have at least 0.85 confidence AND English must be
        // a distant alternative (< 0.10 confidence) for us to
        // believe the document is genuinely non-English.
        if dominantConfidence >= 0.85 && englishConfidence < 0.10 {
            return dominant
        }
        return .english
    }
}

private extension String {
    /// Trim whitespace + newlines.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Returns nil when empty after trimming.
    var nonEmpty: String? {
        let t = trimmed
        return t.isEmpty ? nil : t
    }
}

// ========== BLOCK 06: HELPERS - END ==========
