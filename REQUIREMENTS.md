# Posey Requirements

## Product Intent

Posey is a serious reader's tool for difficult books and documents.
Version 1 exists to help one person open a document, listen while reading, keep simple notes, and return later without losing place.

## Supported Platforms

- iOS latest
- iPadOS latest
- macOS latest

The implementation should favor shared SwiftUI code where practical, but not at the expense of clarity or stability.

## Version 1 Functional Requirements

### 1. Document Ingestion

Supported formats for Version 1 scope:

- `TXT`
- `MD`
- `RTF`
- `DOCX`
- `HTML`
- `EPUB`
- `PDF`

Required behavior:

- Import a supported local file into the app
- Create a stable local document record
- Extract readable text
- Preserve basic structure where reasonably available
- Persist enough metadata to reopen the document later

Version 1 implementation order:

- First milestone: `TXT` only
- `MD` comes next as the smallest formatting-aware extension
- `RTF`, `DOCX`, and `HTML` are planned as lighter-weight expansion blocks after `MD`
- `EPUB` is the first larger container-format block after the lighter steps
- `PDF` follows as a text-based first pass before richer handling or OCR

Out of scope:

- OCR correction
- layout-perfect reconstruction
- AI cleanup
- smart chapter inference

First PDF-pass constraint:

- support text-based PDFs only
- explicitly detect and message scanned or image-only PDFs as unsupported in this pass
- do not silently import empty PDF content

Roadmap-only candidate:

- `.webarchive` may be considered later if real usage justifies it, but it is not an active Version 1 implementation target

Future ingestion feature:

- Safari or share-sheet import via a Share Extension is a valuable later workflow, but it is not part of the current local-file implementation blocks

### 2. Reader View

Required behavior:

- Display document text in a scrollable reading view
- Support adjustable font size
- Support light and dark appearance
- Provide basic navigation sufficient for current block
- Preserve non-text elements visually for richer formats where reasonably available

For Block 01, "basic navigation" means:

- open imported document
- show current reading position
- allow scrolling manually
- return to saved position when reopened

### 3. Text-to-Speech Playback

Required behavior:

- Play
- Pause
- Resume
- Resume from saved reading position
- Provide basic previous or next marker navigation around the current reading position
- Pause automatically at preserved non-text elements in richer formats until the reader chooses to continue

Version 1 utility controls:


Reader chrome expectation:

- keep the primary playback controls lightweight
- use glyph-first playback controls instead of cramped text labels
- prefer a soft monochrome chrome so the document stays visually primary
- let the controls fade away while reading and reappear on tap
- give both the top and bottom controls enough soft separation from document text that they remain legible without feeling heavy
- keep lower-frequency preferences such as font size in a separate preferences surface
- allow a larger maximum font size than the default reading range for walking or other higher-motion reading contexts

Version 1 engine:

- `AVSpeechSynthesizer`

### 4. Read-Along Highlighting

Required behavior:

- Highlight the currently spoken sentence or paragraph
- Auto-scroll to keep spoken content visible
- Resume highlighting correctly after pause and app relaunch when feasible
- If the reader opens Notes while playback is active, pause playback by default

Acceptance threshold:

- Approximate sentence alignment is acceptable
- Perfect word-level sync is not required

### 5. Notes And Bookmarks

Required behavior:

- Highlight a user-selected text range
- Attach a note to the selected text
- Bookmark a position
- Allow text selection and copying from the reading view
- When the reader opens Notes, seed note capture from explicit text selection when available
- If there is no explicit selection, seed note capture from the current highlighted reading context, including a short lookback window

Each saved note or bookmark must store:

- document identifier
- text range or location anchor
- note text where applicable
- timestamp

Out of scope:

- sync
- export
- sharing

Later refinement, not required for the active block:

- an optional "do not pause for non-text elements" mode for listening-only contexts such as driving
- a future "in motion mode" setting group for walking or driving with different interruption and presentation behavior
- that future in-motion mode may bundle behaviors like not pausing at visual elements and enlarging presentation affordances while moving

### 6. Position Memory

Required behavior:

- Save last reading position per document
- Restore last position on reopen
- Keep reading and playback positions aligned closely enough for practical use

## Non-Functional Requirements

- Fast launch for existing library items
- Stable local behavior without a network connection
- Low-friction reading flow with minimal interruptions
- Clear failure behavior when a file cannot be parsed
- Small, understandable codebase

## Block 01 Requirements

Block 01 is complete only when a sample `TXT` file can:

- be imported
- appear in the local library
- open in the reader
- display plain text cleanly
- start speech playback
- highlight the current spoken sentence approximately
- pause and resume without losing place
- remember the last position after closing and reopening the app

## Explicit Version 1 Exclusions

- AI features of any kind
- server or cloud dependency for core flow
- multi-device sync
- search
- document export
- collaboration
- marketplace features
- analytics-heavy behavior
