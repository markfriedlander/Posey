# Next

## Current Target

2026-04-30: Multi-step session reorienting after a context wipe and tackling Mark's autonomous task queue. Step 6 (remove "Page N" chrome from PDF reader display) is done and live on device. Coming up next: Steps 4+5 (position persistence + active-sentence centering), then Step 8 (UI widget audit via simulator + accessibility tree), then Step 7 (research scanned-PDF visual significance detection), then Steps 2+3 (synthetic test corpus + Gutendex downloader).

**Open user-reported issues to verify or fix:**
- ~~Position persistence~~ — **Done** (2026-04-30). `PlaybackPreferences.lastOpenedDocumentID` restores the navigation state at cold launch.
- ~~Scroll-restore on appear~~ — **Done** (2026-04-30, accepted). Initial scroll deferred past the first layout pass.
- ~~Pause latency~~ — **Done** (2026-04-30, accepted). `.word` → `.immediate`; segmenter cap 600 → 250.
- ~~Highlight + scroll centering~~ — **Done** (2026-05-01, portrait accepted; landscape pending). Both chromes are overlays again; only the search bar uses `.safeAreaInset(.top)` (interactive input must displace content). Scroll content area equals the persistent perceived reading area (nav-bar bottom → home-indicator top), so centering math is correct across orientations and chrome states. Portrait off by +3 px, landscape off by +5.5 px (both within visual tolerance, both consistent direction). Test-only `POSEY_FORCE_ORIENTATION` env var added so the simulator MCP can drive orientation without a runtime rotation API.

**Open UI bugs found during Step 5 work (queue for Step 8):**
- Tap-to-reveal-chrome doesn't fire reliably from inside the ScrollView. `.contentShape(Rectangle()).onTapGesture` on the ScrollView is consumed by the children's `.textSelection(.enabled)` gesture recognizers. Need either: a clearer tap target outside text rows, a different gesture priority, or an alternate reveal trigger (long-press, two-finger tap).

**Open architecture decision (deferred until research lands):**
- Scanned-PDF visual significance detection — character count and bounding-box coverage have already been ruled out for the Antifa cover case. Step 7 is research-first; report findings and align before any code.

**Accessibility compliance (target: complete before App Store submission):**
- VoiceOver labels on all custom controls (play, pause, antenna, restart, search, notes, preferences, TOC, etc.).
- Navigation order audit so VoiceOver follows the natural reading and interaction flow.
- Touch target verification — all interactive elements meet Apple's 44×44 pt minimum.
- Dynamic Type support — text scales with system accessibility settings.
- Reduce Motion support — chrome fade and scroll animations suppressed when the system setting is on.
- Color contrast audit (the monochromatic palette already helps; verify the `Color.primary.opacity(0.14)` highlight tier is sufficient).
- Step 8 UI audit is the natural starting point — extend it to cover accessibility alongside widget behavior.

**Future reader UX modes (not active work, captured before they get lost):**
- **Dim surrounding text.** Instead of only highlighting the active sentence, reduce the opacity of every non-active sentence to ~40–50% so the eye is naturally drawn to the brightest element. Functionally additive — keep the existing highlight tier — and likely belongs as a user-selectable reading mode rather than the default.
- **Slot machine / drum roll scroll.** Active sentence centered at full size and brightness; sentences above and below fade out and scale down slightly as they move away from center, creating a smooth rolling transition as playback advances. Higher implementation cost (custom layout + per-row transform driven by distance-from-center), so worth prototyping after the basic centering fix lands and proves stable. Also a user-selectable reading mode, not the default.

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
10. PDF ingestion current state:
   - text-based PDFs: working
   - OCR for scanned PDFs: **Done.**
   - visual-only pages: detected, rendered as PNG at 2× via `PDFPage.thumbnail`, stored as BLOBs in SQLite, displayed inline with tap-to-expand zoom sheet
   - spaced-letter artifacts (`C O N T E N T S`): **Fixed** at normalization.
   - spaced-digit artifacts (`1 9 4 5`): **Fixed** at normalization (`collapseSpacedDigits`).
   - line-break hyphen artifacts (`fas- cism`): **Fixed** at normalization.
   - Unicode soft-hyphen (`\u{00AD}`): **Fixed** — stripped in PDF, HTML, EPUB, TXT, RTF, DOCX.
   - Accented characters (`Á`): **Fixed** — `collapseSpacedLetters` now uses `\p{Lu}`/`\p{Ll}` Unicode property escapes.
   - `¬` (U+00AC) as line-break hyphen: **Fixed** — caught by `collapseLineBreakHyphens`.
   - Cross-page-boundary hyphens: **Fixed** — second normalization pass after page join.
   - Residual: `WORD - WORD` (space-hyphen-space) artifact — rare, deferred.
   - PDF/EPUB block segmentation (Phase B): **Done.** `splitParagraphBlocks()` in `ReaderViewModel` splits each paragraph DisplayBlock into per-TTS-segment rows — highlight and scroll target exactly what is being spoken.
   - OCR confidence gating: **Done.** Pages with average Vision confidence < 0.75 become visual stops rather than text.
   - OCR minimum text threshold: **Done.** Pages with < 10 OCR chars become visual stops.
   - Mixed-content PDF pages (text + inline image): **Done and verified.** `pageHasImageXObjects()` checks CGPDFPage resource dictionary; pages with both text and image XObjects now emit both a text block and a visual stop. Verified with GEB page 14: text preserved in displayText on both sides of the visual stop marker; stored image shows full page with figure and text.
   - General filename sanitization: **Done and verified.** `LibraryViewModel.sanitizeFilename()` handles null bytes, control chars, path separators, macOS-reserved chars, path traversal, duplicate extensions, length limit. Verified via live API tests with 7 bad-filename cases — all sanitized correctly.
   - Image verification tooling: **Done and verified.** `tools/verify_images.py` renders reference pages via macOS PDFKit, fetches stored PNG from device, and compares with Swift pixel comparator (CoreGraphics RGBA MAE). All 11 Antifa visual stops are genuinely blank pages (section dividers) — stored images correctly represent them. **Open UX issue:** blank pages are not worth pausing playback for. A minimum visual-content threshold for visual stops (analogous to the OCR 10-char threshold) should be added to suppress these.
11. Next up (in rough priority order):
   - Text-quality audit: **Pass 3 complete.** 20-file corpus. See `tools/audit_report.json`.
   - PDF TOC detection/navigation: detect TOC pages at import, offer skip/navigate surface.
   - EPUB TOC navigation surface: **Done and verified.** NCX (EPUB 2) and nav document (EPUB 3) both parsed; Contents sheet with jump-to-chapter. 38 unique entries verified for Data Smog on fresh import (0 duplicates). Chapter offsets verified against plainText content — all correct. **Minor: TOCSheet uses `id: \.playOrder` which could be non-unique; a composite id would be safer.**
   - inline images for DOCX/HTML: EPUB and PDF done; DOCX and HTML remain
   - Ask Posey: Apple Foundation Models integration (on-device, offline)
   - document deletion: **Done.**
   - font size persistence: **Done.**
   - monochromatic palette: **Done** as standing standard.
   - local API server: **Done.** (`tools/posey_test.py`, antenna icon, NWListener on port 8765)
   - richer inline non-text preservation beyond visual-only page stops (figures, tables, charts in EPUB/DOCX/HTML)
   - OCR for scanned PDFs: **Done.**
   - in-document search tier 1: **Done.**
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

- Implemented for text-based and scanned PDFs.
- Accepts `.pdf`.
- Uses `PDFKit` to extract readable page text. Falls back to Vision OCR for pages with no extracted text. Purely visual pages (nothing from either path) are rendered as PNG images via `PDFPage.thumbnail(of:for:)` at 2× scale and stored as BLOBs in `document_images`.
- Normalizes wrapped lines into readable sentence text for playback, notes, and restore.
- Collapses glyph-positioning artifacts (`C O N T E N T S` → `CONTENTS`) and line-break hyphens (`fas- cism` → `fascism`) at import time.
- Preserves lightweight page headers and paragraph blocks in the reader.
- Visual-only pages render inline as actual images with tap-to-expand full-screen zoom (ZoomableImageView, pinch-to-zoom, double-tap).
- Playback pauses at visual page boundaries by default.
- Rejects documents where every page fails both PDFKit and OCR with a clear error.
- **Known open issue:** typeset PDFs often produce large text chunks that NLTokenizer cannot split, resulting in highlight blocks spanning a full screen. Needs architectural fix — see priority list.

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

- Three tiers planned.
- Tier 1: **Implemented.** String match find bar, jumps between matches with wrap-around, highlights matches in the sentence-row reader. Works across both plain-segment and displayBlocks rendering modes.
- Tier 2 (roadmap): same surface, extends scope to include note bodies.
- Tier 3 (later): semantic search via Ask Posey — natural language queries without exact word match.

### OCR for Scanned PDFs

- **Implemented.** Vision OCR fallback added to the PDF import pipeline.
- PDFKit text extraction is tried first; Vision OCR runs on any page that yields no text; visual placeholder used only if OCR also finds nothing.
- Uses Apple Vision (VNRecognizeTextRequest, accurate level) — on-device, no dependencies.
- No changes to reader, playback, or persistence layers.

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
