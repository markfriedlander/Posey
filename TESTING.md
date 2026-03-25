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
