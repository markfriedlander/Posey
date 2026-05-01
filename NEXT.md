# Next

## Current Target

**2026-05-01:** All of Mark's earlier autonomous queue is done and on device. Today's session also shipped: NavigationStack double-push fix (alert collision + `.task` re-fire guard), TOC hide-from-reader (segments + displayBlocks filtered at view-model init so the skip region is invisible by construction), shared `TextNormalizer` bringing TXT/MD parity with PDF, format-parity standing policy in CLAUDE.md, antenna default ON for dev, PDF TOC detection at import + auto-skip + entry parsing, simulator MCP setup with idb patch for Python 3.14, push-to-origin policy made explicit in CLAUDE.md, AFM availability verified on device + simulator, Hal blocks read and digested, implementation plan reviewed and approved by Mark with answers to 8 open questions, **Ask Posey Milestone 1 complete on device**.

**Ask Posey is in flight.** Plan: `ask_posey_implementation_plan.md` (approved 2026-05-01). Spec: `ask_posey_spec.md`. Architecture: `ARCHITECTURE.md` "Ask Posey Architecture" (rewritten in Milestone 1 to match the spec). Constitutional commitments: `CONSTITUTION.md` "Ask Posey" (rewritten in Milestone 1).

**Milestone status:**

- **Milestone 1 — Doc alignment + schema migration: DONE (2026-05-01).** ARCHITECTURE.md / CONSTITUTION.md rewritten to the spec; `ask_posey_conversations` and `document_chunks` tables migrated in via `addColumnIfNeeded`-style discipline; `idx_ask_posey_doc_ts` and `idx_document_chunks_doc` created; `ON DELETE CASCADE` verified by integration test; `AskPoseyAvailability` skeleton wraps `SystemLanguageModel.default.availability`; full PoseyTests suite passes on device with the new tests included.
- **Milestone 2 — Document embedding index: DONE (2026-05-01).** Service + DB helpers + hooks (`1ba5ea1`). Three follow-on fixes verified after the token-limit reset (commit pending — see latest): (a) `StoredDocumentChunk: Equatable`; (b) `nonisolated` on `DocumentEmbeddingIndex`, its public types, and `DocumentEmbeddingIndexConfiguration` — confirmed `nonisolated struct/enum` compiles fine in Swift 5 + approachable-concurrency. The MainActor-deinit-on-non-main-thread crash that surfaced during the first test run is gone (synthesised deinit no longer hops via `swift_task_deinitOnExecutorImpl`); (c) `tryIndex(_:)` helper on `DocumentEmbeddingIndex` so importer call sites are `embeddingIndex?.tryIndex(document)` — clean (no unused-`try?` warnings) and adds an NSLog breadcrumb on indexing failure so consistent failures don't go silent. All three M2 test suites green on simulator. Device regression pending Mark's go-ahead (per the no-surprise-device-install rule).
  - **Open follow-up:** retro-indexing of pre-existing imports needs to happen on first Ask Posey invocation — the index call is in place but the "Indexing..." UI state belongs in the sheet milestone (4).
- **Milestone 3 — Two-call intent classifier: NEXT.** AskPoseyService minimal session lifecycle + `@Generable` `AskPoseyIntent` enum. Unit tests for the classifier; manual on-device probe.
- **Milestone 4 — Modal sheet UI shell:** AskPoseyView with anchor + composer, no AFM yet (echo back the question). Validate the half-sheet design risk on device with real documents before locking it in.
- **Milestone 5 — Prose response loop:** Wire intent → prompt builder → AFM `streamResponse` → bubble updates; passage-scoped invocation only.
- **Milestone 6 — Document-scoped + RAG:** Bottom-bar glyph; `.general` intent; RAG retrieval + rolling summary support.
- **Milestone 7 — Navigation pattern + auto-save:** `.search` intent → Generable navigation cards → existing TOC jump infrastructure; auto-save to notes.
- **Milestone 8 — Source attribution + indexing indicator (UI):** Track which RAG chunks contributed to each Ask Posey response and render a "Sources" strip under the assistant message — pills tap-jump to the cited offset via the existing infrastructure. Also wire the first-time "Indexing this document…" → "Indexed N sections." indicator into the sheet (the index work itself ships earlier; this is the UX surface for it). Both are spec'd in `ask_posey_spec.md` (sections "Source Attribution" and the indexing-indicator paragraph under "The Ask Posey Sheet UI"). Persistence: chunk references stored on the assistant turn in `ask_posey_conversations` so attribution survives across sessions.

**Ask Posey v2 candidates (after the v1 milestones land and we have real-use feedback):**

- **Entity-aware multi-factor relevance scoring.** Pure cosine is the v1 ranking in `DocumentEmbeddingIndex`. Mentat's pattern — semantic similarity + entity-match bonus + context relevance, with a 2× multiplier when a query entity matches a chunk entity — is a strong v2 candidate. Most of the parts already exist (NLTagger for entity extraction, chunk text in `document_chunks`, query string at search time). A v2 implementation would extract entities at index time alongside the embedding, persist them, and score `cosine + entity_overlap × 2× factor` (clamped) at query time. See `ask_posey_implementation_plan.md` §7.3 for the design sketch. **Decision criterion for promoting from v2 → v1.x:** real-use complaints where pure-cosine retrieval misses obvious entity matches.

**Audio export — planned post-Ask-Posey feature:**

Mark wants the option to export a document as an M4A audio file rendered via Posey's existing TTS pipeline, saveable to Files and shareable through the iOS share sheet. Someone without Posey could then listen in any audio player.

- **Mechanism:** `AVSpeechSynthesizer.write(_:toBufferCallback:)` writes synthesized audio to a buffer caller-by-caller, which we'd accumulate into an AAC-encoded `.m4a` file. The same `SpeechPlaybackService` that drives in-app playback already produces the segment-level utterances we'd feed in.
- **Important caveat to investigate before any code lands:** Best Available (Siri-tier) voices may NOT be capturable via `write(_:toBufferCallback:)` because Apple gates premium / accessibility-channel voices from third-party audio capture. Custom voices (the user-selectable list from `AVSpeechSynthesisVoice.speechVoices()`) almost certainly are capturable. Concretely: before designing the UI, run a test that calls `write(_:toBufferCallback:)` on a known Siri-tier voice utterance and check whether the buffer callback ever fires. If it doesn't, the audio-export surface is "Custom voice mode only" and the export button is disabled (or the voice picker is overlaid) when the user is in Best Available mode.
- **UX:** progress indicator while rendering (long documents take real time to synthesize); "Save to Files" + share-sheet entry point on completion.
- **Out of scope for v1, do not begin implementation until Ask Posey ships and we've verified the Best Available capturability question.**

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

**TXT/MD normalization gaps — DONE (2026-05-01):** TextNormalizer extracted, TXT and Markdown both delegate to it, verifier 47/47 green. PDFDocumentImporter still has its own proven `normalize()` — migrating it to the shared utility is a future cleanup deferred until corpus tests can catch any divergence.

**Format-parity follow-ups (per the standing policy in CLAUDE.md):**

- **PDF TOC hide-and-skip works for PDFs only.** EPUB has TOCs but they live in NCX or nav-document XHTML — not in dot-leader form. The current `PDFTOCDetector` heuristic (anchor + dot-leader density) won't fire on EPUB. EPUB TOCs are already parsed into `document_toc` for navigation; what's missing is `playback_skip_until_offset` derived from the EPUB's TOC structure (likely: skip everything before the first chapter's offset). Worth doing as a deliberate pass — the principle is "no format reads its TOC aloud."
- **DOCX may also have a TOC.** Word files typically use a TOC field (`{ TOC \\o }`) which produces a styled TOC region with hyperlinks and page numbers. We don't parse Word TOC fields today. Lower priority; treat as discovery work when a real DOCX with this surfaces.
- **`PDFDocumentImporter` still has its own `normalize()` separate from the shared `TextNormalizer`.** Migrating it to delegate is a future cleanup that risks behavior drift; deferred until corpus tests can catch divergence.

**Future polish — landscape rotation re-centering:**
- After rotating between portrait and landscape, the highlighted sentence is briefly off-center until the next sentence advance, when it re-centers correctly. Mark accepted "good enough for now" — fix is to listen for orientation changes (or geometry changes) and re-fire `scrollToCurrentSentence` once layout has settled. Likely a small `.onChange(of: geometry.size)` or `UIDevice.orientationDidChangeNotification` hook in ReaderView. Low priority compared to other reader polish items.

**Next major feature — Ask Posey (designed; not started):**

The most significant remaining V1 feature. **Fully designed and documented** — the Ask Posey sections in `ARCHITECTURE.md`, `CONSTITUTION.md`, and earlier in this file specify the contract; nothing here needs reinvention. Before writing code:

1. Re-read those three sections.
2. Confirm Apple Foundation Models is available and working in the simulator and on device.
3. Read Hal's context-management / RAG code for handling documents that exceed the model's context window — proven architecture exists; do not invent it from scratch. Mark can point to the right files when starting.
4. **Discuss the implementation plan with Mark before writing any code.** This is consequential — three interaction patterns, Apple Foundation Models on-device, transient session model, full modal sheet, AI-generated content always clearly labeled. Plan first.

Three interaction patterns:
- **Selection-scoped** — user selects text, contextual menu offers "Ask Posey", modal sheet opens with the selection quoted at top.
- **Document-scoped** — dedicated glyph far-left of the bottom transport bar, modal sheet opens with the current sentence quoted at top, full document used as context.
- **Annotation-scoped** — accessible from the Notes surface.

Constraints (from CONSTITUTION.md / ARCHITECTURE.md):
- Apple Foundation Models only. Fully on-device. Offline. **No network requests, ever.**
- Full modal sheet for all three patterns.
- Transient session: conversation lives while the sheet is open; user saves to notes or discards on close.
- AI-generated content is always clearly labeled. Never presented as if it were the source document.

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
   - PDF TOC detection/navigation: **Done** (2026-05-01). `PDFTOCDetector` flags the TOC region at import (anchor phrase + ≥5 dot-leader entries, first 5 pages only); reader auto-skips past it on first open so TTS doesn't read the TOC aloud; entries persist via the existing `document_toc` table and surface in the existing TOC sheet for navigation. End-to-end on-device verification pending re-import of "The Internet Steps to the Beat.pdf".
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
