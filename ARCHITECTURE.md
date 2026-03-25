# Posey Architecture

## Current Architectural Goal

Establish a low-drift foundation for Version 1 with proven end-to-end `TXT`, `MD`, `RTF`, `DOCX`, `HTML`, `EPUB`, and first-pass text-based `PDF` loops while keeping the remaining format work incremental.

The architecture should support later `PDF` hardening, richer non-text preservation, and eventual OCR work without forcing those concerns into the current reader, playback, and persistence loop too early.

## Recommended V1 Shape

Use a small set of app layers:

- `App`: app entry point and top-level dependency wiring
- `Features`: SwiftUI screens and feature coordinators
- `Domain`: plain models and protocols used across features
- `Services`: concrete ingestion, playback, and persistence services
- `Storage`: SQLite-backed repositories and database access

This is enough structure to prevent view logic from absorbing file parsing and persistence, without introducing premature modularization.

## Proposed Module Boundaries

### App

Responsibilities:

- launch app
- create shared services
- inject repositories and controllers into root features

Initial examples:

- `PoseyApp`
- `AppEnvironment`

### Library Feature

Responsibilities:

- import local `TXT` file for Block 01
- import local `MD` file with preserved visual structure
- import local `RTF` file through native text extraction
- import local `DOCX` file through a small zipped-XML extraction path
- import local `HTML` file through native HTML text extraction
- import local `EPUB` file through a small container + spine extraction path
- import local `PDF` file through `PDFKit` text extraction
- list imported documents
- route into reader view

Initial examples:

- `LibraryView`
- `LibraryViewModel`
- `DocumentImporter`

### Reader Feature

Responsibilities:

- render document text
- render preserved non-text content blocks for richer formats when available
- manage manual scroll position
- reflect current spoken sentence
- expose fading playback controls that stay out of the way while reading
- separate primary transport controls from lower-frequency reader preferences
- expose note and bookmark entry anchored to the active reading context
- pause playback at explicit visual stop blocks when the current format exposes them in the current V1 model

Initial examples:

- `ReaderView`
- `ReaderViewModel`
- `ReaderScrollCoordinator`

### Playback Service

Responsibilities:

- own `AVSpeechSynthesizer`
- speak text segments in order
- publish playback state
- track current sentence index
- support play, pause, resume, stop, and marker-based restart or stepping
- rely on Apple Spoken Content voice settings for the current playback voice path

Initial examples:

- `SpeechPlaybackService`
- `SpeechSession`

### Persistence Layer

Responsibilities:

- store document metadata
- store extracted text
- store reading position
- store notes and bookmarks

Initial examples:

- `DatabaseManager`
- `DocumentRepository`
- `ReadingPositionRepository`
- `NoteRepository`

## Data Flow

### Block 01 Flow

1. User imports a `TXT`, `MD`, `RTF`, `DOCX`, `HTML`, `EPUB`, or text-based `PDF` file.
2. A format-specific importer reads file contents and basic metadata.
3. `DocumentRepository` stores the document record, display text, and normalized plain text.
4. Library screen displays the imported document.
5. User opens the document in `ReaderView`.
6. `ReaderViewModel` loads full text and saved reading position.
7. User presses play.
8. `SpeechPlaybackService` receives precomputed sentence segments and starts speaking from the saved sentence index.
9. Playback callbacks update the current spoken sentence index.
10. Reader highlights the matching sentence and scrolls it into view if needed.
11. On pause, close, or backgrounding, `ReadingPositionRepository` stores the latest location.

### Richer Format Flow Extension

For `HTML`, `DOCX`, `EPUB`, and `PDF`, Posey should progressively move from text-only extraction toward mixed content blocks:

1. Preserve non-text elements such as images, charts, and tables as visual reader blocks when the source format exposes them reasonably.
2. Keep those blocks inline in reading order.
3. Pause playback when one of those blocks is reached.
4. Let the reader manually continue playback after they have digested the visual element.
5. Treat a later non-interrupting mode as an optional listening convenience, not the default.

Current practical V1 subset:

- `PDF` now preserves visual-only pages as explicit visual stop blocks
- those visual stop blocks stay inline in the reader and pause playback at the following sentence boundary
- arbitrary inline figures, tables, and charts inside mixed-content pages are still a later step

## Initial Data Model

### Document

Purpose:

- stable identity for imported content

Fields:

- `id: UUID`
- `title: String`
- `sourceURLBookmarkData: Data?`
- `fileName: String`
- `fileType: String`
- `importedAt: Date`
- `modifiedAt: Date`
- `displayText: String`
- `plainText: String`
- `characterCount: Int`

Notes:

- Store both display text and normalized plain text directly for V1 simplicity.
- `displayText` is what the reader renders.
- `plainText` is what playback, sentence segmentation, highlighting, notes, and restore logic anchor to.
- For `TXT`, `displayText` and `plainText` are the same.
- For `MD`, `displayText` preserves source structure and `plainText` strips markup for reading flow.
- For `RTF`, Posey currently stores the readable extracted string for both display and playback.
- For `DOCX`, Posey currently extracts readable paragraph text from `word/document.xml` and stores that same result for both display and playback.
- For `HTML`, Posey currently stores the readable extracted string for both display and playback.
- For `EPUB`, Posey currently stores the joined readable chapter text for both display and playback.
- For `PDF`, Posey currently stores form-feed-separated page text for display and normalized extracted page text for playback.

### ReadingPosition

Purpose:

- remember last place for both reading and playback

Fields:

- `documentID: UUID`
- `updatedAt: Date`
- `characterOffset: Int`
- `sentenceIndex: Int`
- `scrollAnchorHint: String?`

Notes:

- `characterOffset` is the primary cross-feature anchor.
- `sentenceIndex` improves playback resume for Block 01.
- `scrollAnchorHint` can remain unused initially if character offset proves sufficient.

### Note

Purpose:

- store user annotations and bookmarks

Fields:

- `id: UUID`
- `documentID: UUID`
- `createdAt: Date`
- `updatedAt: Date`
- `kind: String` (`note` or `bookmark`)
- `startOffset: Int`
- `endOffset: Int`
- `body: String?`

Notes:

- A bookmark is a zero-length or collapsed range with `kind = bookmark`.
- A text note stores a character range plus optional note body.
- In the current sentence-row reader, note capture is seeded from the active reading context.

## Persistence Recommendation

Choose `SQLite` for Version 1.

### Rationale

- The data model is small, relational, and stable.
- Version 1 needs predictable local persistence, not object graph tooling.
- Character offsets, notes, and per-document positions map naturally to simple tables.
- SQLite keeps storage explicit and easy to inspect during debugging.
- It avoids Core Data ceremony at a stage where speed and clarity matter more than framework leverage.

### Alternatives Considered

`Core Data`

- Pros: Apple-supported, integrates with SwiftUI, can scale with richer models.
- Cons: more setup and lifecycle overhead than this project needs right now, and less transparent for debugging simple text-anchor records.

Decision for now:

- Use raw SQLite with a small database manager and focused repositories.

## TTS Pipeline

### Block 01 Strategy

Use `AVSpeechSynthesizer` with sentence-level segmentation.

Pipeline:

1. Reader loads document plain text.
2. A text segmenter splits text into ordered sentence records.
3. Each sentence record stores:
   - index
   - text
   - start character offset
   - end character offset
4. When the user presses play, the playback service creates one `AVSpeechUtterance` per sentence from the active index onward.
5. Delegate callbacks advance the active sentence index.
6. The reader uses the active sentence offsets to highlight and scroll.

When the reader opens Notes:

1. Pause playback by default if it is currently running.
2. Seed note capture from explicit selection when available.
3. Otherwise seed note capture from the current highlighted sentence plus a short lookback window.

### Reader Control Layout

The reader control surface is intentionally split into two layers:

1. Primary chrome:
   - previous marker
   - play or pause
   - next marker
   - restart
   - Notes
2. Secondary preferences sheet:
   - font size
   - later listening and presentation options such as in-motion behavior

The primary chrome fades away after a short idle period and reappears when the reader taps the screen. It should stay glyph-first, visually restrained, and mostly monochrome so the document remains the main focus. Restart rewinds to the beginning without autoplaying, and real-world audio interruptions such as calls should leave playback paused until the reader resumes intentionally. Speech voice and speed are currently left to Apple Spoken Content behavior rather than Posey-owned in-app controls.

### Why Sentence-Level Segmentation

- It is simple and stable.
- It is good enough for the acceptance threshold.
- It avoids premature complexity around word timing.
- It aligns naturally with pause and resume behavior.

### Segmentation Approach

For Block 01:

- Use `NLTokenizer` or a similarly lightweight sentence boundary approach.
- Fall back to paragraph-based chunks if sentence detection produces poor results on malformed text.

## Highlighting Approach

### Block 01 Strategy

- Represent the document as one attributed text stream or a sentence-indexed render model.
- Maintain a single active sentence index.
- Highlight the active sentence with a visually distinct but restrained background treatment.
- Auto-scroll when the active sentence changes and moves outside the comfortable visible region.

### Acceptance Standard

- Highlighting must feel synchronized enough to follow along comfortably.
- Occasional drift within a sentence boundary is acceptable.

## Notes Capture Approach

### Current Strategy

- Allow native text selection in the reader.
- Use note capture as a reading aid, not a separate editor flow.
- Opening Notes should pause playback by default.
- The note draft should be seeded from the current reading context so the reader does not have to race moving text.
- In the current implementation, Posey captures the active sentence and one preceding sentence as a short lookback window when Notes opens.

## Markdown Rendering Approach

### Current Strategy

- Parse Markdown into lightweight display blocks.
- Preserve visual cues that materially help reading:
  - headings
  - paragraph breaks
  - bullets
  - numbered list markers
  - block quotes
- Normalize a separate plain-text reading stream for playback and sentence anchoring.

### Why This Shape

- It keeps the reader readable for serious documents without introducing a full rich-text renderer.
- It preserves the existing sentence-based playback and note architecture.
- It avoids widening the app into a generic document engine before `EPUB` or `PDF` work is justified.

## Position Persistence Approach

Persist at least on:

- pause
- document close
- app background
- periodic playback progress updates if implementation is cheap

Primary saved anchors for Block 01:

- `characterOffset`
- `sentenceIndex`

Resume logic:

- reopen document
- load saved `sentenceIndex`
- derive highlight from sentence list
- scroll to the sentence containing the saved offset

## Notes Persistence Approach

The current implementation keeps note-taking intentionally small and aligned with the existing sentence-row reader.

Approach:

- store note and bookmark records in the same `notes` table
- anchor them by character offsets into the stored plain text
- create notes and bookmarks from the active sentence rather than freeform text selection
- resolve note jumps by locating the sentence that contains the saved start offset

This keeps annotation storage compatible with future richer selection work while avoiding a larger text-selection system right now.

## Minimal Recommended Folder Structure

Recommended next structure inside the app target:

```text
Posey/
  App/
    PoseyApp.swift
    AppLaunchConfiguration.swift
  Features/
    Library/
      LibraryView.swift
    Reader/
      ReaderView.swift
  Domain/
    Models/
      Document.swift
      ReadingPosition.swift
      Note.swift
      DisplayBlock.swift
      TextSegment.swift
  Services/
    Import/
      TXTDocumentImporter.swift
      TXTLibraryImporter.swift
      MarkdownDocumentImporter.swift
      MarkdownLibraryImporter.swift
      MarkdownParser.swift
      RTFDocumentImporter.swift
      RTFLibraryImporter.swift
    Playback/
      SpeechPlaybackService.swift
      SentenceSegmenter.swift
    Storage/
      DatabaseManager.swift
```

This is a recommendation, not a mandate to create every file immediately.
Only create files as the current block demands.

## Testing Architecture

Posey now has a lightweight autonomous QA foundation for Block 01.

### Test Layers

- Unit tests for pure logic and storage behavior
- Integration-style tests for the reader view model and playback flow
- UI test scaffolding for the preloaded `TXT` reading loop
- direct device smoke validation for `TXT`, `MD`, and `RTF`

### Deterministic Test Fixtures

Shared fixtures live in `TestFixtures/`:

- short sample
- long dense sample
- malformed punctuation-heavy sample
- duplicate import sample
- structured Markdown sample
- malformed Markdown sample
- structured RTF sample

These fixtures are bundled into the test targets so the QA loop does not depend on external files.

### Testability Hooks

The app supports launch-time test configuration through environment variables and launch arguments.

Current hooks:

- test mode flag
- custom database path
- database reset on launch
- preload a `TXT` fixture on launch
- preload an `MD` fixture on launch
- preload an `RTF` fixture on launch
- simulated playback mode for UI automation

Operational run instructions live in `TESTING.md`, with a small command wrapper in `scripts/run-tests.sh`.

### Simulated Playback Mode

For normal app use, Posey uses `AVSpeechSynthesizer`.

For automated UI validation, the playback service can run in a deterministic simulated mode that:

- advances sentence indices on a timer
- exposes stable playback state transitions
- avoids dependence on real speech synthesis timing

This keeps UI automation focused on reader state changes rather than audio system behavior.

### Observable UI State

In test mode, the reader exposes stable accessibility-backed state for assertions:

- playback state
- current sentence index
- document title

The library also exposes stable document row identifiers and document count state.

The reader additionally exposes note count in test mode, and the notes sheet has stable identifiers for the current sentence preview, empty state, and saved rows.
