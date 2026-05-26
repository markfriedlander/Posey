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

    /// **Bundle 2d (2026-05-26)** — character offset in the derived
    /// plainText where the reader should auto-jump on first open
    /// (skip past Gutenberg preamble, in-prose TOC, etc.). Zero
    /// means no skip. Previously the persister always wrote 0 to
    /// the `playback_skip_until_offset` column even when the
    /// importer had computed a real value — meaning TXT Gutenberg
    /// docs opened at the license preamble. Now persisted faithfully.
    let playbackSkipUntilOffset: Int

    /// Character offset where the reader should treat the document
    /// as ended (Gutenberg license trailer). Zero means "play to
    /// the end." Same bug, same fix as the skip offset above.
    let contentEndOffset: Int

    /// The unit past which the reader should treat the document as
    /// ended (Gutenberg license trailer, etc.). `nil` means "play to
    /// the end."
    let contentEndUnitID: UUID?

    /// **Bundle 2b (2026-05-26)** — content-hash dedup. SHA-256 hex
    /// of the raw source-file bytes. Each library importer computes
    /// it from the bytes it loaded (URL or Data input). Nil for
    /// older importer paths that haven't been wired yet — persister
    /// stores NULL and the existingDocument query falls back to
    /// plainText comparison.
    let contentHash: String?

    /// **Bundle 2 follow-up (2026-05-26)** — edition-disambiguating
    /// label. Threaded from the importer to the persister so the
    /// library can surface "Illustrated by X" / "by Author" when
    /// two cards share a title. Nil when no metadata is available.
    let editionLabel: String?
}

// ========== BLOCK 01: PARSED DOCUMENT - END ==========
