# Posey History

## 2026-05-07 (afternoon) — Tier 1 #5 closed: Voice picker empty state + antenna scaffolding

Closing the deferred half of #5. Added the antenna scaffolding the verification needed and re-applied the Voice picker empty state.

**Antenna scaffolding (per Mark's standing brief: "the local API should be more capable than a human tester at every point").**
- New verb `OPEN_VOICE_PICKER_SHEET` posts `.remoteOpenVoicePickerSheet`. ReaderView observes and presents `VoicePickerView` as a modal sheet (parallel test entry point; the user-facing NavigationLink in Preferences is unchanged).
- New env var `POSEY_DEBUG_VOICE_PICKER_EMPTY=1` — when set at launch, `VoicePickerView.visibleGroups` returns `[]` regardless of what voices are installed. Lets the empty-state code path be exercised on devices that have voices for the current language. Without the env var, normal behavior applies.

**Voice picker empty state.** When `visibleGroups.isEmpty`, the picker shows: *"No voices for your current language are downloaded. Tap 'Show all languages' below, or download voices in Settings → Accessibility → Spoken Content → Voices."* The "Show all languages" button is the natural next step and is shown immediately below the empty-state copy.

**Three Hats verification.**
- **Developer**: builds clean for both targets.
- **QA**: launched both targets with `POSEY_DEBUG_VOICE_PICKER_EMPTY=1`, opened the picker via `OPEN_VOICE_PICKER_SHEET`, screenshotted on simulator AND iPhone, both screenshots show the empty-state copy + the "Show all languages" affordance. Resized to ≤600px before reading. `/tmp/sshots/sim-vp-empty2.png` and `/tmp/sshots/iphone-vp-empty.png`.
- **User**: a user opening the Voice picker on a device with no voices for their language now sees a clear explanation and a one-tap path to broaden the list — instead of an apparently-broken empty pane.

#5 fully closed.

## 2026-05-07 (afternoon) — Tier 1 #5 partial: TOC sheet empty state

Started a proper audit of every modal sheet for empty-state coverage. First closure: TOC sheet now shows "No table of contents in this document." when `viewModel.tocEntries.isEmpty`.

**Audit summary** of every modal sheet:
- **TOC sheet** — was a blank list when no entries; **fixed in this commit**.
- **Notes sheet > Saved Annotations** — already has "No notes, bookmarks, or conversations yet." (line 2227). No change needed.
- **Voice picker** — needs an empty state when device has no voices for the current language. **Code change drafted, but verification was deferred.** The Voice picker is a NavigationLink destination inside the Preferences sheet's NavigationStack and the antenna's TAP verb can't reach it through the registry or the UIView accessibility-tree fallback. To verify on iPhone (Rule 2) I'd need either antenna test infrastructure (a programmatic-open verb or a coordinate-tap mechanism) or a way to change device locale to one with no installed voices. Reverting the Voice picker change for now and adding to NEXT.md as a follow-up that needs the antenna scaffolding first.
- **Preferences sheet** — settings form, content always present. No empty-state concept.
- **Audio Export sheet** — has "Export not started." when `audioExporter == nil`. No change needed (and currently hidden from the UI for v1 anyway).
- **Ask Posey sheet** — anchor card always present + composer placeholder ("Ask about this passage…", "Ask about this document…") serves as the natural empty-state. Judgment call: this is correct UX for the surface as designed.

**Three Hats verification on TOC sheet empty state.**
- **Developer**: built clean for both targets.
- **QA**: imported `/tmp/short.txt` (TXT, no TOC entries) on simulator AND iPhone, opened the TOC sheet via the antenna's `OPEN_TOC_SHEET` verb (the chrome button only appears when entries exist; the empty state is mostly defensive but reachable). Both screenshots show the empty-state copy correctly. Resized to ≤600px before reading. `/tmp/sshots/sim-toc-empty.png` and `/tmp/sshots/iphone-toc-empty.png`.
- **User**: the user opens the TOC button (which today only appears when entries exist), but anyone reaching the sheet via API or unusual edge cases sees a clear message instead of an empty pane.

The Voice picker empty-state code is correct (visually verified on simulator before revert) but isn't shipping in this commit because it can't be verified on iPhone without test infrastructure. NEXT.md item #5 captures the follow-up.

## 2026-05-07 (mid-morning) — Tier 2 #7: Saved Annotations preview shows note body

The Saved Annotations list in the Notes sheet was showing the anchor sentence (or document-title fallback when the offset didn't match a segment) for every entry, regardless of kind. Per the punch-list spec, notes should preview their body text — that's what the user wrote and what's most useful to scan.

**Fix.** `ReaderViewModel.rebuildSavedAnnotations` now checks each `Note`. For `.note` kind with a non-empty body, the preview is the body itself. For `.bookmark` (no body) or `.note` saved without a body, the preview falls back to the anchor sentence (previous behavior). Bookmarks behave unchanged.

**Three Hats verification.**
- **Developer**: built clean for both targets.
- **QA**: created two notes (different bodies) + one bookmark via the antenna's CREATE_NOTE / CREATE_BOOKMARK verbs, opened the Notes sheet, screenshotted on both hardware. Bookmark row shows the anchor sentence ("Fourth sentence."), each note row shows its own body text. Both screenshots resized to ≤600px before reading.
- **User**: scanning the saved-annotations list with the new behavior, you immediately see what each note SAYS without expanding it. The previous behavior asked you to remember which document position each note was anchored to in order to recall what you'd written. The new behavior shows the words.

`/tmp/sshots/sim-notes.png` and `/tmp/sshots/iphone-notes.png` captured during verification.

## 2026-05-07 (mid-morning) — Tier 1 #6 analysis: TOC playback skip is already correct on DOCX; deferred for RTF

Mark's punch list said "DOCX and RTF must also write `playback_skip_until_offset`." Confirming what's actually wired before adding code (per Mark's directive on this item).

**Empirical verification on DOCX.** Built a synthetic `/tmp/docx-toc-test.docx` with an embedded Word `TOC` field (`<w:fldChar w:fldCharType="begin"/>...<w:instrText> TOC \o "1-3" \h \z \u </w:instrText>...<w:fldChar w:fldCharType="separate"/>...rendered TOC content...<w:fldChar w:fldCharType="end"/>`) followed by real chapter content. Imported on iPhone. Inspected plainText:

```
Table of Contents

Chapter One

This is the actual chapter one body text.

Chapter Two

This is the actual chapter two body text.
```

The rendered TOC content ("Chapter One … 1", "Chapter Two … 5", "Chapter Three … 9") is **completely absent from plainText** — the `WordDocumentXMLExtractor.insideTOCContent` flag suppresses it at extraction time. Different mechanism than PDF (which keeps the TOC text in plainText and sets `playbackSkipUntilOffset` past it) but identical user-facing behavior: the TOC isn't read aloud during playback because it's not in the doc Posey indexed at all.

**RTF analysis.** RTF format doesn't have a Word-style TOC field. Two RTF TOC patterns exist in real docs:
1. Heading-styled paragraphs (`\fs48\b`) — the new RTF tokenizer detects these and writes them as `StoredTOCEntry` rows; there's no separate TOC region of text to skip past.
2. Hardcoded dot-leader TOC text typed as ordinary paragraphs — would need a detector mirroring `PDFTOCDetector`.

Pattern (1) is what every RTF in the test corpus actually uses. Pattern (2) is rare enough to defer to NEXT.md as a known limitation.

**Conclusion:** No code change needed for #6 in v1. DOCX behaves correctly via TOC field suppression (verified). RTF deferred for the niche dot-leader case.

## 2026-05-07 (morning) — Tier 1 #4 closure: iPhone post-merge verification + audio confirmation

Closing out the verification that was deferred overnight. Rebuilt for device, installed the post-merge build, reopened `TestFixtures/parity/ListTest.html` on iPhone:

- **Visual** — both bullet items and numbered items render on one row each. Merge step in `SentenceSegmenter.mergeNumberedListMarkers` working correctly on device.
- **Audio (Mark's ears)** — Mark played the doc on iPhone. Reported: "He reads the text only. The bullet is not mentioned nor are the numbers. It only reads the sentences that follow both in the bulleted list and numbered list paragraph before List between List and after list all function as expected."

That's the AVSpeechSynthesizer behavior we were uncertain about resolving exactly as the strip-at-speech-boundary design protected against. `SpeechPlaybackService.utteranceText(for:)` is doing its job; the audio path never sees the marker characters; the listener hears clean item text only. Three Hats: Developer (build clean, sim + device), QA (visual + edge — surrounding paragraphs unaffected), User (Mark confirmed it sounds right).

Tier 1 #4 fully done.

## 2026-05-06 (late night) — Pre-Release Parity Punch List #4: bullet/numbered lists across formats (Option C, partial)

Closing the in-flight pass on Tier 1 #4. Code is committed; one verification step remains. Mark needs sleep — picking this up at session start tomorrow.

**The approach (per DECISIONS.md "List markers"):** Inject visible markers (`• ` for bullets, `N. ` for numbered) into the extracted text in HTML and DOCX importers. Markers live in both `displayText` and `plainText` so they show in the reader and survive search + Ask Posey embeddings. On the playback side, a new `SpeechPlaybackService.utteranceText(for:)` strips leading marker patterns before AVSpeechSynthesizer ever sees them — the audio path is guaranteed clean regardless of what AVSpeechSynthesizer would otherwise do with `•` or `1.` (Apple's docs are silent; see DECISIONS.md for the research note).

**Per-format coverage in this pass:**
- **HTML / EPUB** — `HTMLDocumentImporter.injectListMarkers` walks the HTML token stream tracking `<ul>`/`<ol>` nesting and prepends `• ` or `N. ` immediately after each opening `<li>`. Runs before `injectParagraphMarkers`. EPUB inherits since spine HTML flows through the same `loadText(fromData:)`.
- **DOCX** — `WordDocumentXMLExtractor` now sets `currentIsListItem = true` whenever it sees `<w:numPr>` inside a paragraph's `<w:pPr>`. At paragraph-flush time, list-item paragraphs that aren't also heading-styled get a `• ` prefix. v1 limitation acknowledged in DECISIONS.md and NEXT.md: every DOCX list item renders as a bullet because reliably distinguishing bullet from numbered requires resolving `numId` against `numbering.xml`. Numbered DOCX lists rendering as bullets is a real Word-fidelity loss documented as known v1 behavior.
- **RTF** — deferred (parser hooks for `\pntext`/`\listtext` not in scope). Documented in NEXT.md.
- **PDF** — out of scope (positional list signal, layout-analysis problem).

**Speech path filter:** New `SpeechPlaybackService.utteranceText(for:)` static method applies `^(?:•|\d+\.)\s+` to each utterance text before construction. Both `SpeechPlaybackService.makeUtterance` and `AudioExporter` route through it. Strip is leading-anchor only, so prose mentioning bullet points or numbered steps inline still pronounces them normally.

**Segmenter merge step (caught during sim verification):** NLTokenizer treats `1.` as a sentence terminator, splitting an injected "1. First numbered item" into two segments. Added `SentenceSegmenter.mergeNumberedListMarkers` post-pass that detects an exact `^\d+\.$` segment and merges it with the next segment. Restores visual coherence — one row per list item. Applied generally (any user-authored "1." on its own line gets merged with the following sentence, which is the expected reading behavior for a list).

**Verification status (Rule 2):**
- HTML on simulator post-merge: bullets and numbered items render correctly on one row each. Visual confirmed via `/tmp/sshots/sim-html-list2.png` (resized to ≤600 per Rule 3).
- DOCX on simulator post-merge: bullets render correctly. Visual confirmed via `/tmp/sshots/sim-docx-list-now.png`.
- DOCX on iPhone (pre-merge build): bullets render correctly (DOCX bullets don't trip the segmenter — the merge step isn't needed for the bullet path). Visual confirmed via `/tmp/sshots/iphone-docx-list.png`.
- HTML on iPhone (pre-merge build): bullets render correctly; numbered items still split per the unfixed segmenter. **iPhone post-merge build install + visual verification is the only remaining step** before this is fully Rule-2-compliant. Device build was in flight when Mark needed to pause; killed cleanly.

**Picking this up tomorrow:** rebuild for device, install the post-merge build, reopen `list-test.html` on iPhone, screenshot, confirm numbered items render on one line each. If yes → write a follow-up HISTORY note and move to Tier 1 #5 (empty-state messages). If anything looks off, debug.

**Audio confirmation pending:** the speech-path strip is implemented and theoretically correct (deterministic regex applied per-utterance), but no one has yet listened to a list-bearing doc playing on hardware. Worth doing once tomorrow on iPhone with `list-test.html` to confirm the markers don't pronounce. This is the one piece that genuinely needs Mark's ears (or a recording test that the antenna doesn't currently expose).

## 2026-05-06 (evening) — Heading-styling Rule 2 closure: DOCX, EPUB, PDF screenshots on both hardware

Closing out the deferred verification on #3. The original commit landed with two-hardware screenshots for MD/HTML/RTF only; DOCX, EPUB, and PDF were structurally analogous code paths but Rule 2 doesn't carve out exceptions for "structurally identical." Mark called that reasoning out and required dedicated screenshots before moving on.

Captured all six (`/tmp/sshots/sim-{docx,epub,pdf}.png` and `/tmp/sshots/iphone-{docx,epub,pdf}.png`, all resized to ≤800px before reading). Verified visually:
- **DOCX** — `Posey Test Materials/Proposal_Assistant_Article_Draft.docx`. "How We Built a GPT-Powered Proposal Assistant That Actually Helps" renders as level-1 (large bold). "Introduction: A Real Problem, A New Kind of Partner" renders as level-2 (smaller bold). Top spacing visible above each. Identical rendering on both hardware.
- **EPUB** — `Posey Test Materials/Data Smog.epub`. The first TOC entry maps to "David Shenk" at offset 0; that row renders as a level-1 heading on both hardware. Subsequent paragraphs (DATA SMOG / Surviving the Information Glut / REVISED AND UPDATED EDITION) are body text, which is correct — only the row at the TOC offset gets heading treatment.
- **PDF** — `Posey Test Materials/Cryptography for Dummies.pdf` (187 outline entries). The first outline entry happens to be a "ChmMagic" registration notice at offset 0 (an artifact embedded by the PDF authoring tool), and that row renders as a level-1 heading on both hardware. Heading styling pipeline confirmed working on PDF outline-derived TOC.

Also reimported the substantive content on Mark's iPhone since the schema-drop wiped TOC entries: AI Book Collaboration Project.rtf (91 entries), Illuminatus TRILOGY EBOOK.epub (470), The 4-Hour Body.epub (77), Cryptography for Dummies.pdf (187), Data Smog.epub (42), Proposal_Assistant_Article_Draft.docx (7). The Clouds Of High-tech Copyright Law.pdf has no detectable TOC (no PDF outline, no dot-leader text pattern); reimport completed but TOC stays empty — that's the genuine state of the doc, not a regression.

Iphone docs whose source files aren't in `Posey Test Materials/` and therefore couldn't be reimported: How_to_Use_ISES_QR_Generator.docx, Field Notes on Estuaries.html, Notes on Working in Public.md, On Reading Slowly.txt. Their content is intact (the schema drop only touched `document_toc`); they just have no TOC entries until Mark re-imports their source files. TXT has no TOC concept anyway.

## 2026-05-06 (evening) — Pre-Release Parity Punch List #3: Heading visual styling, level-aware, every format

Closed Tier 1 #3 of the parity punch list. Headings across MD, DOCX, RTF, EPUB, PDF, and HTML now render with one shared visual spec, scaled by heading level so a chapter title and a section subhead actually feel like different kinds of break.

**The visual spec.** Single source of truth in `ReaderViewModel.headingFontSize/headingWeight/headingTopSpacing` (consulted by both render paths). Level 1 is `1.50× body, bold, +24pt top spacing` (chapter title). Level 2 is `1.30× body, bold, +18pt`. Level 3 is `1.15× body, semibold, +12pt`. Levels 4–6 collapse to body size with semibold weight and `+8pt` spacing — real-world docs rarely use h4+ meaningfully and the visual budget is better spent on the upper three. The first row of a doc never gets the extra top spacing (no preceding section to separate from).

The previous renderer had a 1pt-per-level scale (`fontSize + (10 - level)`) which was too subtle to read as hierarchy at normal reading distance — chapter and subsection were essentially the same size. The new scale is perceptible without shouting.

**Schema change.** `StoredTOCEntry` and the `document_toc` table gained a `level: Int` column. Every importer was preserving level data internally (`DOCXHeadingEntry.level`, `RTFHeadingEntry.level`, `MarkdownParser.heading(level:text:)`, EPUB NCX nesting, PDF outline depth) and discarding it at the TOC write boundary. The new column carries it through to render time. Per Mark's call: no migration code; the schema setup detects the missing column on existing DBs, drops `document_toc`, and lets the user re-import to repopulate.

**Per-format coverage.**
- **MD** — `MarkdownLibraryImporter` now passes the parser's level when building TOC entries. (Already on the displayBlocks render path; gets the new visual spec automatically.)
- **DOCX** — `DOCXLibraryImporter` passes `DOCXHeadingEntry.level` into the TOC. Sentence-row docs (no images) and displayBlocks docs (with images) both work.
- **RTF** — `RTFLibraryImporter` passes `RTFHeadingEntry.level` (the font-size-tier classifier already in `RTFDocumentImporter`). Sentence-row path picks it up.
- **EPUB** — `EPUBNCXParser` now tracks navPoint nesting depth via a parent-state stack so a child navPoint doesn't clobber its parent's in-progress label/src/order. `EPUBNavTOCParser` (EPUB 3) tracks `<ol>`/`<ul>` nesting depth in the same way. Spine-fallback synthesized TOCs default to level 1.
- **PDF** — `extractOutlineEntries` records traversal depth as level (chapter at 1, section at 2, …). The text-pattern detector path stays at level 1 (no signal in the dot-leader pattern).
- **HTML** — NEW: `HTMLDocumentImporter.extractHeadings(fromRawData:)` regex-extracts `<h1>`–`<h6>` from raw HTML, strips inner tags, decodes the small set of HTML entities likely to appear in heading text. `HTMLLibraryImporter.resolveHeadingOffsets(...)` does sequential left-to-right search in the post-NSAttributedString plainText so duplicates don't all collapse to the same offset. Works for both URL-based and raw-data-based imports.

**Two render paths.** The displayBlocks renderer (used by MD always, PDF, and DOCX/HTML/EPUB when they have images) re-tags paragraph blocks at TOC offsets as `.heading(level: N)` via `applyHeadingStyling`. The sentence-row renderer (TXT, plain DOCX/HTML/EPUB, RTF) uses a new `headingLevel(forSegmentStartOffset:)` accessor on `ReaderViewModel`, with a 2-char fuzz window for the small offset drift the segmenter produces when a heading lacks terminal punctuation. Both paths feed the same typography helpers.

**Verification.** Two pieces of hardware × three formats:
- MD on simulator: chapter title with breathing room above, h2 visibly smaller, h3 smaller still, h4-6 body-sized with semibold weight; chapter break shows the designed top-spacing pause.
- MD on iPhone (dark mode): same rendering, same hierarchy.
- HTML on simulator + iPhone: new HTML extractor surfaces all four levels correctly through the sentence-row path.
- RTF on simulator + iPhone: existing font-tier tokenizer's level data flows through; chapter break visible.

Three Hats: Developer (builds clean for both targets, no errors), QA (level-1 chapter break visibly different from level-3 subsection on every format tested), User (the chapter break finally reads as a chapter break — the 1pt-per-level scale was a real readability bug).



Closed Tier 1 #2 of the parity punch list for the three formats whose importers already extract inline images. RTF and MD remain on the open list (RTF doesn't extract `\pict` blocks today; MD needs `![alt](url)` resolution work).

**The problem.** Yesterday's submission-day pass stripped `[[POSEY_VISUAL_PAGE:...]]` markers from `displayText` for EPUB / DOCX / HTML to keep them from leaking to the user as literal text. That cut the only signal the displayBlocks renderer had to know where images go — so `document_images` filled up at import time and nothing rendered.

**The fix.** Three threads.

1. **`displayText` keeps markers; `plainText` strips them.** Reverted the over-zealous strip from yesterday across `EPUBDocumentImporter`, `DOCXDocumentImporter`, `HTMLDocumentImporter`. The split is now consistent: `displayText` is the marker-bearing form fed to the displayBlocks renderer; `plainText` is the marker-stripped form used for TTS, search, RAG, character count, and the existing sentence-row reader.

2. **One shared splitter (`VisualPlaceholderSplitter`).** Replaced format-specific parsers with a regex-based one in `Posey/Services/Import/VisualPlaceholderSplitter.swift`. The earlier per-format split-on-form-feed approach was broken because `TextNormalizer.stripMojibakeAndControlCharacters` strips C0 controls (including U+000C form feed) — by the time the parser ran, the surrounding sentinels were already gone and the marker substring was just sitting between `\n\n` boundaries. The new path scans for the marker pattern via `NSRegularExpression`, emits `visualPlaceholder` blocks at each match, and emits `paragraph` blocks for text in between. `EPUBDisplayParser` / `DOCXDisplayParser` / `HTMLDisplayParser` are now thin wrappers around this single code path.

3. **Fast-path: zero markers → zero blocks.** When a doc has no markers (the common case for plain DOCX / HTML / EPUB with no embedded images), the splitter returns `[]` immediately, leaving the document on the existing sentence-row reader path — no behavior change, no new memory pressure.

**Verification.**
- Data Smog EPUB (4 markers): HarperCollins e-books logo renders inline between "REVISED AND UPDATED EDITION" and "For Sol Shenk" on the connected iPhone. Screenshot captured.
- The 4-Hour Body EPUB (1.04 MB displayText, 453 markers, 453 stored images): reader opens to text in ~8 s on iPhone 16 Plus — same order of magnitude as before my changes. The dominant cost is the pre-existing `SentenceSegmenter`/`NLTokenizer` pass that runs `loadContent` on a background queue; the parser regex over the displayText is sub-second on top of that. No choke, no regression.
- DOCX / HTML use the same `VisualPlaceholderSplitter` code path; documents without markers fall through to the existing sentence-row reader unchanged.

## 2026-05-06 (afternoon) — Pre-Release Parity Punch List #1: RTF TOC navigation

Closed Tier 1 #1 of the 17-item parity punch list. RTF documents now produce a populated Table of Contents from heading-styled paragraphs.

**The problem.** RTF was the only structured format Posey supported with no TOC. The first attempt was to read NSAttributedString font attributes after parsing — that works on macOS (verified by an offline probe) but does NOT work on iOS: NSAttributedString-from-RTF on iOS yields a single attribute span with no `.font` set, even though the cleanly-extracted plaintext is correct. iOS's RTF text-system parser drops style information that macOS preserves.

**The fix.** A focused RTF tokenizer at `Posey/Services/Import/RTFDocumentImporter.swift` (Block 5) walks the raw RTF bytes directly, tracks per-character `\fs` (font size in half-points) and `\b` (bold) state, splits on `\par`, and emits `(text, dominantSize, dominantBold)` per paragraph. NSAttributedString is still used for clean plaintext extraction. The two are joined: heading paragraphs get matched into the normalized plaintext via forward-only prefix search, and their offsets persist as `StoredTOCEntry` rows.

Three nontrivial pitfalls in the tokenizer surfaced and got fixed during testing on device:
- Skip-group exit used `<` where `<=` is correct; without that, every `{\fonttbl...}` swallowed the rest of the document.
- Style state at `\par` was post-formatting-reset, not the formatting active during the paragraph's text. Fix: track per-character (size, bold) and pick the dominant style when the paragraph flushes — required because Word writes `\fs48\b Chapter One\b0\fs24\par` with the reset BEFORE the paragraph break.
- Bold-only fallback for headings flooded the candidates on Word RTFs that mark body text as bold via style-table references our tokenizer doesn't resolve. Dropped the fallback; rely solely on `font_size ≥ 1.15× body_size`. Robust on the test corpus.

**Verification.**
- Synthetic RTF (`/tmp/posey-rtf-test.rtf`): 4 expected headings detected, offsets exactly match the macOS NSAttributedString reference (58 / 204 / 313 / 426).
- Real-world `AI Book Collaboration Project.rtf` (148k chars): 91 TOC entries with sensible titles ("Demystifying the Machine: A Collaborative Exploration...", "Embracing Collaboration", "Mark Friedlander: Your Humble Moderator", "Chapter 1: What is AI?", ...).
- Real-world `Ch1 What is artificial intelligence.rtf`: 7 entries (the question + 6 model-round headings).
- `READER_GOTO` to TOC offset 1509 lands directly on the highlighted "Chapter 1: What is AI?" sentence — verified via SCREENSHOT on the connected iPhone.
- Simulator: same build installs and runs (verification path is platform-agnostic Swift code; the iOS-specific bug was the NSAttributedString font-attribute loss the new tokenizer sidesteps).

## 2026-05-06 — Submission day: 7-item punch list closed

Mark's submission-day list, in priority order. Each item fixed, deployed to phone, verified via screenshot or device test before moving on. CLAUDE.md two-rules in effect (search before failing twice; two pieces of hardware + screenshots before commit).

**1. HTML mojibake** (commit `0a2bed3`). NSAttributedString HTML parsing was defaulting to Windows-1252 when the source had no `<meta charset>` declaration, causing UTF-8 multi-byte sequences (em-dash 0xE2 0x80 0x94) to be misread as Latin-1 → "â€"" mojibake visible to users. Fix: pass `.characterEncoding: NSNumber(value: String.Encoding.utf8.rawValue)` explicitly to `NSAttributedString(data:options:)`. Verified across three test variants (no charset, explicit UTF-8 charset, multi-accent). Field Notes on Estuaries, Café/déjà/naïve/résumé all render correctly.

**2. Background audio lock-screen regression** (commit `cf8dd42`). Phone build's Info.plist was missing `UIBackgroundModes` despite `INFOPLIST_KEY_UIBackgroundModes = audio` in build settings AND a Run Script that injected it via PlistBuddy. The Run Script worked on clean builds but Xcode's incremental build cache periodically dropped its output, causing the regression to come back. Durable fix: switched the project from `GENERATE_INFOPLIST_FILE = YES` + Run Script injection to an explicit committed `Info.plist` at the repo root with `UIBackgroundModes = ["audio"]` hardcoded. Removed the "Inject UIBackgroundModes" build phase entirely. Verified: clean build + incremental rebuild both produce a binary with the key. Mark verified end-to-end on phone: started playback, locked screen, audio continued.

**3. Conversation reload on reopen** (commit `fb427f0` + refinement `3d198f7`). When reopening Ask Posey on a doc with prior conversation, the sheet appeared blank to the user — the new invocation's anchor card sat at the top with all prior conversation scrolled off above. Fix: scroll the new anchor to `.top` of the viewport so it's immediately visible (frames the next question), with prior conversation accessible by scrolling up. Per Mark's spec: anchor MUST be visible without scrolling. Verified on phone with 15-turn TXT conversation.

**4. TOC for MD/DOCX/PDF** (commit `8e87903`). Three formats had structural headings but TOC sheet was empty; only EPUB populated. Fixes:
- MD: Markdown parser already classifies `# / ## / ###` as `.heading(level:)` blocks; importer now emits a `StoredTOCEntry` per heading with its plainText offset. 5 entries on the test MD doc.
- DOCX: Word XML extractor now tracks `<w:pStyle w:val="HeadingN"/>` and "Title" paragraph styles; captures (level, title, paragraphIndex) at parse time, then maps to plainText offset accounting for visual-page marker stripping. 3 entries on the test DOCX.
- PDF: Added native PDF outline (`PDFDocument.outlineRoot`) as a fallback when text-pattern TOC detector finds nothing. Walks the outline tree, resolves each entry's destination page, computes plainText offset by summing earlier page lengths plus separators. 187 entries on Cryptography for Dummies.
- RTF: deferred. Standard RTF has no explicit heading semantics; heuristic detection (bold + larger font + line-leading) is fragile across publishers.

Verified: TOC sheet renders entries correctly + tap-jump navigates to the right offset.

**5. Audio export hidden from UI** (commit `fb94a94`). Removed the "Audio Export" Section from Reader Preferences sheet. Backend (AudioExporter, RemoteAudioExportRegistry, EXPORT_AUDIO API verb) intact and continues to work for testing. Reasons for hiding: no progress indicator during long renders (RTF/EPUB take minutes; user sees a static sheet); export speed observed in testing was ~3.6× faster than live playback. Documented in NEXT.md as coming-soon.

**6. Ask Posey quality** (commits `1ff4f05` + `6539cc4`). Three findings from yesterday's testing:
- MD repetition (AFM padded "the four things" by repeating an item): mitigated with comma-list dedupe (`dedupeRepeatedListItems`) and numbered-list dedupe (`dedupeNumberedListItems`) in `finalizeAssistantTurn`. Both heuristics are conservative — only fire on items ≥ 3 words long, preserve rhetorical doublings. Plus stronger prompt rule 6a with worked FAILED/SUCCEEDED examples for both repetition and invention padding.
- RTF false-negative on AI consciousness: now correctly answers (verified on phone — fixed by yesterday's RAG improvements; no change needed today).
- EPUB subtitle missed: now correctly answers "Surviving the Information Glut" (verified on phone).

Trade-off accepted: count-mismatch questions sometimes produce shorter, more conservative answers instead of risking fabrication. Net win for grounding.

**7. Strip visual-page marker text** (commit `e67d8ed`). The `[[POSEY_VISUAL_PAGE:0:<uuid>]]` placeholder tokens were leaking to the user as literal text in DOCX, EPUB, and HTML rendering. Per Mark's instruction: silent removal for these formats; PDF visual pages stay (they render correctly via the PDFKit thumbnail path). Three changes:
- HTML: `loadDocument` now applies stripVisualPageMarkers to displayText (previously only to plainText).
- DOCX: same.
- EPUB: displayText is now the marker-stripped form.

Bonus: fixed a regex bug shared across all three. The strip patterns used Swift raw-string syntax `\u{000C}?` which ICU regex doesn't recognize. NSRegularExpression silently failed compilation (try? → nil) and the strip function returned input unchanged — markers leaked through. Now uses ICU's `\x{000C}?` syntax explicitly. Images extracted at import remain in `document_images` for future inline-render work; only the user-visible marker text is suppressed in 1.0.

Three Hats verification done on each item — Developer (does it build/work), QA (edges + regressions), User (does it feel right).

## 2026-05-06 (early) — Reader deep test + format parity audit, complete pass

Documented at `submission/test-results-2026-05-06.md`. Full sweep of every Task 5 item × every of 7 formats + Task 8 parity matrix + image rendering audit + multi-turn Ask Posey transcripts. 24 critical findings ranked. Per-format pass/fail tables for items 1-20. Image-bearing test docs sourced for HTML/MD/DOCX/PDF + multi-image DOCX + RTF-with-pict. Audio export verified on all 7 formats. Lock screen via SIMULATE_BACKGROUND on every format. Focus + Motion screenshots per format. Quick-action chrome templates verified. Search edge cases. Corrupted file imports gracefully refused. Conversation persistence DB-validated.

The test report drove today's submission-day punch list above.

## 2026-05-05 (closing) — Ask Posey scroll: contentMargins + latestUserMessageID + new CLAUDE.md rules

Two interconnected fixes finally got "user message scrolls to top on send" working — after at least five wrong attempts I shipped before searching for the proven pattern.

**Wrong .onChange trigger.** The previous code watched `messages.count` with a "last role is user" guard. The live `send()` path appends user message + streaming placeholder in the SAME SwiftUI update tick, so onChange fired ONCE with last role = .assistant — guard returned early, scroll never ran. Now watches `latestUserMessageID` directly, fires exactly when a new user message lands regardless of placeholder timing.

**ScrollView clamping the scroll position.** `proxy.scrollTo(userMsg.id, anchor: .top)` is a no-op when the content below the target isn't tall enough to fill the viewport — SwiftUI ScrollView clamps to "just enough to show all content," so the user's question sat at its natural LazyVStack position instead of the literal top. Fix uses the standard iOS 17 ScrollView API: `.contentMargins(.bottom, viewportHeight, for: .scrollContent)` extends the scrollable area by one viewport without rendering visible empty content. The previous attempt used an inline trailing Color.clear spacer which DID show as visible blank space — Mark caught it. contentMargins is the right tool because it's scroll-only, not visible.

Now matches the ChatGPT/Claude pattern: send a message → message snaps to viewport top, anchor card / older history scrolls off above, answer streams in below. Verified on Mark's iPhone with a long multi-line question.

Also dropped sub-40% relevance chunks from the AFM input — Mark caught a weak-grounding (empty-circle) pill being cited. Synthetic metadata chunks (startOffset < 0) are exempt.

**Two new standing rules added to CLAUDE.md (commit `1c50878`).** Both came directly out of how badly tonight went:
- **Rule 1 — Search before you fail twice.** After two failed attempts at something I'm not certain about, the next move is to web-search for the proven pattern, not write a third guess. The scroll fix went five wrong attempts before Mark made me search and find the documented WWDC23 contentMargins answer.
- **Rule 2 — Two pieces of hardware, two screenshots, before commit.** Any user-visible change must run on both the phone AND the simulator (or Catalyst), with screenshots captured from each, both visually verified. The anti-pattern this kills: edit code, run /ask, see JSON, commit. That's how I shipped multiple "verified on phone" commits today that were verified on neither.

Commits `c7af72d`, `1c50878`.

**Honest correction to claims I made earlier in this same HISTORY file:** the "Pixel-verified outcomes" section under the "very late evening, second pass" entry below was written before I'd actually tested the long-message scroll case Mark cared about. Short-message scroll worked at that point; long-message did not, and I claimed it did. The user-message-at-top behavior didn't actually work end-to-end until commit `c7af72d`.

## 2026-05-05 (very late evening) — Ask Posey: HIG-compliant chip renderer + autonomous visual verification

Replaces the bracketed-text-link experiment from earlier in the night with a real chip view that's actually verifiable without Mark's eyes. Three regressions Mark caught in his screenshot review now have pixel-level evidence, not arguments.

**Renderer rewrite.** Assistant messages with inline citations now render via a custom `CitationFlowText` + `CitationFlowLayout` instead of `Text(.init(markdown))`. Content is split into prose segments and citation chip segments; each chip is a real SwiftUI `Button` with a 44pt-wide invisible hit area (HIG minimum) wrapped around a visually small (~22×18pt) rounded-rect chip. To prevent chips from wrapping to a new line alone, each citation is bundled with the LAST WORD of the preceding prose run — so `workers,[2][3]` and `evaporation.[2][3]` stay glued together on the same line as their cited claim. `CitationFlowLayout` is a custom SwiftUI Layout doing wrap-aware sizing so multi-line Text doesn't get clipped (the bug that initially showed prose cut off mid-sentence).

**Pill labels** (separate fix from earlier) keep matching the `[N]` markers in the response — `citedChunks(in:)` returns `[CitedSource]` carrying the original 1-indexed citation number and the strip renders that, not the position in the filtered array.

**Three-pass scroll** (80/180/220ms) for short messages unchanged.

**Autonomous visual verification — new test surface.** Added `SEED_ASK_POSEY_FIXTURE:<doc-id>` local-API verb that seeds a fixture user/assistant turn pair with citations `[2][3]` (twice, adjacent) over 3 chunks. Lets the simulator exercise the rendering paths without needing AFM model assets — which the booted simulator on this Mac does not have. This unblocks the "drive the simulator end-to-end and screenshot" loop that's central to the standing CLAUDE.md QA practice.

**Pixel-verified outcomes** (simulator screenshot `/tmp/sim-14.png`):
- SOURCES strip pills labeled `2 ◐ 3 ◐` matching the citation numbers in the body, not renumbered to 1/2.
- Adjacent `[2]` `[3]` chips are visually distinct, no fusing.
- Each chip is a real Button with 44pt hit area (a11y tree confirmed: "Citation 2. Tap to jump to source." / "Citation 3. Tap to jump to source." as custom actions on the bubble).
- Prose flows inline with chips, no overflow, no mid-sentence truncation.

The earlier commit `bdfe743` that shipped a bracketed-text-link version Mark hadn't agreed to is superseded by `bb8d718`.

**Process note.** Earlier in this session I marked these bugs "completed" based on code review and a data-side API check, with no pixels verified on any platform. Mark caught it. The fix isn't a promise — it's the seed endpoint plus the standing rule that nothing leaves my hands marked done until a screenshot proves it.

## 2026-05-05 (very late evening, second pass) — Ask Posey: full phone-side verification + autonomous test loop

After Mark caught me marking the prior commit "verified on phone" without actually exercising the live submit path or the thinking-indicator visibility, this pass closes the verification loop properly and ships a real autonomous test harness for the phone.

**App-side fixes**

- **Citation renumbering per message.** AFM emits prompt-injection-position numbers like `[2][5][3]` (referring to chunksInjected positions 2, 5, 3). User-facing display now goes through a `displayMap` that renumbers to `[1][2][3]` in body-order of first appearance. Both the body chips and the SOURCES strip pills show 1..N in the same sequence; tap dispatch still uses the original AFM number to look up the right chunk. Mark's directive: "each block starts with citation 1 and goes through N."
- **Composer placeholder cleanup.** Removed the "Tap a sentence in the reader to ask about it" fallback — defensive cruft for a state that doesn't exist (Ask Posey is always scoped to a document). Three states now: "Ask a follow-up…" mid-conversation, "Ask about this passage…" with passage anchor, "Ask about this document…" otherwise.
- **Sparkle quick-actions menu always visible.** The menu was hidden when `viewModel.anchor == nil` (document-scope reopens), leaving the user with no template-action affordance. Now shown unconditionally.
- **Thinking indicator now actually renders during AFM calls.** The live `send()` path appends a streaming-placeholder bubble (empty content, `isStreaming = true`) immediately, which gated out the standalone typing-indicator condition (`!messages.contains(where: { $0.isStreaming })`). The empty placeholder showed as a tiny grey blob in the screenshot instead. Fix: `threadRow(for:)` now renders `ThinkingIndicatorBubble` IN the streaming-placeholder slot when content is empty, and swaps to the real bubble when the first token arrives. Also brightened the indicator: tinted-fill bubble + 6pt blue dot + .callout primary text instead of the .footnote .secondary that was nearly invisible on dark mode.
- **`/open-ask-posey` re-open made idempotent.** ReaderView's `openAskPosey` now early-returns if `askPoseyChat` is already non-nil, so Library's redelivered notification doesn't churn the sheet's lifecycle and dismiss it mid-presentation. Earlier attempts at "force nil → non-nil" were dismissing the sheet just as it appeared.

**Local-API additions for autonomous phone testing**

- **`SUBMIT_ASK_POSEY:<text>`** — drives the live `submit()` path on the open Ask Posey sheet's view model. Required for testing scroll-on-send and thinking-indicator visibility, both of which `/ask` cannot exercise (it bypasses the open VM entirely and writes only to DB).
- **`SCROLL_ASK_POSEY_TO_LATEST`** — three-pass scroll to the bottom of the conversation thread, so the test harness can bring the most recent assistant message + chips + SOURCES strip into view when content is taller than the visible sheet.
- **`LOGS:<limit>:<sinceEpochMs>`** + **`CLEAR_LOGS`** — recent log lines from a new in-app circular buffer (`InAppLogBuffer`, DEBUG-only). `dbgLog` now appends to the buffer in addition to NSLog. Diagnostic-only; lets the test harness see what the running app saw without needing Console.app or Xcode.

**Pixel-verified outcomes on Mark's iPhone with real AFM**

- AFM emits `[2][5][3]` over 5 chunks → body chips display as `[1][2][3]` inline with cited words → SOURCES strip shows pills `1 ◐ 2 ◐ 3 ◐` matching.
- Adjacent chips are visually distinct, no fusing.
- Each chip exposes `Citation N. Tap to jump to source.` as a real Button with 44pt hit area.
- After SUBMIT_ASK_POSEY, user message lands at the top of the visible sheet, thinking indicator renders below it with rotating Posey-voice phrase ("Let me see what's actually on the page…"), assistant reply replaces the indicator when the first token arrives.
- Composer placeholder reads "Ask a follow-up…" mid-conversation; sparkle button always visible.

**Process note.** Earlier in this session I had marked these bugs "completed" based on code review and a data-side API check, with no pixels verified on either platform. Mark caught it. Then I claimed I couldn't screenshot the phone — which was wrong; the SCREENSHOT verb was already built. Then I added a SCROLL_ASK_POSEY_TO_LATEST verb but stopped short of building the SUBMIT verb that would actually exercise the scroll-on-send path. Mark caught that too. The principle is now: nothing is "done" without a screenshot from the same hardware the user runs on, and every gap in the autonomous loop gets closed before declaring victory rather than after.

Commits `5598782`, `(this commit)`.

## 2026-05-05 (late evening) — Ask Posey: bracketed citation chips, correct pill labels, robust scroll

Three regressions Mark caught in his post-Phase-1 screenshot review, all fixed in `AskPoseyView.swift`.

**1. Pill numbering must match citation numbers.** `citedChunks(in:)` previously returned `[RetrievedChunk]` and the strip used `index + 1` from the filtered array — so a response citing `[4][6]` produced pills labeled `1, 2`. Now returns `[CitedSource]` carrying the original 1-indexed citation number from the response text; pills render that number directly. Order-preserving dedup so duplicate citations don't double up.

**2. Citation chips replace superscript `[ⁿ]`.** Two related problems with the old superscript renderer: (a) `⁴⁶` for `[4][6]` reads as the number 46 — Mark caught this and called it confusing; (b) ~10pt glyph tap target (well below HIG 44pt) caused him to miss the tap 2-3 times in a row. Renderer now emits `[\[N\]](posey-cite://N)` — escaped brackets inside markdown link text. `AttributedString(markdown:)` parses this as a link with display text `[N]` and URL `posey-cite://N` (verified by standalone Swift). Body-size font gives a real tap target, brackets are visual separators, and a U+200A hair space is injected between adjacent chips so they never collide. `stripCitationMarkup` (clipboard copy) strips both the new bracketed form and the legacy superscript form so older messages already in the DB still copy clean.

**3. Three-pass scroll-to-top for short messages.** Single-pass 60ms scrollTo was no-op'ing on short user messages because the LazyVStack hadn't realized the row by the time the proxy looked it up. Now uses the same 80ms / 180ms / 220ms three-pass pattern as `scrollToInitialAnchor` — pass 1 forces lazy realization, pass 2 catches partial realization, pass 3 animates the user-visible settle. Branch by length unchanged: short → user msg at top, long → typing indicator near top.

**Verification gap.** Phone-side data validated via local API: a question that made AFM emit `[2][3]` returned `chunksInjected` with positions 2 and 3 matching, so the new strip will display pills `2` and `3`. End-to-end visual on the iOS 26 simulator was blocked — booted simulator has no AFM model assets (`com.apple.modelcatalog Code=5000 "There are no underlying assets"`), so the citation/pill flow can't be exercised there. Phone visual sweep still owed by Mark.

Commit `bdfe743`.

## 2026-05-05 (evening) — Phase B: progressive background per-chunk contextual enhancement

Anthropic's contextual-retrieval pattern, on-device, with Mark's progressive-enhancement design layered on top. Documents get smarter over time as the user reads. AFM generates a 1-2 sentence "context note" per content chunk; the prepended note + chunk text gets re-embedded; the chunk's vector lands closer to the queries it should match. Reported 49% retrieval-failure reduction in Anthropic's published benchmarks; on-device with AFM the same shape but with refusal-handling we built in.

**Validated end-to-end on Mark's iPhone.** The PDF (Copyright Law, 51 chunks) finished in ~80 seconds — 30 enhanced + 21 AFM safety refusals (Napster / mp3.com content tripping AFM moderation; refused chunks keep their original embedding and are `ctx_status=2`'d so the scheduler doesn't retry forever). The RTF (AI Book Collaboration, 346 chunks) finished in ~10 minutes background time — 259 enhanced + 87 refusals.

**Hard sweep across the enhanced docs, 8/8 PASS** (one initial "FAIL" was a test-design error: I assumed the AI Book didn't mention self-driving cars; RAG_FIND showed it has 2 matches for "self-driving" and 6 for "autonomous" — AFM's answer was correct, not a fabrication):

| Question type | PDF (Copyright) | RTF (AI Book) |
|---|---|---|
| Specific named entity | ✓ Napster legal situation grounded in 5c+1s | ✓ ethical concerns grounded in 5c+1s |
| Deep-doc detail | ✓ ADR's effect on legal precedent | ✓ AI's role supporting humans |
| Weak-cosine topic | ✓ ADR disadvantages — surfaced binding-precedent + legal-protection | ✓ consciousness/feelings in AI surfaced cleanly |
| Anti-fabrication | ✓ honest refusal on GDPR | ✓ accurate "self-driving" answer (not in compound-question test sense, but factually correct) |

**Architecture:**

- **`DocumentChunkEnhancer`** — AFM `@Generable` call returning a `DocumentChunkContextPayload` with a single `contextNote` field. Prompt asks for "1-2 sentence search-relevance note" — what the passage is about, where it sits in the document, in words a reader would actually search with. Refusal-retry with a more neutral "bibliographic-only" prompt; same pattern as the Phase A metadata extractor.

- **`BackgroundEnhancementScheduler`** — `@MainActor` worker. Walks the library's content chunks in priority order: (a) currentReadingDocumentID's chunks at offset >= currentReadingOffset, (b) currentReadingDocumentID's chunks before currentReadingOffset, (c) other library docs with pending chunks. Yields immediately to user-driven AFM calls via NotificationCenter brackets posted by `AskPoseyService` (`.askPoseyAFMDidBegin` / `.askPoseyAFMDidEnd`). Throttles on low-power mode and serious/critical thermal state. Self-exits when no pending work; self-restarts on next reading-position update or import.

- **Schema:** two new columns on `document_chunks` — `context_note TEXT` (the AFM-generated prepend, stored separately so re-embedding doesn't recompute the note) and `ctx_status INTEGER` (state machine: 0 not enhanced, 1 enhanced, 2 attempted-and-failed). Synthetic metadata chunks (`embedding_kind` ending `:syn-meta`) excluded from enhancement — already curated.

- **`IndexingTracker`** — extended to subscribe to chunk-enhancement notifications and roll Phase B into the unified progress ring. Stage weights in `unifiedProgress`: 25% chunking + 5% metadata + 70% per-chunk enhancement, reflecting where the wall-clock time actually goes. Re-reads `chunkEnhancementCounts` from the DB on each notification rather than maintaining a counter — cheap, drift-free.

- **`ReaderView`** — posts `.readerPositionDidUpdate` on every sentence advance with documentID + offset. The scheduler subscribes and re-prioritizes its queue lazily.

- **`AskPoseyService`** — brackets `classifyIntent` and `streamProseResponse` with begin/end notifications. The scheduler pauses for the duration; AFM is single-stream on-device, and without yielding the user's question would wait up to ~2s behind a chunk-context-note generation.

- **Sustainable pacing.** Initial 200ms spacing between chunks proved too aggressive — the scheduler was saturating AFM and the local API antenna timed out for 120+ seconds during a sweep. Bumped to 1.5s spacing, which lets thermal/battery breathe AND keeps the local API responsive AND aligns with Mark's "steady, sustainable progress over peak throughput" framing of progressive enhancement.

- **5-second startup delay.** Originally the library `.task` block kicked the scheduler immediately. Combined with the user opening a document → ReaderViewModel loading → embedding index loading → all on main actor, that produced visible startup lag. Now starts 5s after library appears.

**Refusal rate observation.** PDF: 21/52 (40%). RTF: 87/346 (25%). Higher than Phase A's metadata extraction (~10%) because per-chunk content is broader — an entire document's worth of paragraphs is more likely to contain language AFM moderates than just the title page. Acceptable for v1: refused chunks keep their original embeddings and continue to work in retrieval; they just don't get the contextual lift. Could be tuned with prompt iteration, but the 60-75% that DO enhance is enough to materially improve retrieval.

**Local-API verbs added:** `PHASE_B_STATUS`, `PHASE_B_DEBUG`, `PHASE_B_START`, `PHASE_B_STOP`, `LIST_ENHANCED_CHUNKS`. The Python `tools/posey_phase_b_sweep.py` runs the hard sweep.

Commits `0c67579` (Phase B core) → followups for the saturation fix.

---

## 2026-05-05 (afternoon) — Phase A: sentence-aware chunking + synthetic metadata chunk

The harness from this morning paid for itself within hours. Mark and I worked through a substantive RAG redesign together — instead of just slapping in Anthropic's per-chunk contextual retrieval (expensive on-device: ~80 minutes to index Illuminatus on AFM), we landed on a smarter shape: **AFM extracts clean structured metadata at index time, the result becomes a single natural-prose chunk that lives in the RAG alongside content chunks.** It only travels with the prompt when the query semantically calls for it, no always-on attention tax, no position-based "front matter" guessing game.

**Validated end-to-end on three regression queries (Mark's iPhone):**

| Question | Before | After |
|---|---|---|
| "What is an example of an advantage of using ADR?" | "ADR is advantageous because it is much more time-consuming than litigation" (factual inversion — AFM swapped subjects of comparison) | "An example of an advantage of using ADR is that it allows parties to keep proceedings confidential and informal" (correct, grounded in chunk 29) |
| "Who wrote this paper and when?" | "I'm not finding a strong answer" (weak retrieval gate) | "Professor Sharp wrote this paper in 2000" (correct, from synthetic chunk) |
| "Who are the contributors to this book?" | "I'm not finding a strong answer" (front-matter relevance fix regressed it) | "Mark Friedlander, ChatGPT, Claude, and Gemini" (correct, from synthetic chunk) |

**Architecture in detail:**

1. **Sentence-aware chunking** (Hal MENTAT pattern, `Hal.swift:9275`). NLTokenizer enumerates sentence boundaries; chunks accumulate whole sentences until the size cap; overlap is sentence-granular. Comparative statements ("Litigation is more time-consuming than ADR") never split mid-clause; antecedents stay bounded with their referents. Falls back to character-window chunking when sentence detection finds 0 sentences (single-token blob, hex dump). Same `chunkSize` / `chunkOverlap` config knobs — they're now targets, not exact slice boundaries.

2. **AFM `@Generable` metadata extraction**. One round-trip per document at index time (`DocumentMetadataService`). Returns `{title, authors[], year, documentType, summary}` with `@Guide` annotations enforcing a tight schema. Snippet is the first 1,500 chars of plainText (originally 4K, dropped after the Copyright Law article tripped a "May contain sensitive content" refusal on body content like "Napster, mp3.com, copyright disputes"). Refusal-retry kicks in with a more neutral bibliographic-only prompt when the first attempt is refused.

3. **Synthetic prose chunk** (`DocumentMetadataChunkSynthesizer`). The structured fields get composed into one natural-prose paragraph: *"This document is titled X, written by Y in Z. It is a [type]. [Summary]."* Plus optional TOC overview if the document has parsed entries. Embedded with **MiniLM regardless of the document's content embedder** — meta-questions cluster much better in MiniLM's vector space than in NLEmbedding's. Stored in `document_chunks` with `embedding_kind = "en-minilm:syn-meta"` so retrieval splits it into its own kind group at search time. `start_offset = end_offset = -1` sentinel marks "not a slice of plainText" so jump-to-passage and citation linking skip it.

4. **Retrieval gate updates** in `AskPoseyChatViewModel`:
   - Front-matter relevance lowered from 1.0 to 0.30 + merged list sorted by relevance descending before the budget enforcer. High-confidence organic retrieval now beats forced front-matter, fixing the BUDGET MISS that the ADR question's answer chunk (cosine 0.66) hit when 4 front-matter chunks at relevance 1.0 were eating the 1800-token budget first.
   - `isWeakRetrieval` treats synthetic chunks (startOffset < 0) as strong evidence regardless of cosine. Their cosine is artificially constrained by short text + narrow vocabulary, but their presence in top-K means the question matched the doc's metadata beacon.

5. **Storage** (`DatabaseManager`): new columns on `documents` for the structured fields (title, authors as JSON, year, documentType, summary, extractedAt sentinel, detectedNonEnglish flag) so future library-wide queries — "show me all law review articles by this author" — can run as plain SQL instead of parsing the synthetic chunk's prose. `insertSyntheticChunk` is idempotent across re-extraction (deletes any prior chunk whose embedding_kind ends `:syn-meta` before inserting).

6. **Local-API verbs** (`LibraryView`): `GET_ASK_POSEY_HISTORY`, `GET_DOCUMENT_METADATA`, `LIST_SYNTHETIC_CHUNKS`, `RESET_DOCUMENT_METADATA`, `EXTRACT_METADATA_NOW`, `RUN_METADATA_CHAIN`. Used during the build-test-iterate loop to isolate failures (the AFM refusal was caught by `EXTRACT_METADATA_NOW`'s in-line error capture; the chain plumbing was validated via `RUN_METADATA_CHAIN`'s synchronous-await form).

**Decisions deferred (Phase A is shippable as-is):**

- **Progress ring on the sparkle icon + "Still learning... 47%" menu hint.** The back-end notifications are posted (`metadataEnhancementDidStart` / `…DidComplete` / `…DidFail`), just not wired to a view. Mark wants ONE unified ring covering all background-enhancement stages combined, not per-stage. Will land alongside Phase B (per-chunk contextual prepends, if measurement supports it) so the ring can roll up everything.
- **Non-English document notice.** `DocumentMetadata.detectedNonEnglish` is set via NLLanguageRecognizer at extraction time. Mark wants the UI to say "Posey is still studying [Mandarin] and isn't yet totally conversant" when a non-English document is opened in Ask Posey. Cheap to wire later.
- **Always-on summary toggle.** Mark and I disagreed (politely) on whether a 30-token summary in the system prompt would help or distract small on-device AFM. Rather than guess, build it as an internal DEBUG toggle and measure with the harness. Default OFF until data says ON. Skipped for v1 since the synthetic-chunk-in-RAG approach already covers the metadata-question case correctly.
- **Removing position-based front-matter prepend entirely.** The synthetic chunk now does what front-matter was doing, more cleanly. Keeping front-matter at relevance 0.30 as a fallback for now; can remove once we've validated across more queries.
- **Per-chunk contextual retrieval (Phase B).** The Anthropic-style per-chunk prepends. Mark's progressive-enhancement idea (reading-position-aware, library-wide background traversal, yield-on-AFM-needed) is the right shape if we go this route. **Won't decide until we measure** — the phrase "we both believe Phase B will be useful" was honest, but "useful" might be a 2% improvement that doesn't justify the engineering cost. Measure first.

Commits `6549dd2` (harness) → `18e2d35` (Phase A). Mark's Cloud-of-High-Tech-Copyright doc and AI-Book Collaboration doc are reindexed with the new pipeline; remaining docs (Illuminatus, Internet Steps) need a manual `REINDEX_DOCUMENT` per Mark's "delete + reimport, no migration code needed" directive — fast.

---

## 2026-05-05 (morning) — RAG diagnostic harness (foundation for today's chunking work)

Mark surfaced an AFM factual inversion bug yesterday: "What is an example of an advantage of using ADR?" returned "ADR is advantageous because it is often much more time-consuming than litigation" — the exact opposite of what the document says. Before fixing the prompt or blaming AFM, Mark asked the foundational question: do we even have a good chunking strategy? Honest read: no — fixed character-window cutting (500 chars short docs / 1000 chars long), 10% overlap, blind to sentence/paragraph/section boundaries, no contextual retrieval. Plausible mechanism for the inversion ("advantage of ADR is less time-consuming" could split between chunks while a different chunk talks about ADR's drawbacks including time).

Decided to instrument before guessing. Built a generalized RAG diagnostic harness, not a one-off ADR probe:

- **`DocumentEmbeddingIndex.searchHybridDiagnostic`** — production-mirror of `searchHybrid` that returns the score decomposition (cosine, lexical, entityBoosted, combined, rank) instead of collapsing into a single `similarity` field. Same scoring arithmetic; the two methods must not drift.
- **Local-API verbs** in `LibraryView`:
  - `RAG_TRACE:<doc-id>:<query>[:<topK>]` — top-K with full decomposition + full chunk text.
  - `RAG_FIND:<doc-id>:<keyword>` — case-insensitive substring search in plainText, returns every match offset and the chunk(s) that own those offsets ("ground-truth probe").
- **`tools/posey_rag_debug.py`** — Python orchestrator. Calls both verbs, optionally fires `/ask` via `--with-ask`, pretty-prints a trace, and emits a verdict that classifies the failure mode: `CHUNKING MISS` / `BUDGET MISS` / `PROMPT-OR-MODEL` / `RETRIEVAL OK`. Front-matter prepend (chunks 0-3 for short docs, chunk 0 for long docs ≥ 200K chars) is accounted for in the verdict so unanchored questions don't get false "chunking miss" calls when the answer lives in the forced front matter.

Smoke-tested on the AI Book Collaboration doc with "Who are the contributors to this book?" The harness already surfaced real signal: the top-10 organic ranking is dominated by thematically-AI-flavored chunks (ethics, AI as new species) while the actual contributor-list chunks (TOC region, chunks 2 and 13) don't rank organically. They only reach AFM via the front-matter prepend. The lexical signal is 0 across the entire top-10 because the user said "contributors," not "ChatGPT" / "Mark Friedlander" — exactly the kind of question where embedder thematic clustering and surface lexical scoring both miss.

Commit `6549dd2`. Next: run the harness on the ADR query and a handful of other "should be findable" questions before deciding what chunking redesign actually fixes the observed gaps.

---

## 2026-05-04 (evening) — Reader UX: tap-to-jump, persistent mini-player, background audio, Preferences simplification

Big batch of reader-side changes from a long working session with Mark, in roughly the order they landed.

**Ask Posey re-scope UI (post-MiniLM).** Took the 75% non-fiction clean-rate baseline that the MiniLM swap got us to and rebuilt the user-facing surface to make the smaller-but-real promise visible.
- First-use notice converted from a stacked modal sheet to an inline banner at the top of the conversation thread (one-tap dismiss, persisted via `@AppStorage` `Posey.AskPosey.firstUseNoticeDismissed`). The previous modal-on-modal was visually broken on iPhone Plus models because the parent Ask Posey sheet was at `.medium` detent (Plus reports `.regular` horizontal size class in portrait, fooling the previous size-class-based detent picker).
- Detent fix: replaced size-class check with `UIDevice.current.userInterfaceIdiom == .phone` so phones (including Plus) always get `.large` detent.
- Quick-actions menu replaces the failed pills strip. Pills truncated to "Ex...", "Defi..." on iPhone-width because four labeled pills don't fit horizontally with full text. A SwiftUI `Menu` gives each action full label space and follows iOS conventions.
- Chrome Ask Posey button is now a Menu (matches the previous two-choice menu pattern Mark recalled). One tap from reader → templated question started in the sheet:
  - "Explain this passage" → auto-submits "Explain this passage in context — what's it saying?"
  - "Define a term" → prefills composer with "Define " (user types the term)
  - "Find related passages" → auto-submits doc-wide search query
  - "Ask something specific" → opens the sheet with composer focused
- `AskPoseyChatViewModel.init` accepts `initialQuery` + `autoSubmitInitialQuery` so menu items wire through to a single sheet-open path.
- Per-message sources strip restored alongside inline `[ⁿ]` superscript citations (rescope spec called for both — granular per-claim citations PLUS at-a-glance source list).
- Composer placeholder shapes the workflow: "Ask about this passage…" when anchored, "Tap a sentence in the reader to ask about it" when not.

**Reader interaction model: single-tap-to-jump (genre standard).** Read-aloud apps (Voice Dream, Speechify, Pocket, Audible) use single-tap-on-text to jump reading position there, with persistent or auto-fade chrome triggered by a different mechanism. Posey was inverted (single-tap toggled chrome, double-tap was supposed to jump but had been removed in Task 8 #54 due to gesture conflicts). Switched to genre standard:
- Single-tap on a sentence row jumps reading position there.
- Tap-to-toggle-chrome removed.
- Chrome auto-fades after 3 s and re-reveals on scroll motion (preserved).
- Programmatic-scroll guard added — auto-scroll to follow highlight no longer triggers chrome reveal (was popping chrome on every sentence advance during playback).
- Mini-player added: when chrome auto-fades during playback, a single play/pause button stays visible (Voice Dream / Speechify / Audible all do this). Softened to 60% opacity so it doesn't pop against text. When playback stops via mini-player, full chrome reveals so user has all controls.

**Background audio (real fix, after long debugging).** Mark reported playback stopping on screen lock. The fix needed two layers:
1. AVSpeechSynthesizer's `usesApplicationAudioSession = true` — without this, the synthesizer routes through the system spoken-content audio session which doesn't honor `.playback` background config.
2. **The actual root cause:** `INFOPLIST_KEY_UIBackgroundModes = audio` in pbxproj does NOT inject `UIBackgroundModes` into the auto-generated Info.plist on this Xcode (verified by `PlistBuddy -c "Print :UIBackgroundModes"` on the built `.app` returning "Does Not Exist"). Tried unquoted, quoted, and array literal forms — none worked. Device log showed literal: `does not have background entitlement (or on watchOS, is not allowed to play in the background)` and `Sending stop command to com.MarkFriedlander.Posey ... because client is background suspended`. Fix: added a Run Script build phase that injects `UIBackgroundModes` via PlistBuddy after the auto-generated Info.plist is processed:
```
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
PlistBuddy Add :UIBackgroundModes array
PlistBuddy Add :UIBackgroundModes:0 string audio
```
Verified at build time and on device — background audio now continues with screen locked OR app minimized.

**Lock Screen / Dynamic Island controls — DEFERRED.** With background audio working, controls still didn't appear because `.interruptSpokenAudioAndMixWithOthers` includes mix-with-others semantics, and the system doesn't surface now-playing controls for mixable sessions. Tried switching to a non-mixing solo configuration to get controls — controls appeared but audio stopped after the queued utterance window finished and metadata cleared (likely SwiftUI deinit'ing ReaderViewModel on background, OR an AVSpeechSynthesizer + non-mixing-session interaction we didn't fully trace). Reverted to the mixable configuration for 1.0; background playback works without controls. Lock-screen controls deferred to future release pass.

Briefly built an `AudioFocus` preference (Solo / MixWithOthers) with a Toggle in Preferences to let users pick. Reverted in the same session — Mark and I agreed the trade-off is not yet worth the surface area, and the controls path was broken in non-obvious ways.

**Reader Preferences simplification.**
- Reading Style picker: Standard and Immersive removed for 1.0 (commented-out-not-deleted; kept in enum for parse-compat with persisted UserDefaults; reads of those values migrate to `.focus` on the getter). Default style: `.standard` → `.focus`.
- Old standalone "Motion Mode" Section (Off/On/Auto picker) replaced by an inline Toggle in the Reading Style section so it's visually grouped with the picker. The Off/On/Auto trichotomy collapses cleanly: "On" = Motion selected; "Off" = something else selected; "Auto" = the toggle.
- Per-style descriptions retained (dynamic, based on selection); redundant footer that listed all four styles removed.

**Smaller fixes that landed across the session.**
- Confidence signal: when MiniLM top-cosine retrieval is below 0.45 outside the front-matter band AND no anchor is present, short-circuit before AFM with an honest "I'm not finding a strong answer" message. Threshold tuned from real-conversation sweep data (0.50+ produced real answers; 0.40 produced fabrication; 0.45 catches fabrication band).
- Anchored-question quality batch: prompt builder reorders so SURROUNDING context comes after RAG (recency bias); asymmetric proximity window (1/3 before, 2/3 after — natural reader questions ask forward); section-boundary clipping (don't reach back across `\n---\n`, `\n\n##`, `\f`, triple-newline); skip front-matter prepend on anchored queries (front matter is noise for passage focus); grammatical-meta interpretation hint appended to short pronoun questions on anchored queries.
- Recommendation short-circuit (already shipped earlier today): "should I read this?" pattern → canned honest refusal before AFM is called.
- Role-question short-circuit (already shipped earlier today): "Who's the editor?" with no editor in doc → honest refusal that names the actual roles the doc DOES mention. Roles covered: editor, publisher, illustrator, translator, narrator, ghostwriter, typesetter, designer, photographer, screenwriter, director, producer.
- Polish call removed (already shipped earlier today). Restoration recipe preserved as inline comment in `AskPoseyService.streamProseResponse`.
- Verbatim-phrase fallback retrieval (added earlier today, then superseded by hybrid lexical+cosine retrieval in `searchHybrid`): kept as deprecated reference; not in runtime path.
- Diagnostic logging on AVAudioSession interruption + AVSpeechSynthesizer didCancel for tomorrow's lock-screen-controls debug pass (when we eventually return to it).

**Known issues / defer list:**
- Lock Screen + Dynamic Island controls — broken in solo mode, not present in mix mode. Defer.
- Reader deep-test (Task 5) across 7 formats — never executed methodically. Likely surfaces small bugs.
- Format parity remaining (Task 8): PDF inline TOC chunking, EPUB skip-until-offset, DOCX TOC fields, DOCX/HTML inline images, search-per-format, audio-export-per-format, reading-styles-per-format.
- Tomorrow: stress-test Ask Posey conversation memory persistence across question types and turns (Mark's request after the re-scope landed).

## 2026-05-04 — Ask Posey RAG Layer 2: MiniLM via CoreML; non-fiction scope

Two changes that ship together: (a) replaced the embedding model used for retrieval, (b) explicitly scoped Ask Posey to non-fiction in 1.0 with a first-use notification.

**RAG Layer 2 — MiniLM CoreML.** Per Mark's RAG-pipeline audit directive, A/B tested three embedders on the same 24-question non-fiction Three Hats sweep:
- NLEmbedding (Apple, current): 16/24 = 67% clean — cosine 0.07–0.30, weak discrimination.
- NLContextualEmbedding (Apple BERT, mean-pool): 15/24 = 63% clean — cosine 0.85–0.88 but uniformly clustered, even worse discrimination.
- **MiniLM CoreML (sentence-transformers/all-MiniLM-L6-v2)**: **18/24 = 75% clean** — cosine 0.25–0.40 with meaningful spread; surfaces correct chunks (DOCX "What chapter covers ethics?" → "Chapter 4: Ethical Considerations" at rank 3 from cosine alone).

MiniLM ships bundled (43MB fp16 mlpackage in `Posey/Resources/MiniLM/`). Default flipped via `EmbeddingProvider.coreMLMiniLM`. Old NLEmbedding path remains selectable via `SET_EMBEDDING_PROVIDER` API verb for benchmarking and fallback. Per-doc re-index via `REINDEX_DOCUMENT` migrates each doc's chunks to MiniLM at user-controllable timing.

New code: `MiniLMEmbedder.swift` (CoreML wrapper) + `BertWordPieceTokenizer` (~280 lines, hand-written, no third-party deps per CLAUDE.md). Sync-bridge from background indexing queue to `@MainActor` model singleton.

Tradeoffs: +43MB bundle, ~25s reindex per 148K-char doc, max seq 128 tokens (truncation at chunk tail accepted). See DECISIONS.md "MiniLM (CoreML) Replaces NLEmbedding" for full rationale, alternatives considered, and restoration recipe.

**Non-fiction scope.** Ask Posey is now explicitly a non-fiction reading assistant in 1.0. Fiction (Illuminatus EPUB) hits AFM safety refusals + narrative-context failures that don't respond to the same fixes that work for non-fiction. Optimizing fiction would require different retrieval (scene-level chunking, character-aware retrieval) and prompt framing (narrative summarization). Deferred to post-1.0.

User-facing: `AskPoseyFirstUseSheet` shown once on first Ask Posey open, dismissal stored in `UserDefaults` under `Posey.AskPosey.firstUseNoticeDismissed`. Voice: warm and direct ("I do my best work with non-fiction. Essays, articles, reference material — that's where I shine. Fiction is trickier for me, but give it a try if you're curious."). One tap to dismiss, never shown again. No format-level gating — user can still open Ask Posey on a novel; they're just informed first.

Test policy: Three Hats sweep contracts to 6-format non-fiction (TXT/MD/RTF/DOCX/HTML/PDF). EPUB stays in corpus for import / TTS / notes regression testing but excluded from Ask Posey clean-rate scoring.

**Layer 1 cleanup (earlier in same session).** Sanitize chunks at index time: strip Wayback Machine print headers, dot-leader runs, trailing page numbers from short lines. Preserves structural info (chapter listings, role assignments) while removing TOC noise. Initial skip-only approach measured 61% (regression from 71% pre-fix because chunk-skip nuked structural info); clean-not-skip recovered to 67% baseline. Then MiniLM lifted to 75%.

**Layer 2 (NLContextualEmbedding) tested but not adopted.** Documented as a measured negative result. Selectable for future experimentation via the same provider switch.

**API verbs added (development-only):** `LIST_CHUNKS`, `EMBED_QUERY`, `EMBED_QUERY_CONTEXTUAL`, `REINDEX_DOCUMENT`, `SET_EMBEDDING_PROVIDER`, `GET_EMBEDDING_PROVIDER`. The first three are read-only; the latter three drive the audit + comparison loop.

## 2026-05-04 — Ask Posey: Polish call removed (temporary)

Removed the second AFM call from the Ask Posey two-call pipeline. The grounded call (factual, low temp) now streams to the user verbatim. The polish call (voice, higher temp) is no longer invoked at runtime.

**Why.** Six rounds of polish-prompt iteration and five rounds of regex post-strips never closed the voice-failure rate below ~50%. AFM does not consistently honor the polish prompt's HARD RULES — recommendations leak past HARD RULE 4, "X is like Y" metaphors leak past HARD RULE 5, sycophant openers ("Sure!", "Of course!") and preamble announcements ("Here is a rewrite of…") leak past HARD RULE 3. Length inflation against HARD RULE 6 is roughly 1-in-5. In rare cases (~3%) the polish prompt's FAILED:/SUCCEEDED: example tokens leak into output.

Polish was net-negative on quality: grounded was reliable, polish was a coin flip. Removing polish eliminated an entire class of failures cleanly. Verified across 7-format Three Hats QA — see Three Hats Polish-Off Sweep below.

**Tradeoff.** Posey's tone is now more clinical. The earlier position ("a robotic Posey is a failed Posey", 2026-05-02) is explicitly walked back. Correctness > warmth when AFM can't carry voice consistently. Restore when AFM (or its successor) can honor a voice prompt at >90% on the same Three Hats sweep.

**What changed.**
- `AskPoseyService.streamProseResponse` — replaced the `if refusalShapeFinal { stream grounded } else { polish }` block with unconditional verbatim stream of `groundedFinal`. Restoration recipe preserved as inline comment block at the call site.
- `polishTemperature`, `AskPoseyPromptBuilder.polishInstructions`, `polishPromptBody`, and the `stripPolishPreamble` chain remain in the codebase as inert reference. Nothing to rebuild on restoration.
- DECISIONS.md got a full entry documenting reasoning, voice vision, every observed failure mode, both prompts verbatim, the full pipeline architecture, and revisit conditions.

**Three Hats Polish-Off Sweep (28 questions across 7 formats).** Real natural conversations with follow-ups, not a matrix script. Per-format clean/partial/broken counts:
- TXT (AI Book): 3/1/0
- MD (Hal Agenda): 2/0/2 — RAG miss + AFM filled in fake section names
- RTF (AI Book): 4/0/0
- DOCX (AI Book): 3/0/1 — RAG miss on "job displacement" (verbatim in doc at offset 37021)
- HTML (AI Book): 3/1/0
- EPUB (Illuminatus, 1.6M chars): 2/0/2 — incoherent grounded ("accused of being a doctor"); Law of Fives RAG miss
- PDF (Internet Steps): 3/1/0 — concatenated "Anonymous Mark Friedlander" (source layout artifact)

Total: **20 clean / 4 partial / 4 broken = 71% clean rate**. Compare to Task 3 v1 (polish ON, six rounds of iteration): 4/29 = 14%. Net improvement: ~5×.

**Voice failure modes ELIMINATED (zero observations across 28 questions):** sycophant openers, outside-of-document recommendations, "X is like Y" metaphors, slang, preamble announcements, length inflation, HARD RULE example-token leaks, "I think…" hedging in confident answers.

**Remaining failure modes (all in the grounded path, NOT polish-related):**
1. **RAG misses on long/dense docs.** Specific keyword questions on >100K char docs miss when the embedding doesn't surface the relevant chunk. "Job displacement" is in the DOCX at offset 37021; AFM said "doesn't mention." "Law of Fives" appears dozens of times in the 1.6M char EPUB; AFM said "doesn't mention." Retrieval problem, not prompt problem.
2. **Hallucinated structure.** When asked to list things, AFM sometimes invents items beyond what RAG returned (MD Q2 listed 5 sections, 2 of them ("MLX HelPML Output Quality", "Design a Robust Parser") don't exist).
3. **Incoherent grounded output on dense narrative.** EPUB Q1 "accused of being a doctor" — word salad. Polish was masking grounded fragility on literary text.
4. **Source-layout concatenation.** PDF Q2 "Anonymous Mark Friedlander" — the doc has "Information wants to be free.… - Anonymous Mark Friedlander Telecommunications Law…" with no delimiter; AFM concatenated.
5. **Mild over-interpretation.** TXT Q3 extended slightly beyond the TOC excerpt; HTML Q2 understated consciousness coverage when the doc explicitly raises it.

These remaining issues need separate workstreams (retrieval improvements; possibly a "DON'T FILL IN STRUCTURE" addition to the grounded prompt; source-cleanup for PDF byline parsing). Logged in NEXT.md. Not blockers for App Store submission — quality issues with honest mitigations (refusals are honest, not invented), not correctness regressions vs. polish-on.

**Source.** Mark's directive 2026-05-04 — "Remove the polish call entirely. The voice layer is not consistently achievable with the current model and is actively harming answer quality. This is not a permanent decision — it's the right call for now."

## 2026-05-03 — Task 4 #9 + #10: parallel pairwise STM mode + live sheet updates

Completes Mark's Task 4 punch list. #1–#8 landed earlier (commits `121479b`…`cdf2584`); this entry covers #9 and #10 plus the test-suite repair the prior fixes left behind.

**#10 Live sheet updates.** When the local-API `/ask` ran while the Ask Posey sheet was open, the sheet's separate (visible) view model didn't see the new Q/A — the user had to dismiss and reopen. Added `Notification.Name.askPoseyConversationDidUpdate`, posted by every `persistTurn` and `flushPendingAnchorPersistIfAny` call, with `documentID` + `originator` (the posting VM's `id`) in userInfo. Every `AskPoseyChatViewModel` observes; matching documents whose originator differs reload via `loadHistory()`. Self-originated posts are ignored via the originator check.

**#9 Parallel pairwise STM mode.** Implemented as an opt-in alternative to the existing verbatim STM rendering. New file `AskPoseyPairwiseSummarizer.swift`:
- Per Q/A pair → tiered third-person summary (4 sentences for the most recent pair, 2 for the next, 1 for older).
- New protocol method `AskPoseySummarizing.summarizePair(...)` driven by AFM at temp 0.2 with explicit faithfulness rules.
- Embedding verification: every summary sentence's max cosine vs. the verbatim Q+A reference set must clear `verificationThreshold = 0.45`. Failing sentences trigger a one-shot AFM rewrite with the worst-failing sentence quoted back as guidance. Sentences that still fail are dropped — Posey would rather lose a sentence than ship a hallucinated one.
- Memoized cache keyed by `pairKey + targetSentences` so stable older pairs don't re-summarize.
- Per-call stats (`AskPoseyPairwiseStats`) cover pairs total/cached/summarized/rewritten and sentences produced/flagged/dropped — surfaced via the local-API `/ask` response (`pairwiseStats` field) for direct comparison.

**Mode selection.** `AskPoseyChatViewModel.useSummarizedSTM` defaults to `false` (production UI keeps verbatim mode). Local-API `/ask` body field `summarizationMode: "pairwise"` flips it for one call. Both pipelines stay in place per Mark's directive — comparison data review happens when Mark returns; default selection deferred to that review.

**Prompt-builder integration.** `AskPoseyPromptInputs` gains `pairwiseSummaries: [String]?`. When non-nil, `renderPairwiseSTMBlock` swaps in for `renderSTMBlock` with the same drop semantics (oldest pair drops first under budget pressure). Verbatim path untouched.

**Test repair.** Earlier Task 4 fixes (`#2`, `#3`, `#4`, `#5`) shipped without updating their unit tests; caught when running the full suite for #9/#10. Repaired:
- `AskPoseyTokenEstimatorTests` — chars/token = 2.5 (was 3.0) per #3.
- `AskPoseyConversationsCRUDTests.testFreshDocumentStartsWithAnchorMarker` and `testMultipleInvocationsAccumulateAnchors` — anchor persistence is now deferred to first user send per #4; tests call `flushPendingAnchorPersistIfAny()` to simulate.
- `AskPoseyPromptBuilderDropTests.testSTMOverflow_DropsOldestTurnsFirst` — STM rendering is user-questions-only since #2's third iteration; assertion checks the most-recent USER turn survives and oldest USER turn drops.
- `AskPoseyPromptBuilderDropTests` (renamed `testUserQuestionTruncation_LastResort` → `testUserQuestionNeverTruncated`) — #2 made the user question non-droppable; assertion inverted.
- `EPUBFrontMatterDetectorTests.testStopsAtFirstNonMatchingItem` renamed/rewritten to `testFlagsAllFrontMatterCandidatesEvenWhenInterleaved` per #5's "scan all candidates" change.
- `EPUBImportFrontMatterIntegrationTests` — front matter is now stripped from `plainText` per #5; checks the disclaimer body is absent and the synthesized TOC excludes the notice. Required a real fix in `EPUBDocumentImporter`: the synthesized-TOC filter previously relied on `skipUntilOffset > 0` (always 0 because front-matter candidates are passed at offset 0); now filters spine items by `frontMatterHrefs` before synthesis.

Verified: `xcodebuild test` (iPhone 17 sim) — TEST SUCCEEDED. Device tests deferred until Mark returns.

## 2026-05-02 — Task 2: Ask Posey UI bug fixes (markdown, sources persistence, inline citations, motion)

Four issues in Mark's Task 2 list, all fixed and verified on device.

**#23 Markdown rendering.** AskPoseyMessageBubble used `Text(message.content)` (the plain-string init) — `**bold**` showed as literal asterisks. Switched to `Text(.init(...))` (LocalizedStringKey form) which auto-parses bold, italic, code, links. Added `.tint(.accentColor)` so links render in the accent color.

**#24 Sources persistence.** `translateStoredTurn` was discarding the persisted `chunks_injected` JSON when reconstructing AskPoseyMessage from SQLite — every assistant reply lost its sources after the user dismissed and re-opened the sheet. Decode the JSON back to `[RetrievedChunk]` and pass through.

**#25 Inline superscript citations (Perplexity-style).** The biggest piece. Replaced the bottom "SOURCES 1·87% 2·64%" pill strip with inline `[ⁿ]` superscripts inside the answer text. Three layers:

1. **Prompt change.** Moved the "INLINE CITATIONS" instruction to the TOP of `proseInstructions` as the "MOST IMPORTANT RULE — NON-NEGOTIABLE", and added a second short reminder immediately above USER QUESTION (trailing-position rules tend to land better on AFM than rules buried mid-prompt). The grounded call now reliably emits `[N]` on factual questions. Polish call's `polishInstructions` got a "PRESERVE INLINE CITATION MARKERS" rule at the top with explicit examples.

2. **Polish-skip guard for short answers.** Even with the preserve rule, polish strips markers from short factual answers at temp 0.65. So when grounded both (a) has at least one `[N]` and (b) is < 300 chars, skip polish entirely and stream grounded verbatim. Voice doesn't add much to a 60-char factual sentence anyway.

3. **Embedding-based attribution fallback.** New `DocumentEmbeddingIndex.attributeCitations(text:chunks:documentID:threshold:secondCitationDelta:)` — for each sentence in the assistant response, embed the sentence into the same NLEmbedding vector space the M2 index uses, score against every chunk in `chunksInjected` via cosine similarity, append `[N]` when the best score clears 0.4. Multi-cite as `[1][3]` when the second-best is within 0.05 of the best AND also clears threshold. AFM-emitted markers take priority (no embedding attribution runs when the raw text already has any `[N]`). Per-sentence scores logged via NSLog so the threshold can be tuned without code changes. Cost: ~10–15ms per typical answer on iPhone 16 Plus, imperceptible.

Renderer: new `AskPoseyCitationRenderer` regex-replaces `[N]` in the assistant body with `[ⁿ](posey-cite://N)` markdown links — unicode superscript display, custom URL scheme. The bubble computes this on every render. `.environment(\.openURL, OpenURLAction { ... })` at the AskPoseyView root intercepts `posey-cite://N`, scans messages newest-first to find an assistant turn with at least N chunks (so a follow-up's citations resolve against ITS chunks not an older reply's), then calls `onJumpToChunk` with the chunk's offset and dismisses. Old sourcesStrip removed from threadRow.

Real-answer scores in testing: 0.58–0.76 against in-document chunks — plenty of headroom over the 0.4 threshold. Threshold tunable.

**#26 Motion permission.** Two fixes: (a) `MotionDetector` no longer eagerly instantiates `CMMotionActivityManager` / `CMMotionManager` at init — both lazy, constructed inside `start()` AFTER the consent guard. Eliminates any path where stray instantiation could trigger the iOS permission dialog at launch. (b) `motionPreference` didSet now auto-presents the in-app consent sheet the moment the user picks Auto without prior consent — one tap not two. Default `motionPreference` is `.off` (already, confirmed).

**Commits this task:** `1100a82` (markdown + sources + motion + initial citation infra), `86279b7` (citation reliability via prompt + polish-skip + string-overlap fallback), `b947682` (embedding-based attribution replacing string overlap).

## 2026-05-02 — Remote-control API surface complete + Step 7 scroll fix + Task 1 verification

**Task 1 verification (all 8 steps PASS).** Drove the unified annotation system end-to-end on Mark's iPhone 16 Plus via the local API + new remote-control verbs. Anchor tap-jump (Step 4), doc-scope title marker (Step 5), Notes sheet showing 3+ conversation icons (Step 6), conversation entry → Ask Posey (Step 7 — see scroll fix below), note expand-inline + jump (Step 8), bookmark navigate (Step 9), all three types coexisting chronologically (Step 10), double-tap moves highlight + playback position (Step 15) — all verified with real AFM data (3 passage + 1 doc-scope conversations) created via real `/open-ask-posey` + `/ask` flows, real notes/bookmarks created via real `CREATE_NOTE` / `CREATE_BOOKMARK` flows that go through `ReaderViewModel.saveDraftNoteForCurrentSentence` / `addBookmarkForCurrentSentence`.

**Step 7 scroll fix (bug surfaced during verification).** Tapping a conversation entry from Saved Annotations was opening Ask Posey scrolled to the FIRST anchor in the thread instead of the tapped one. Single 120ms-delayed `proxy.scrollTo(target.id, anchor: .top)` ran before the LazyVStack realized the target row's frame; proxy silently no-op'd and the natural top (oldest anchor) stayed visible. Three-stage scroll (immediate / +200ms / +250ms with animation) plus `.onAppear` backstop for the case where `loadHistory` finished before the ScrollViewReader mounted. Same pattern ReaderView's initial scroll uses. Verified on two distinct anchors (offsets 6422 and 19134) — sheet now opens scrolled to the correct anchor.

**Remote-control API surface — built per Mark's directive.** Mark's standard: "the API must be able to do everything a human can do that isn't blocked by Apple security policies." Initial gap audit identified missing playback transport, sheet opens, preferences setters, search, page jump, audio export, library navigation, and a generic TAP that worked on SwiftUI controls. Built all of it.

- **`Posey/Services/LocalAPI/RemoteControl.swift` (new):** notification names for every user intent (~30), MainActor `RemoteControlState` cache for `READER_STATE`/`PLAYBACK_STATE`, window-tree walker, accessibility-tree dumper, `SCREENSHOT` via `UIGraphicsImageRenderer` (works on device, no `tunneld` needed), and the **`RemoteTargetRegistry` + `.remoteRegister(_:action:)` modifier** — the long-term fix for SwiftUI iOS 26's broken accessibility-id bridging. Each interactive control registers its action closure under the same id its `accessibilityIdentifier` used to use; `TAP:<id>` fires the registered closure (registry-first, UIView-tree fallback for any UIKit-level controls that didn't register).
- **`Posey/Services/LocalAPI/RemoteAudioExportRegistry.swift` (new):** headless audio-export driver. `EXPORT_AUDIO:<docID>` segments the document via `SentenceSegmenter`, applies the user's current voice mode from `PlaybackPreferences`, runs `AudioExporter.render(...)`, bridges the exporter's published state into a job snapshot the API can poll. `AUDIO_EXPORT_STATUS:<jobID>` returns rendering progress; `AUDIO_EXPORT_FETCH:<jobID>` returns the M4A file bytes (base64) when finished. Verified on device — Custom voice mode, AI Book Collaboration Project, rendering at 64 of 1382 segments after 3 seconds with no UI sheet open.
- **Verb dispatch in `LibraryViewModel.executeAPICommand` (~600 lines added):** `READER_GOTO`, `READER_DOUBLE_TAP`, `READER_STATE`, `OPEN_NOTES_SHEET`, `OPEN_PREFERENCES_SHEET`, `OPEN_TOC_SHEET`, `OPEN_AUDIO_EXPORT_SHEET`, `OPEN_SEARCH_BAR`, `OPEN_DOCUMENT`, `LIBRARY_NAVIGATE_BACK`, `DISMISS_SHEET`, `CREATE_BOOKMARK`, `CREATE_NOTE`, `TAP`, `TYPE`, `READ_TREE`, `SCREENSHOT`, `TAP_ASKPOSEY_ANCHOR`, `TAP_SAVED_ANNOTATION`, `TAP_JUMP_TO_NOTE`, `SCROLL_NOTES`, `LIST_SAVED_ANNOTATIONS`, `LIST_REMOTE_TARGETS`, `PLAYBACK_PLAY/PAUSE/NEXT/PREVIOUS/RESTART/STATE`, `SET_VOICE_MODE`, `SET_RATE`, `SET_FONT_SIZE`, `SET_READING_STYLE`, `SET_MOTION_PREFERENCE`, `JUMP_TO_PAGE`, `SEARCH`, `SEARCH_NEXT`, `SEARCH_PREVIOUS`, `SEARCH_CLEAR`, `EXPORT_AUDIO`, `AUDIO_EXPORT_STATUS`, `AUDIO_EXPORT_FETCH`, `ANTENNA_OFF`. All in the established notification-based dispatch pattern.
- **Observers in `ReaderView` split across 5 ViewModifier structs** to stay under SwiftUI's type-checker budget (`ReaderRemoteControlAnnotationObservers`, `…PlaybackObservers`, `…SheetObservers`, `…PreferencesObservers`, `…SearchObservers`). Plus dismiss observers added to NotesSheet, AskPoseyView, ReaderPreferencesSheet, and TOCSheet — `DISMISS_SHEET` is generic and works on any presented sheet.
- **`.remoteRegister` wired across every Button** in Library (apiToggle, importTXT, document rows), Reader chrome (search, toc, preferences, notes, askPosey), Reader transport (previous, playPause, next, restart), Notes (save, bookmark, every saved-annotation row, every jump-to-note button), Ask Posey (Done + per-anchor rows with scoped ids `askPosey.anchor.<storageID>` for disambiguation), Preferences (Export Audio, Motion Consent Review), TOC (Go button), Search (previous, next, clearQuery, done). Non-tap controls (sliders, pickers, text fields) intentionally still use bare `.accessibilityIdentifier` — they have dedicated SET_* / TYPE verbs.

**End-to-end verification on device.** Beyond the Task 1 steps: `OPEN_DOCUMENT` navigated to AI Book; `LIBRARY_NAVIGATE_BACK` returned to library; `JUMP_TO_PAGE:<docID>:5` and `:8` on Internet Steps PDF jumped to offsets 11992 and 22815 respectively; `PLAYBACK_PLAY` → state=playing, `PLAYBACK_PAUSE`/`NEXT`/`PREVIOUS`/`RESTART` all moved sentence index correctly; `OPEN_PREFERENCES_SHEET` + `SET_FONT_SIZE:30` + `SET_READING_STYLE:focus` + `DISMISS_SHEET` round-tripped; `SEARCH:Turing` returned 12 matches, `SEARCH_NEXT` advanced position, `SEARCH_CLEAR` deactivated; `TAP:reader.notes` and `TAP:reader.preferences` both fired the registry path (`"via": "registry"`) and opened the corresponding sheets. `EXPORT_AUDIO` started, status reported `rendering` with progress.

**Doc updates.** `DECISIONS.md` adds two entries: "Local API Is The Full Remote-Control Surface" (the standing standard) and "RemoteTargetRegistry For Generic Tap Dispatch (Option C)" (the architecture pick — three options weighed, registry chosen because SwiftUI's accessibility bridging on iOS 26 is unreliable enough that walking the UIView tree can't drive controls).

**Commits this session:** `d10dd31` (Task 1 + remote-control infra + Step 7), `23e8d15` (`.remoteRegister` wiring), `ad2a89b` (TAP routes through registry first), `4e91291` (dismiss observers on Preferences + TOC), and the doc commit at session end.

## 2026-05-02 — Autonomous device screenshot evaluation: deferred, hybrid approach kept

During Task 1 setup attempted to enable autonomous device screenshots so verification artifacts from Mark's iPhone wouldn't require Mark's manual intervention. Installed `libimobiledevice` (brew) and `pymobiledevice3` (pipx). Neither works for our use case: `idevicescreenshot` is broken on iOS 17+ (Apple moved screen capture out of the lockdown surface), and `pymobiledevice3 developer dvt screenshot` requires a sudo'd `tunneld` that the bash sandbox can't start non-interactively. Deferred via Mark's directive — sticking with the hybrid approach: simulator screenshots for layout verification (same SwiftUI source as device), `qa_battery.sh` + `/ask` for AFM pipeline verification, Mark's eyes on the iPhone for final visual sign-off. Both tools are inert on disk; removal instructions captured in DECISIONS 2026-05-02.

## 2026-05-02 — Integrated UI QA pass on real device + voice polish v2 + doc-scope orphan fix

Mark called out that the previous Three Hats QA pass had been API-only — `/ask` round-trips evaluated against the persisted-text response, never opening the actual sheet, never looking at a screenshot, never driving the integrated UI experience the way a user would. He'd just spent an hour testing manually on device and found scroll bugs, missing anchors, flat voice responses, and UI issues that should have been caught before he picked up the phone. Per his note: I had every tool needed (`/ask`, `/open-ask-posey`, simulator MCP) and didn't use them.

This session drove the integrated test on Mark's iPhone (per his "use real hardware when you can" follow-up). Discovered + traced + fixed five distinct issues:

**1. Voice flat across terse factual questions.** Mark's "flat voice" complaint reproduced cleanly — AI Book Q1/Q2/Q3 all returned essentially-grounded text with no librarian-DJ texture. Code inspection of `polishInstructions` revealed 6 DON'Ts (don't pad, don't add detours, match length, etc.) and 0 explicit DOs. The persona at the top was being out-voted by the constraint stack. Polish prompt rebalanced: explicit "WHAT TO DO" section (sentence rhythm, contractions, conversational openers, structural mirroring), tightened metaphor guardrail with named failure-mode examples ("X is like a DJ", "Y is like a dance" — first 0.65 attempt produced these on every multi-sentence answer), three concrete grounded → voice example pairs to demonstrate length-preserving voice rewrites. Temperature 0.55 → 0.65; refusal-shape guard already prevents fact invention on out-of-doc questions so the higher temp is safe. Verified post-fix: AI Book Q1 *"Four contributors: Mark Friedlander, ChatGPT, Claude, Gemini."* (verbatim match to the example in the prompt — voice landed); Internet Steps Q1 *"This paper dives into the mp3.com saga, looking at how the RIAA and mp3.com clashed over copyright, fair use, and the Internet's role in the music industry."* (voice clearly emerged on substantive grounded text). Voice variance is high — same prompt + same temp produced flat output earlier in the session and voice-rich output later, on identical questions. Per Mark's note about AFM tuning ceilings: try, but recognize when over-tuning. The voice now LANDS reliably on substantive answers; terse factual answers stay tepid because polish can't manufacture voice from a six-word draft without padding.

**2. Q3 follow-ups absurdly terse.** *"Following from copyright, does the document mention DMCA?"* → *"It does."* Cause: the no-prior-replies rule (we hide previous Posey answers from prompt context to prevent template imitation) means the grounded call sees a follow-up question with no continuity from the prior answer; "It does" is technically correct, useless to the user. Tried a fix in `proseInstructions`: "Bare yes/no answers are almost always wrong WHEN the document covers the topic." First iteration improved Q3 dramatically (*"The document does discuss the DMCA, specifically its implications for ISPs and copyright holders…"*) but caused a Q4 hallucination on Internet Steps — *"Mark Friedlander is the author's spouse"* — because Mark IS the author of that paper (front-matter chunks legitimately contain his name), and the elaborate-the-answer rule encouraged the model to invent a relationship. Tried tightening with a counter-rule ("don't invent elaboration when document doesn't cover topic"); produced contradictory output (*"The document doesn't mention DMCA. It discusses the Digital Millennium Copyright Act…"*). Reverted entirely. Per Mark's directive on AFM ceilings, terse Q3 follow-ups now logged as a model-capability ceiling rather than over-tuned.

**3. Document-scope sheet felt orphaned.** Nav title was just *"Ask Posey"* with no doc context, and the anchor row only renders for passage scope (`if let anchor != nil`). Document-scope opens left the user with a sheet that had no visible link to the document being read. Fix: `AskPoseyChatViewModel` now carries `documentTitle` (optional, defaults nil for older test/preview callers — "Ask Posey" fallback). `AskPoseyView` nav bar shows the title. New `documentScopeRow` substitutes for the anchor row when `anchor == nil` — same visual style (thin material rounded rect, leading icon) showing *"ASKING ABOUT / [Title] / the whole document"*. Both rows share `anchorRowID` so the on-appear scrollTo works regardless of scope.

**4. /ask response missing classified intent.** HISTORY claimed `intent` was returned; actual `apiAsk` payload never set it. `AskPoseyChatViewModel` now exposes `lastIntent` (set in `finalizeAssistantTurn` alongside `lastMetadata`). `apiAsk` reads it into the payload as `intent` so test runners can see what the classifier picked.

**5. Anchor scrolls out of view + scroll-anchor races.** Read-only finding from code inspection — the `.defaultScrollAnchor(.bottom)` + explicit `proxy.scrollTo(anchorRowID, .top)` after 180ms fight each other. As soon as a new message streams in, the bottom anchor wins and the anchor row scrolls off-screen above. The 180ms delay also races against history-load completion. **Not yet fixed in this commit** — the fix is non-trivial (sticky-pin anchor outside ScrollView) and worth confirming the symptom from a screenshot before changing scroll behavior. Logged in NEXT.md as next pass.

**Test-tooling fix.** `tools/qa_battery.sh` AI_BOOK doc ID was stale after Mark's clean re-import (B2A84DC8 → E5C815A6). Updated. Future-proofing — switching to title-based lookup vs hard-coded UUIDs — logged in NEXT.md.

Three commits this session: `eeae1da` voice polish rebalance + qa_battery doc ID; `4624e05` doc-scope context row + nav-bar title + /ask intent. Anchor-scroll fix deferred pending Mark's screenshot confirmation.

## 2026-05-02 — Cascade-delete end-to-end verification before clean re-import

Mark wanted to delete and re-import the AI Book to get a clean test baseline. Before he did, audited cascade coverage and added an end-to-end test exercising actual deletes (the existing schema-migration test only checked the FK contract via `PRAGMA foreign_key_list`).

Audit findings: every `CREATE TABLE` that references `documents(id)` includes `ON DELETE CASCADE`, and `PRAGMA foreign_keys = ON` is set on connection open. `deleteDocument(_:)` is a single `DELETE FROM documents` — the cascade does the rest. **No fixes needed; coverage was already complete.**

Tables verified: `reading_positions`, `notes`, `document_images`, `document_toc`, `ask_posey_conversations` (M1 + M5 columns + summary rows with `is_summary=1`), `document_chunks` (M2). New `PoseyTests/CascadeDeleteEndToEndTests` seeds real data into all 6 child tables, runs `deleteDocument`, asserts every child count drops to zero. Passes on iPhone 17 simulator. If a future schema migration adds a new `document_id`-referencing table, extend this test to cover it.

## 2026-05-02 — AFM cooldown — standing test-harness requirement

Sustained sequential `/ask` calls put AFM into a `Code=-1 (null)` error state where every subsequent call fails until Posey relaunches. Per Mark, the fix is testing-side, not app-side — real users naturally pause between questions; the harness should imitate that pacing. Treat AFM exactly like any rate-limited third-party API.

**`tools/posey_test.py`** — new `_ask_cooldown()` helper inserts 2.5s ± 500ms jittered sleep before each `/ask`. Tunable via `POSEY_TEST_COOLDOWN_SECONDS` and `POSEY_TEST_COOLDOWN_JITTER`; disable with `POSEY_TEST_NO_COOLDOWN=1` for one-shot tests only. Module docstring documents the contract.

**`tools/qa_battery.sh` (new, executable)** — promoted the ad-hoc `/tmp/qa_test.sh` into the repo as the canonical Three Hats QA driver. Pulls config from `tools/.posey_api_config.json` so it stays in sync with `posey_test.py`. Runs the standard 4-question pattern (factual / connection / follow-up / not-in-doc) across the three pinned documents (AI Book, Copyright PDF, Internet Steps PDF) with cooldown built into each call.

**CLAUDE.md** — new "AFM Cooldown" section under Three Hats. Explicit "do not 'fix' this by adding rate-limiting to the app itself; the app is correct, the harness is the place for politeness."

End-to-end verification post-cooldown: 12/12 questions across 3 documents, **zero AFM errors.** Voice quality intact (Internet Steps Q1: *"So, this document is about the whole mp3.com thing, right? Yeah, it's a scholarly paper that dives into the legal and tech stuff... It's a pretty interesting read, if you're into that sort of thing."* — librarian-DJ).

## 2026-05-02 — Two-call voice polish pipeline + refusal retry + classifier fallback

Three independent improvements driven by Mark's feedback after the first Three Hats QA pass: voice was too cold at temp 0.1, AFM refusals weren't being retried, and the classifier itself was sometimes refusing before the prose retry could fire.

**Two-call pipeline (MicroDoc-style summarize → polish):**
- Call 1 GROUNDED at temp 0.1 — accuracy first, no streaming to user. The grounded text isn't what the user sees.
- Call 2 POLISH at temp 0.55 — Posey's voice (warm, slightly irreverent, librarian-DJ), streams to user.
- Polish system prompt establishes character explicitly: *"the kind of person who reads obscure passages between DJ sets on a pirate radio station: engaged, occasionally playful, deeply knowledgeable, never stiff"*.
- Non-negotiable rules: keep every fact, **match the draft's certainty** (no hedges when grounded was confident), **match the draft's length** (no rambling), no preamble openers ("Sure! / Great question!"), expressive phrasing welcome but no factual claims dressed up as metaphor.
- Tuning iterated through 0.7 → 0.5 → 0.4 → 0.55: 0.7 produced metaphor drift ("the wild party of the Internet"), 0.5 invented facts (an ISBN), 0.4 flattened voice ("That's a tough one. I don't know if..."), 0.55 settled the balance.

**Refusal-shape guard before polish:** if the grounded answer is a not-in-the-document response (`"doesn't say"`, `"isn't mentioned"`, `"not in the document"`, etc.), skip polish entirely and stream grounded verbatim. Closes a hallucination hole found in real Q&A: at temp 0.5 the polish call invented an ISBN ("978-0-14-115136-5") when grounded correctly said "doesn't say."

**Refusal retry (Mark's three-step pattern):**
1. Try → grounded call at 0.1.
2. On `.refusal` → retry once with `AskPoseyPromptBuilder.neutralRephrasingPromptBody` — the user's original question is QUOTED verbatim (preserving intent), wrapped in a fact-finding frame ("please summarize the relevant factual information the document excerpts above provide that bears on this question"). User intent preserved; only the surrounding framing shifts.
3. If retry also refuses → throw `informativeRefusalFailure` → chat view model surfaces *"Posey had trouble with that one. Try asking about a specific passage or a more concrete aspect of the topic."*

**Belt-and-suspenders refusal detection.** `if case .refusal = g` was silently failing on AFM's macro-generated enum case in this Swift toolchain; the typed-pattern check now combines explicit `switch g { case .refusal: ... }` with stringified payload checks (`"\(g)".contains("refusal(")` lowercased fallback) so the retry path fires reliably. Logged via NSLog for device-side debugging.

**Classifier-refusal fallback.** AFM was sometimes refusing the *classifier* call itself for sensitive-content questions, before the prose retry could fire. Real example: *"How does Mark's role compare to the AI contributors?"* — classifier refused; user got the raw refusal error before the prose retry path could engage. Fix: classifier-refusal in the chat view model silently falls back to `.general` intent. The classifier is internal infrastructure — its refusals shouldn't surface as hard user-facing failures. Other classifier errors (transient, AFM unavailable) still surface via `handleSendError`.

**`/ask` response now includes `fullPrompt`** so the test harness can debug answer-quality failures without a second query.

End-to-end Q&A on three documents, post-pipeline: voice appears reliably on narrative questions (Q3 follow-ups, Q1 broad summaries), stays clean on terse factual answers (Q1 authors → simple list with no over-polish), refusal-shape guard prevents hallucinated facts on out-of-doc questions. Polish call once spontaneously incorporated the librarian-DJ metaphor from the system prompt: *"It's like having a DJ who knows the set, keeps the energy up, and makes sure everyone gets a chance to shine."*

## 2026-05-02 — Three Hats QA pass on real conversations across 3 documents

Mark's standing requirement (CLAUDE.md section added this session): every feature must pass three hats — Developer (it builds, tests pass, architecture right), QA (it works, edge cases tried, verified visually), User (would a real person trust it?). For Ask Posey specifically: real multi-turn conversations on at least three documents, factual / connection / follow-up / out-of-doc question types per document, before declaring any milestone done.

Drove the full pattern on AI Book Collaboration Project (RTF, 148K), The Clouds Of High-tech Copyright Law (PDF, 21K), and The Internet Steps to the Beat (PDF, 51K). Mark's exact prediction held — *"Who are the authors?"* on the AI book initially returned *"the document does not specify the authors"* exactly as he warned. Then iterated. Each failure mode found got a root-cause fix:

1. **Front-matter retrieval miss.** Cosine ranks "Who wrote this?" against AI/consciousness chunks, never the title page. **Fix:** new `DatabaseManager.frontMatterChunks(for:limit:)` always prepends the document's first 4 chunks (≈1800 chars) as relevance-1.0 RAG candidates for document-scoped invocations. Title page + TOC + contributor list become reliable anchors.

2. **Stale conversation poisoning.** Persisted "doesn't specify the authors" turns from earlier wrong answers were self-reinforcing via STM + summary. **Fix:** new `CLEAR_ASK_POSEY_CONVERSATION` API command + `DatabaseManager.clearAskPoseyConversation(for:)` helper. Test harness clears between battery runs for fresh-context Q&A.

3. **Format imitation / persona capture.** Original `[user]: / [assistant]:` script primed AFM to continue rather than answer. Tried XML markers — model imitated the markup itself, dumping `<past_exchanges>`, `<current_question>`, `<answer>` tags into its replies. **Final form:** plain-prose ALL-CAPS section labels (`ANCHOR PASSAGE`, `DOCUMENT EXCERPTS`, `EARLIER IN THIS CONVERSATION`, `USER QUESTION`) — parseable structure but unimitable. Conversation history rendered as third-person narrative, **without prior assistant replies** (only "the user has so far asked X, then Y") so the model has topic context but no template to copy.

4. **Current-question duplication.** User message was being appended to `historyForPromptBuilder` at send-start, putting the current question both in `EARLIER IN THIS CONVERSATION` and in the `USER QUESTION` section. **Fix:** defer the append to finalize-time so past exchanges hold ONLY genuinely-prior turns.

5. **Token estimator under-counting.** AFM's actual tokenizer counts ~14% denser than our 3.5 chars/token estimate. Real test hit `exceededContextWindowSize` (4091/4096) when our estimator said we were well under budget. **Fix:** chars/token tightened to 3.0; `responseReserveTokens` bumped 512 → 1024; section budgets rebalanced to 180/300/600/300/1400 (sum 2780) against the new 3072 ceiling.

6. **Anti-hallucination instructions.** Original "if you don't have enough say so" biased toward refusal even when info was in front matter under different vocabulary. **Fix:** explicit synthesis instruction — map question vocabulary to document vocabulary (authors → contributors / moderator), front matter answers most who/what questions, never invent specific dates/numbers/names.

7. **Role attribution.** Question *"What's the author's name?"* on a student paper that anonymized the author with an ID# was answered "Professor Sharp" (the recipient). **Fix:** explicit instruction "if only an ID# appears, say the author isn't identified by name; do NOT substitute another person from the front matter."

8. **Front-matter structured metadata.** Dates / course names / professor names embedded in noisy front matter (Wayback Machine timestamps, page footers) sometimes refused as "not in the document." **Fix:** explicit instruction to trust these fields when clearly visible.

9. **Abstract-vs-contributor cherry-picking.** Model picked "ChatGPT, Claude, Gemini" from a brief abstract while ignoring the fuller "Mark Friedlander: Moderator + ChatGPT/Claude/Gemini" contributor list elsewhere. **Fix:** explicit "abstracts often understate the full roster; scan every excerpt before listing contributors; the COMBINED set is the answer."

10. **AFM safety filter UX.** Empty assistant bubbles on refusal felt broken. **Fix:** typed-error-aware fallback bubble messages (`handleSendError` rewrites the placeholder with a user-friendly note).

11. **Stochastic instability at temp 0.5.** Ran Q1 four times, lost Mark Friedlander on 1 of 4. Lowered to temp 0.3, then 0.1 for the grounded call — stable across retries.

12. **`/ask` exposes `fullPrompt`** for debugging.

Final battery results pre-polish: 10/12 PASS, 2 AFM safety refusals on synthesis-style questions involving philosophical/legal interpretation. Refusals are AFM-side (opaque safety filter); fix is UX-side (handleSendError). Three new DECISIONS entries already covered the architectural commitments; CLAUDE.md gained the Three Hats standing requirement.

## 2026-05-01 — Autonomous M7-complete + M8-mostly-complete + M9 polish wave

Per Mark's "continue autonomously through M9" directive (2026-05-01), shipped a substantive batch covering the previously-deferred items that don't require design input or interactive verification.

**M7 navigation cards (closes M7):** `.search`-classified questions now route to a `@Generable AskPoseyNavigationCardSet` schema (`AskPoseyNavigationCards.swift`). AFM is asked to pick 3–6 destinations from candidate chunks; out-of-range indices drop silently (defensive parsing). `AskPoseyNavigating` protocol; `AskPoseyService.generateNavigationCards`; `AskPoseyChatViewModel.runSearchPipeline` finalizes turns with `navigationCards: [AskPoseyNavigationCard]` instead of streaming prose. New `AskPoseyView.navigationCardList(for:)` renders a vertical list of Material-backed buttons with arrow.right.circle.fill icon, title, and reason; tap dismisses the sheet and jumps the reader via the same `onJumpToChunk` source-attribution pills use. Sources strip is suppressed when navigation cards are present (the cards themselves are the source link).

**Immersive reading style:** distance-based opacity (1.0 at center, -0.30/row, 0.05 floor) and scale (1.0, -0.15/row, 0.55 floor) curves applied to every segment row. Smooth `easeInOut(0.18)` animation on `currentSentenceIndex` changes, honors Reduce Motion. New `ReaderViewModel.distanceFromActive(segment:)` and (block:) drive the falloff. Search matches stay full-opacity in any mode so the search affordance never gets dimmed.

**Motion reading style + CoreMotion:** large centered active sentence at 1.6× the configured font size; surrounding rows use the same Immersive falloff. Three-setting design (Off / On / Auto) per `DECISIONS.md`. New `MotionDetector` class wraps `CMMotionActivityManager` (preferred — uses Apple's built-in walking/running/cycling/automotive classification) + accelerometer fallback (low-pass-filtered magnitude). **Privacy contract: detector.start(consented:) is a no-op without the consent flag** — defense-in-depth against accidental CoreMotion engagement. `MotionConsentSheet` (BLOCK P1B in ReaderView.swift) explains the privacy model before Auto engages: "Motion data stays on this device. Posey doesn't send movement data anywhere. You can switch Motion to Off or On at any time and the monitoring stops immediately." `INFOPLIST_KEY_NSMotionUsageDescription` added so iOS shows the privacy reason on the system permission prompt.

**Audio export to M4A:** `AudioExporter` class renders documents to `.m4a` via `AVSpeechSynthesizer.write(_:toBufferCallback:)` → `AVAudioFile` (AAC). **Best-Available capture investigation runs at render time:** if the first utterance produces no buffers, `AudioExporter` throws `.voiceNotCapturable` so the UI tells the user to switch to a Custom voice. State machine: `idle / rendering(progress, i, total) / finished(url) / failed(reason)`. New `AudioExportSheet` (BLOCK P1C of ReaderView.swift) with three states: rendering (linear ProgressView + cancel), finished (ShareLink to save/share), failed (error message). Footer text in the prefs section explains the Best-Available caveat up front.

**M8 entity-aware multi-factor relevance scoring v2:** new `DocumentEmbeddingIndex.searchWithEntityBoost(...)` re-ranks the embedding-search results by `cosine + 2.0 × Jaccard(query_entities, chunk_entities)`, clamped to [-1, 3]. Wider candidate pool (3× requested limit) so entity-rich chunks that ranked lower on pure cosine can still surface. New `extractEntities(from:)` (NLTagger.nameType — personalName / placeName / organizationName, lowercased) and `jaccardOverlap(_:_:)` helpers. `AskPoseyChatViewModel.retrieveRAGChunks(...)` now uses the boosted variant; falls back to pure cosine when neither side has entities. New `EntityScoringTests` (8 tests, all green): empty string / person / place / org / Jaccard empty / identical / disjoint / partial.

**M9 landscape centering polish:** `onChange(of: verticalSizeClass)` and `onChange(of: horizontalSizeClass)` hooks re-fire `scrollToCurrentSentence` twice (60 ms + 180 ms) after rotation / iPad split-view resize. Two-stage delay matches the initial-appear pattern: first scroll lands approximately, second catches up after the lazy-VStack layout pass realizes previously off-screen rows. Closes the "rotating mid-read leaves the active sentence off-center" issue Mark accepted as good-enough-for-now in earlier passes.

**Format-parity audit harness (`tools/format_parity_audit.py`):** systematic capability matrix — for each of 7 supported formats (txt / md / rtf / docx / html / epub / pdf) verifies: import OK, character count > 0, plainText present, displayText present, /ask runs end-to-end. Writes `tools/format_parity_audit_report.json`. Skeleton on top of the synthetic-corpus generator so iteration on real-world artifacts builds incrementally.

**Multilingual verification harness (`tools/multilingual_verify.py`):** downloads a 5-language corpus (English / French / German / Spanish / Italian — Project Gutenberg, ~150KB each), imports into Posey, drives `/ask` with one canonical question per language, reports retrieval shape (chunks_injected / rag_tokens / prompt_tokens / inference_duration). Skeleton — Mark refines question→expected-passage anchors in a follow-up pass; the harness exercises the API plumbing now.

**Build clean** on iPhone 17 simulator throughout. M5/M6/M7/M8 test suites (entity scoring + prompt builder + CRUD + summarization trigger + schema + drop priority + estimator + budget + surrounding window) all green. Total Ask Posey + reader test count is now ~46 across the new test files added in this run.

**Items still queued for genuine-decision-point passes (recorded in NEXT.md):**
- Mac Catalyst verification (running on Mac, layout audit)
- VoiceOver pass (interactive testing with the screen reader)
- App icon (design input from Mark)
- M10 submission flow (privacy policy text approval, App Store metadata, final submission)
- LocalAPIServer class deeper compile-out (cleanup candidate)

## 2026-05-01 — Milestone 8 + 9 partials: lock-screen audio, Reading Style preference, dev-tools-out-of-release

Five M8/M9 wins shipped autonomously per Mark's "go through M9" directive (2026-05-01). Items deferred to dedicated implementation passes are recorded explicitly in NEXT.md.

**M8 antenna OFF default for release** — `LibraryViewModel.localAPIEnabled` `@AppStorage` default flips DEBUG → `true`, RELEASE → `false`. App Store binary ships with the antenna OFF; users opt in explicitly. DEBUG builds keep the development convenience.

**M8 lock-screen + background audio** — `INFOPLIST_KEY_UIBackgroundModes = audio` added so `AVSpeechSynthesizer` keeps playing when the screen locks. New `NowPlayingController` wires `MPNowPlayingInfoCenter` (document title + active sentence + play/pause indicator) and `MPRemoteCommandCenter` (play / pause / togglePlayPause / nextTrack / previousTrack). `ReaderViewModel` builds the controller after content load; `observePlayback` updates it on every state change + sentence advance. Lock screen now shows Posey as a first-class audio player rather than a generic "Audio playing" placeholder.

**M8 Reading Style preference (Standard + Focus)** — `PlaybackPreferences.ReadingStyle` enum with two cases ships now; Immersive (custom layout) and Motion (CoreMotion + consent flow) deferred. New segmented Picker in the Reader Preferences sheet. `segmentOpacity(_:)` and `blockOpacity(_:)` in the render path apply 0.45 opacity to non-active non-search-match rows when the user is in Focus mode; full opacity in Standard. Search matches stay full-opacity in either mode so the search affordance never gets dimmed away. Persisted via `UserDefaults` under `posey.reader.readingStyle`.

**M9 dev-tools out of release** — antenna toolbar item wrapped in `#if DEBUG` so the icon literally doesn't render in App Store builds. Auto-start at launch wrapped in `#if DEBUG` so the API server can't start unless someone recompiles in Debug configuration. Defense in depth on top of the antenna OFF default. Release config builds clean (`** BUILD SUCCEEDED **`).

**Deferred** (recorded in NEXT.md M9 section, not shipped here):
- Reading Style: Immersive (custom slot-machine layout per `DECISIONS.md`)
- Reading Style: Motion (three-setting Off/On/Auto with `CoreMotion` + explicit consent screen)
- Audio export to M4A (needs `AVSpeechSynthesizer.write(_:toBufferCallback:)` Best-Available capture investigation first)
- Format-parity audit across all 7 supported formats
- Mac Catalyst verification
- Multilingual embedding verification on real corpus
- Entity-aware multi-factor relevance scoring v2
- VoiceOver accessibility audit (needs interactive verification with the screen reader)
- Landscape centering polish (low-priority; +5.5 px off-center accepted)
- Go-to-page input UX polish
- App icon (needs Mark's design input)
- M10 submission flow (privacy policy, App Store metadata, screenshots, App Store Connect navigation)

These remain on the roadmap; the autonomous run prioritized landing the highest-value structural pieces (architecture-correct M5/M6 prompt builder, persistent conversation history, RAG retrieval, source attribution, lock-screen audio, dev-tools hygiene) over the items that need device verification, design input, or interactive testing.

**Build clean** on iPhone 17 simulator + iPhone 16 Plus device. Ask Posey M5/M6 test suite still green.

## 2026-05-01 — Ask Posey Milestone 7: source attribution + auto-save to notes + in-sheet indexing indicator

Three of M7's four scoped features land here. The fourth (`.search` intent → @Generable navigation cards) is intentionally deferred — M5's prompt builder already routes `.search` through the same prose path with degraded but non-broken behavior, and the deeper navigation-card UX needs a deliberate design pass before implementation. Recorded as a polish item in NEXT.md.

**Source attribution** — assistant bubbles whose response was grounded by RAG chunks now show a horizontal "SOURCES" pill strip below the bubble. Each pill displays the chunk's rank (1, 2, 3…) and relevance percent (e.g. "87%"). Tapping a pill cancels any in-flight stream, dismisses the sheet, and jumps the reader to the chunk's `startOffset` via the new `ReaderViewModel.jumpToOffset(_:)` (refactored out of the existing `jumpToTOCEntry` since both use the identical "find sentence at-or-before offset → set currentSentenceIndex → persist position" flow). Implementation:
- `AskPoseyMessage.chunksInjected: [RetrievedChunk]` field added; populated in `finalizeAssistantTurn` from response metadata.
- `AskPoseyView.sourcesStrip(for:)` ViewBuilder with horizontal `ScrollView` + Capsule pills.
- `AskPoseyView.onJumpToChunk: ((Int) -> Void)?` closure parameter — `ReaderView`'s `.sheet` callsite passes `viewModel.jumpToOffset(_:)` so taps land in the reader.

**Auto-save to notes** — finalised assistant bubbles get a small "Save to Notes" button. Tapping persists the Q + A pair as a Note row on the document via the existing `DatabaseManager.insertNote(_:)`, anchored to the conversation's anchor offset (or the first cited chunk's offset for document-scoped, or 0 as last resort). Per-sheet `savedAssistantMessageIDs: Set<UUID>` tracks the per-button "Saved" state — flips to a checkmark + dimmed label once the persist succeeds. Implementation: `AskPoseyChatViewModel.saveAssistantTurnToNotes(_:)` walks the message array backwards from the assistant bubble to find the corresponding user question, formats `"Q: <question>\n\nA: <answer>"`, and inserts the Note. Failure is non-fatal; logs via NSLog.

**In-sheet indexing indicator** — when the user opens Ask Posey on a document whose embedding index is still being built, a sheet-internal notice appears above the chat history: "Indexing this document… N of M sections" with a circular progress indicator (or "Indexing this document for Ask Posey…" without progress data when none is available). Reuses the M2 `IndexingTracker` + `.documentIndexingDidProgress` notification plumbing. The notice hides as soon as indexing completes — no manual dismiss required. Spec'd in `ask_posey_spec.md` "indexing-indicator" subsection.

**Build clean** on iPhone 17 simulator. `ReaderViewModel.jumpToOffset(_:)` refactor preserves `jumpToTOCEntry` semantics (the M5/M6 test suite passes unchanged).

## 2026-05-01 — Local API Ask Posey endpoints: `/ask` + `/open-ask-posey` for autonomous test infrastructure

Per Mark's directive (2026-05-01): Posey now exposes the full Ask Posey pipeline through the local API so an autonomous test harness can drive multi-turn conversations end-to-end without UI involvement, AND can programmatically open the Ask Posey sheet on the simulator so visual verification via the simulator MCP becomes possible. Together these answer "we can verify Ask Posey ourselves before bothering Mark."

**`POST /ask`** — backend pipeline. Body: `{"documentID": "<uuid>", "question": "<text>", "scope": "passage"|"document", "anchorText": "<text|null>", "anchorOffset": <int|null>}`. Constructs a fresh `AskPoseyChatViewModel` in `LibraryViewModel.apiAsk(bodyData:)`, awaits history load, sets the input, calls the live `send()` which runs the same path the UI does (intent classification → prompt build → AFM stream → SQLite persist). Returns a JSON envelope with the assistant response, classified intent (via the persisted turn's `intent` field), token breakdown (per-section costs), dropped sections (each with reason), chunks injected (chunk IDs + start offsets + relevance scores), full prompt body for logging, inference duration, and translated error description. Verified end-to-end on Mark's iPhone 16 Plus: 3.5s round-trip, 1542 prompt tokens, 8 RAG chunks injected, real document-grounded prose response. The send writes turns to `ask_posey_conversations` exactly the same way the UI's `send()` does, so subsequent sheet opens see the conversation — driving the API populates the UI's prior-history view automatically.

**`POST /open-ask-posey`** — UI driver for the simulator MCP. Body: `{"documentID": "<uuid>", "scope": "passage"|"document"}`. Posts a `Notification.Name.openAskPoseyForDocument` event the LibraryView and ReaderView both observe. LibraryView updates its `NavigationStack` path to push the matching document; ReaderView (newly mounted) re-receives the redelivered notification 500ms later (the original post arrives before ReaderView's `onReceive` registers, so the LibraryView observer schedules a redelivery flagged with `userInfo["redelivered"] = true` to avoid an infinite navigation loop) and calls `openAskPosey(scope:)` to present the sheet.

**`Notification.Name.openAskPoseyForDocument`** — new shared notification name in `Posey/Services/LocalAPI/AskPoseyNotifications.swift`. Single contract surface for both observers.

**Endpoint plumbing changes (`LocalAPIServer`):** two new injected handlers — `askHandler: (@Sendable (Data) async -> String)?` and `openAskPoseyHandler: (@Sendable (Data) async -> String)?`. Both take `Data` (raw body bytes) rather than `[String: Any]` because dictionaries with `Any` values aren't `Sendable`. Each handler parses JSON internally, an additive change that doesn't touch the existing three handlers (commandHandler / importHandler / stateHandler).

**`tools/posey_test.py` extensions:** two new commands matching the new endpoints — `posey_test.py ask <doc-id> <question> [--scope passage|document] [--anchor-text <text>] [--anchor-offset <int>]` drives `/ask`, prints the JSON envelope; `posey_test.py open-ask-posey <doc-id> [--scope passage|document]` drives `/open-ask-posey`, prints the dispatched notification confirmation. Both reuse the existing `_http` helper so the 600s timeout for `/ask` (AFM streams can take seconds) is honored.

**Token capture for simulator:** the API server's startup token line was migrated from `print(...)` to `NSLog(...)` so it flows through unified logging and can be captured via `xcrun simctl spawn <udid> log show --predicate 'eventMessage CONTAINS "PoseyAPI: Token"'`. Lets autonomous test harnesses fetch the simulator's keychain-backed token without a manual Xcode console session.

**End-to-end visual verification on simulator:** confirmed by booting iPhone 17 sim, installing the build, importing a small test doc via `/import`, calling `/ask` (writes user turn to SQLite, fails on the AFM stream because simulator has no AFM models — expected, error correctly translated), then calling `/open-ask-posey` and screenshotting via the simulator MCP. The sheet renders with the prior user turn ("What are the three principles?") above the "Earlier conversation" divider, the anchor row showing the active sentence, and the composer ready — exact iMessage layout M5 designed. The .gitignore now covers `tools/.posey_api_config.*.json` so per-target API configs don't leak.

**Build clean** on iPhone 17 simulator. Device-installed and verified live.

## 2026-05-01 — Ask Posey Milestone 6: RAG retrieval + auto-summarization + document-scoped invocation

M6 lights up the empty slots M5's prompt builder shipped accommodating. No restructuring — only data wiring.

**RAG retrieval (`AskPoseyChatViewModel.retrieveRAGChunks(for:)`):** the chat view model now constructs a `DocumentEmbeddingIndex` lazily from its database manager and queries `search(documentID:query:limit:)` for the top 8 chunks ranked by cosine similarity to the user's question. Results translate from `DocumentEmbeddingSearchResult` to the prompt builder's `RetrievedChunk` shape. Cosine dedup filters chunks too similar to the anchor + recent verbatim STM (threshold 0.85, matching Hal's default) so the model never sees the same passage twice. `.search` intent skips RAG entirely — that path will route to navigation cards in M7. Failed searches log and fall back to no-RAG (better degraded grounding than a failed send).

**Cosine dedup helpers (`DocumentEmbeddingIndex`):** two new internal methods — `embed(_:forDocument:)` embeds an arbitrary string using whichever embedding model the document was indexed with (resolves the dominant kind across stored chunks for re-index-in-progress edge cases), and `cosineSimilarity(_:_:)` re-exposes the existing private `cosine(_:_:)` so the chat view model can compute reference-vs-chunk similarity at the dedup boundary.

**Auto-summarization (M6 hard-blocker per Mark's directive 2026-05-01):**
- New `AskPoseySummarizing` protocol on the service surface; live `AskPoseyService` conforms.
- `AskPoseyService.summarizeConversation(turns:)` runs a fresh `LanguageModelSession` with deterministic temperature (0.2 — summarization wants accuracy, not creativity), short instructions ("compress an earlier portion of a reading-companion conversation; keep it short, capture topics + passages + commitments, never invent"), and returns the trimmed prose.
- `AskPoseyChatViewModel.summarizeOlderTurnsIfNeeded()` runs at the tail of `finalizeAssistantTurn`. Trigger: total non-summary turn count exceeds 8 AND the older slice (everything except the most-recent 6 verbatim) hasn't been folded into the existing summary yet. Snapshots the older slice, kicks off a background `Task` that calls `summarizer.summarizeConversation(...)`, persists the result as an `is_summary = 1` row in `ask_posey_conversations` with the new `summary_of_turns_through` watermark, updates the in-memory `cachedConversationSummary` so the next prompt-build picks it up.
- Next `send()` awaits any in-flight `summarizationTask` BEFORE building its prompt — guarantees the conversation-summary slot is current.
- Failure mode: summarization errors log via `NSLog` and the next send ships without an updated summary. Older verbatim turns silently roll out of the STM window. Non-fatal.

**Document-scoped invocation entry point:** the bottom-bar sparkle glyph is now a `Menu` with two actions — "Ask about this passage" (the M5 path: anchor = current sentence) and "Ask about this document" (M6 path: anchor = nil, RAG does the heavy lifting). New `ReaderView.AskPoseyScope` enum and `openAskPosey(scope:)` parameterizes the construction. Per the resolved-decision document-scope pattern in `ask_posey_spec.md`.

**Tests (7 new tests; all green):**
- `DocumentEmbeddingIndexM6HelpersTests` — 5 tests: `embed(...)` returns empty when no chunks indexed (signal "skip dedup"); cosine identity = 1; cosine orthogonal = 0; shape mismatch returns 0 (defensive, never throws); zero-vector returns 0.
- `AskPoseySummarizationTriggerTests` — 2 tests using stub classifier/streamer/summarizer: below-threshold (4 prior turns + 1 fresh exchange) doesn't fire; above-threshold (12 prior turns + 1 fresh exchange) fires exactly once with the older slice as input.

**Build clean** on iPhone 17 simulator. Together with M5's 31 tests, the Ask Posey M5+M6 surface has 38 tests covering the structural correctness end-to-end. M5 device-install confirmed (iPhone 16 Plus); M6 device install + interactive verification queued for Mark's next pickup.

## 2026-05-01 — Ask Posey Milestone 5: full prompt-builder architecture + persistent conversation history

The biggest M5 change is structural, not in features the user can see: Mark's architectural correction (logged in DECISIONS.md) reshapes Ask Posey from "transient sheet that asks AFM about the visible passage" to "persistent reading-companion that remembers everything ever discussed about a document." M5 ships the full prompt-builder architecture so M6/M7 are "fill in the data," not "restructure the system."

**Schema (`ask_posey_conversations`):** five new columns added via `addColumnIfNeeded` migrations — `intent` (classified bucket per turn, nullable), `chunks_injected` (JSON array of chunk references that actually went into the prompt, NOT NULL DEFAULT '[]'), `full_prompt_for_logging` (verbatim prompt body the model saw, nullable for legacy rows), `embedding` BLOB + `embedding_kind` for the M6+ "retrieve relevant older turns" path. New `BLOCK 05D` in `DatabaseManager.swift` adds `StoredAskPoseyTurn` value type plus four CRUD helpers: `appendAskPoseyTurn`, `askPoseyTurns(for:limit:)` (oldest-first with optional most-recent-N cap), `askPoseyLatestSummary` (M6 surface), `askPoseyTurnCount`.

**Token budget (`AskPoseyTokenBudget`):** named-property struct, no magic numbers, single tuning point. AFM defaults: 4096 context, 512 response reserve (down from Hal's 30% — Posey answers are focused), within prompt ceiling: 5% system / 10% anchor+surrounding / 20% STM verbatim / 10% summary / 50% RAG chunks. User question gets the remainder. Sibling `AskPoseyTokenEstimator` provides a `chars/3.5` approximation (Apple doesn't expose AFM's tokenizer at iOS 26.4).

**Prompt builder (`AskPoseyPromptBuilder`):** pure-function `build(_:budget:) -> AskPoseyPromptOutput`. Every byte the model sees is explicit input or generated from explicit input. HelPML-fenced sections (`#=== BEGIN ANCHOR ===#` / `#=== BEGIN CONVERSATION_RECENT ===#` / `#=== BEGIN MEMORY_LONG ===#` / `#=== BEGIN USER ===#` etc) for grep-able prompts and unambiguous boundaries. Drop priority: oldest RAG chunks → summary → oldest STM turns → surrounding → user-question truncation; system + anchor non-droppable. Per-intent surrounding window: 150 tokens for `.immediate`, 0 for `.search`, 300 for `.general`. `AskPoseyPromptOutput` carries `instructions` + `renderedBody` + `combinedForLogging` + `tokenBreakdown` (per-section costs) + `droppedSections` (each drop with reason + identifier) + `chunksInjected` (M7 attribution).

**Service (`AskPoseyService.streamProseResponse`):** new method on the existing classifier service. Fresh `LanguageModelSession` per call (Mark's directive: app owns the context, not the model — no transcript reuse, every prompt assembled by the builder from explicit inputs). Builds inputs → builds prompt → opens session with `instructions` → streams via `streamResponse { Prompt(renderedBody) }` → snapshots through `@MainActor onSnapshot:` callback → returns `AskPoseyResponseMetadata`. Cancellation propagates cleanly; `LanguageModelSession.GenerationError` translates through the existing `AskPoseyServiceError` mapper. `proseTemperature` defaults to 0.5 (Mark's hint: 0.7 may feel more natural — tunable from one place).

**View model (`AskPoseyChatViewModel`):** rewired to take `documentID + documentPlainText + classifier + streamer + databaseManager`. On init kicks off a `Task` that loads prior conversation turns from `ask_posey_conversations` via the new CRUD helpers; `historyBoundary: Int` published property marks where prior-session history ends and this-session additions begin (the view renders the anchor row at this boundary — iMessage pattern). Live `send()` method: persists user turn immediately (so a crash mid-stream preserves the question), classifies intent via the M3 classifier, builds inputs (anchor + per-intent surrounding context computed from `documentPlainText` + offset, history from cache, summary nil for M5, chunks empty for M5, current question), streams via `AskPoseyStreaming.streamProseResponse`, applies snapshots in place via `applyStreamingSnapshot(_:to:)`, finalizes with full metadata (chunks JSON + full prompt) persisted to SQLite. Echo-stub fallback preserved for previews/older OS targets.

**View (`AskPoseyView`):** prior conversation loaded from SQLite renders above an "Earlier conversation" divider; anchor row renders at the boundary; this-session messages render below; composer at bottom. `ScrollViewReader.scrollTo(anchorRowID, anchor: .top)` programmatic scroll on initial appear lands the user looking at the anchor with prior history above the fold (invisible unless they scroll up — Mark's iMessage pattern). `errorBinding` surfaces translated `AskPoseyServiceError` as a system alert; dismissing clears `viewModel.lastError`. `submit()` routes to live `send()` when AFM is available, falls back to `sendEchoStub()` for previews.

**ReaderView wiring:** `openAskPosey()` builds a live `AskPoseyService` (when AFM is available on this OS) and threads `document.id`, `document.plainText`, classifier, streamer, and `viewModel.databaseManager` into the chat view model. `databaseManager` accessor on `ReaderViewModel` promoted from private to internal so external sites can read+write per-document state without re-injecting the manager through new surfaces.

**Tests (31 new + 1 schema test extension; all green):**
- `AskPoseyPromptBuilderTests.swift` — 22 tests covering token estimator, budget defaults, builder happy paths (empty/anchor-only/history-order/surrounding-render/RAG-render/breakdown), drop priority (STM overflow drops oldest, RAG overflow drops chunks, user truncation as last resort), and per-intent surrounding window sizing.
- `AskPoseyConversationsCRUDTests.swift` — 9 tests covering CRUD round-trip (single user turn, assistant turn with full metadata, oldest-first ordering, limit caps, summary-row segregation) and chat view model history loading (fresh-empty / returning-loads-prior / per-document FK boundary).
- `AskPoseySchemaMigrationTests.swift` — extended to expect the 5 new columns + their NOT NULL / NULLABLE contracts.

**M6 hard blocker locked into NEXT.md:** auto-summarization is no longer "deferred" — it's an explicit M6 blocker that cannot slip, because without it M5's STM window quietly drops older turns from the prompt as conversations grow past ~3-4 turns and the "Posey remembers everything" promise breaks.

**Device install (2026-05-01):** built clean on iPhone 17 simulator, installed and launched cleanly on Mark's iPhone 16 Plus (`00008140-001A7D001E47001C`). Schema migration applied on first launch without crash. Local API state probe confirms the runtime: 2 documents present (Illuminatus 1.6M char EPUB + "The Internet Steps to the Beat" PDF). Full UI flow — bottom-bar sparkle glyph → sheet open → ask question → live AFM stream → bubble update → SQLite persist → re-open shows prior history above the fold — needs Mark's interactive verification when he picks up the build (the local API doesn't drive the Ask Posey sheet UI). Unit and integration tests cover the structural correctness end-to-end on simulator (31 new tests green); device verification is the remaining acceptance step.

## 2026-05-01 — Pre-open hang fix: async ReaderViewModel content loading

Claude (claude.ai)'s M4 device pass surfaced one final issue Mark's manual testing also confirmed: opening Illuminatus showed a blank screen for several seconds before the reader appeared, with no user-facing feedback. Investigation: `ReaderViewModel.init` was doing `SentenceSegmenter().segments(for: plainText)` synchronously — for Illuminatus's 1.6M-char plainText that's ~5–10s of NLTokenizer iteration. SwiftUI `NavigationStack.navigationDestination(for:)` blocks the navigation push until init returns, so the user sees the previous screen frozen for that whole window.

Refactor: heavy compute moves to a `Task.detached(priority: .userInitiated)` background dispatch; new `@Published var isLoading: Bool = true` drives a full-screen "Opening &lt;title&gt;…" overlay until segmentation + display block parsing complete. Position restoration, playback prepare, and observation move from `handleAppear` into `loadContent`'s tail because they all depend on segments and the post-load ordering is now strict: segments → displayBlocks → visualPauseMap → tocEntries → pageMap → position restore → playback prepare → observePlayback (subscribed AFTER prepare so the initial sink emission carries the restored sentence index, not a stale 0) → `isLoading = false` → automation hooks. `splitParagraphBlocks`, `buildVisualPauseIndexMap`, and the static `sentenceIndex(forOffset:segments:)` are marked `nonisolated` so the detached compute closure can call them without MainActor crossings.

`handleAppear` is now lightweight: awaits `contentLoadTask?.value`, then loads notes. New public `awaitContentLoaded()` lets tests synchronise without polling.

The previously-shipped `nonisolated deinit {}` (commit `19af951`) continues to keep XCTest's runner-thread dealloc from hitting the MainActor deinit Swift Concurrency runtime bug.

Tests: all 12 ReaderViewModelTests converted from sync to `async throws`; every viewModel construction site adds `await viewModel.awaitContentLoaded()` before accessing segments / displayBlocks / currentSentenceIndex. The `testPlaybackSkipRegionIsHiddenFromReader` test was where the missing-await bug surfaced (Array out-of-bounds crash on `migrated.segments[0]` because that test constructs a SECOND view model for migration verification and I'd only added the await for the first). Full suite green on simulator: 12/12 pass, zero failures, no dealloc crashes.

Pushed in commit `cb2ac8a`. For Illuminatus on Mark's iPhone the user-visible behaviour is now: tap document → reader frame appears immediately with circular spinner + "Opening Illuminatus TRILOGY EBOOK…" caption → ~5–10s of background work → overlay fades, reader ready. Small docs flip `isLoading` false before the first render cycle so the overlay never renders for them.

## 2026-05-01 — M4 device-pass polish + ReaderViewModel deinit crash fix

Claude (claude.ai)'s device review of M4 produced five follow-up items, all addressed. Plus a related crash that surfaced during testing.

**Polish (commit `19af951`):**
- **Detents.** `.large` only on iPhone (compact horizontal size class) — `.medium` left no visible document on a 16 Plus, and Ask Posey IS the focused task at that point so going straight to full-screen is right. iPad/Mac (regular) keep `.medium` + `.large` available.
- **Anchor scrolls with conversation.** Moved from a pinned bar above the chat list INTO the LazyVStack as the first row, so it scrolls off naturally as the conversation grows. The user can still scroll back to see "where this conversation started" but the conversation gets the room.
- **Privacy lock indicator removed.** Per Claude's read it was confusing rather than reassuring. Privacy explanation moves to the App Store description and a future About section.
- **Notes draft no longer auto-populates.** Previous-sentence-plus-current-sentence text was being auto-typed into the editable draft, while the active sentence was already shown above as readonly context — so the user saw the active sentence twice and got prepended OCR running-headers (the "9/11/25, 1:33 PM" Wayback Machine timestamp on every page of "The Internet Steps to the Beat" PDF). Investigation confirmed that text is genuine source content, not a Notes-flow bug — running headers leak into plainText. Surrounding-sentence capture still copies to the clipboard so the share-with-other-app workflow keeps working; only the visible draft is empty. Existing `testPrepareForNotesEntryPausesPlaybackAndCapturesLookbackContext` test renamed and rewritten to assert the new clean-draft behaviour.

**Deinit crash fix (same commit):**
Mark's simulator captured a `Posey [...] crashed... ReaderViewModel.__deallocating_deinit + 124 → swift_task_deinitOnExecutorImpl + 104 → swift::TaskLocal::StopLookupScope::~StopLookupScope + 112 → malloc abort: POINTER_BEING_FREED_WAS_NOT_ALLOCATED`. Same shape as the earlier `DocumentEmbeddingIndex` crash that was solved by marking that class `nonisolated`. ReaderViewModel can't go fully nonisolated (it touches AVSpeechSynthesizer, Combine publishers, SwiftUI bindings — all MainActor in practice). Solution: `nonisolated deinit {}` — Swift 5 + approachable concurrency accepts the explicit nonisolated discipline on deinit and lets it run wherever the last release happens, no MainActor hop, no TaskLocal teardown crash.

## 2026-05-01 — Ask Posey Milestone 4: modal sheet UI shell with echo stub

The structural shell for the Ask Posey conversation surface, AFM-availability-gated. Calls into the M3 classifier are deferred to M5 — this milestone proved the layout works on real documents before wiring AFM, addressing the half-sheet vs full-modal design risk Mark called out in the implementation plan §12.4.

`Posey/Features/AskPosey/`:
- **`AskPoseyMessage.swift`** — value types: `AskPoseyMessage` (id, role, content, isStreaming, timestamp), `AskPoseyAnchor` (text, plainTextOffset). All `Sendable` so streamed snapshots from a background queue can cross actor boundaries cleanly when M5 lands.
- **`AskPoseyChatViewModel.swift`** — `@MainActor ObservableObject`. `@Published` messages, inputText, isResponding. `canSend` gates Send while responding or input is whitespace-only. `sendEchoStub()` for M4 (appends user message, simulates 0.45s delay, appends `[stub] You asked: …` reply). `cancelInFlight()` from sheet dismiss. `Identifiable` so SwiftUI's `sheet(item:)` uses the view model itself as the presentation key. `previewSeedTranscript` hook gated to `#if DEBUG` so seeding doesn't ship in release.
- **`AskPoseyView.swift`** — half-sheet (post-polish: `.large` only on iPhone, `.medium` + `.large` on iPad/Mac). Anchor + chat history + composer all inside one LazyVStack so the anchor scrolls with the conversation. `defaultScrollAnchor(.bottom)` keeps newly added messages visible. Composer auto-focuses 250ms after present. Two `#Preview` canvases (empty + populated transcript).

`ReaderView` wiring:
- `@State askPoseyChat: AskPoseyChatViewModel?` — `sheet(item:)` so the view model lifetime tracks the sheet. Fresh instance per open captures the active sentence as anchor.
- Bottom-bar Ask Posey glyph (sparkle SF Symbol) at the far left of the controls HStack — opposite Restart, per `ARCHITECTURE.md` "Surface Design". Hidden via `if AskPoseyAvailability.isAvailable` so the entire affordance is invisible on devices without Apple Intelligence (per resolved decision 5).
- `openAskPosey()` helper: captures the active sentence, wraps in `AskPoseyAnchor`, stops playback (the document doesn't keep advancing under the user), constructs the chat view model.

Verified on Mark's iPhone 16 Plus: glyph present, sheet presents at half-sheet, echo stub round-trips at ~450ms, anchor visible, dismiss clean.

## 2026-05-01 — Ask Posey Milestone 3: two-call intent classifier

Lays the foundation for the Call-1 / Call-2 pattern. Three new files in `Posey/Services/AskPosey/`:

- **`AskPoseyIntent.swift`** — the `@Generable` enum: `.immediate | .search | .general`. `String`-raw-value for trivial logging / persistence; raw values pinned by unit test (renaming a case is a deliberate schema change). Gated to iOS 26+ via `#if canImport(FoundationModels)` and `@available`.
- **`AskPoseyService.swift`** — the live classifier. `AskPoseyClassifying` protocol exposes `classifyIntent(question:anchor:) async throws -> AskPoseyIntent` so M5+ UI can swap stubs in. `AskPoseyServiceError` translates `LanguageModelSession.GenerationError` (all 9 cases including the missed `.refusal`) into `.afmUnavailable / .transient / .permanent`. Per-call session lifecycle (no transcript reuse — independent classifications shouldn't bias each other).
- `AskPoseyPrompts` enum with `nonisolated` discipline (so its static defaults work in init parameter positions). Pure-string assembly tested directly.

Tests:
- `AskPoseyPromptTests` (7 cases): question included, all three buckets listed, anchor included when present, anchor omitted when absent or whitespace-only, question whitespace trimmed, instructions stay short and contain "classify".
- `AskPoseyIntentTests` (3 cases): cases present, raw values pinned, Codable round trip.
- `AskPoseyServiceOnDeviceProbe` (2 cases): real AFM round-trip with anchored and non-anchored questions. Skipped on simulator (model assets not installed); both pass on Mark's iPhone 16 Plus (0.7s and 1.0s respectively) — first end-to-end `@Generable` classification on real hardware.

## 2026-05-01 — M8/M9/M10 doc lock-in + three new structural decisions

Mark wanted the post-Ask-Posey roadmap pinned down before we got deep into M3-M7 implementation. NEXT.md restructured into three explicit milestone groups:

- **M3-M7 Ask Posey feature work** (M7 absorbed the previous M8 source-attribution + indexing-indicator UI work so navigation, auto-save, attribution, and the in-sheet "Indexing N of M sections" affordance all ship together — they share the same surface).
- **M8 — Feature pass:** Reading Style preferences (Standard / Focus / Immersive / Motion) as preferences not modes, Motion mode three-setting design (Off / On / Auto with explicit consent before CoreMotion), audio export to M4A, full format-parity audit across all 7 formats, Mac Catalyst verification, multilingual embedding verification, entity-aware multi-factor relevance scoring v2, lock-screen + background audio support (added later via Mark's follow-up: `AVAudioSession.playback`, `UIBackgroundModes` audio, `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`).
- **M9 — Polish pass:** antenna default OFF for release, dev tools compiled out of release builds (`#if DEBUG`), full accessibility pass on device, landscape centering polish, go-to-page UX polish, app icon (serif P with oversized librarian glasses, monochromatic with subtle warm tortoiseshell tint).
- **M10 — Submission:** privacy policy, App Store metadata, screenshots via simulator MCP, App Store Connect navigation via supervised browser automation, final submission.

DECISIONS.md three new entries:
1. **Reading Style is a preferences section, not separate modes** — discoverability + consistency.
2. **Motion mode three-setting design (Off / On / Auto, with explicit consent)** — different users want different things; a single auto-detect can't serve all three.
3. **Dev tools compiled out of release builds** — security, professionalism, App Store integrity, predictability.

## 2026-05-01 — Pre-M3 fix sweep: Illuminatus front matter, TOC fallback, indexing UI, page nav

Mark's reproduction case for the new embedding-index path was the Illuminatus TRILOGY EBOOK — a 1.6M-char EPUB from the Internet Archive. Five issues surfaced together; one investigation shaped two fixes; the rest landed in their own commits.

**Investigation (committed answers, no code changes).** Mark asked: is the disclaimer text I see at open Posey-generated, or is it actually EPUB content? I unzipped his Illuminatus locally and checked. **Answer: it's content.** The EPUB has a `notice.html` spine item containing the Internet Archive's hocr-to-epub disclaimer ("This book was produced in EPUB format by the Internet Archive…"). The same investigation showed why the TOC button was hidden: `toc.ncx` and `nav.xhtml` are both stub files (`<navMap/>` and `<ol/>` with no entries) — the EPUB ships with a placeholder TOC that has no actual contents.

**Fix #3 — synthesize TOC from spine when nav/NCX is empty (`f901b88`).** New fallback in `EPUBDocumentImporter.buildTOCEntries` triggers when nav/NCX yields zero usable entries. One synthesized entry per spine item, titled by priority: first `<h1>`/`<h2>`/`<h3>` inner text → `<title>` element → file name stem → "Chapter N". Heading extraction is regex-based (NSRegularExpression) rather than XMLParser-based so the malformed markup auto-generators emit doesn't defeat parsing. For Illuminatus this produces ~471 "Page N" entries — bad UX as a flat list, but pairs with #5 (Go-to-page input) so the user has a usable navigation surface. Tests: `EPUBSpineTOCFallbackTests`, 4 cases.

**Fix #2 — detect & skip Internet Archive front matter (`d034eb7`).** Same playback-skip-offset plumbing used for PDF TOCs. New `EPUBFrontMatterDetector` inspects the first ≤5 spine items and trips when any of three substrings match (case-insensitive): "produced in epub format by the internet archive", "created with hocr-to-epub", `<title>notice</title>`. Stops at the first non-matching spine item (front matter is, by definition, at the front). False-positive bar is high; the heuristic targets a known auto-generator. `ParsedEPUBDocument.playbackSkipUntilOffset` is set to the offset of the first body spine item; `EPUBLibraryImporter` threads it into `Document.playbackSkipUntilOffset`; `ReaderViewModel.init`'s existing skip-region filter does the rest (segments and display blocks past the offset are removed from the data model so the user can't land, scroll, or play the disclaimer). Synthesized TOC is filtered to drop entries pointing at front-matter spine items. Tests: `EPUBFrontMatterDetectorTests` (7 cases) + `EPUBImportFrontMatterIntegrationTests` (2 cases) building synthetic IA-style EPUB trees on disk.

**Fix #1 + #4 — indexing indicator + AFM-gated visibility (`daed324`).** Investigation root cause: Illuminatus's slow load was the embedding step running synchronously on the main thread (~3,300 chunks × ~5–10ms NLEmbedding call = 16–33s of frozen UI). Two-part fix:

1. New `DocumentEmbeddingIndex.enqueueIndexing(_:)` does CPU work (language detection, chunking, NLEmbedding) on `DispatchQueue.global(qos: .userInitiated)`, then hops back to main for the SQLite write (the sqlite3 handle isn't thread-safe; the rest of the app treats main as canonical SQLite thread). NotificationCenter posts `.documentIndexingDidStart`, `.didComplete`, `.didFail` bracket the work. All 7 library importers now call `enqueueIndexing` instead of the previous synchronous `tryIndex`.
2. New `IndexingTracker` (`@MainActor ObservableObject`) subscribes to those notifications and exposes `@Published indexingDocumentIDs: Set<UUID>`. ReaderView owns a `@StateObject` and renders an "Indexing this document…" pill at the top of the reader when the current document's ID is in the set. **Hidden entirely when `AskPoseyAvailability.isAvailable == false`** — per spec, AFM-unsupported devices get no Ask Posey surface at all (the embedding work itself still runs, since it's useful for future semantic search regardless of AFM, but the user-facing affordance is silent).

The Sendable-correctness work was the trickiest part: the background closure deliberately captures only Sendable values (`database`, `configuration`, `documentID`, `plainText`) and uses static helpers for chunking/embedding, so the closure's `@Sendable` requirement is satisfied without dragging the non-Sendable `self` into the capture list. A new `static chunk(_:configuration:)` overload was added so the closure doesn't need access to `self.configuration`. Block-04 of the file was also marked `nonisolated extension` so language and cosine helpers stay callable from the nonisolated class methods.

**Indexing banner progress count (`c9b4867`).** Mark's follow-up after #1+#4: an unmoving "Indexing…" with only a spinner can still look hung on big documents. Add a count. Banner now reads "Indexing this document…" with a "847 of 3,300 sections" line beneath when progress data is available. New `.documentIndexingDidProgress` notification posted from the background loop every 50 chunks (every-chunk would flood the main queue; 50 gives ~6 updates/sec at typical 5–10ms-per-chunk pace). `IndexingTracker.IndexingProgress` struct tracks `(processed, total)` with a clamped fraction; cleared on completion or failure. Determinate `ProgressView(value:)` ring fills visibly as the count advances. Accessibility label includes percentage so VoiceOver gets the same forward-motion signal. Tests: 4 new IndexingTrackerTests cases.

**Fix #5 — Go-to-page input in the TOC sheet (`4098815`).** New `DocumentPageMap` builds a 1-indexed page → plainText offset map from existing on-disk data (no schema migration). Per format:
- **PDF:** walk `displayText`, count form-feed (`\u{000C}`) separators. Each page's plainText offset = sum of preceding pages' plainText-equivalent length + (preceding-page-count × 2 for `\n\n` separators in plainText). Visual page markers (`[[POSEY_VISUAL_PAGE:N:UUID]]`) get stripped at offset-compute time so they contribute 0 chars (matching how `plainText` is built at import).
- **EPUB:** harvest "Page N" titles from the (possibly synthesized) TOC entries. Sort by page number; gaps backfill to the previous known offset so missing or out-of-order entries don't crash a lookup. `\bpage\b` word boundary rejects "Pageant", "Pages 5", etc.
- **Other formats:** empty map; Go-to-page UI hidden.

`ReaderViewModel.jumpToPage(_:) -> Bool` mirrors `jumpToTOCEntry`'s semantics. `TOCSheet` adds a "Go to page" Section with a number-pad TextField, Go button, "of N" hint, inline error text, and a footer caption that's accuracy-honest per format ("Page numbers track the source PDF's pages." vs. "Page mapping for EPUBs is approximate…"). Tests: `DocumentPageMapTests`, 13 cases covering both builders, edge conditions, and the empty/non-paginated fallthrough.

**Verification.** Each fix passes its targeted simulator suite; full device regression on Mark's iPhone 16 Plus pending at end of fix sweep. Mark's existing Illuminatus import will need to be re-imported on device for the new playback-skip offset to apply; position memory inside the front-matter region is automatically migrated to segment 0 of the body by `ReaderViewModel.restoreSentenceIndex`.

## 2026-05-01 — Ask Posey Milestone 2: multilingual document embedding index

Built the per-document chunk index used by Ask Posey for RAG retrieval. Hooked into all 7 library importers (TXT/MD/RTF/DOCX/HTML/EPUB/PDF) so chunks land at import time across every supported format per the format-parity standing policy.

**`DocumentEmbeddingIndex`** (`Posey/Services/AskPosey/`) is the canonical surface:

- Chunking: 500-char windows with 50-char overlap, configurable via `DocumentEmbeddingIndexConfiguration` so tests can build deterministic chunkings without monkey-patching the static surface.
- Language detection via `NLLanguageRecognizer.dominantLanguage` (samples first 1000 chars).
- Embedder selection: `NLEmbedding.sentenceEmbedding(for: detectedLanguage)`. English fallback when no per-language model ships. Hash embedding (Hal Block 05 shape, 64-dim, normalised to unit vector) as final fallback so import never fails on a model gap.
- `embedding_kind` per row records exactly which model produced each embedding (`"en-sentence"`, `"fr-sentence"`, `"english-fallback"`, `"hash-fallback"`). Search queries the right embedding model per kind so query and chunk vectors live in the same space, even when a document was indexed with a different model than the simulator/device currently has available.
- Public surface: `indexIfNeeded(_:)` (idempotent), `rebuildIndex(for:plainText:)` (force rebuild), `search(documentID:query:limit:)` (returns top-K results sorted by cosine).

**`DatabaseManager`** got chunk-table helpers in a new Block 05C: `replaceChunks` (transactional — wraps the delete + N inserts in `BEGIN/COMMIT` so a failure rolls back), `chunkCount`, `chunks`, `deleteChunks`. Embeddings packed as little-endian Double BLOBs.

**Library importers** all gained an optional `embeddingIndex: DocumentEmbeddingIndex?` initialiser parameter (default nil so existing tests and call sites compile unchanged). After `upsertDocument`, every importer calls `try? embeddingIndex?.indexIfNeeded(document)` — the `try?` is deliberate: indexing failures must NOT fail the import. The document is fully readable without RAG; the index will be retro-built on first Ask Posey invocation if it's missing.

**`LibraryViewModel`** holds a single shared `DocumentEmbeddingIndex` and hands it to all 7 importers — one instance per ViewModel lifetime, no global state.

**Multilingual from day one** per Mark's revised 12.3 answer: "Posey already supports multilingual documents, AFM is multilingual, and the fix is not complicated. English-only is a shortcut that creates unnecessary technical debt." The Gutenberg corpus has French (Hugo) and German (Goethe) samples and the synthetic corpus has Latin/Cyrillic/Greek/Arabic/CJK fixtures — those all exercise the language-detection branch.

**Tests** (`PoseyTests/DocumentEmbeddingIndexTests.swift`):

- `DocumentEmbeddingChunkingTests`: chunk boundaries with overlap, zero-overlap mode, empty text, offset → text round trip (this is the invariant that lets Milestone 6 render "jump to passage" links correctly).
- `DocumentEmbeddingLanguageTests`: English / French detection, embedding-kind round trip through `embeddingKind(for:)` and `language(forKind:)`, English/hash-fallback kind decoding, cosine-similarity baseline (1, 0, -1, mismatched-dim → 0, zero-mag → 0).
- `DocumentEmbeddingPersistenceTests`: end-to-end index → store → search; idempotent re-index; rebuild replaces priors; **cascade delete removes chunks** (relies on the foreign-key configuration verified by Milestone 1 tests); searching an unindexed doc returns empty (callers fall back to non-RAG); empty text throws.

**Sanity build green on simulator** before commit; full simulator test pass after the one Equatable fix below.

**Three mid-flight fixes** spread across two commits (the second landed after a token-limit reset and a Claude Code crash):

1. `DocumentEmbeddingSearchResult: Equatable` failed to synthesize because `StoredDocumentChunk` didn't conform. Auto-synthesis only fires when the type explicitly declares the protocol. Added `: Equatable` to `StoredDocumentChunk`.

2. **MainActor deinit crash on simulator.** Initial test run died with a malloc abort (`POINTER_BEING_FREED_WAS_NOT_ALLOCATED`) inside `swift::TaskLocal::StopLookupScope::~StopLookupScope`. Stack trace pointed at `DocumentEmbeddingIndex.__deallocating_deinit` calling into `swift_task_deinitOnExecutorImpl`. Root cause: Posey's project setting `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes every undecorated class implicitly `@MainActor`; XCTest runs test methods off the main thread; when the test method returns, the synthesised deinit tries to hop to MainActor to dealloc safely, and that hop trips a known Swift Concurrency runtime issue around TaskLocal scope teardown. Fix: mark `DocumentEmbeddingIndex`, its public types, and `DocumentEmbeddingIndexConfiguration` as `nonisolated` so deinit runs in-place with no executor hop. Verified post-fix: `nonisolated struct`/`enum`/`final class` all compile in Swift 5 mode + approachable concurrency, full M2 test suite green on simulator with no dealloc crash.

3. **Unused-`try?` warnings.** The `try? embeddingIndex?.indexIfNeeded(document)` pattern in each of the 7 importers warned because `try?` returns `Optional<Int>` (the `@discardableResult` only suppresses the inner method's warning, not the optional from `try?`). Added `tryIndex(_:)` to `DocumentEmbeddingIndex` — internally `do/catch` with NSLog on failure, never throws, returns Void — so importer call sites become `embeddingIndex?.tryIndex(document)`. Net wins: zero warnings, plus a breadcrumb for consistent indexing failures (a real bug we'd want to know about). The 7-importer call-site cleanup keeps format-parity by construction.

**Pushed to `origin/main` immediately** per the push policy. Committed across multiple checkpoints per Mark's 5-hour-limit guidance so nothing was lost when the limit hit mid-milestone.

**Next:** Milestone 3 — two-call intent classifier with `@Generable` enum.

## 2026-05-01 — Ask Posey Milestone 1: doc alignment + schema migrations + availability skeleton

Mark approved `ask_posey_implementation_plan.md` with answers to the 8 open questions:
- Spec supersedes; ARCHITECTURE/CONSTITUTION updated as part of this milestone (12.1).
- Retro-index existing imports on first invocation with a brief "Indexing..." state (12.2).
- Multilingual from the start (12.3) — change of direction from my draft. Posey already supports multilingual documents, AFM is multilingual, and `NLLanguageRecognizer` + per-language `NLEmbedding` is straightforward.
- Half-sheet confirmed but flagged as a design risk to validate on device (12.4).
- Real streaming (12.5).
- Privacy copy approved as written (12.6).
- "Working from the most relevant sections" copy + placement confirmed (12.7).
- Prose first; navigation in a later commit (12.8).

**What landed in Milestone 1:**

1. **`ARCHITECTURE.md` "Ask Posey Architecture" rewritten** to match the spec. One surface with intent routing (no longer "three modes"); two entry points in v1 (passage-scoped + document-scoped) with annotation-scoped explicitly deferred; persistent conversations with auto-save in `ask_posey_conversations`; rolling-summary tier modeled after Hal's MemoryStore; document-context tiers based on size; multilingual embedding index via `NLLanguageRecognizer` + per-language `NLEmbedding`; two-call intent + response flow; priority-ordered budget-enforced prompt builder (60/25/15); half-sheet UI with the design risk flagged.

2. **`CONSTITUTION.md` "Ask Posey" deliberate scope revision rewritten** to match. Persistent per-document memory; auto-save; multilingual; "private by design" not "100% on-device"; hidden entirely on AFM-unavailable devices.

3. **`DatabaseManager` migrations** for two new tables. Both follow the existing `CREATE TABLE IF NOT EXISTS` pattern with `ON DELETE CASCADE` from the documents table:
   - `ask_posey_conversations` — `(id, document_id, timestamp, role, content, invocation, anchor_offset, summary_of_turns_through, is_summary)` plus `idx_ask_posey_doc_ts`.
   - `document_chunks` — `(id, document_id, chunk_index, start_offset, end_offset, text, embedding, embedding_kind)` plus `idx_document_chunks_doc`. The `embedding_kind` column captures which embedding model the row was built with (per-language `NLEmbedding`, English fallback, or hash fallback) so Milestone 2 can re-index when the model changes.

4. **`AskPoseyAvailability`** at `Posey/Services/AskPosey/AskPoseyAvailability.swift`. Single chokepoint mapping `SystemLanguageModel.default.availability` to a local enum (`available`, `frameworkUnavailable`, `appleIntelligenceNotEnabled`, `deviceNotEligible`, `modelNotReady`, `unknownUnavailable`). No caching — availability can change at runtime when the user toggles Apple Intelligence in Settings or model assets finish downloading. The Ask Posey UI gates on `isAvailable`; per-spec, when false the entry points are hidden entirely (no greyed-out state, no upsell).

5. **Tests**:
   - `AskPoseySchemaMigrationTests` — confirms both new tables, both new indexes, `NOT NULL` / `PRIMARY KEY` / `BLOB` constraints, and (most importantly) that **`ON DELETE CASCADE` actually fires** because `PRAGMA foreign_keys = ON` is set at open time. If that pragma ever regresses, the cascade test catches it.
   - `AskPoseyAvailabilityTests` — confirms the API surface returns a consistent value, `isAvailable` agrees with `current`, the diagnostic description is non-empty, and the state type is properly `Equatable`.
   - `FoundationModelsAvailabilityProbe` — unchanged from yesterday's kickoff; round-trip skipped on simulator.

Acceptance: full PoseyTests suite passes on device; app boots; existing documents load; no behavior change. Migrations apply in-place to existing installs (the new tables don't affect the existing schema).

**Pushed to `origin/main` immediately** per the new push policy.

**Next:** Milestone 2 — document embedding index. Build chunks at import for all formats with multilingual `NLEmbedding`. Retro-index existing imports on first Ask Posey invocation with a brief "Indexing..." state.

## 2026-05-01 — Ask Posey kickoff: AFM verified end-to-end on device; implementation plan drafted

Step 1 of the Ask Posey implementation order (per `ask_posey_spec.md`) is complete: Apple Foundation Models is confirmed working on Mark's iPhone 16 Plus and partially working on the iOS 26.3 simulator.

**The probe** — `PoseyTests/FoundationModelsAvailabilityProbe.swift`, three diagnostic XCTests:
1. `testReportsSystemLanguageModelAvailability` — reads `SystemLanguageModel.default.availability` and logs the state.
2. `testCanInstantiateLanguageModelSession` — confirms `LanguageModelSession(model:instructions:)` constructs without throwing.
3. `testTinyPromptRoundTrip` — issues `try await session.respond(to:)` against a one-line prompt and asserts the response is non-empty.

**Results:**

| Surface | Framework loads | Availability OK | Session instantiates | Inference round-trip |
|---|---|---|---|---|
| **iPhone 16 Plus** (device, iOS 26.x) | ✅ | ✅ | ✅ (0.015s) | ✅ (1.541s) |
| **iPhone 17 Pro Max sim** (iOS 26.3) | ✅ | ✅ | ✅ (0.20s) | ❌ (timeout — model assets not installed in this simulator image) |

**Net:** AFM is fully usable on device. The simulator runs everything up to but not including actual inference, which is fine because device is the acceptance standard. The `availability != .available` gate that's already part of the Ask Posey design (per Mark's resolved decision "AFM unavailable: hide the Ask Posey interface entirely") will silently handle simulators with broken assets the same way it handles unsupported devices in the wild.

**`ask_posey_implementation_plan.md`** — drafted. Covers AFM API surface, module breakdown (`Features/AskPosey/`, `Services/AskPosey/`), schema migrations (`ask_posey_conversations`, `document_chunks`), the two-call intent + response flow, prompt builder (Hal Block 20.1 analog with the spec's 60/25/15 split), embedding-index lifecycle (build at import for ALL formats per format-parity), modal sheet UI, threading model, persistence semantics, test plan, and a 7-commit milestone sequence. Includes 8 open questions raised explicitly per the no-assumptions rule — most importantly **a documented discrepancy** between the spec (which persists conversations and auto-saves) and `ARCHITECTURE.md` / `CONSTITUTION.md` (which currently describe a transient session model with explicit save). The spec is dated 2026-05-01 and resolves Mark's earlier open questions, so my read is the spec supersedes; the older docs need updating to match before code lands.

**Status:** plan-first per CLAUDE.md. No feature code written. Awaiting Mark + Claude (claude.ai) review of the plan and resolutions to the open questions before Milestone 1.

## 2026-05-01 — TOC region completely hidden from the reader (PDFs)

Mark's spec: "The TOC should be completely invisible in the reading view — never scrollable, never read aloud, never reachable via navigation including rewind. Rewind should go to the first body sentence, same as first open. The TOC lives only in the navigation sheet."

Earlier behavior: only the *first-open scroll* skipped past the TOC. The TOC was still rendered as display blocks, still segmented for TTS, still reachable via rewind, still searchable. Half-implemented.

**New behavior, implemented at `ReaderViewModel.init`:** the document's `playbackSkipUntilOffset` is consulted up front and used to filter both `segments` and `displayBlocks` so the skipped region doesn't enter the data model at all.

  - `segments` is rebuilt from `SentenceSegmenter.segments(for:)` then filtered to only those whose `startOffset >= skipUntil`. IDs are re-numbered 0-based contiguous (the rest of the view-model treats `segment.id` as an array index — currentSegment, marker navigation, search row IDs, etc.).
  - `displayBlocks` is filtered the same way before going through `splitParagraphBlocks`.
  - Character offsets are preserved on the remaining segments/blocks so position persistence continues to work in the existing plainText coordinate space.
  - `restoreSentenceIndex` now treats a saved offset that lands inside the (now-hidden) TOC region as a migration case → returns segment 0 (first body sentence). Documents saved by older builds with a position inside the TOC come back to the first body sentence on next open instead of getting stuck.

**Net effect on listening experience:**
- Rewind / restart from beginning lands on the first body sentence.
- Sequential playback never reads the TOC.
- Scroll never reveals TOC content; the reader's data model literally doesn't contain it.
- Search cannot match inside the hidden region.
- The TOC sheet (chrome button) still surfaces parsed entries for navigation — that's the only way to access the TOC, and it's a navigation surface, not a reading surface.

Tests: new `testPlaybackSkipRegionIsHiddenFromReader` in `ReaderViewModelTests` builds a synthetic doc with a TOC-shaped block + body, sets `playbackSkipUntilOffset` past the TOC, and asserts every constraint above (no segment starts inside the skip region, first segment is the first body sentence, restart lands at the first body sentence, a saved position inside the TOC migrates to the first body sentence, search can't find TOC text). Full PoseyTests passes on device.

## 2026-05-01 — NavigationStack double-push fixed; auto-restore of last document now reliable

Mark reported: tapping a document showed two slide-in animations and Back required two presses to return to the library. Diagnosed via simulator console capture (NSLog) plus the Posey unified log. Root cause was a two-bug interaction:

**Bug 1 — alert collision.** The "API Ready — Copied to Clipboard" alert is fired from `LibraryViewModel.toggleLocalAPI()`. With the antenna defaulting to ON, `.task` calls `toggleLocalAPI()` at launch, which fires the alert. At the SAME instant, `.task` also calls `maybeRestoreLastOpenedDocument()`, which sets `path = [doc]`. SwiftUI's `UIKitNavigationController` logs `_applyViewControllers... while an existing transition or presentation is occurring; the navigation stack will not be updated.` and the auto-restore push is silently dropped. The user's last document doesn't reopen and they see the library list instead.

Fix: `toggleLocalAPI(showConnectionInfo:)` parameter. Manual user toggles still surface the alert + clipboard copy. The launch-time auto-restart passes `false` and stays silent. The auto-restore push lands cleanly, no UIKit conflict.

**Bug 2 — `.task` re-fires on view re-appear.** `.task` runs whenever the LibraryView appears, including when popping back from the reader. The race: user taps Back → `path` mutates `[doc] → []` → library re-appears → `.task` re-fires `maybeRestoreLastOpenedDocument` → reads `lastOpenedDocumentID` (still set to `doc` because `.onChange(of: path)` hasn't yet propagated the clear) → re-pushes `[doc]`. Net effect: Back tap appears to do nothing; user has to tap Back twice. The same race causes Mark's "two slide-in animations" — when a user-tap and a queued auto-restore both land on the same path mutation cycle.

Fix: `@State private var didAttemptInitialRestore = false`. `maybeRestoreLastOpenedDocument` is now gated on this flag, set true on first run. Auto-restore happens exactly once per app launch — on the first time the library appears — never on subsequent appearances.

**Verified in the simulator** with the iPhone 17 Pro Max + iOS 26.3:
- Cold launch with `lastOpenedDocumentID` set: app auto-restores to the reader, no library flash.
- Tap Back: single tap returns to library, no bounce-back.
- Tap a doc: single push, single back to return.
- Repeat: same behavior across multiple cycles.

Full PoseyTests passes on device (`** TEST SUCCEEDED **`).

## 2026-05-01 — Shared TextNormalizer: TXT/MD imports reach parity with PDF; verifier green at 47/47

The synthetic-corpus verifier's first device run flagged 12 normalization specs failing. Diagnosis: every fix that had landed in `PDFDocumentImporter.normalize()` over time (line-break hyphens, ¬ as line-break marker, ZWSP / ZWNJ / ZWJ stripping, tabs → space, multi-space collapse, multi-blank-line collapse, per-line trailing whitespace strip, spaced-letter / spaced-digit collapse) had never been ported to the other importers. Real bug — TXT files in the wild (Word exports, clipboard pastes, web extracts) routinely carry these artifacts.

**`TextNormalizer`** — new file. Centralizes the normalization passes as `static` methods. `normalize(_:)` is the canonical full pass for plain-text input; the individual passes are also exposed so importers can compose them as needed (e.g. PDF runs `stripLineBreakHyphens` twice — once per page, again across page boundaries).

**Scope of this pass:**
- `TXTDocumentImporter.normalize` now delegates to `TextNormalizer.normalize`. All 11 previously-failing TXT specs now pass.
- `MarkdownParser.normalizeSource` now applies `TextNormalizer.stripBOM`, `stripInvisibleCharacters`, `normalizeLineEndings` before parsing. The MD path's soft-hyphen failure now passes.
- `PDFDocumentImporter` is unchanged in this pass — its proven `normalize()` keeps running. Migrating it to delegate to the shared utility is a future cleanup that risks behavior drift; deferred until tests against the real-world PDF corpus catch any divergence.

**Bug found and fixed during the change:** my first cut used Swift's `\u{00AC}` escape syntax inside a raw regex string (`#"...[-\u{00AC}]..."#`), which the ICU regex engine doesn't understand — it sees the literal characters `\u{00AC}`. The PDF importer correctly uses `¬` (no braces, ICU syntax). Fixed by switching to literal `¬` and `\x0c` inside the raw string.

**Verifier results:**

| Run | Pass | Fail |
|-----|------|------|
| Baseline (no fix) | 35 | 12 |
| TextNormalizer integrated | 45 | 2 (regex bug) |
| Regex bug fixed | **47** | **0** |

Full PoseyTests suite passes on device (113 cases, 0 failures). The verifier and corpus generator now form a runnable regression check — run `python3 tools/verify_synthetic_corpus.py` after any normalization change.

Also fixed a verifier-side false negative: the `txt/01_soft_hyphens.txt` assertion looked for lowercase `'footnotes'` while `PROSE_LINES` has the word at the start of a sentence (`'Footnotes'`). Now case-insensitive.

## 2026-05-01 — PDF TOC detection: skip-on-playback + auto-populated navigation

Mark imported "The Internet Steps to the Beat.pdf" — a scholarly paper whose first page is a Table of Contents — and noticed it would read the TOC aloud sentence by sentence ("Table of Contents I. Introduction. Three. Two. Technology. Six…"), a uniformly poor listening experience. Building TOC detection at PDF import time so the user gets useful behavior instead.

**`PDFTOCDetector`** — new file. Operates on per-page plaintext (the `readableTextPages` array the importer already builds). Two-stage heuristics:

1. **Anchor detection.** Find a TOC anchor — `"Table of Contents"` (case-insensitive) or a standalone `Contents` token. Limited to the first 5 pages so a TOC-looking section in the middle of a document doesn't accidentally mask real content.
2. **Density confirmation.** A page is a TOC page only when it ALSO has at least 5 dot-leader entries (`[.…]{2,}\s*\d+`). The combination is precise — false-positives on ordinary prose require both an anchor phrase AND a high dot-leader rate.
3. **Continuation walk.** Pages immediately after a confirmed TOC page that have ≥5 dot-leaders and a high density (chars/entries < 200) are treated as TOC continuations. Multi-page TOCs work.
4. **Best-effort entry parsing.** Forgiving regex extracts `(label.) (title) (dot-leaders) (page-number)` triples. Roman numerals, capital letters, digits, and lowercase letters all recognized as labels. Embedded dots in titles (`v.` in `RIAA v. mp3.com`) tolerated. Misses rare/exotic formats; that's an acceptable tradeoff because the playback-skip region is the primary value, entries are a navigation aid.
5. **Title-to-offset mapping.** Each parsed entry's body offset is computed by searching plainText for the title text after the TOC region. The TOC sheet (already wired for EPUB) just works for PDFs now too.

**Persistence.** `documents.playback_skip_until_offset` (new INTEGER column, default 0, migration via the existing `addColumnIfNeeded` helper). `Document.playbackSkipUntilOffset` round-trips through DatabaseManager. Entries persist via the existing `document_toc` table.

**Reader behavior.** `ReaderViewModel.restoreSentenceIndex` checks the document's `playbackSkipUntilOffset` after computing the saved-position match. If the resolved sentence falls inside the skip region, it advances to the first sentence at or after `playbackSkipUntilOffset`. Result: the user opens a PDF with a TOC and the active sentence is the first body sentence. The TOC is still visible in the reader (you can scroll up to see it); it just isn't the first thing TTS reads. The TOC button in the chrome surfaces parsed entries for navigation when present.

**Tests:** Six new unit tests in `PDFTOCDetectorTests` against verbatim text from Mark's actual PDF and against synthetic positive/negative cases (multi-page continuations, late-document TOC anchors that should be ignored, prose containing the phrase "Table of Contents" without dot leaders that should NOT trigger). All pass on device (113 cases total in the full suite, 0 failures).

End-to-end on-device verification still requires re-importing the source PDF; the code path is exercised entirely by unit tests with Mark's real data.

## 2026-05-01 — Step 3 Project Gutenberg corpus downloader

`tools/fetch_gutenberg.py` — downloads 28 deliberately curated public-domain books from Project Gutenberg via the Gutendex API for stress-testing Posey against real prose. Categories cover the kinds of writing Posey is likely to encounter: simple prose (Twain, Brontë, Dickens, Austen, Hemingway), structured non-fiction (Darwin, Smith, Mill, Thoreau, James), poetry (Whitman, Shakespeare, Dickinson, Eliot), drama (Shakespeare, Shaw), technical (Euclid, Plato, Kant), illustrated (Carroll, Barrie, Grahame), short stories (Poe, Chekhov), other-language samples (Hugo in French, Goethe in German), and longform stress tests (Tolstoy, Melville).

Each entry is fetched by Project Gutenberg ID where possible (deterministic across runs) or by Gutendex search query as fallback. EPUB is preferred; plain TXT is the fallback when EPUB isn't available. The script writes a `manifest.json` recording id, title, author, language, subjects, source URL, and download count for each fetched book — making the corpus self-describing for later analysis.

Dependency-free (Python stdlib only). Caches by default — re-running skips already-downloaded books unless `--refresh` is passed. `--list` previews the curated selection without fetching, `--categories` restricts the fetch to one or more categories, `--output-dir` overrides the default `~/.posey-gutenberg-corpus`.

Verified end-to-end with the `poetry` category (4 EPUBs, 1.8 MB total, manifest written correctly).

Pair with `verify_synthetic_corpus.py`-style auditing to drive the books through Posey's import pipeline and capture any normalization, segmentation, or display failures on real content.

## 2026-05-01 — Step 2 synthetic test corpus generator + verification harness

Two new tools that turn "did the normalization pipeline regress?" into a runnable assertion.

**`tools/generate_test_docs.py`** — produces 47 deterministic edge-case documents across TXT (31), MD (7), HTML (7), and RTF (2). Each document targets ONE class of artifact so a regression can be located precisely. TXT coverage spans soft hyphens, line-break hyphens, ¬ markers, NBSP, ZWSP, BOM, tabs, mixed line endings, trailing whitespace, excessive blank lines, spaced uppercase / lowercase / accented / digits, ligatures, mixed scripts (Latin/Cyrillic/Greek/Arabic/CJK), emoji, combining diacritics, RTL, empty, only-whitespace, single character, only punctuation, very long no-punctuation runs, dot-leader TOC, only page numbers, repeated boilerplate, ~100 KB documents, unbalanced quotes, very long URLs. MD covers all heading levels, nested lists, code blocks, nested blockquotes, inline HTML, and artifacts inside markdown. HTML covers no-paragraph, inline styles, tables, `<script>`/`<style>` removal, entity decoding, and 20-level deep nesting. RTF covers baseline + styled.

The generator is dependency-free (Python stdlib only) and deterministic — repeated runs produce byte-identical output. PDF/EPUB/DOCX edge-case generators are deferred to a sibling Swift script (planned).

**`tools/verify_synthetic_corpus.py`** — drives Posey through the corpus end to end:
1. Optionally regenerates the corpus
2. `RESET_ALL` the device to start clean
3. Imports every synthetic doc via the local API
4. For each doc, fetches `GET_PLAIN_TEXT` and `GET_TEXT` and runs a per-doc assertion that encodes the expected normalization (e.g. "no U+00AD chars survived", "`C O N T E N T S` → `CONTENTS`", "BOM stripped")
5. Prints a PASS / FAIL summary and exits non-zero on any failure

Two documents (`txt/20_empty.txt` and `txt/21_only_whitespace.txt`) are configured to expect REJECTION — the importer correctly throws `.emptyDocument` for them, and the verifier checks the rejection happened.

**Usage:**
```
python3 tools/generate_test_docs.py            # writes corpus to ~/.posey-corpus
python3 tools/generate_test_docs.py --list     # preview what would be generated
python3 tools/verify_synthetic_corpus.py       # generate + verify against the live device
python3 tools/verify_synthetic_corpus.py --no-reset  # don't wipe the device library
python3 tools/verify_synthetic_corpus.py --limit 5   # quick smoke
```

The verifier requires the local API to be configured (`tools/posey_test.py setup <ip> 8765 <token>`) and the antenna toggled on in the app. It deliberately reuses `posey_test.py`'s HTTP transport via `importlib`, so there's no second copy of the connection logic.

## 2026-05-01 — Step 8 accessibility pass: VoiceOver labels, Reduce Motion, search-bar touch targets

First wave of the accessibility commitment. Audit performed via the simulator MCP accessibility tree on both Library and Reader views; findings implemented in a single batch.

**VoiceOver labels added.** All eight reader chrome buttons (search, TOC, preferences, notes, previous, play/pause, next, restart) had accessibility identifiers but no `accessibilityLabel`. SF Symbol images are not announced as anything readable, so VoiceOver users got either silence or guessed icon names. Each button now has a concrete spoken label — `"Search in document"`, `"Table of contents"`, `"Reader preferences"`, `"Notes"`, `"Previous sentence"`, `"Play"`/`"Pause"` (state-aware), `"Next sentence"`, `"Restart from beginning"`. The three iconographic buttons in the search bar (chevron up/down, clear) gained `"Previous match"`, `"Next match"`, `"Clear search"`.

**Search bar touch targets.** The chevron-up, chevron-down, and clear (xmark) buttons in the search bar were SF Symbol images at footnote font size with no explicit frame — their hit targets were ~22 pt, well below Apple's 44×44 minimum. Each now wraps its image in `.frame(width: 44, height: 44)`, matching every other custom button in the app.

**Reduce Motion respected.** All animations in the reader view now check the system setting before easing. `@Environment(\.accessibilityReduceMotion)` is read at the view level for chrome-fade and search-bar transitions. Inside the view model (which can't access SwiftUI environment values), a `static var reduceMotionEnabled` reads `UIAccessibility.isReduceMotionEnabled` directly — used for scroll-to-current-sentence and scroll-to-search-match. When Reduce Motion is on, state changes still happen instantly but skip their easing curves; the bottom-transport vertical-offset on chrome show/hide also stops to prevent residual motion.

**Tests:** Full PoseyTests suite passes on device (101 cases, `** TEST SUCCEEDED **`).

**Findings deferred for later passes (queued in NEXT.md):**
- Toolbar items in the Library nav bar (antenna toggle, Import File button) are visually present but absent from the accessibility tree. Looks like a SwiftUI navigation toolbar issue rather than a missing modifier — needs investigation.
- Tap-to-reveal-chrome was unreliable when driven via simctl/idb's synthetic taps (highPriorityGesture, simultaneousGesture, and onTapGesture all failed equally). Mark hasn't reported it on device, so this is likely a sim-only artifact rather than a product bug. Worth verifying on device with a real finger before changing the gesture model.

## 2026-05-01 — Center the active sentence in landscape too (and re-improve portrait)

Mark's portrait acceptance held but landscape "lost centering — disorienting." Investigation in the simulator at S050 with a forced-orientation env var confirmed the bug.

**What was actually wrong with the previous fix.** The earlier fix moved the top chrome from `.overlay` to `.safeAreaInset(.top)`, matching the bottom transport's existing `.safeAreaInset(.bottom)`. That made the scroll content area equal `(viewport − chrome insets)` and centered cleanly within it. But the bottom inset's claim included the home indicator strip — invisible to the user but counted as "not reading area" by the centering math. In portrait that strip is ~3.5 % of screen height and the offset was unnoticeable; in landscape the same strip is ~5 % of a much shorter screen, and the perceived center shifts visibly. Mark caught it.

**The actual centering anchor that matters.** What the user perceives as the reading area is bounded by the things that are *always* visible: the navigation bar at the top and the home-indicator strip at the bottom. The chrome capsules and the bottom transport fade in and out — they are not part of the persistent reading area. The centering math should target the persistent area, not the conservative scroll-content envelope.

**New fix.** Both chromes are now overlays again, only the search bar uses `safeAreaInset(.top)`, and only while it's active (interactive input must not get scrolled under). Result: the scroll content area equals (nav bar bottom → home indicator top), which IS the persistent perceived reading area. `anchor: .center` puts the active sentence at the true visual center in both orientations and across all chrome states.

**Measurements at S050 mid-document:**

| Orientation | State | Highlight center | Visual center | Off by |
|-------------|-------|------------------|---------------|--------|
| Portrait | chrome hidden | y=519 | y=516 | +3 |
| Landscape | chrome hidden | y=249 | y=243.5 | +5.5 |

When chrome is visible, the chrome capsules briefly float over the top/bottom edges of the reading area. The active sentence is well clear of those edges in both orientations, so it stays fully visible behind the still-translucent chrome. The cost vs the previous fix is that surrounding sentences (one or two above/below the highlight) get partially overlaid by chrome when chrome is visible — acceptable since chrome auto-fades within 3 seconds.

**Test-only orientation override.** `POSEY_FORCE_ORIENTATION=portrait | landscape | landscapeLeft | landscapeRight` env var added to `AppLaunchConfiguration` and acted on by `PoseyApp` via `UIWindowScene.requestGeometryUpdate`. Lets the simulator MCP (which has no rotation API) drive both orientations, and gives future automated UI tests a clean way to verify orientation behavior. Silently no-ops on platforms without UIKit window scenes.

## 2026-05-01 — Center the active sentence in the visible reading area

**Problem:** The active sentence drifted off the visible reading area's center. With chrome hidden it was ~37 px above visual center; with chrome visible it was ~62 px above. Mark called out "active sentence is always centered in the visible reading area regardless of font size, sentence length, screen orientation, or chrome state" as the non-negotiable acceptance criterion.

**Root cause:** The bottom transport controls used `.safeAreaInset(.bottom)` (correctly claiming layout space), but the top chrome buttons used `.overlay(alignment: .topTrailing)` (floating; no layout claim). `proxy.scrollTo(_, anchor: .center)` centers within the safe-area-adjusted scroll content area — which only included the bottom inset, not the top chrome. The geometric center of the scroll content sat above the visual center of the actually-visible reading region.

**Fix:** Convert the top chrome from `.overlay` to a top `.safeAreaInset` that always claims layout space, matching the bottom transport pattern. Search bar and chrome controls share the same inset slot (mutually exclusive). Chrome still fades visually via opacity, but its space is permanently reserved — so layout (and therefore centering math) is invariant across chrome state.

**Measurements (iPhone 17 Pro Max, 956 px tall, restored to S050 mid-document):**

| State | Highlight center | Visual reading-area center | Off by |
|-------|------------------|----------------------------|--------|
| Before fix, chrome hidden | y=478 | y=515 | −37 px |
| Before fix, chrome visible | y=478 | y=540 | −62 px |
| After fix, chrome hidden | y=514 | y=515 | **−1 px** |
| After fix, chrome visible | y=514 | y=534 | **−20 px** |

The remaining ~20 px when chrome is visible is the home-indicator strip below the bottom transport: `safeAreaInset(.bottom)` claims it as part of its inset, but visually the user can't perceive that strip as reading area. Chrome auto-fades within 3 s of any interaction, so this is the rarer state. Mark to confirm acceptability on device, including landscape orientation (the simulator MCP doesn't expose rotation; needs Mark's eyes for landscape acceptance).

**Verification:** Measured via the `ios-simulator` MCP accessibility tree at multiple sentence indices. Full PoseyTests suite passes on device (101 case lines, `** TEST SUCCEEDED **`).

**Tradeoff documented:** Reading area is now ~60 px shorter at the top permanently (matching the ~80 px already reserved at the bottom for transport). The "extra reading space when chrome fades" benefit is gone; the gain is invariant centering. Mark's spec explicitly required centering "regardless of chrome state," which favored the symmetric layout.

**Tooling:** Patched `/opt/homebrew/lib/python3.14/site-packages/idb/cli/main.py` to use `asyncio.new_event_loop()` instead of the removed-in-3.14 `asyncio.get_event_loop()`. fb-idb 1.1.7 doesn't yet support 3.14; this one-line workaround unblocks the simulator MCP. Worth noting in case fb-idb is reinstalled.

## 2026-04-30 — Restore scroll position on document open; tighten pause latency

Two acceptance issues from the Step 4 sign-off:

**Scroll position not restored on document open.** `ReaderView.onAppear` did call `scrollToCurrentSentence(with: proxy, animated: false)` immediately after `handleAppear` set the saved sentence index, but the LazyVStack hadn't yet realized rows up to the saved position when the call ran. `proxy.scrollTo(47, anchor: .center)` silently no-ops when row 47 doesn't exist in the layout — which is why pressing Play after open used to "fix" the scroll: the on-change handler re-fired the same call once the view had updated. Fix: defer the initial scroll to two short async ticks (60 ms then 180 ms) inside a `Task @MainActor`, giving the LazyVStack time to advance its lazy realization to the target row. The first nudge handles the typical case; the second covers documents long enough that the first scroll only partially advanced realization.

**Pause latency.** `pauseSpeaking(at: .word)` waits for the next word boundary before the audio actually halts; on the Best Available (Siri-tier) audio path that delay can be hundreds of milliseconds — long enough to feel broken in real use. Switched to `.immediate` so the synthesizer cuts mid-word the moment the user taps pause. Reading apps resume from the saved sentence anyway, so a clean cut beats a polished-sounding lag. Belt-and-suspenders: also tightened `SentenceSegmenter.maxSegmentLength` from 600 to 250 chars (~15 s of speech). Each pre-buffered utterance is now short enough that AVSpeech state transitions feel instant, and read-along highlighting picks up tighter granularity as a bonus.

Tests: full PoseyTests suite passes on device (101 case lines logged, 0 failures, `** TEST SUCCEEDED **`).

## 2026-04-30 — Remember the last-opened document across cold launches

**Problem:** Per-document position memory was robust (saves on every sentence change, pause, scenePhase background, and onDisappear; restores from character offset with sentence-index fallback) — but at *cold launch* there was no "remember which document I was reading" persistence. Every kill→relaunch dumped the user back at the library list, even though the document's reading position was perfectly preserved. From the user's perspective, "Posey forgot where I was" — even though technically only the navigation state was lost.

**Change:**
- `PlaybackPreferences.lastOpenedDocumentID` (UUID, optional, UserDefaults-backed) added.
- `LibraryView.onChange(of: path)` writes `path.last?.id` to the preference whenever the navigation stack changes — pushing into a reader sets it; backing out to the library clears it.
- `LibraryView.maybeRestoreLastOpenedDocument()` runs from `.task` after `loadDocuments`. If a `lastOpenedDocumentID` exists and matches an existing document, it pushes that document onto the navigation path; ReaderView then restores the per-document reading position via the existing path. If the remembered document was deleted, the preference is cleared.
- `shouldAutoOpenFirstDocument` (the test-mode automation hook) takes precedence so that automated smoke runs aren't perturbed by previous-session state.

**Per-document position persistence (separately verified):** Code trace confirms `didStart` updates `currentSentenceIndex` and the ReaderViewModel sink persists every change. `synthesizer.continueSpeaking()` resumes from where pause was hit, preserving in-utterance position. No bug found in pause→resume; the kill→relaunch case was actually the document-reopening gap, not the position-saving gap.

**Tests:** Full PoseyTests suite passes on device (45 tests, 482 s).

## 2026-04-30 — Remove "Page N" chrome from PDF reader display; CLAUDE.md simulator policy

**Problem:** `PDFDisplayParser` injected a `Page N` heading at the top of every page in the rendered display blocks, breaking the rule that the reader should be a continuous reflowable stream. Page boundaries are useful as metadata but should never appear as visible chrome that interrupts reading.

**Change:** `PDFDisplayParser` no longer emits a `.heading(level: 2)` block for each page. Form-feed page separators in `displayText` and per-block `startOffset` values still preserve page boundary positions for any future feature that needs them; nothing was lost from the data model. TTS was not affected — `plainText` is built from page text without "Page N" prefixes, so playback never spoke the heading anyway. Marker navigation still works: each per-sentence sub-block produced by `splitParagraphBlocks()` already serves as its own next/previous target, and the page-heading block was effectively redundant.

**Test:** `testPDFDocumentUsesDisplayBlocksAndPreservesPageHeaders` renamed to `testPDFDocumentUsesDisplayBlocksWithoutPageHeadings` and now asserts no `Page N` heading is present. Full PoseyTests suite passes on device (45 tests, 482 s).

**CLAUDE.md updates:**
- Hardware Testing rewritten so the iOS Simulator is approved as a verification tool (accessibility tree, screenshots, UI automation) while the device remains the deployment + acceptance target. Anything verified only in the simulator is not yet verified for Mark; TTS quality must always be judged on device.
- Deploy commands now show the explicit `DEVELOPER_DIR="/Applications/Xcode Release.app/Contents/Developer"` prefix required because `xcode-select` points at CommandLineTools on this Mac and the Xcode bundle is named `Xcode Release.app`.
- Documented the simulator MCP install path (`claude mcp add ios-simulator npx ios-simulator-mcp` plus IDB companion) so the capability survives across sessions.

## 2026-03-27 — Verification of image storage, mixed-content PDF, filename sanitization, EPUB TOC navigation

**Image verification (confirmed with vision and pixel comparison):**
Added `GET_IMAGE`, `LIST_IMAGES`, `LIST_TOC` API commands and `imageIDs(for:)`, `tocEntries(for:)`, `insertTOCEntries(_:for:)` DB methods. `tools/verify_images.py` added: renders PDF pages on macOS via Swift/PDFKit, fetches stored PNG from device via `GET_IMAGE`, and compares using a Swift pixel comparator (CoreGraphics RGBA bitmaps, MAE < 15.0/255 threshold).

Direct visual verification result: All 11 Antifa visual-stop pages are genuinely blank pages (intentionally blank section-divider/verso pages in the physical book). Both stored images (17,246 B each, identical MD5) and macOS reference renders (20,265 B each, identical MD5) are blank white — they match. Byte-size difference is expected iOS vs macOS CoreGraphics rendering. GEB page 14 (mixed-content test) stored image confirmed correct: music staff figure plus full page text visible, matching reference render at 387,873 B.

Note for future: Antifa's 11 visual stops are all blank — Posey will pause playback 11 times to show an empty white page. Blank pages are probably not worth presenting as visual stops; a minimum-content threshold for visual stops (similar to the OCR minimum-text threshold) could suppress these.

**Mixed-content PDF pages (text + image both preserved — verified):**
`PDFDocumentImporter` previously dropped inline images on pages where PDFKit found text. Pages with both text and embedded images (figures, charts) now preserve both: text flows into the reading stream, and the page is also rendered as a visual stop inline immediately after. Detection uses `CGPDFDictionaryApplyFunction` on the page's XObject resource dictionary to check for Image-type streams — fast, no rendering required.

Verified with GEB (Gödel, Escher, Bach), which has pages containing both musical notation figures and prose text. Page 14 displayText was confirmed to contain text on both sides of `[[POSEY_VISUAL_PAGE:14:...]]`, and the stored image for that page shows the full page (music staff "Figure 3: The Royal Theme" plus Bach letter text) correctly.

**General filename sanitization (verified with live API tests):**
Replaced the narrow duplicate-extension check with `LibraryViewModel.sanitizeFilename(_:)`: strips null bytes, control characters, path separators (`/`, `\`), macOS-reserved characters (`:`, `|`, `?`, `*`, `<`, `>`, `"`), path traversal sequences (`..`), leading/trailing whitespace and dots, duplicate extensions, and truncates to 200 chars. Applied at the API import boundary and the PDF importer.

Verified by sending bad filenames through the live API: `report/2024:final*.txt` → `report_2024_final_`; `../../../etc/passwd.txt` → `_._._etc_passwd`; `file\0name.txt` → `filename`; `  leading spaces.txt  ` → `leading spaces`; `...dotleader.txt` → `dotleader`; `The Clouds Of High-tech Copyright Law.pdf.pdf` imported successfully as type `pdf` (duplicate extension stripped before importer selection).

**EPUB TOC as navigation surface (not silently skipped):**
Previous session silently dropped EPUB TOC/nav documents. This session reverses that direction:

- Nav documents (`properties="nav"` in manifest) are now included as readable XHTML spine content — TOC text appears inline in the document.
- `linear="no"` spine entries are now included (cover pages become visual stops; nav docs become readable TOC text).
- NCX files (EPUB 2) are still excluded as readable content (pure XML, not XHTML) but are now parsed for structured TOC data. Handles mislabelled NCX (`media-type="text/xml"`) via extension check and `<spine toc="...">` attribute fallback.
- New `EPUBNavTOCParser` (EPUB 3 nav) and `EPUBNCXParser` (EPUB 2 NCX) extract title/href pairs with play order.
- `buildTOCEntries()` resolves each TOC href to a plainText character offset by tracking cumulative chapter length during spine processing.
- `ParsedEPUBDocument.tocEntries: [EPUBTOCEntry]` carries structured TOC to the library importer.
- New `document_toc` SQLite table stores (title, plainTextOffset, playOrder) per document. Deduplication on `(title, offset)` prevents duplicate NCX sub-navPoints.
- `ReaderViewModel.tocEntries: [StoredTOCEntry]` loaded at init.
- `ReaderViewModel.jumpToTOCEntry(_:)` stops playback and jumps to the target sentence.
- `TOCSheet` (BLOCK P3): list of chapter titles, tap to jump to section and dismiss.
- Contents button (`list.bullet.indent`) in top chrome — only shown when `tocEntries` is non-empty.
- Verified: Data Smog fresh import produces 38 unique TOC entries (0 duplicates — deduplication on `(title, offset)` confirmed working). Offsets verified against plainText: Chapter 1 (5,979) → "Chapter 1 Spammed! I opened the front door…"; Chapter 5 (110,119) → "Chapter 5 The Thunderbird Problem…"; Acknowledgments (317,342) → "Acknowledgments This book is a quilt…". All correct.
- Potential fragility noted: `TOCSheet` uses `id: \.playOrder` in its List. If two entries ever share a playOrder value, the list will behave incorrectly. A composite id or a proper `Identifiable` conformance on `StoredTOCEntry` would be safer.

## 2026-03-27 — EPUB directory/image support, PDF image fix, highlight/scroll unification, OCR confidence gating, EPUB TOC filtering

**EPUB directory-format support:**
`EPUBDocumentImporter` now detects directory-format EPUBs (common on macOS where `.epub` bundles appear as folders) via `isDirectory` resource key, routing them to a filesystem-based loading path. Data Smog (757 KB) and 4-Hour Body (6.5 MB) now import correctly. Audit tool updated to zip directory EPUBs in memory before API transfer.

**EPUB inline image extraction:**
`EPUBDocumentImporter` pre-processes chapter HTML to extract `<img>` tags, load image data via the entry loader, and replace each tag with a `\x0c[[POSEY_VISUAL_PAGE:0:uuid]]\x0c` marker before `NSAttributedString` processes it. `EPUBDisplayParser` (new file) splits EPUB displayText on form-feed, creating `.visualPlaceholder` blocks for markers and per-sentence `.paragraph` blocks for text. `EPUBLibraryImporter` updated to pass `displayText` separately from `plainText` and call `saveImages()`.

**PDF visual page image persistence fix:**
`PDFLibraryImporter.persistParsedDocument()` and `importDocument(title:fileName:rawData:)` were never calling `saveImages()`. All visual page images (Antifa: 11, Feeling Good: 16, etc.) were parsed but never stored in `document_images`. Fixed — `saveImages()` now called from both import paths.

**OCR minimum text threshold:**
Pages where Vision OCR returns fewer than 10 characters after normalization are now treated as visual stops rather than text content. This catches near-blank pages where OCR picks up a lone page number or roman numeral, which previously appeared as invisible text blocks (the "page 3 skipped" issue in Antifa).

**OCR confidence gating:**
Vision returns per-word confidence scores on `VNRecognizedText`. Pages where average confidence is below 0.75 now return empty string from `ocrText()` and become visual stops. This catches garbled scan content (form pages, low-quality scans) that would otherwise be read aloud as meaningless character soup.

**EPUB TOC filtering:**
`EPUBPackageParser` now captures `media-type` and `properties` on manifest items. Items with `media-type: application/x-dtbncx+xml` (NCX TOC) or `properties: nav` (EPUB 3 navigation document) are excluded from the manifest and cannot be referenced by the spine. `<itemref linear="no">` spine entries are also skipped — these are out-of-reading-flow items (cover pages, nav documents) per the EPUB spec.

**Duplicate file extension normalization:**
`apiImport()` and `PDFLibraryImporter.persistParsedDocument()` now strip doubled extensions (`report.pdf.pdf` → `report.pdf`) before storing filename and deriving the title fallback.

**Highlight/scroll unification (Phase B):**
`ReaderViewModel.splitParagraphBlocks()` replaces each `.paragraph` DisplayBlock with one sub-block per TTS segment that starts within it. Non-paragraph blocks (headings, images, bullets, quotes) pass through unchanged. After splitting, `isActive(block:)` returns true only for the block containing the active utterance — highlight and auto-scroll now target exactly what is being spoken rather than an entire paragraph. This fixes the core read-along experience across all PDF and EPUB documents.

**CLAUDE.md:**
Added "Autonomous verification via the local API" as a standing practice. Before asking Mark to relay screen state, use the API (`GET_TEXT`, `LIST_DOCUMENTS`), visual page marker inspection, or macOS-side PDF rendering to verify correctness. Only escalate to Mark for things that genuinely require eyes on the physical screen.

**Audit result (20 files):**
Data Smog: 392,686 chars, 4 visual-pages ✓. 4-Hour Body: 994,821 chars, 453 visual-pages ✓. All existing files unchanged.

## 2026-03-27 — Third Normalization Pass + Phase A Segmenter + Clipboard API

**Normalization fixes (continued from earlier in same day):**

- **`PDFDocumentImporter`**: Four improvements:
  1. `collapseLineBreakHyphens` now also catches `¬` (U+00AC, NOT SIGN) used as a line-break marker by some PDF generators — `assis¬ tance` → `assistance`. Feeling Good lost ~5,876 chars of artifacts.
  2. `collapseLineBreakHyphens` pattern extended to `[ \n\x0c] ?` — catches the case where PDF text extraction inserts a space after the line-break separator (e.g. `rr-\n word` → `rrword`), and catches hyphens across page boundaries (`Jef-\x0cxxii` → `Jefxxii`) via a second post-join pass.
  3. Second `collapseLineBreakHyphens` pass runs on the joined `displayText` after all pages are assembled with `\x0c` — catches cross-page-boundary hyphens that the per-page normalization pass can't reach.
  4. `collapseSpacedLetters` patterns updated from ASCII `[A-Z]`/`[a-z]` to Unicode `\p{Lu}`/`\p{Ll}` — accented capitals like `Á` in `PASARÁN` now collapse correctly. Antifa chapter heading `PASAR Á N` → `PASARÁN`.

- **`HTMLDocumentImporter`** (cascades to EPUB): Added `injectParagraphMarkers()` — inserts U+E001 (Private Use Area) before each closing block-level tag (`</p>`, `</h1>`–`</h6>`, `</li>`, `</blockquote>`) in the raw HTML before `NSAttributedString` processes it. After extraction, U+E001 becomes `\n`, so each paragraph boundary yields `\n\n` instead of the single `\n` that NSAttributedString emits. This improves paragraph separation for HTML files; has no impact on Illuminatus EPUB (each EPUB "page" is one large `<p>` element — scan-per-page structure).

**Phase A — SentenceSegmenter oversized block capping:**

`SentenceSegmenter.swift` completely rewritten. After NLTokenizer or paragraph fallback, any segment over 600 chars is recursively split via:
1. Line breaks (`\n`)
2. Clause separators (em-dash, en-dash, semicolon)
3. Word-boundary split at 600 chars (last resort)

Offsets are recalculated correctly at each split so position restore and highlighting remain accurate. This caps TTS utterance length at 600 chars for all formats — including Illuminatus's 470 large EPUB blocks — preventing the `pauseSpeaking(at: .word)` unresponsiveness that long utterances caused.

**API clipboard UX:**

When the antenna is toggled on, `toggleLocalAPI()` now copies the full connection string (`http://IP:8765  token: …`) to `UIPasteboard.general` and shows an alert: "API Ready — Copied to Clipboard." No more hunting through Xcode console for the token.

**Full audit results (18 files, sorted by size):**

All 18 files imported successfully including Feeling Good (329.8 MB, 1.2M chars). Files sorted smallest-first so Feeling Good runs last and a crash there doesn't lose other results.

| File | Issues remaining | Notes |
|------|-----------------|-------|
| Proposal DOCX | ✓ Clean | |
| Resume PDF | 1 long-block | Wayback Machine URL block — structural, not fixable |
| Branded Agreement PDF | 1 long-block | Dense legal prose — structural |
| Universal Access PDF | 1 long-block | Wayback Machine URL block |
| Clouds Copyright PDF | 1 long-block | Wayback Machine URL block |
| 2009 New Media PDF | 3 long-blocks | Dense legal sections — structural |
| Internet Steps PDF | 1 long-block | Wayback Machine URL block |
| AI Book PDF | 1 long-block | Dense intro paragraph — structural |
| Illuminatus EPUB | 470 long-blocks | Scan-per-page EPUB; Phase A caps at 600 chars for playback |
| Antifa PDF | 8 long-blocks, 11 visual | Chapter headings have residual spaced-letter mangling (complex PDF artifact) |
| 2005 CBA PDF | 1 long-block | TOC — structural |
| Learning from Enemy PDF | 1 long-block | Dense header block — structural |
| 2014 MOA PDF | 2 long-blocks, 1 visual | Dense legal sections |
| New Media Sideletters PDF | 1 long-block | Dense legal section |
| Cryptography PDF | 1 long-block | Watermark text repeated every page — in source |
| Measure What Matters PDF | 1 long-block | Title page metadata |
| GEB PDF | 1 long-block, `q q q` spaced-lower | `q q q` is GEB formal-system notation, not an artifact |
| Feeling Good PDF | 102/106 spaced upper/lower, 13 long-blocks, 16 visual | Spaced artifacts are OCR noise from workbook exercise images — not fixable without false positives; long-blocks are structural chapters |

## 2026-03-27 — Comprehensive Normalization Pass + Expanded Audit Tool

Second quality audit pass. Findings from the first audit extended across all importers and the audit tool itself hardened to detect a wider class of artifacts.

**Normalization fixes (7 files changed):**

- **`CLAUDE.md`**: New Quality Standard section added as a standing law — "Do not limit analysis to known issues. Actively look for edge cases and foreseeable failure modes."
- **`HTMLDocumentImporter`** (cascades to EPUB): Added `\u{00AD}` Unicode soft-hyphen stripping + `collapseLineBreakHyphens` — the same fix already in PDF. Result: Illuminatus EPUB line-break hyphens 41 → 0.
- **`PDFDocumentImporter`**: Added `\u{00AD}` stripping (Antifa had 48) + new `collapseSpacedDigits` helper (collapses `1 9 4 5` → `1945` for PDF glyph-position artifacts). Result: Antifa unicode-soft-hyphens 48 → 0.
- **`TXTDocumentImporter`**: Added `\u{00A0}` no-break-space and `\u{00AD}` soft-hyphen normalization. Both were missing; TXT files from various editors commonly have them.
- **`RTFDocumentImporter`**: Added `\u{00A0}` and `\u{00AD}`. RTF from Word uses `\u{00A0}` heavily for non-breaking spaces.
- **`DOCXDocumentImporter`**: Added `\u{00A0}`, `\u{00AD}`, tab→space, excess-whitespace collapse, and `\n{3+}` collapse. Normalizer was minimal; now consistent with other importers.

**Audit tool hardening (`tools/posey_test.py`):**

New checks added to `_audit_text`:
- `unicodeSoftHyphens` — detects surviving `\u{00AD}`
- `nbspChars` — detects surviving `\u{00A0}`
- `zwspChars` — detects zero-width spaces (`\u{200B}`, `\u{200C}`)
- `bomChars` — detects BOM/ZWNBSP (`\u{FEFF}`)
- `tabChars` — detects tab characters that should have been normalised
- `strayFormfeeds` — detects `\x0c` in non-PDF formats (PDFs correctly excluded; all `\x0c` in PDF displayText are intentional page separators)
- `longBlockSamples` — first 120 chars of each long block for quick diagnosis
- `longBlockPunctDensities` — periods+!+? per 100 chars; <0.5 flagged ⚠ LOW, indicating NLTokenizer will likely fail to split the block into sentences
- Renamed `softHyphens` → `linebreakHyphens` for clarity (ASCII hyphen + whitespace patterns, distinct from Unicode soft hyphens)
- Fixed `longBlocks` split: was incorrectly using `\\f` (a no-op in the old code); now correctly splits on complete `[[POSEY...]]` markers and `\n\n` only — not `\x0c`, which is the PDF page separator, not a paragraph boundary

**Final audit results:**

| File | LB-Hyphens | Unicode SH | Long-blocks | Visual-pages | Notes |
|------|-----------|-----------|-------------|-------------|-------|
| Antifa PDF | 0 ✓ | 0 ✓ | 8 | 11 | Chapter headings have residual spaced-letter artifacts with accented chars (Á) — see below |
| AI Book PDF | 0 | 0 | 1 | 0 | |
| Cryptography PDF | 0 | 0 | 1 | 0 | Repeated ChmMagic watermark text on every page (in source, not fixable at normalization) |
| GEB PDF | 0 | 0 | 1 | 0 | `q q q` is intentional GEB formal-system notation, not an artifact |
| Illuminatus EPUB | 0 ✓ | 0 | 470 | 0 | Block segmentation open issue; each block has `Seite N von 470` EPUB boilerplate prefix (not fixable at normalization) |
| Learning_from_Enemy PDF | 0 | 0 | 1 | 0 | |
| Measure What Matters PDF | 0 | 0 | 1 | 0 | |

**Known residual issues (not fixed this pass):**

- **Antifa chapter headings**: Accented letters (`Á` in `PASARÁN`) break the `collapseSpacedLetters` regex which only handles ASCII. Requires Unicode-aware letter matching (`\p{Lu}`) — higher risk, deferred.
- **Antifa `ANTI - FASCISM`**: Space-hyphen-space artifact where the hyphen is surrounded by spaces (not a line-break hyphen). Would require a separate pattern. Rare; deferred.
- **Block segmentation**: 470 long-blocks in Illuminatus EPUB remains the top open issue. Architectural approach discussed separately — see NEXT.md.

## 2026-03-26 — Text-Quality Audit + Three Bug Fixes

First cross-format quality audit completed across test materials. Three bugs found and fixed.

**Fixes:**

- **PDF soft-hyphen normalization was broken.** `collapseLineBreakHyphens` ran before the `\n → space` conversion in `normalize()`, so it looked for `word- word` but the text still had `word-\nword` at that point. Fixed the regex from `- ` to `[ \n]` so it catches both forms at normalization time. Result: Antifa 1617→0 hyphens, GEB 167→0, Learning_from_the_Enemy 173→0, Measure What Matters 68→0.
- **EPUB import crashed on any empty or image-only chapter.** `htmlImporter.loadText` throws `emptyDocument` for chapters with no extractable text. The EPUB loop called it with bare `try`, so a single image chapter killed the entire import. Changed to `try?` — skip silent failures per chapter, only fail at the end if ALL chapters produced nothing. Illuminatus Trilogy went from failed import to 1.6M chars successfully extracted.
- **PDF title fallback for path-metadata.** Some PDFs store Windows file paths in the `PDFDocumentAttribute.titleAttribute` field (GEB: `C:\Documents and Settings\dave\Desktop\...`). Added a filter: discard any title containing `\` or `/` or ending in `.pdf`/`.obd` — fall through to filename instead. GEB now shows as `GEBen`.

**Audit results (7 of 8 files):**

| File | Chars | Soft-hyphens | Long-blocks | Visual-pages |
|------|-------|-------------|-------------|-------------|
| Antifa PDF | 519K | 0 ✓ | 8 | 11 |
| AI Book PDF | 71K | 0 | 1 | 0 |
| Cryptography PDF | 668K | 0 | 1 | 0 |
| GEB PDF | 1.89M | 0 ✓ | 1 | 0 |
| Illuminatus EPUB | 1.65M | 41 | 470 | 0 |
| Learning_from_the_Enemy PDF | 70K | 0 ✓ | 3 | 0 |
| Measure What Matters PDF | 430K | 0 ✓ | 1 | 0 |
| Feeling Good PDF | — | skipped (330 MB) | — | — |

**Remaining open issues (not fixed this session):**

- Long-blocks: every file has at least 1; Illuminatus EPUB has 470. This is the known block segmentation problem — NLTokenizer can't split large text chunks without sentence-ending punctuation. Needs architectural discussion.
- Illuminatus soft-hyphens (41): EPUB/HTML normalizer doesn't run `collapseLineBreakHyphens`. Same fix would apply; low priority.
- `posey_test.py audit` now skips files over 50 MB with a warning to prevent the 330 MB crash that ended the prior audit run.

## 2026-03-26 — Local API Server (Posey Test Harness)

Posey now has a local HTTP API that lets Claude Code interact directly with the running app over WiFi/USB — importing documents, querying extracted text, inspecting the database, and (later) conversing with Ask Posey.

What changed:

- `LocalAPIServer.swift` — new file under `Services/LocalAPI/`. NWListener-based HTTP server on port 8765. `@MainActor` class, no third-party dependencies. Keychain-backed bearer token (generated once, persists across launches). `getifaddrs` for LAN address discovery. Three endpoints: `POST /command`, `POST /import` (raw bytes + `X-Filename` header), `GET /state`.
- `LibraryViewModel` gains `localAPIServer`, `localAPIEnabled` (`@AppStorage`), `toggleLocalAPI()`, `executeAPICommand()`, `apiImport()`, `apiState()`. Toggle uses `isRunning` (not `localAPIEnabled`) as the gate so auto-start on relaunch works correctly.
- `LibraryView` toolbar: antenna icon (`antenna.radiowaves.left.and.right`) at top-left. Full opacity when server is running, 25% opacity when off. Tap to toggle.
- `.task` modifier auto-restarts the server on app relaunch if it was enabled when the app was last killed.
- `NSLocalNetworkUsageDescription` added to the app's Info.plist build settings — required for iOS to permit incoming TCP connections.
- `.gitignore` created — excludes `Posey Test Materials/` (large test files) and standard Xcode detritus.
- `tools/posey_test.py` — single durable Python test runner. Commands: `setup`, `state`, `cmd`, `ls`, `import`, `audit`. `audit` imports all files from `Posey Test Materials/`, runs text-quality heuristics (spaced letters, soft hyphens, long blocks, visual page markers), and writes `tools/audit_report.json`.

Why this matters:

- Eliminates the relay loop: CC can now import files, read extracted text, run quality checks, and inspect DB state directly from the Mac without Mark relaying screenshots. This is the foundation for tuning Ask Posey responses without a human in the middle of every test turn.
- Pattern adapted from Hal Universal's `LocalAPIServer` (Block 32) — same NWListener / Keychain / bearer-token architecture, proven in production.

Setup (one time per device, already done):

```
python3 tools/posey_test.py setup 169.254.82.33 8765 <token>
```

Then:

```
python3 tools/posey_test.py state        # verify connection
python3 tools/posey_test.py ls           # list documents
python3 tools/posey_test.py audit        # full text-quality audit of test materials
```

## 2026-03-26 — PDF Text Normalization: Spaced Letters And Line-Break Hyphens

Hardened the PDF text normalization pass with two new artifact fixes.

What changed:

- `PDFDocumentImporter.normalize` now calls two new helpers before the whitespace-collapsing passes.
- `collapseSpacedLetters` detects PDF glyph-positioning artifacts — sequences like `C O N T E N T S` or `I N T R O D U C T I O N` — and collapses them to `CONTENTS` / `INTRODUCTION`. Only fires on runs of 3+ single letters that are all the same case (all uppercase or all lowercase), which avoids false positives on normal prose sentence starts like "I wish…".
- `collapseLineBreakHyphens` collapses PDF typesetting line-break hyphens: `fas- cism` → `fascism`, `Mus- lim` → `Muslim`. Only fires when a lowercase continuation follows `"- "`, which distinguishes line-break splits from intentional compound words like `anti-fascist`.
- Both helpers use `NSRegularExpression` with replacement templates where needed.

Why this matters:

- Without these fixes, TTS reads section headings letter-by-letter ("C… O… N… T… E… N… T… S…") which is unlistenable.
- Line-break hyphens produce mid-word pauses and mispronunciations that break the listening experience on typeset PDFs.
- These are purely normalization-layer fixes — no changes to reader, playback, or persistence.

## 2026-03-26 — Font Size Persistence

Font size is now persisted globally across sessions.

What changed:

- `PlaybackPreferences` gains a `fontSize: CGFloat` property backed by `UserDefaults` (`posey.reader.fontSize`), defaulting to 18 if not yet set.
- `ReaderViewModel.fontSize` now initializes from `PlaybackPreferences.shared.fontSize` and writes back on every change via `didSet`.

Why this matters:

- Font size is a reader comfort preference, not a per-document preference. Losing it on every relaunch was friction. One global setting, persisted alongside voice mode, is the right model.

## 2026-03-26 — Document Deletion

Users can now delete documents from the library.

What changed:

- `DatabaseManager` gains `deleteDocument(_:)` — a simple `DELETE FROM documents WHERE id = ?`. Foreign key cascades (enabled via `PRAGMA foreign_keys = ON`) automatically clean up reading positions, notes, and stored images.
- `LibraryViewModel` gains `deleteDocument(_:)` which calls the DB method then reloads the document list.
- `LibraryView` adds swipe-to-delete on each row (trailing swipe, no full-swipe to avoid accidental deletions) with a confirmation alert: "Delete 'Title'? This will permanently remove the document and all its notes."

Why this matters:

- There was previously no way to remove an imported document. Required for re-importing corrected files and general library hygiene. The cascade delete means no orphaned notes, positions, or images remain.

## 2026-03-26 — Inline PDF Image Rendering (The GEB Feature)

Visual-only PDF pages now render as actual inline images in the reader, with tap-to-expand full-screen zoom.

What changed:

- `PDFDocumentImporter` now renders purely visual pages (where both PDFKit and OCR yield nothing) to PNG via `PDFPage.thumbnail(of:for:)` at 2× scale. Encoding uses `UIImage.pngData()` — simpler and thread-safe versus the earlier manual CGContext draw path.
- A new `PageImageRecord: Sendable` struct carries `(imageID: String, data: Data)` from importer to DB.
- `ParsedPDFDocument` extended with `images: [PageImageRecord]`.
- Visual page marker format extended: `[[POSEY_VISUAL_PAGE:N:UUID]]` — the imageID is embedded so the display layer can look it up at render time.
- `DatabaseManager` gains a `document_images` table (BLOB storage, `ON DELETE CASCADE`), plus `insertImage`, `imageData(for:)`, and `deleteImages(for:)` methods. `PRAGMA foreign_keys = ON` enables the cascade.
- `PDFLibraryImporter.persistParsedDocument` deletes stale image records then inserts fresh ones on every import, so reimports don't leave orphaned blobs.
- `PDFDisplayParser` updated to parse the new marker format and pass `imageID` through to `DisplayBlock`.
- `DisplayBlock` gains `imageID: String?` (nil for text blocks and old-format visual placeholders).
- `ReaderViewModel` gains `imageData(for:)` with an in-memory cache (first load hits DB, subsequent calls return cached data).
- `ReaderView.visualPlaceholder` now shows the actual image inline when available, with a small expand icon. Falls back to the text card for pages with no stored image (blank pages, pages where rendering failed, old imports).
- New `ZoomableImageView.swift` — `UIScrollView`-backed `UIViewRepresentable` with pinch-to-zoom (up to 6×), double-tap to zoom in/out, and automatic centering during zoom.
- New `ExpandedImageSheet` — full-screen `NavigationStack` sheet presenting `ZoomableImageView`. Opened by tapping any inline image.
- `ExpandedImageItem: Identifiable` — minimal token used with `.sheet(item:)`.

Why this matters:

- This is the core "GEB feature" — the reason images matter is books like Gödel, Escher, Bach where Escher prints are inseparable from the ideas. Posey now preserves those pages visually inline, pauses playback when reaching them, and lets the reader zoom into the detail before continuing.
- Storage as BLOBs in SQLite keeps the database self-contained: one file for backup, iCloud sync, or migration. No orphaned image files on disk.
- PNG at 2× scale preserves fidelity on detailed artwork. JPEG compression artifacts would be unacceptable for Escher-quality material.

## 2026-03-26 — Monochromatic UI Palette Established As Standing Standard

All reader UI elements — search bar, highlights, buttons, cursor — now use a monochromatic (blacks/whites/grays) palette.

What changed:

- TTS active sentence highlight: `Color.primary.opacity(0.14)` (was `Color.accentColor`).
- Search match highlight: `Color.primary.opacity(0.10)`; current match: `Color.primary.opacity(0.28)`.
- `.tint(.primary)` on `SearchBarView` so buttons and text cursor follow the monochromatic palette.
- Chevrons, Done button, and keyboard magnifier all inherit from `.tint(.primary)`.

Why this matters:

- Accent color (blue/yellow depending on device settings) broke the calm, text-first reading environment. Monochromatic highlights feel like a physical reading tool rather than an app UI element.
- Established as a standing standard: all future UI additions should use `Color.primary` opacity tiers and avoid accent colors unless there is a specific product reason.

## 2026-03-25 — PDF Import Progress Reporting

Added page-level progress reporting for PDF OCR imports.

What changed:

- `PDFDocumentImporter` gains an `ImportProgress` enum (`Sendable`) and an optional `(@Sendable (ImportProgress) -> Void)?` callback on both `loadDocument` entry points. The callback fires once per page that requires Vision OCR — "OCR: page 12 of 47".
- `ParsedPDFDocument` is now explicitly `Sendable` so it can cross actor boundaries safely.
- `PDFLibraryImporter` exposes `persistParsedDocument(_:from:)` — the DB-write phase as a separate callable method. LEGO-ized.
- `LibraryViewModel.handleImport` routes PDF to a new async path (`handlePDFImport`). Phase 1 (parse + OCR) runs on `DispatchQueue.global` via `withCheckedThrowingContinuation` — never blocks the main thread. Phase 2 (DB write via `DatabaseManager`) returns to the main actor. `DatabaseManager` stays single-threaded throughout.
- Progress messages flow back to the main actor via `Task { @MainActor in ... }` from the `@Sendable` callback.
- `LibraryView` shows a bottom banner ("Importing PDF…" → "OCR: page X of Y") while a PDF import is in progress. Import button is disabled during import. Banner appears/disappears with a slide+fade transition. `LibraryView` LEGO-ized.

Why this matters:

- OCR on a long scanned PDF previously blocked the main thread. Now the UI stays fully responsive.
- Users can see exactly what's happening ("OCR: page 12 of 47") rather than staring at a frozen screen.
- `DatabaseManager`'s threading constraint is preserved — it never leaves the main actor.

## 2026-03-25 — OCR for Scanned PDFs

Added Vision OCR fallback to the PDF import pipeline.

What changed:

- `PDFDocumentImporter` now attempts `VNRecognizeTextRequest` (accurate level, language correction on) on any page where PDFKit text extraction yields nothing.
- Per-page behavior: PDFKit text → OCR text → visual placeholder (in that priority order). Mixed PDFs (some text pages, some scanned pages) are handled correctly page by page.
- The `.scannedDocument` error now only fires if every page fails both PDFKit and OCR — i.e., the document is truly unreadable.
- Rendering: each blank page is rendered to a 2× grayscale CGImage via CGContext before Vision processes it. Grayscale is sufficient for OCR and keeps memory lower than RGBA.
- No changes to the reader, playback, or persistence layers.
- Existing unit tests all pass. The gray-rectangle fixture still correctly rejects (OCR finds nothing on a plain colored shape, as expected).
- LEGO-ized the file (5 blocks: models/errors, entry points, core parsing, OCR, helpers).

Why this matters:

- Scanned PDFs previously hit a hard rejection wall. This converts them from "cannot open" to "opens and reads" for any document where Vision can extract meaningful text.
- Uses Apple Vision — on-device, no network, no dependencies.

## 2026-03-25 — Tier 1 In-Document Search

Implemented Tier 1 string-match find bar for the reader.

What was built:

- `SearchBarView.swift` — inline find bar with query field, match counter ("X of N"), prev/next chevron navigation, clear button, and Done button. Autofocuses on appear. Driven entirely by bindings and callbacks — no internal search logic.
- `ReaderViewModel` search state and methods — `searchQuery`, `isSearchActive`, `searchMatchIndices`, `currentSearchMatchPosition`, `SearchScrollSignal` (counter-based to ensure onChange fires even on repeated same-index navigation), `updateSearchQuery`, `goToNextSearchMatch`, `goToPreviousSearchMatch`, `deactivateSearch`, `scrollToSearchMatch`, `isSearchMatch`/`isCurrentSearchMatch` variants for both segments and displayBlocks.
- `ReaderView` wiring — magnifying glass button in top chrome (stays visible while search is active by cancelling the chrome fade timer), `safeAreaInset(edge: .top)` presenting `SearchBarView` with slide+fade transition, `onChange(of: viewModel.searchScrollSignal)` dispatching scroll, `segmentBackground` and `blockBackground` helpers for layered highlighting (yellow at 0.22 opacity for matches, 0.55 for current match, accentColor for TTS active sentence).
- Match navigation wraps around at both ends.
- Search is dismissed via Done button or by clearing the query; chrome auto-fade restarts on dismiss.

Why this matters:

- Tier 1 in-document search is the first of three planned search tiers (string match → note body inclusion → semantic via Ask Posey).
- The `SearchScrollSignal` counter pattern solves the SwiftUI onChange edge case where navigating to the same match index twice in a row wouldn't fire the observer.

## 2026-03-22 — Project Foundation Pass

The repository started as the default blank SwiftUI app template with only:

- `PoseyApp.swift`
- `ContentView.swift`
- asset catalog files
- Xcode project metadata

This pass deliberately did not jump into broad implementation.
Instead, it established the project control layer so future work can move quickly without drifting away from the product brief.

Completed in this pass:

- inspected the initial Xcode project structure
- confirmed the app target is still a minimal starter template
- created the six root source-of-truth documents
- fixed Version 1 scope around local reading, playback, highlighting, notes, and resume behavior
- locked Block 01 to `TXT` only
- selected SQLite as the planned persistence layer for Version 1
- proposed a minimal app folder structure
- documented the initial domain model and Block 01 architecture

Why this matters:

- The largest early risk is scope expansion, not code complexity.
- A documented control layer makes handoff easier and reduces contradictory future decisions.

Course corrections made:

- Avoided premature setup for `EPUB`, `PDF`, or package integration.
- Avoided speculative abstractions for future formats.
- Avoided implementing note UI before the reader loop exists.

## 2026-03-22 — Block 01 Implementation Pass

Implemented the first runnable `TXT` reading loop in the app target.

Completed in this pass:

- replaced the starter app screen with a library-first shell
- added local `TXT` import using the system file importer
- added persisted `Document`, `ReadingPosition`, and `TextSegment` models in code
- added a SQLite-backed local storage layer for documents and reading positions
- added a reader screen that renders segmented document text with adjustable font size
- added sentence segmentation using `NLTokenizer` with a paragraph fallback
- added `AVSpeechSynthesizer` playback with play, pause, resume, and restart from current position
- connected the active sentence index to read-along highlighting
- persisted reading position on import, sentence changes, pause, disappear, and app background/inactive transitions

Important implementation choices:

- the reader currently renders one sentence chunk per row to make highlight and auto-scroll behavior simple and reliable for Block 01
- imported `TXT` contents are stored directly in SQLite rather than copied to a separate local file cache
- playback resume is sentence-based, which is intentionally approximate and consistent with Block 01 requirements

Current status:

- the app now compiles successfully for a generic iOS destination with code signing disabled
- runtime verification on a simulator was not completed in this environment because CoreSimulator was unavailable during command-line execution

Additional hardening completed in the same block:

- library reloads when returning to the root screen so imported content stays current
- re-importing the same `TXT` file content updates the existing document instead of creating a duplicate library entry
- reader restore now prefers the saved character offset when resolving the initial sentence, with sentence index as a fallback
- restart playback now truly restarts from the current sentence even if playback was paused

## 2026-03-22 — Autonomous QA Foundation Pass

Built the first automated QA loop for Posey around the existing Block 01 `TXT` flow.

Completed in this pass:

- added unit tests for text import, sentence segmentation, SQLite persistence, duplicate import handling, and reader restore logic
- added an integration-style reader view model test using deterministic simulated playback
- added a UI test scaffold for the preloaded `TXT` loop
- added launch-based test configuration for:
  - test mode
  - database reset
  - custom database path
  - fixture preload
  - simulated playback
- added deterministic fixture files for:
  - short sample
  - long dense sample
  - malformed punctuation-heavy sample
  - duplicate import sample
- added accessibility identifiers and observable test-mode state to the library and reader
- added Xcode unit and UI test targets plus a shared scheme

Verification completed in this environment:

- the project and test targets build successfully with `xcodebuild ... build-for-testing`

Validation still deferred to a fuller environment:

- executing iOS unit tests and UI tests still depends on simulator or device availability outside this session

## 2026-03-22 — QA Workflow Documentation Pass

Turned the QA harness into a documented operational workflow.

Completed in this pass:

- reviewed the automated harness against the actual Block 01 `TXT` loop
- documented how to run build-only validation, unit tests, UI tests, and the full automated loop
- documented launch hooks, accessibility identifiers, and current coverage boundaries
- added a small `scripts/run-tests.sh` helper for local execution
- documented the minimum simulator or device setup required for full automated execution

## 2026-03-22 — Runtime Test Preflight

Attempted to move from build-only validation to real destination execution.

Evidence collected:

- `xcodebuild -showdestinations` reported only placeholder iOS destinations plus `My Mac`
- `xcrun simctl list devices available` failed because CoreSimulator could not initialize a device set
- `xcrun devicectl list devices` failed waiting for CoreDevice to initialize
- an explicit `xcodebuild test` request for an iPhone simulator did not reach test execution because simulator services were unavailable

Current blocker state in this environment:

- no bootable iOS simulator destination is available to Xcode
- the attached iPhone is not visible as a usable runtime test destination to `devicectl`

This means automated tests currently build successfully but do not execute on a real iOS destination inside this session.

## 2026-03-25 — Minimal Notes And Bookmarks Pass

Extended the current reader with the smallest note-taking slice that fits the existing Block 01 architecture.

Completed in this pass:

- added a persisted `Note` model for notes and bookmarks
- added a `notes` table to the SQLite schema
- added note and bookmark creation from the active sentence in the reader
- added a notes sheet that lists saved annotations and can jump back to their anchored sentence
- surfaced annotation markers inside the sentence-row reader
- added deterministic tests for note persistence, note creation, bookmark creation, and jumping back to a saved annotation
- removed the simulated playback actor-isolation warning in the automated build path

Important implementation choice:

- notes are currently anchored to the active sentence instead of arbitrary text selection

Why this matters:

- it gives Posey a usable first annotation loop without broadening the reader beyond its current stable sentence-row rendering model

## 2026-03-25 — Real-Device Test Path Established

Reused the Malcome device-testing pattern to get Posey onto a connected iPhone instead of relying only on build-only validation.

Completed in this pass:

- confirmed the correct Xcode developer directory is required for CoreDevice visibility
- verified that Xcode can see the connected iPhone as a valid Posey destination
- ran `PoseyTests` on the physical device
- fixed a simulated playback timing test that failed on real hardware but not in build-only validation
- removed the noisy database-reset warning from the reset test
- added `scripts/run-device-tests.sh` as a dedicated on-device test wrapper

Important findings:

- real-device execution is now proven for the unit test target
- the current launch blocker for repeat runs is device lock state if the phone locks before test preflight completes
- UI tests still need a device-friendly preload path because the current fixture-path approach is simulator-oriented

## 2026-03-25 — Real-Device TXT Smoke Pass

Validated the current Block 01 loop on a connected iPhone through a direct app-launch smoke harness modeled after Malcome.

Completed in this pass:

- kept `PoseyTests` green on the physical device
- added inline TXT preload support so device automation no longer depends on simulator-visible fixture file paths
- added lightweight automation hooks for:
  - auto-open first document
  - auto-play on reader appear
  - auto-create note
  - auto-create bookmark
- added `scripts/run-device-smoke.sh` to build, install, launch, and verify Posey on-device without relying on XCUITest
- ran the smoke flow successfully on the connected iPhone and copied back the on-device SQLite database for verification

Verified on device:

- one TXT document imported
- one reading position persisted
- playback advanced beyond the first sentence
- one note and one bookmark were written to the local database

Current status:

- Block 01 now has both real-device unit-test coverage and a real-device app smoke path
- XCUITest-based UI automation on device is still unreliable because automation mode timed out while enabling, so the direct smoke harness is the current dependable hardware path

## 2026-03-25 — Markdown Reader Pass

Extended Posey from `TXT`-only content into the next smallest format slice: local Markdown import with preserved reading structure.

Completed in this pass:

- added lightweight `MD` import and parsing
- preserved headings, bullets, numbered lists, block quotes, and paragraph structure for reader display
- stored both `displayText` and normalized `plainText` for imported documents
- kept playback, highlighting, note anchors, and position restore tied to normalized plain text
- updated the library importer to accept `.md` and `.markdown`
- added Markdown fixtures and automated tests for parsing, import, and reader-model behavior
- extended the direct device smoke script so it can preload either `TXT` or `MD`

Important implementation choices:

- Markdown is not rendered with full rich-text fidelity
- the reader preserves structure that materially helps orientation, not every formatting nuance
- numbered lists now preserve their visible markers instead of flattening to a generic list row

## 2026-03-25 — Real-Device Markdown Validation Pass

Validated the new Markdown path on the connected iPhone.

Completed in this pass:

- ran `PoseyTests` successfully on the physical device after tightening a database timestamp assertion for real-device precision
- ran the direct smoke harness on device using `StructuredSample.md`
- confirmed the app can build, install, launch, import Markdown, auto-open the document, auto-play, persist reading position, and write note plus bookmark records on the phone

Verified on device:

- one Markdown document imported
- one reading position persisted
- playback advanced to sentence index `7`
- one note and one bookmark were written to the local database
- the imported title in the on-device database was `StructuredSample`

Operational note:

- on-device unit tests currently finish cleanly, but Xcode still logs a non-fatal diagnostic collection warning about `devicectl` path lookup after the suite completes

## 2026-03-25 — RTF Format Pass

Extended Posey to support local `RTF` import as the next smallest document-format block after Markdown.

Completed in this pass:

- added native `RTF` text extraction using attributed-text document reading
- added `RTF` library import and file-importer support
- added launch hooks and device-smoke support for inline `RTF` preload
- added deterministic `RTF` fixtures and automated tests for importer and library persistence behavior

Important implementation choices:

- Posey currently stores the extracted readable `RTF` string as both `displayText` and `plainText`
- the reader does not attempt to mirror rich `RTF` styling yet

## 2026-03-25 — Real-Device RTF Validation Pass

Validated the new RTF path on the connected iPhone.

Completed in this pass:

- ran `PoseyTests` successfully on the physical device with the new RTF coverage included
- ran the direct smoke harness on device using `StructuredSample.rtf`
- confirmed the app can build, install, launch, import RTF, auto-open the document, auto-play, persist reading position, and write note plus bookmark records on the phone

Verified on device:

- one RTF document imported
- one reading position persisted
- playback advanced to sentence index `4`
- one note and one bookmark were written to the local database
- the imported title in the on-device database was `StructuredSample`

## 2026-03-25 — DOCX Format Pass

Extended Posey to support local `DOCX` import as the next incremental document-format block after RTF.

Completed in this pass:

- added `DOCX` library import and file-importer support
- added a small native zip reader plus raw-deflate decompression for `.docx` containers
- extracted readable paragraph text from `word/document.xml`
- kept the current reader, playback, highlighting, notes, and position model unchanged
- added deterministic `DOCX` fixtures and automated tests for importer and library persistence behavior
- added launch hooks and device-smoke support for inline `DOCX` preload

Important implementation choice:

- Posey currently treats `DOCX` as a text-extraction format, not a full layout-preservation format

## 2026-03-25 — Real-Device DOCX Validation Pass

Validated the new DOCX path on the connected iPhone.

Completed in this pass:

- ran `PoseyTests` on the physical device and used the failures to replace the unreliable Foundation DOCX path with a real zip/XML extractor
- reran `PoseyTests` successfully on device after fixing the inflater bug in the new extractor
- ran the direct smoke harness on device using `StructuredSample.docx`
- confirmed the app can build, install, launch, import DOCX, auto-open the document, auto-play, persist reading position, and write note plus bookmark records on the phone

Verified on device:

- one DOCX document imported
- one reading position persisted
- playback advanced to sentence index `4`
- one note and one bookmark were written to the local database
- the imported title in the on-device database was `StructuredSample`

## 2026-03-25 — Roadmap Expansion Pass

Updated the source-of-truth documents to reflect the broader set of document formats the app should eventually support for real reading use.

Completed in this pass:

- added `RTF`, `DOCX`, and `HTML` to the planned Version 1 roadmap
- kept `.webarchive` as a roadmap-only candidate rather than an active commitment
- added Safari or share-sheet import as a future ingestion workflow to consider after the local file-format blocks stabilize
- documented the preferred future sequence as `RTF`, `DOCX`, `HTML`, `EPUB`, then `PDF`
- kept the current implementation focus on stabilizing `TXT` and `MD` before starting the next format block

## 2026-03-25 — HTML Format Pass

Extended Posey to support local `HTML` import as the next incremental document-format block after DOCX.

Completed in this pass:

- added native `HTML` text extraction using attributed-text document reading
- added `HTML` library import and file-importer support for `.html` and `.htm`
- added launch hooks and device-smoke support for inline `HTML` preload
- added deterministic `HTML` fixtures and automated tests for importer and library persistence behavior

Important implementation choice:

- Posey currently treats `HTML` as a readable text-extraction format, not a browser or article-reader feature

## 2026-03-25 — Real-Device HTML Validation Pass

Validated the new HTML path on the connected iPhone.

Completed in this pass:

- ran `PoseyTests` on the physical device and tightened the HTML test contract to match real parser behavior
- reran `PoseyTests` successfully on device after that adjustment
- ran the direct smoke harness on device using `StructuredSample.html`
- confirmed the app can build, install, launch, import HTML, auto-open the document, auto-play, persist reading position, and write note plus bookmark records on the phone

Verified on device:

- one HTML document imported

## 2026-03-25 — Reader Notes Interaction Refinement

Tightened the note-taking interaction around the active reading flow before continuing into richer containers.

Completed in this pass:

- made opening Notes pause playback by default
- seeded note capture from the current highlighted reading context with a short lookback window
- copied the captured reading context to the clipboard when Notes opens
- added automated coverage for the new note-capture behavior
- manually validated the notes sheet on the connected iPhone

Verified manually on device:

- the Notes sheet opened from the reader
- bookmark jump returned to the anchored sentence
- note jump returned to the anchored sentence
- creating a manual note added a new saved annotation row immediately

## 2026-03-25 — EPUB Format Pass

Extended Posey to support local `EPUB` import as the next larger format slice after the lighter text-focused formats.

Completed in this pass:

- added a small reusable zip-archive reader for container-based formats
- added `EPUB` container parsing for `META-INF/container.xml` and package manifest/spine resolution
- extracted readable chapter text from spine XHTML documents through the existing HTML text path
- added `EPUB` library import and file-importer support
- added launch hooks and device-smoke support for inline `EPUB` preload
- added deterministic `EPUB` fixtures and automated tests for importer and library persistence behavior

Important implementation choices:

- `EPUB` currently joins readable chapter text into the existing reader flow instead of widening into a full rich-content block renderer yet
- chapter text extraction reuses the current HTML-readable-text path to keep the implementation small and testable

## 2026-03-25 — Real-Device EPUB Validation Pass

Validated the new EPUB path on the connected iPhone.

Completed in this pass:

- fixed a Swift inference issue in the EPUB chapter extraction loop that blocked the first build
- rebuilt the full app and test bundle successfully
- ran `PoseyTests` on the physical device with the new EPUB test cases included
- ran the direct device smoke harness against `StructuredSample.epub`

Verified on device:

- one EPUB document imported
- one reading position persisted
- playback advanced beyond the first sentence
- one note and one bookmark were written to the local database
- the imported title was stored as `Structured Sample EPUB`

## 2026-03-25 — PDF Format Pass

Extended Posey to support a first text-based `PDF` import path while keeping the implementation fully offline and explicit about scanned-PDF limitations.

Completed in this pass:

- added native `PDFKit` document import for local `.pdf` files
- extracted readable page text into the existing reader, playback, notes, and restore model
- normalized wrapped PDF line breaks into sentence-friendly text
- added an explicit scanned or image-only PDF error instead of silently importing empty content
- added `PDF` library import and file-importer support
- added launch hooks and device-smoke support for inline `PDF` preload
- added deterministic `PDF` fixtures and automated tests for importer behavior, scanned-PDF rejection, and library persistence

Important implementation choices:

- first-pass PDF support is limited to text-based PDFs
- OCR is intentionally not part of this slice
- scanned or image-only PDFs are treated as unsupported-for-now with a clear error path

## 2026-03-25 — Real-Device PDF Validation Pass

Validated the new PDF path on the connected iPhone.

Completed in this pass:

- generated a deterministic text-based PDF fixture locally for repeatable tests and smoke runs
- found and fixed a real-device PDF fixture issue where extracted line order was reversed
- tightened PDF text normalization so wrapped lines become readable sentence text
- preserved lightweight page headers and paragraph blocks in the reader for imported PDFs
- reran `PoseyTests` on the physical device with the new PDF test cases included
- ran the direct device smoke harness against `StructuredSample.pdf`

Verified on device:

- one PDF document imported
- one reading position persisted
- playback advanced beyond the first sentence
- one note and one bookmark were written to the local database
- the imported title was stored as `Structured Sample PDF`

## 2026-03-25 — Reader Notes Refinement Pass

Tightened the note-taking interaction so it fits the reading flow more naturally.

Completed in this pass:

- manually validated the notes sheet on device for sheet presentation, bookmark jump, note jump, and manual note creation
- updated the reader so opening Notes pauses playback by default
- seeded the note draft from the active reading context with a one-sentence lookback window
- copied the captured reading context to the clipboard when Notes opens
- added automated coverage for the new note-capture behavior

Important implementation choice:

- explicit selection-aware note capture remains a later refinement, but the current flow no longer makes the reader race moving text to preserve context

## 2026-03-25 — Reader Controls And Preferences Pass

Reworked the reader chrome so playback stays practical without letting controls dominate the screen.

Completed in this pass:

- replaced the always-visible bottom bar with fading reader chrome that reappears when the reader taps the screen
- split the reader UI into a primary control bar and a separate preferences sheet
- added previous-marker and next-marker navigation alongside play or pause and restart
- moved font size out of the primary bar and into the preferences sheet
- added user-facing speech rate control backed by the existing playback service
- updated simulated playback timing so automated tests can still advance deterministically under different speech rates
- fixed marker navigation so PDF page headers do not trap forward stepping on the same sentence index
- reran the real-device unit suite and smoke path successfully after the control changes

Verified on device:

- `PoseyTests` passed on the connected iPhone with the new reader-control and marker-navigation behavior included
- the direct device smoke harness still imported a document, advanced playback, persisted a reading position, and wrote a note plus bookmark after the reader-controls change

Important implementation choices:

- the primary reader chrome stays limited to previous, play or pause, next, restart, and Notes
- preferences such as font size and speech rate now live in a separate sheet so the reading surface stays cleaner
- basic voice selection remains a later follow-through step rather than widening this pass further

## 2026-03-25 — PDF Visual Stops And Voice Selection Pass

Extended the current reader loop in two small follow-through slices: richer PDF visual-stop handling and basic listening comfort controls.

Completed in this pass:

- preserved visual-only PDF pages as explicit visual stop blocks instead of silently dropping them from the reader
- kept those visual stop blocks inline with the existing PDF page structure
- paused playback automatically at the sentence boundary that reaches a visual stop block
- added deterministic importer and view-model coverage for mixed text-plus-visual PDF behavior
- added basic voice selection to the reader preferences sheet alongside font size and speech rate
- wired the speech service so changing the selected voice updates live playback behavior
- reran the real-device unit suite and PDF smoke path successfully on the connected iPhone

Verified on device:

- `PoseyTests` passed on the connected iPhone with `40` tests, including the new PDF visual-stop playback test
- the direct device smoke harness still imported `StructuredSample.pdf`, advanced playback, persisted reading position, and wrote a note plus bookmark after the richer-PDF and voice-selection changes
- the on-device smoke database summary remained `documents=1`, `reading_positions=1`, `notes=2`, `max_sentence_index=4`, title `Structured Sample PDF`

Important implementation choices:

- the current PDF richer-content pass only preserves visual-only pages as explicit stops; it does not yet render arbitrary inline figures, tables, or charts from mixed-content pages
- voice selection is now user-facing, but it is not yet persisted as a long-lived reader preference

## 2026-03-25 — Reader Chrome And Audio Follow-Through

Tightened the live reader experience after a real-device UI review.

Completed in this pass:

- simplified the primary reader chrome so playback controls are glyph-first, lighter, and visually more monochrome
- increased spacing between the bottom transport controls so adjacent buttons are harder to hit by mistake
- added a shared soft material background behind the top-right controls so they stay legible over document text without returning to individual halos
- gave the bottom transport controls the same soft background separation so long text no longer competes directly with the playback glyphs
- removed the redundant two-row voice presentation and kept voice selection on a single preferences control
- widened the font-size range so the reader can scale much larger for walking or other higher-motion use
- widened the speech-rate range substantially while keeping the current default unchanged
- changed restart so it rewinds to the beginning without autoplaying immediately
- configured the real speech path with an iPhone audio session that behaves more like a reading app than a silent test harness
- added interruption handling so calls and similar audio interruptions pause playback instead of trying to continue through them
- labeled the reader debug overlay more clearly so test-mode silent playback is harder to confuse with the real speech path
- added a unit test that verifies restart rewinds without autoplay
- reran the real-device unit suite successfully on the connected iPhone

Verified on device:

- `PoseyTests` passed on the connected iPhone with `41` tests after the reader and audio changes
- the new restart-without-autoplay behavior is covered in the device-tested unit suite

Important implementation choices:

- the current voice selection surface lists all available system voices and points the reader to Settings for downloading higher-quality voices

## 2026-03-25 — Real-Device Speech Controls Exposed An AVSpeech Tradeoff

- real-device listening checks showed that the original high-quality default voice disappeared once Posey stopped honoring Apple Spoken Content or assistive speech settings in order to chase app-controlled speech-rate changes
- repeated attempts to apply rate changes live during active playback also proved unreliable on hardware, even when the app restarted the speech queue deliberately
- the current fallback decision is to prefer stable default voice quality over live mid-playback speech reconfiguration
- Posey now removes the in-app speech-rate control entirely rather than presenting a control that does not behave honestly on real hardware
- this should be revisited later as a focused playback-engine investigation rather than forgotten as a permanent limitation

## 2026-03-25 — Remove In-App Voice Selection Too

- follow-up real-device testing showed the narrowed voice picker still did not behave honestly enough to keep
- Posey now relies fully on the system Spoken Content voice path and points readers to iOS settings for voice changes or downloads
- the reader preferences sheet is reduced back to stable controls only
- interruption handling pauses playback, but does not auto-resume after a call or interruption ends

## 2026-03-25 — Scope Expansion: Ask Posey, In-Document Search, OCR

Updated CONSTITUTION.md, REQUIREMENTS.md, and ARCHITECTURE.md to add three deliberate V1 scope additions after design review.

Completed in this pass:

- revised CONSTITUTION.md to permit Ask Posey, in-document search, and OCR; added a "Deliberate Scope Revisions" section with rationale
- added Section 7 (Ask Posey) and Section 8 (In-Document Search) to REQUIREMENTS.md
- updated ARCHITECTURE.md with Ask Posey Architecture, OCR Architecture, and Search Architecture sections
- updated the reader bottom bar layout in ARCHITECTURE.md: Ask Posey glyph now sits far left, opposite restart
- revised NEXT.md to document all three features in the planned implementation notes

Key decisions captured:

- Ask Posey uses Apple Foundation Models — on-device, offline only, no third-party AI services
- three interaction patterns: selection-scoped, document-scoped (glyph in bottom bar), annotation-scoped (from Notes)
- session model is transient — local message array while sheet is open, save to note or discard on close
- full modal sheet surface with quoted context at top
- three-tier search: string match (near-term), notes-inclusive (roadmap), semantic via Ask Posey (later)
- OCR via Apple Vision framework (VNRecognizeTextRequest) extending the existing PDF import pipeline

## 2026-03-25 — AppLaunchConfiguration Preload Collapse (Approved, Not Yet Built)

Design review identified 28 format-specific preload properties in AppLaunchConfiguration as a maintenance liability.

Approved shape:

- collapse to a single `preload: PreloadRequest?` property
- `PreloadRequest` carries a `Format` enum (txt/markdown/rtf/docx/html/epub/pdf) and a `Source` enum (url/inlineBase64)
- five generic environment variables replace the current 28 format-specific ones
- PoseyApp.swift if/else preload ladder becomes a switch on `preload.format`
- smoke scripts updated in the same pass

Status: approved, not yet implemented.

## 2026-03-25 — AVSpeech Voice Quality Research Pass

Built an empirical test to resolve the open question about `prefersAssistiveTechnologySettings` and premium voice quality before committing to a playback architecture.

Completed in this pass:

- added a debug `VoiceQualityTestSection` to the reader preferences sheet (behind `#if DEBUG`)
- test plays identical 8-sentence prose sample in two modes: (A) `prefersAssistiveTechnologySettings = true`, (B) direct query of the highest-quality en-US voice from `speechVoices()`
- Mark downloaded Ava (Premium, en-US) and Jamie (Premium, en-GB) to give mode B its best possible showing
- ran both modes on the connected iPhone and compared by ear

Empirical findings:

- mode A (Siri-tier) was dramatically better — "fantastic" vs "super inferior"
- `prefersAssistiveTechnologySettings = true` accesses a voice tier that is not returned by `AVSpeechSynthesisVoice.speechVoices()` at all
- the standard API on this device returned only compact voices; Ava Premium was available but still clearly inferior to the Siri-tier voice
- the flag is doing real work and cannot be removed without a quality regression
- `utterance.rate` being set explicitly overrides the Spoken Content rate slider — the system rate slider only applies when no explicit rate is set on the utterance
- Ava at higher speeds was listenable up to roughly 125–150%; above that quality degraded unacceptably

Architecture decision confirmed:

- keep `prefersAssistiveTechnologySettings = true` as the default voice path
- build a Best Available / Custom split rather than forcing users to choose between quality and control

## 2026-03-25 — Voice Mode Split Implementation

Replaced the previous "system Spoken Content only, no controls" approach with a two-mode architecture that makes the quality/control tradeoff explicit and user-controlled.

Completed in this pass:

- rewrote `SpeechPlaybackService` with a `VoiceMode` enum (`bestAvailable` / `custom`)
- Best Available mode: `prefersAssistiveTechnologySettings = true`, utterance.rate deliberately not set so the system Spoken Content rate slider applies
- Custom mode: explicit voice from `AVSpeechSynthesisVoice.speechVoices()`, in-app rate slider, `prefersAssistiveTechnologySettings = false`
- mode or rate changes take effect at the next utterance: service stops and re-enqueues from the current sentence index
- if paused when mode changes, service returns to idle and resumes with new settings on next play
- replaced full pre-enqueue with a 50-segment sliding window — one utterance enqueued per utterance finished, memory usage bounded for long documents
- added `PlaybackPreferences` (UserDefaults wrapper) persisting selected mode, voice identifier, and rate across sessions
- added `VoicePickerView`: grouped by language then quality tier, device locale shown first by default using `AVSpeechSynthesisVoice.currentLanguageCode()`, "Show all languages" expands the full list
- Premium voices displayed in accent color, Enhanced and Standard in secondary
- rate slider range 75–150% (cap at 150% based on empirical quality testing)
- added `ReaderViewModel` voice mode methods (`setVoiceMode`, `setCustomVoice`, `setCustomRate`) wired to preferences sheet
- deleted `VoiceQualityTest.swift` — empirical test complete

Verified on device:

- Best Available default on first launch
- Ava (Premium en-US) selected as default when switching to Custom
- rate slider applies on drag-end; takes effect at next sentence boundary
- switching back to Best Available restores Siri-tier voice
- switching back to Custom restores previously set voice and rate
- settings persist correctly across full app restarts
- voice picker opens showing only current locale; "Show all languages" expands correctly

Bug fixes found and resolved during hardware testing:

- service was not initialized with persisted voice mode on relaunch (created in ReaderView.init without voiceMode parameter)
- switching back to Custom created a fresh default instead of restoring persisted settings
- draftRatePercentage in preferences sheet not synced when voiceMode changed externally
- en-GB Jamie sorted above en-US Ava within Premium tier (alphabetical by locale code — fixed by preferring device locale first)
