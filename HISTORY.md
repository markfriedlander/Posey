# Posey History

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
