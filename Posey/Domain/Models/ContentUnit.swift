import Foundation

// ========== BLOCK 01: CONTENT UNIT KIND - START ==========

/// The kind of content a `ContentUnit` represents. String-raw so it
/// can be stored as a SQL column without coupling on case-position;
/// new kinds can be added (with renderer + handler updates) without
/// schema changes.
///
/// Kind-specific data lives in `ContentUnit.metadata` (heading level,
/// list marker, page number, image data ref, etc.). Keeping kind as
/// a flat string means the database doesn't have to model the
/// associated-value surface.
enum ContentUnitKind: String, Equatable, Hashable, Sendable {
    /// A paragraph of body text. The dominant kind for almost every
    /// document. Carries text.
    case prose

    /// A section / chapter / subsection title. `metadata.headingLevel`
    /// is 1–6 (matching HTML `h1`–`h6`). Carries text.
    case heading

    /// A quoted passage (Markdown `>`, HTML `<blockquote>`, etc.).
    /// Carries text.
    case blockquote

    /// One item of a bulleted or numbered list. `metadata.listMarker`
    /// carries the rendered prefix (`"• "`, `"1. "`, etc.). Carries
    /// text — just the item body, marker is metadata.
    case listItem = "list_item"

    /// An inline image. `metadata.imageID` references the bytes in
    /// the side-store. `metadata.caption` if available. The unit's
    /// `text` field carries the caption (so it shows up in search /
    /// TOC / TTS if the user wants captions read).
    case image

    /// A page boundary in paginated formats (PDF; future paginated
    /// formats). `metadata.pageNumber` carries the page index this
    /// break sits between (the page that's *starting*). No text.
    /// The reader uses these to build a page map; TTS pauses at them
    /// if the user has pause-at-images enabled.
    case pageBreak = "page_break"

    /// A horizontal-rule separator (Markdown `---`, HTML `<hr>`).
    /// Renderer shows a thin centered line. No text. TTS passes
    /// silently.
    case horizontalRule = "horizontal_rule"

    /// True iff this kind carries prose-style text that TTS should
    /// read aloud and that contributes to search / RAG retrieval.
    var carriesProseText: Bool {
        switch self {
        case .prose, .heading, .blockquote, .listItem:
            return true
        case .image, .pageBreak, .horizontalRule:
            return false
        }
    }
}

// ========== BLOCK 01: CONTENT UNIT KIND - END ==========

// ========== BLOCK 02: CONTENT UNIT METADATA - START ==========

/// Kind-specific data carried alongside a `ContentUnit`. Stored as
/// JSON in the `document_units.metadata_json` column. All fields are
/// optional — readers should match the field they expect against
/// the unit's kind, not assume populated fields by default.
///
/// New fields can be added freely (additive JSON evolution); the
/// JSON decoder ignores unknown keys.
struct ContentUnitMetadata: Codable, Equatable, Hashable, Sendable {
    /// For `.heading`: the heading level, 1–6 (matching HTML
    /// `h1`–`h6`). 1 is most prominent (chapter / book title), 6 is
    /// the deepest subsection. Nil for non-heading kinds.
    var headingLevel: Int?

    /// For `.listItem`: the rendered marker prefix (`"• "`, `"1. "`,
    /// `"a. "`, etc.). Carried as the rendered string rather than a
    /// structured marker enum so the importer is the single source
    /// of marker decisions and the renderer is a passthrough.
    var listMarker: String?

    /// For `.image`: the id of the image in the side-store
    /// (`~/Library/Application Support/PoseyImages/<id>.{png|jpg}`).
    /// The renderer loads bytes by this id; if loading fails the
    /// renderer falls back to a placeholder.
    var imageID: String?

    /// For `.image`: an optional caption, if the source format
    /// provided one. May be empty even when the image has visible
    /// caption text in the source — fidelity depends on the importer.
    var caption: String?

    /// For `.pageBreak`: the 0-based page index of the page that's
    /// *starting* at this break. A document with N pages has N
    /// pageBreak units, one before each page's content.
    var pageNumber: Int?

    init(
        headingLevel: Int? = nil,
        listMarker: String? = nil,
        imageID: String? = nil,
        caption: String? = nil,
        pageNumber: Int? = nil
    ) {
        self.headingLevel = headingLevel
        self.listMarker = listMarker
        self.imageID = imageID
        self.caption = caption
        self.pageNumber = pageNumber
    }

    /// Empty metadata. Convenience for kinds that carry no
    /// kind-specific data.
    static let empty = ContentUnitMetadata()
}

// ========== BLOCK 02: CONTENT UNIT METADATA - END ==========

// ========== BLOCK 03: CONTENT UNIT - START ==========

/// The atomic unit of document content. The new single source of
/// truth — replaces the prior `plainText` + `displayText` +
/// `displayBlocks` triad. Every importer emits an ordered list of
/// content units; every consumer (visual reader, TTS engine, search,
/// Ask Posey RAG) derives its view from this list.
///
/// Ordering inside a document is by `sequence` (monotonically
/// increasing, but not necessarily contiguous — leaves room for
/// future in-place edits without renumbering every unit).
///
/// **Offset anchoring**: notes, reading positions, TOC entries, and
/// sentences all reference `(unit.id, intra_unit_character_offset)`.
/// There is no document-global character offset space anymore.
///
/// 2026-05-23 — introduced as part of the architecture rebuild. See
/// `docs-internal/architecture-rebuild-proposal.md`.
struct ContentUnit: Identifiable, Equatable, Hashable, Sendable {
    /// Stable identifier. Generated at unit creation, never
    /// reassigned. Other tables (notes, positions, TOC, sentences,
    /// embedding chunks) reference units by this id.
    let id: UUID

    /// Owning document.
    let documentID: UUID

    /// Position within the document. Lower sequences render / play
    /// first. Not necessarily contiguous (gaps are fine — leaves
    /// room for insertion between existing units without renumbering).
    let sequence: Int

    /// What kind of content this unit represents. Drives renderer
    /// switch, TTS inclusion, and search-result presentation.
    let kind: ContentUnitKind

    /// The unit's text. For prose-bearing kinds (prose, heading,
    /// blockquote, listItem) this is the body text. For images this
    /// is the caption (if any). For pageBreak / horizontalRule this
    /// is empty.
    let text: String

    /// Kind-specific data. See `ContentUnitMetadata` for the
    /// individual fields and which kinds use which.
    let metadata: ContentUnitMetadata

    /// Incremented every time the enhancement pipeline mutates this
    /// unit's text. New units land at revision 1. After a Tier 2 page
    /// swap or Tier 3 token correction, affected units get revision++.
    /// Used by the embedding chunker to detect what needs re-embedding.
    let revision: Int

    /// Which extraction tier produced the current version of this
    /// unit's text:
    ///   - `"importer"` — original importer output (TXT/MD/RTF/DOCX/
    ///                    HTML/EPUB importers, or PDF Tier 1 PDFKit)
    ///   - `"tier2_vision"` — replaced by Vision OCR on a flagged page
    ///   - `"tier3_afm"`    — text was edited by AFM fusion repair
    let sourceTier: String

    init(
        id: UUID = UUID(),
        documentID: UUID,
        sequence: Int,
        kind: ContentUnitKind,
        text: String,
        metadata: ContentUnitMetadata = .empty,
        revision: Int = 1,
        sourceTier: String = "importer"
    ) {
        self.id = id
        self.documentID = documentID
        self.sequence = sequence
        self.kind = kind
        self.text = text
        self.metadata = metadata
        self.revision = revision
        self.sourceTier = sourceTier
    }
}

// ========== BLOCK 03: CONTENT UNIT - END ==========

// ========== BLOCK 04: SENTENCE - START ==========

/// A sentence within a `ContentUnit`. Pre-computed at import time by
/// `SentenceIndexer` (runs `NLTokenizer` per unit) and persisted to
/// `document_sentences`. Replaces the prior runtime-computed
/// `TextSegment` array that `ReaderViewModel.computeContent` produced
/// on the open path.
///
/// Pre-computation means the reader's open path is sub-second even
/// on Moby-sized documents — no `NLTokenizer` pass at open. The
/// playback service consumes these directly.
///
/// **Anchoring**: each sentence sits inside exactly one content unit.
/// `intraStart` / `intraEnd` are character offsets within
/// `unit.text`. A "global" sentence index across the whole document
/// exists only as a render-time concept (the row index in the
/// playback queue); it's not stored.
struct Sentence: Identifiable, Equatable, Hashable, Sendable {
    /// Stable identifier. Not currently referenced by other tables;
    /// kept for symmetry and debuggability.
    let id: UUID

    /// Owning document. Denormalized for cheap per-document fetch.
    let documentID: UUID

    /// The content unit this sentence sits inside.
    let unitID: UUID

    /// The owning unit's sequence number. Denormalized so the
    /// playback queue can be built with one query, ordered by
    /// `(unitSequence, sentenceIndex)`.
    let unitSequence: Int

    /// 0-based index of this sentence within its unit. The first
    /// sentence of a unit is index 0.
    let sentenceIndex: Int

    /// Character offset within `unit.text` where this sentence
    /// starts (inclusive).
    let intraStart: Int

    /// Character offset within `unit.text` where this sentence
    /// ends (exclusive).
    let intraEnd: Int

    /// The sentence's text. Denormalized from `unit.text` for cheap
    /// playback enqueue without having to fetch the unit row too.
    let text: String

    init(
        id: UUID = UUID(),
        documentID: UUID,
        unitID: UUID,
        unitSequence: Int,
        sentenceIndex: Int,
        intraStart: Int,
        intraEnd: Int,
        text: String
    ) {
        self.id = id
        self.documentID = documentID
        self.unitID = unitID
        self.unitSequence = unitSequence
        self.sentenceIndex = sentenceIndex
        self.intraStart = intraStart
        self.intraEnd = intraEnd
        self.text = text
    }
}

// ========== BLOCK 04: SENTENCE - END ==========
