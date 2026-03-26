# Next

## Current Target

Use the now-working real-device loop to keep `TXT`, `MD`, `RTF`, `DOCX`, `HTML`, `EPUB`, and first-pass text-based `PDF` stable on hardware, then decide whether the next highest-value step is deeper rich-content preservation or the next listening-comfort follow-through after the new playback-controls pass.

## Priority Order

1. Keep `scripts/run-device-tests.sh` for real-device unit tests and `scripts/run-device-smoke.sh` for direct app smoke validation on the connected iPhone.
2. Treat the direct smoke harness as the primary hardware-validation path unless Parker becomes reliable enough to justify more time.
3. Keep the manual notes validation outcome recorded and rerun it only when reader or note behavior materially changes.
4. Keep the richer-format rule explicit: non-text elements stay visible, pause playback by default, and are revisited later under a user-facing in-motion mode setting group for walking or driving.
5. Fix any runtime or automation issues discovered during hardware validation before expanding scope.
6. Keep new changes inside the existing test harness so routine regressions are caught automatically.
7. Keep `TESTING.md` current when hooks, fixtures, or target run commands change.
8. Keep the current `MD`, `RTF`, `DOCX`, `HTML`, `EPUB`, and text-based `PDF` loops stable on hardware as the baseline for new format work.
9. Keep the new reader-controls split stable on hardware:
   - top-level chrome fades away to keep focus on the text
   - primary controls stay limited to previous, play or pause, next, restart, and Notes
   - preferences such as font size stay in the separate sheet
10. Harden the current PDF slice before broadening scope:
   - keep scanned or image-only PDFs explicit with clear unsupported messaging
   - avoid silent empty imports
   - preserve lightweight page structure in the reader
   - preserve visual-only pages as explicit visual stop blocks
   - pause playback at those visual stop boundaries by default
   - do not add OCR yet
11. Reassess the next step after the current PDF slice settles:
   - richer inline non-text preservation beyond visual-only page stops
   - playback-settings investigation: voice quality tiers and rate control (see AVSpeech research note)
   - revisit the playback-engine tradeoff between high-quality Spoken Content voices and live mid-playback speech-rate changes
   - OCR for scanned PDFs via Apple Vision framework (VNRecognizeTextRequest — on-device, no dependencies, extends the existing PDF import pipeline without touching the reader or persistence model)
   - Safari/share-sheet import only after the local format blocks are stable enough to justify extension work
12. Keep `.webarchive` on the roadmap only; do not begin it without a concrete need.
13. Keep Safari or share-sheet import on the future roadmap only; do not begin app-extension work until the local file-ingestion blocks are stable.
14. Keep a future in-motion mode on the roadmap so listening behavior can be tuned without losing the reader-first defaults.

## Current Implementation Notes

### TXT Ingestion

- Implemented.
- Uses the system file importer.
- Accepts plain text files only.
- Reads UTF-8 first and falls back to several common text encodings.
- Saves document metadata plus normalized plain text in SQLite.
- Re-importing identical content updates the existing document entry.

### Markdown Ingestion

- Implemented.
- Accepts `.md` and `.markdown`.
- Preserves lightweight display structure while also storing normalized plain text.
- Keeps playback, highlighting, notes, and position restore on the normalized text stream.

### RTF Ingestion

- Implemented.
- Accepts `.rtf`.
- Uses native document reading to extract readable text.
- Keeps the current reader, playback, highlighting, notes, and position model unchanged.

### DOCX Ingestion

- Implemented.
- Accepts `.docx`.
- Reads the zip container directly and extracts readable paragraph text from `word/document.xml`.
- Keeps the current reader, playback, highlighting, notes, and position model unchanged.

### HTML Ingestion

- Implemented.
- Accepts `.html` and `.htm`.
- Uses native document reading to extract readable text.
- Keeps the current reader, playback, highlighting, notes, and position model unchanged.

### EPUB Ingestion

- Implemented.
- Accepts `.epub`.
- Reads the container manifest and spine, then extracts readable XHTML chapter text through the current HTML text path.
- Keeps the current reader, playback, highlighting, notes, and position model unchanged.

### PDF Ingestion

- Implemented for text-based PDFs.
- Accepts `.pdf`.
- Uses `PDFKit` to extract readable page text into the current reader flow.
- Normalizes wrapped lines into readable sentence text for playback, notes, and restore.
- Preserves lightweight page headers and paragraph blocks in the reader while keeping playback on normalized plain text.
- Rejects scanned or image-only PDFs with an explicit unsupported-for-now error instead of silently importing empty content.

### Planned Next Format Blocks

- `.webarchive`: optional later candidate only
- Safari/share-sheet import: future convenience workflow, likely through a Share Extension after the core local-reader path is stable
- richer non-text handling: preserve visual elements inline and pause playback at them by default in the richer formats
- in-motion mode: future user setting group for walking or driving with different interruption and presentation behavior, including choices like not pausing at visual elements and larger presentation affordances

### Ask Posey — On-Device AI Reading Assistance

- Planned V1 feature. Uses Apple Foundation Models (on-device, offline only).
- Three patterns: selection-scoped queries (from text selection menu), document-scoped queries (dedicated glyph, far left of bottom reader bar), annotation-scoped queries (from Notes surface).
- Session model for pattern 3 is transient — local message array while sheet is open, save to note or discard on close.
- Full modal sheet surface. Active sentence or selection quoted at top.
- No network requests. No third-party AI services.
- Not started yet. Comes after the core format and playback blocks are stable.

### In-Document Search

- Planned in three tiers.
- Tier 1 (near-term): string match find bar, jumps between matches, highlights in the sentence-row reader.
- Tier 2 (roadmap): same surface, extends scope to include note bodies.
- Tier 3 (later): semantic search via Ask Posey — natural language queries without exact word match.
- Only tier 1 is near-term implementation work.

### OCR for Scanned PDFs

- Planned near-term extension to the PDF import pipeline.
- Uses Apple Vision framework (VNRecognizeTextRequest) — on-device, no dependencies.
- Does not require changes to the reader, playback, or persistence model.
- Current behavior (explicit rejection of scanned PDFs with a clear error) stays until this pass begins.

### Reader Screen

- Implemented.
- Opens one document at a time.
- Uses fading chrome so the text can reclaim more of the screen during reading.
- Includes previous-marker, play or pause, next-marker, restart, and Notes controls in the primary reader bar.
- Keeps the primary reader chrome glyph-first and visually restrained so the document remains dominant.
- Gives the transport controls enough horizontal separation that accidental taps are less likely while walking or reading one-handed.
- Uses soft material separation for both the top and bottom chrome so controls stay readable over long passages without returning to heavy button halos.
- Keeps font size in a separate preferences sheet instead of the primary reader bar.
- Renders sentence rows for simple highlight targeting and auto-scroll.
- Renders lightweight display blocks for Markdown headings, lists, quotes, and PDF page/paragraph structure.
- Treats visual-only PDF pages as explicit visual stop blocks in the current reader model.
- Opening Notes pauses playback and seeds the draft from the active reading context.

### TTS Playback

- Implemented.
- Uses one playback service per reader session.
- Maintains `idle`, `playing`, `paused`, and `finished` states.
- Resumes from the saved sentence index.
- Rewinds to the beginning without autoplay when restart is tapped.
- Pauses at preserved PDF visual-stop blocks by default in the current richer-format pass.
- Uses a 50-segment sliding window — utterances are enqueued one-for-one as each finishes rather than pre-enqueuing the full document tail.
- Supports two voice modes, persisted in UserDefaults across sessions:
  - **Best Available**: `prefersAssistiveTechnologySettings = true`, Siri-tier voice quality, utterance.rate not set so the system Spoken Content rate slider applies. This is the default.
  - **Custom**: user-selected voice from `AVSpeechSynthesisVoice.speechVoices()`, in-app rate slider 75–150%, `prefersAssistiveTechnologySettings = false`. Lower voice quality than Best Available, but fully user-controlled.
- Mode or rate changes take effect at the next sentence boundary (stop + re-enqueue from current index).
- Voice picker groups by language then quality tier; device locale shown first by default.

### Highlighting

- Implemented.
- Segments by sentence with a paragraph fallback.
- Tracks character offsets per segment.
- Highlights one active sentence at a time.
- Auto-scrolls to the active sentence on appear and sentence changes.

### Position Memory

- Implemented.
- Saves sentence index and character offset.
- Restores the saved sentence on reopen.
- Resolves the initial sentence from saved character offset first, then falls back to sentence index.
- Persists on sentence changes, pause, disappear, and app lifecycle changes.

## Guardrails For The Next Pass

- Do not start Safari/share-sheet import yet.
- Do not widen `PDF` work into OCR or full document-layout reconstruction in the current pass (OCR is planned near-term as its own pass).
- Do not widen reader chrome back into text-heavy or visually dominant controls.
- Do not widen note-taking into arbitrary text selection, editing, deletion, or export yet.
- Do not attempt live mid-utterance speech-rate changes; the current architecture applies rate changes at the next sentence boundary (stop + re-enqueue), which is sufficient and honest.
- Do not add sync, export, or network-dependent AI behavior. (Ask Posey via Apple Foundation Models is a planned V1 feature and is in-scope; in-document search tier 1 is near-term.)
- Do not widen the architecture before a real runtime bug forces it.
- Do not add broad test abstractions unless the current QA loop becomes too repetitive to maintain.
