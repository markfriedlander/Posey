import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

// ========== BLOCK 01: RESULT TYPE - START ==========
/// Result of bibliographic extraction. `source` records WHICH strategy
/// produced each field, for the diagnostic log + tuning loop.
///
/// 2026-05-29 — Revives the bibliographic half of the `DocumentMetadataService`
/// that Step 8f removed (it went out as collateral with the legacy
/// synthetic-chunk retrieval; the structured-column plumbing —
/// `saveDocumentMetadata` / `documentMetadata` / the `metadata_*` columns —
/// survived orphaned). Scope per Mark (2026-05-29): **author + publication/
/// copyright year only.** Title is already a structured field
/// (`documents.title`); publisher is deferred. Hal has no bibliographic
/// extraction to port (it tags imported content with filename + sourceType
/// only), so this is Posey's own prior art, trimmed.
///
/// One entry point (`extract`) with two internal strategies:
/// (1) deterministic parse of Gutenberg-style title-page text, where it
/// works; (2) AFM fallback for everything else. Mark's call to keep it a
/// single clean interface rather than two services.
nonisolated struct ExtractedBibliographic: Sendable, Equatable {
    var authors: [String]
    var year: String?
    /// "deterministic" | "afm" | "hybrid" | "none" — diagnostics.
    var source: String

    var isEmpty: Bool { authors.isEmpty && (year ?? "").isEmpty }
}
// ========== BLOCK 01: RESULT TYPE - END ==========


// ========== BLOCK 02: GENERABLE PAYLOAD - START ==========
#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct BibliographicPayload: Sendable {
    @Guide(description: "List of the people who WROTE this work — the author(s). For a novel or book, the author of the WORK itself, NOT the author of any preface, introduction, or editorial apparatus (e.g. for a book 'by Jane Austen, with a Preface by George Saintsbury', the author is Jane Austen, NOT Saintsbury). NOT the publisher, editor, illustrator, or translator. Empty array only if no author is genuinely named in the opening.")
    let authors: [String]

    @Guide(description: "The year the WORK was originally published or written, as a 4-digit year string (e.g. '1851', '1813'). Prefer the original publication/copyright year of the work over a reprint/ebook release date. Empty string if no year is determinable from the opening text.")
    let year: String
}
#endif
// ========== BLOCK 02: GENERABLE PAYLOAD - END ==========


// ========== BLOCK 03: EXTRACTOR - START ==========
enum DocumentMetadataExtractor {

    /// Last failure diagnostic, surfaced via the local-API verb.
    nonisolated(unsafe) static var lastFailureReason: String = ""

    /// Import-time / backfill coordinator. Reads the document, extracts
    /// author + year, persists to the structured `metadata_*` columns via
    /// the (still-present) `saveDocumentMetadata` plumbing. Idempotent:
    /// skips documents already extracted unless `force`. Called from the
    /// central import hook (`UnitEmbeddingService.enqueueIndexing`), the
    /// `EXTRACT_METADATA` antenna verb, and a launch backfill.
    @MainActor
    static func extractAndStoreIfNeeded(documentID: UUID,
                                        databaseManager: DatabaseManager,
                                        force: Bool = false) async {
        if !force,
           let existing = try? databaseManager.documentMetadata(for: documentID),
           existing.extractedAt.timeIntervalSince1970 > 0,
           (!existing.authors.isEmpty || (existing.year ?? "").isEmpty == false) {
            return  // already have something; don't re-spend an AFM call
        }
        guard let plainText = try? databaseManager.plainText(for: documentID),
              !plainText.isEmpty else { return }
        let title = (try? databaseManager.documents())?
            .first(where: { $0.id == documentID })?.title

        guard let bib = await extract(plainText: plainText, knownTitle: title) else {
            dbgLog("DocMeta: nothing extracted for %@", documentID.uuidString as NSString)
            return
        }
        let stored = StoredDocumentMetadata(
            title: title,
            authors: bib.authors,
            year: bib.year,
            documentType: nil,
            summary: nil,
            extractedAt: Date(),
            detectedNonEnglish: false
        )
        do {
            try databaseManager.saveDocumentMetadata(stored, for: documentID)
            dbgLog("DocMeta stored: doc=%@ authors=[%@] year=%@ source=%@",
                   documentID.uuidString as NSString,
                   bib.authors.joined(separator: ", ") as NSString,
                   (bib.year ?? "—") as NSString, bib.source as NSString)
        } catch {
            dbgLog("DocMeta save failed: %@", "\(error)" as NSString)
        }
    }

    /// Single entry point. Tries deterministic title-page parsing first;
    /// fills any missing field via AFM. Returns `nil` only when BOTH
    /// strategies produced nothing (caller stores nothing; document still
    /// works without bibliographic metadata).
    @MainActor
    static func extract(plainText: String, knownTitle: String?) async -> ExtractedBibliographic? {
        let opening = String(plainText.prefix(3_000))

        // 1) Deterministic.
        var result = parseDeterministic(opening, knownTitle: knownTitle)

        // 2) AFM fallback — only when a field is still missing, so a clean
        //    Gutenberg header skips the model round-trip entirely.
        let needsAuthor = result.authors.isEmpty
        let needsYear = (result.year ?? "").isEmpty
        if needsAuthor || needsYear {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *),
               let afm = await extractViaAFM(plainText: plainText) {
                if needsAuthor && !afm.authors.isEmpty {
                    result.authors = afm.authors
                }
                if needsYear, let y = afm.year, !y.isEmpty {
                    result.year = y
                }
                result.source = result.source == "deterministic" ? "hybrid" : "afm"
            }
            #endif
        }

        if result.isEmpty { return nil }
        return result
    }

    // MARK: - Deterministic (Gutenberg / title-page)

    /// Parse the opening text for an explicit byline + year. Conservative:
    /// only returns fields it's confident about; leaves the rest empty for
    /// the AFM fallback. Pure / testable.
    nonisolated static func parseDeterministic(_ opening: String, knownTitle: String?) -> ExtractedBibliographic {
        var authors: [String] = []
        var year: String?

        // --- Author ---
        // (a) Explicit Gutenberg "Author:" header line.
        if let m = firstCapture(in: opening,
            pattern: #"(?im)^\s*Author:\s*(.+?)\s*$"#) {
            authors = splitAuthors(m)
        }
        // (b) A clean byline: "by <Name>" on a single line, NOT a
        //     "Preface by / Introduction by / Edited by / Translated by"
        //     attribution (those name the apparatus author, not the work's).
        //     Name words require an initial-cap-then-LOWERCASE shape
        //     ("Herman", "Melville") so ALL-CAPS headings that follow on
        //     the next line ("CONTENTS", "ETYMOLOGY") can't be swept in,
        //     and the word separator is HORIZONTAL whitespace only
        //     ([ \t], never a newline) so the byline can't cross into the
        //     table of contents.
        if authors.isEmpty,
           let m = firstCapture(in: opening,
            pattern: #"(?im)(?<!preface )(?<!introduction )(?<!edited )(?<!translated )(?<!foreword )\bby[ \t]+([A-Z][a-z][\p{L}.'’-]*(?:[ \t]+(?:[A-Z][a-z][\p{L}.'’-]*|[A-Z]\.))*)"#) {
            // Reject obvious false positives (sentence "by the …").
            let lowerFirst = m.split(separator: " ").first.map { $0.lowercased() } ?? ""
            let stop: Set<String> = ["the","a","an","this","that","his","her","their","which","whom","means","way","far","then","now","day"]
            if !stop.contains(lowerFirst) { authors = splitAuthors(m) }
        }

        // --- Year ---
        // Prefer original-publication / copyright phrasing over an ebook
        // release date.
        if let y = firstCapture(in: opening,
            pattern: #"(?i)(?:first published|originally published|first edition|copyright(?:\s*©)?|\(c\)|©)\s*(?:in\s+)?(\d{4})"#) {
            year = y
        } else if let y = firstCapture(in: opening,
            pattern: #"(?i)(?:release date|posting date|publication date)[^0-9]{0,40}(\d{4})"#) {
            year = y
        }

        let src = (authors.isEmpty && (year ?? "").isEmpty) ? "none" : "deterministic"
        return ExtractedBibliographic(authors: authors, year: year, source: src)
    }

    /// Split an author string on common separators, trim, drop empties +
    /// trailing punctuation.
    nonisolated static func splitAuthors(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;&")
        let parts = raw
            .replacingOccurrences(of: " and ", with: ",")
            .components(separatedBy: separators)
        return parts
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t.\u{2019}'")) }
            .filter { $0.count >= 2 && $0.rangeOfCharacter(from: .letters) != nil }
    }

    nonisolated static func firstCapture(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = re.firstMatch(in: text, range: range), match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        let captured = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        return captured.isEmpty ? nil : captured
    }

    // MARK: - AFM fallback

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    @MainActor
    static func extractViaAFM(plainText: String) async -> ExtractedBibliographic? {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            lastFailureReason = "AFM unavailable: \(model.availability)"
            return nil
        }
        // First ~1,500 chars — the byline/year live on the title page, and
        // a tighter window trips AFM's content-moderation refusals less
        // often than 4K did (prior service's hard-won lesson).
        let snippet = String(plainText.prefix(1_500))

        let instructions = """
        You extract bibliographic facts from the opening of a document for \
        a personal reading companion. Return only the author(s) of the WORK \
        and the year it was originally published. Never invent — when a \
        field isn't determinable, return an empty string (or empty array). \
        Do not summarize, characterize, or reproduce the content.
        """
        let prompt = """
        Below is the opening of a document. Identify the work's author(s) \
        and original publication year.

        ----- DOCUMENT OPENING -----
        \(snippet)
        ----- END DOCUMENT OPENING -----
        """
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let response = try await session.respond(to: prompt, generating: BibliographicPayload.self)
            let p = response.content
            let authors = p.authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 }
            let year = p.year.trimmingCharacters(in: .whitespacesAndNewlines)
            return ExtractedBibliographic(authors: authors,
                                          year: year.isEmpty ? nil : year,
                                          source: "afm")
        } catch {
            lastFailureReason = "AFM extract failed: \(error)"
            dbgLog("DocumentMetadataExtractor: %@", lastFailureReason as NSString)
            return nil
        }
    }
    #endif
}
// ========== BLOCK 03: EXTRACTOR - END ==========
