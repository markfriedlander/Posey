import Foundation

// ========== BLOCK 01: PARSED DOCUMENT - START ==========

/// The output of an importer in the unit-based architecture. The
/// importer reads a source file and emits this value; the persistence
/// layer writes the header, units, sentences, and skip references in
/// one transaction.
///
/// 2026-05-23 — introduced as part of the architecture rebuild.
struct ParsedDocument: Sendable {
    /// The new document's id. The importer generates this so unit /
    /// sentence rows can reference it before the header is inserted.
    let id: UUID

    /// User-facing title. Derived per format (PDF metadata, EPUB OPF,
    /// MD H1, filename for plain TXT, etc.).
    let title: String

    /// Original filename including extension. Used for duplicate
    /// detection and display.
    let fileName: String

    /// Lowercase extension: "txt" / "md" / "rtf" / "docx" / "html" /
    /// "epub" / "pdf".
    let fileType: String

    /// The ordered content units that make up the document.
    let units: [ContentUnit]

    /// Pre-computed sentences across all prose-bearing units. The
    /// importer runs `SentenceIndexer.sentences(for: units)` and
    /// includes the result here so persistence is a single
    /// transaction.
    let sentences: [Sentence]

    /// Optional TOC entries. Many formats have none (plain TXT,
    /// short MD); EPUB / PDF typically do.
    let toc: [StoredTOCEntry]

    /// The unit the reader should open at, if smart-skip detection
    /// fired. `nil` means "open at the first unit." Set when
    /// importer detected Gutenberg preamble, in-prose TOC,
    /// publisher front matter, etc.
    let skipUnitID: UUID?

    /// Classification of how the skip target was determined. Drives
    /// the smart-skip prompt UI:
    ///   • `""`          — no skip detected
    ///   • `"gutenberg"` — authoritative; silent skip
    ///   • `"heuristic"` — prompt the user once
    let skipSource: String

    /// The unit past which the reader should treat the document as
    /// ended (Gutenberg license trailer, etc.). `nil` means "play to
    /// the end."
    let contentEndUnitID: UUID?
}

// ========== BLOCK 01: PARSED DOCUMENT - END ==========
