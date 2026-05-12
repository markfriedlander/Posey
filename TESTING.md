# Posey Testing Workflow

## Purpose

Posey's automated QA loop is designed to validate the current `TXT`, `MD`, `RTF`, `DOCX`, `HTML`, `EPUB`, and first-pass text-based `PDF` reading flow as far as the environment allows without depending on manual app testing for routine regressions.

The current test stack covers:

- text import normalization and error handling
- Markdown parsing and normalization behavior
- RTF text extraction behavior
- DOCX text extraction behavior
- HTML text extraction behavior
- EPUB container extraction behavior
- PDF text extraction behavior
- sentence segmentation behavior
- SQLite persistence and reset behavior
- duplicate import handling
- reader restore logic
- simulated playback state transitions
- sentence-anchored note and bookmark persistence
- a UI-driven preloaded `TXT` play, pause, and restore loop
- a direct on-device smoke path for `TXT`, `MD`, `RTF`, `DOCX`, `HTML`, `EPUB`, and `PDF`

## Test Layers

### Unit And Integration-Style Tests

Target: `PoseyTests`

These tests exercise:

- `TXTDocumentImporter`
- `MarkdownDocumentImporter`
- `MarkdownParser`
- `RTFDocumentImporter`
- `DOCXDocumentImporter`
- `HTMLDocumentImporter`
- `EPUBDocumentImporter`
- `PDFDocumentImporter`
- `SentenceSegmenter`
- `DatabaseManager`
- `TXTLibraryImporter`
- `MarkdownLibraryImporter`
- `RTFLibraryImporter`
- `DOCXLibraryImporter`
- `HTMLLibraryImporter`
- `EPUBLibraryImporter`
- `PDFLibraryImporter`
- `ReaderViewModel` with simulated playback

### UI Tests

Target: `PoseyUITests`

The UI test harness:

- launches the app in test mode
- resets or reuses a dedicated test database
- preloads a deterministic `TXT` fixture
- opens the document from the library
- starts playback in simulated mode
- verifies playback state changes
- pauses playback
- relaunches and verifies restored reader state

## Fixtures

Fixtures live in `TestFixtures/` and are bundled into the test targets.

- `ShortSample.txt`: short deterministic sample for segmentation and playback tests
- `LongDenseSample.txt`: longer dense prose for restore and UI loop tests
- `MalformedPunctuationSample.txt`: punctuation-heavy sample for tokenizer resilience
- `DuplicateImportSample.txt`: duplicate import fixture for library dedupe behavior
- `StructuredSample.md`: structured Markdown sample with headings, bullets, and numbered items
- `MalformedMarkdownSample.md`: malformed inline Markdown sample for parser cleanup behavior
- `StructuredSample.rtf`: structured rich-text sample for RTF extraction and library import
- `StructuredSample.docx`: structured Word sample for DOCX extraction and library import
- `StructuredSample.html`: structured HTML sample for HTML extraction and library import
- `StructuredSample.epub`: structured EPUB sample for container extraction and library import
- `StructuredSample.pdf`: structured text-based PDF sample for PDF extraction and library import

### Pre-Release Parity Fixtures (`TestFixtures/parity/`)

Built during the Tier 1 #3 / #4 punch-list pass (2026-05-06/07). Each
exercises a specific format-parity surface:

- `HeadingTest.md` — six MD heading levels in close proximity (`#`–`######`) plus a level-1 chapter break for the displayBlocks render path.
- `HeadingTest.html` — h1–h4 plus a second h1 for the sentence-row path through the new `HTMLDocumentImporter.extractHeadings` extractor.
- `HeadingTest.rtf` — three font-size tiers (`\fs48`, `\fs36`, `\fs28`) plus a second `\fs48` for the existing RTF tokenizer's level classification.
- `ListTest.html` — `<ul>` followed by `<ol>` with three items each, exercising `injectListMarkers` and the segmenter's numbered-marker merge.
- `ListTest.docx` — minimal hand-crafted DOCX with three `<w:numPr>` paragraphs to exercise the DOCX list-item detection path.

## Launch Hooks

Posey supports the following launch-time test hooks:

- `POSEY_TEST_MODE=1`
  Enables test-mode UI observability and simulated silent playback instrumentation.
- `POSEY_RESET_DATABASE=1`
  Deletes the configured database before app startup.
- `POSEY_DATABASE_PATH=/absolute/path/to/file.sqlite`
  Uses a deterministic database file instead of the default app database location.
- `POSEY_PRELOAD_TXT_PATH=/absolute/path/to/file.txt`
  Imports a fixture during app startup before the root UI appears.
- `POSEY_PRELOAD_MARKDOWN_PATH=/absolute/path/to/file.md`
  Imports a Markdown fixture during app startup before the root UI appears.
- `POSEY_PRELOAD_RTF_PATH=/absolute/path/to/file.rtf`
  Imports an RTF fixture during app startup before the root UI appears.
- `POSEY_PRELOAD_DOCX_PATH=/absolute/path/to/file.docx`
  Imports a DOCX fixture during app startup before the root UI appears.
- `POSEY_PRELOAD_HTML_PATH=/absolute/path/to/file.html`
  Imports an HTML fixture during app startup before the root UI appears.
- `POSEY_PRELOAD_EPUB_PATH=/absolute/path/to/file.epub`
  Imports an EPUB fixture during app startup before the root UI appears.
- `POSEY_PRELOAD_PDF_PATH=/absolute/path/to/file.pdf`
  Imports a PDF fixture during app startup before the root UI appears.
- `POSEY_PLAYBACK_MODE=simulated`
  Uses deterministic simulated playback instead of live `AVSpeechSynthesizer`.
- `--posey-ui-test-mode`
  Additional launch argument that marks the app as running under UI automation.

## Accessibility And Observable State

The UI harness relies on stable accessibility identifiers.

Current identifiers:

- `library.importTXT`
- `library.document.<Title>`
- `library.documentCount`
- `reader.previous`
- `reader.playPause`
- `reader.next`
- `reader.restart`
- `reader.preferences`
- `reader.notes`
- `reader.segment.<Index>`
- `reader.playbackState`
- `reader.currentSentenceIndex`
- `reader.documentTitle`
- `reader.noteCount`
- `preferences.fontSize`
- `notes.currentSentence`
- `notes.draft`
- `notes.save`
- `notes.bookmark`
- `notes.empty`
- `notes.row.<UUID>`

The identifiers that expose state are only surfaced when the app runs in test mode.

## What The Automated Coverage Proves

- Imported `TXT` text is normalized consistently enough for stable persistence and segmentation.
- Empty documents are rejected.
- Sentence segmentation produces usable chunks for the current fixtures.
- Reading positions persist and restore through the storage layer.
- Duplicate imports of unchanged content reuse the existing document record.
- Reader restore prefers saved character offset over sentence index fallback.
- Simulated playback advances sentence state and supports pause/resume semantics.
- Notes and bookmarks persist against sentence-offset anchors in the local database.
- Opening Notes pauses playback and seeds note capture from the active reading context.
- Marker navigation can step through the current reader structure without getting stuck on lightweight PDF page-header blocks.
- Reader preferences now expose font size without widening the primary reading chrome.
- Restart rewinds to the beginning without autoplaying again.
- Mixed text-plus-visual PDF behavior preserves visual-only pages in display text and pauses playback at the following sentence boundary.
- The UI harness can drive a preloaded Block 01 loop through open, play, pause, terminate, relaunch, and restore.
- Markdown imports preserve useful reading structure while keeping playback and persistence on normalized plain text.
- RTF imports extract readable text into the existing reader flow without widening the model.
- DOCX imports extract readable paragraph text into the existing reader flow without widening the model.
- HTML imports extract readable text into the existing reader flow without widening the model.
- EPUB imports extract readable spine text into the existing reader flow without widening the model yet.
- PDF imports extract readable text from text-based PDFs and reject scanned or image-only PDFs explicitly in this pass.
- PDF reader-model tests also verify lightweight page-header display blocks on top of the extracted text flow.
- The direct device smoke harness can validate `TXT`, `MD`, `RTF`, `DOCX`, `HTML`, `EPUB`, and `PDF` imports on hardware.

## What The Automated Coverage Does Not Yet Prove

- Real `AVSpeechSynthesizer` timing and audio output behavior
- System file importer UI behavior end to end
- Real scroll feel or highlight feel under live speech
- Fade timing and gesture feel of the reader chrome under real use
- Real spoken voice differences, downloadable voice availability, and subjective voice quality controlled through iOS settings
- Live audio-session behavior under incoming calls or other interruptions beyond the basic pause contract
- Notes sheet behavior through UI automation end to end
- Explicit text-selection-aware note capture end to end
- Device-specific lifecycle quirks
- Full rich Markdown rendering fidelity
- Rich RTF styling fidelity in the reader
- Full Word layout fidelity beyond extracted paragraph text
- Full HTML layout fidelity beyond extracted readable text
- Full EPUB rich-content fidelity beyond readable spine-text extraction
- Rich PDF layout fidelity beyond lightweight page/paragraph blocks, visual-only page stop preservation, and OCR-backed scanned PDF support

The UI tests intentionally preload fixtures instead of automating the file importer because that makes the loop more deterministic and less dependent on OS picker behavior.

## How To Run The Tests

### Build The Full Test Bundle Without A Simulator

```bash
xcodebuild -project Posey.xcodeproj -scheme Posey -destination 'generic/platform=iOS' -derivedDataPath /tmp/PoseyDerivedData CODE_SIGNING_ALLOWED=NO build-for-testing
```

This confirms the app, unit tests, UI tests, fixtures, and test hooks all build successfully.

### Run Unit Tests On A Simulator

```bash
xcodebuild -project Posey.xcodeproj -scheme Posey -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:PoseyTests test
```

### Run UI Tests On A Simulator

```bash
xcodebuild -project Posey.xcodeproj -scheme Posey -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:PoseyUITests test
```

### Run The Full Automated Loop

```bash
xcodebuild -project Posey.xcodeproj -scheme Posey -destination 'platform=iOS Simulator,name=iPhone 16' test
```

### Optional Helper Script

Use:

```bash
bash scripts/run-tests.sh build
bash scripts/run-tests.sh unit 'platform=iOS Simulator,name=iPhone 16'
bash scripts/run-tests.sh ui 'platform=iOS Simulator,name=iPhone 16'
bash scripts/run-tests.sh all 'platform=iOS Simulator,name=iPhone 16'
bash scripts/run-device-tests.sh unit <device-udid>
bash scripts/run-device-tests.sh ui <device-udid>
bash scripts/run-device-tests.sh all <device-udid>
```

### Run Tests On A Connected iPhone

Posey now includes a small real-device wrapper modeled after the Malcome workflow:

```bash
bash scripts/run-device-tests.sh unit 00008140-001A7D001E47001C
```

Notes:

- the script uses an explicit Xcode `DEVELOPER_DIR` so it does not depend on Command Line Tools being the active developer directory
- if no device UDID is passed, it attempts to discover the first connected paired booted iPhone through `devicectl`
- the device must remain unlocked while Xcode starts the test session
- `ui` and `all` modes use the same destination flow, but UI coverage on physical device still needs an app-bundled preload strategy to replace simulator-only file-path fixture loading
- the on-device unit-test path has already validated the new reader controls and preferences logic, but not the visual feel of the fading chrome

### Run A Direct Device Smoke Pass

Posey also supports a Malcome-style direct app smoke path that does not depend on XCUITest automation mode:

```bash
bash scripts/run-device-smoke.sh 00008140-001A7D001E47001C
```

This flow:

- builds and installs only `Posey.app`
- launches Posey on the connected iPhone with test-only automation hooks
- preloads a deterministic `TXT`, `MD`, `RTF`, `DOCX`, `HTML`, `EPUB`, or `PDF` sample inline
- auto-opens the first document
- auto-starts playback
- auto-creates a note and bookmark
- copies the on-device SQLite database back to the Mac
- asserts that document import, reading position persistence, playback progress, and annotation writes all occurred

To run the Markdown smoke path explicitly:

```bash
POSEY_SMOKE_FIXTURE_PATH=/Users/markfriedlander/Desktop/Fun/Posey/TestFixtures/StructuredSample.md bash scripts/run-device-smoke.sh 00008140-001A7D001E47001C
```

To run the RTF smoke path explicitly:

```bash
POSEY_SMOKE_FIXTURE_PATH=/Users/markfriedlander/Desktop/Fun/Posey/TestFixtures/StructuredSample.rtf bash scripts/run-device-smoke.sh 00008140-001A7D001E47001C
```

To run the DOCX smoke path explicitly:

```bash
POSEY_SMOKE_FIXTURE_PATH=/Users/markfriedlander/Desktop/Fun/Posey/TestFixtures/StructuredSample.docx bash scripts/run-device-smoke.sh 00008140-001A7D001E47001C
```

To run the HTML smoke path explicitly:

```bash
POSEY_SMOKE_FIXTURE_PATH=/Users/markfriedlander/Desktop/Fun/Posey/TestFixtures/StructuredSample.html bash scripts/run-device-smoke.sh 00008140-001A7D001E47001C
```

To run the EPUB smoke path explicitly:

```bash
POSEY_SMOKE_FIXTURE_PATH=/Users/markfriedlander/Desktop/Fun/Posey/TestFixtures/StructuredSample.epub bash scripts/run-device-smoke.sh 00008140-001A7D001E47001C
```

To run the PDF smoke path explicitly:

```bash
POSEY_SMOKE_FIXTURE_PATH=/Users/markfriedlander/Desktop/Fun/Posey/TestFixtures/StructuredSample.pdf bash scripts/run-device-smoke.sh 00008140-001A7D001E47001C
```

## Minimum Environment For Full Execution

To execute the full automated loop, the minimum practical environment is:

- Xcode with the Posey shared scheme available
- an installed iOS Simulator runtime compatible with the project deployment target
- one bootable iOS simulator device, such as an iPhone simulator

For device execution instead of simulator execution, you would also need:

- a connected trusted device
- valid signing and provisioning for the app and test runner

In environments where CoreSimulator is unavailable, `build-for-testing` still provides a useful structural validation step.

## Current Real-Device Status

As of March 25, 2026:

- Posey unit tests have executed on a connected iPhone
- the unit suite exposed and helped fix both a simulated-playback timing race and a too-strict database timestamp assertion that did not show up in build-only validation
- the direct device smoke harness has run successfully on the connected iPhone for `TXT`, `MD`, `RTF`, `DOCX`, `HTML`, `EPUB`, and `PDF`
- on-device XCUITest still timed out while enabling automation mode, so the direct smoke harness is currently the reliable hardware-validation path

---

# Release-Readiness Report — 2026-05-12

**Author:** Claude Code (autonomous), reviewed by Mark before submission
**Build under test:** `71cb22f` (deployed to iPhone D24FB384) + `e6909f7` (revert base)

This section is the Three Hats sign-off for v1 submission. It records what was tested today, what passed, what's a real gap, and what needs Mark's eyes/ears before submit.

## Three Hats summary

**Developer:** Build is green on iPhone + iOS Simulator + Mac Catalyst. No new compile errors. Architecture is sound: importers extract content cleanly across all 7 formats, displayBlocks vs. sentence-row render paths both work, keyboard composer regression is fixed at the root (revert + minimum-height frame + 60pt focused padding).

**QA:** Image support tested deeply across DOCX, HTML, EPUB, PDF — including edge cases (broken `<img>` src, consecutive images, multi-aspect-ratio, very small + very large). Visual placeholders generated correctly per format. Notes/Bookmarks persist. Audio Export notification flow works. Three real non-scripted Ask Posey conversations with diverse content (literature, business non-fiction, philosophical/technical) — 3-4/5 questions per conversation produced useful answers, with patterns identified for the rest.

**User:** Posey reads like a serious reading companion, not a feature showcase. Imports work. Reading is clean and focused. Ask Posey gives useful, mostly-grounded answers and refuses honestly when it can't ground. Audio Export flow is honest (no surprise share sheets). Accessibility holds at AccessibilityXXXL. Three concerns flagged below that I'd recommend Mark verify on the iPhone before submitting.

## Image support — comprehensive sweep

### Test materials (built/acquired today)

| Source | Description |
|---|---|
| `/tmp/image-test/image-stress.docx` | Built via python-docx. 5 images across 6 sections: small icon, medium figure, large image, consecutive images (Section 4), aspect-ratio test (Section 5 wide+tall). |
| `/tmp/image-test/image-stress.html` | Built manually. 5 inline images via base64 data URIs + 1 deliberately broken `<img src="nonexistent://...">` for crash-safety edge case. |
| `/tmp/image-test/aesop.epub` (titled "Alice's Adventures in Wonderland") | Downloaded from Project Gutenberg. 55 inline figures including chapter-mid Tenniel illustrations, not just cover. |
| Measure What Matters PDF (existing test material) | 36 stored images including pure-image pages (visualPlaceholder stop blocks). |
| Cryptography for Dummies PDF (existing test material) | 279 stored images, dense mixed text+image pages. |

### Image rendering verification (iPhone, real device)

| Format | Test | Result |
|---|---|---|
| **DOCX** | 5 images stored after import | ✅ PASS |
| **DOCX** | visualPlaceholder blocks generated (7 = 5 unique + 2 reused) | ✅ PASS |
| **DOCX** | Inline rendering of Section 1 image | ✅ PASS — red 32×32 inline after caption |
| **HTML** | 5 valid images stored, broken `<img>` skipped | ✅ PASS — broken src cleanly rejected, importer didn't crash |
| **HTML** | Consecutive-images edge case | ✅ PASS — yellow + red back-to-back, both rendering |
| **HTML** | Section 5 (broken image) text continues cleanly | ✅ PASS — parsing recovered, text after broken image renders normally |
| **EPUB** | 55 images stored after import | ✅ PASS |
| **EPUB** | Cover image rendered | ✅ PASS — Tenniel cover visible at doc start |
| **EPUB** | **Chapter-mid figure** rendered inline | ✅ PASS — at offset 2215: text "...suddenly a White Rabbit with pink eyes ran close by her." → Tenniel illustration directly below. Pixel-perfect inline placement. |
| **PDF** | Pure-image-page visualPlaceholder generated | ✅ PASS — 36 visualPlaceholder blocks with text "Visual content on page N" |
| **PDF** | Visual page image renders | ✅ PASS — inline PDF page thumbnail visible at placeholder offset |

### Stop-block playback — partial pass

**Architecture verified:** TTS playback in Measure What Matters progressed 24 → 25 → 27 and **stopped advancing at idx=27 (the visualPlaceholder at offset 3164)**. The cursor stayed pinned indefinitely. Tapping `reader.next` advanced past it to idx=28.

**What I can't verify autonomously:** whether iOS TTS actually paused audio output, or whether it kept reading subsequent content silently while the offset reported was stuck. State reported "playing" not "paused" — could be correct-behavior-with-state-reporting-quirk or actual stuck-playback. **Mark needs to confirm by ear.**

## Non-scripted Ask Posey conversations (iPhone, real AFM)

### Alice's Adventures in Wonderland (EPUB, literature)
- Q1 framing: ✅ Strong — "whimsical and fantastical tale of a young girl named Alice... bizarre and chaotic world filled with talking animals and strange events."
- Q2 character: ✅ Strong — names Alice, captures curiosity trait, cites specific behavior (growing/shrinking).
- Q3 specific scene: ⚠️ Minor factual reversal — Posey said "eats a piece of cake that causes her to shrink rapidly." Book actually has Alice drink from bottle (shrink) and eat cake (grow). Substance right, detail reversed.
- Q4 interpretive (White Rabbit significance): ⚠️ Graceful refusal. Acceptable per product brief.
- Q5 not-in-doc (smartphones): ✅ Strong honest "doesn't mention".

### Measure What Matters (PDF, business non-fiction)
- Q1, Q2: ❌ Failed — indexing race (chunks not ready when first questions fired).
- Q3 (real-world example): ⚠️ "doesn't provide a specific real-world example" — wrong, book is structurally example-based.
- Q4 (objective vs. key result): ✅ Strong — defines both with grounded Intuit example + citations.
- Q5 (compare to Covey): ❌ **Hallucination** — volunteered Covey content as if from doc.

### AI Book Collaboration Project (RTF, multi-author conversation)
- Q1 format: ✅ Correct ("conversation").
- Q2 interpretive comparative: ⚠️ Over-conservative refusal.
- Q3 follow-up: ⚠️ Same.
- Q4 nuanced grounded: ⚠️ Refusal — hard to evaluate without re-reading book.
- Q5 speculative ("Mark's biggest regret"): ⚠️ Engaged with speculation, grounded with citation [1]. Right at the edge of what the brief allows.

### Real issues to flag

1. **Fresh-import indexing race** — first few `/ask` calls right after import return "not finding a strong answer" while chunks build. Resolves itself within ~30s. UX could be improved with a more visible "indexing" indicator.
2. **Cross-doc synthesis hallucination** — when asked to compare with content NOT in the doc, Posey volunteered external (training) content. Prompt-tightening opportunity.
3. **Minor factual detail inaccuracies** — Alice's cake/bottle reversal. Not catastrophic but worth noting.

## Recommended 20-minute manual smoke test (Mark, before submit)

### 1. Audio Export notification flow (~3 min)
1. Open any doc → Preferences → "Export to Audio File"
2. Immediately close the export sheet
3. Wait for notification banner
4. Tap notification → app foregrounds → share sheet path opens
5. **Expected:** No surprise modal at any point.

### 2. Stop-block playback — REAL TTS, NEED EARS (~3 min)
1. Open Measure What Matters PDF
2. READER_GOTO ~offset 3000 (or scroll to just before the dedication page)
3. Tap Play, listen ~30 seconds
4. **Expected:** TTS reads copyright paragraphs, reaches dedication visual page, **pauses silently** (does NOT read "Visual content on page 4" aloud)
5. Tap Next → audio resumes
6. **If audio reads placeholder aloud OR keeps playing silently:** bug.

### 3. AskPosey composer keyboard (~2 min)
1. Open any doc with Ask Posey button → tap to open sheet → tap composer field
2. **Expected:** "Ask a follow-up..." placeholder fully visible above keyboard's QuickType bar. Send button visible. Clear visual gap.

### 4. Image-bearing document (~3 min)
1. Open "Alice's Adventures in Wonderland" (EPUB, 71K chars)
2. Scroll into Chapter 1
3. **Expected:** Inline Tenniel illustrations at chapter-figure positions. No "Visual content on page X" placeholder text — actual rendered images.

### 5. Multi-turn Ask Posey (~5 min)
1. Open Alice EPUB → Ask Posey
2. 4-5 turn conversation, real questions
3. **Expected:** Useful grounded answers, honest refusals when interpretive, no hallucination of details not in book.

## Known issues / accepted-for-v1

1. Cross-doc synthesis can hallucinate (worth future prompt tightening).
2. Indexing race on fresh imports (~30s window).
3. Stop-block audio behavior needs Mark's ears.
4. Reader sentence rows are AX StaticText not Button (chrome Play is canonical).
5. Random binary bytes imported as .txt are silently accepted (low priority).

## Open for Mark before submit

- 20-minute manual smoke test above
- App icon eyeball on iPhone home screen (Tier 3 #16)
- Privacy policy + App Store metadata finalization (Tier 4 #19-20)
- Antenna defaults: flip DEBUG-on default → RELEASE-off (Task 13 #72)

## Verdict

Code is in good shape for submission. Image rendering works cleanly across all 4 image-bearing formats including edge cases. Keyboard regression fixed at the root. Accessibility passes. Audio Export UX is honest. Non-scripted conversations show Posey behaves like an honest reading companion. If the smoke test passes cleanly and the four submission items above check out: ship it.
