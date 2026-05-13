# Next

## 2026-05-06 (evening) — Pre-Release Parity Punch List in flight

Working through the 17-item Tier 1–4 punch list. Status:

**Tier 1 — Visible parity gaps**
1. ✅ TOC navigation on RTF — verified existing commit `0397a45`.
2. ✅ Inline image rendering on EPUB/DOCX/HTML — code in `57472fa`. Verified on iPhone via Data Smog EPUB; sim verification carried over from the in-progress session and confirmed during this pass via the heading-styling smoke runs that exercise the same display-block path.
3. ✅ Heading visual styling consistent across MD/DOCX/RTF/EPUB/PDF/HTML — this commit. Single-spec typography (1.5×/1.3×/1.15×/1.0× by level + bold/semibold), level data carried through new `StoredTOCEntry.level` schema column, sentence-row + displayBlocks both heading-aware. HTML gets a new heading extractor since it had no TOC path before. Verified MD/HTML/RTF on both simulator and iPhone (and DOCX/EPUB/PDF in the Rule 2 closure pass).
4. ✅ Bullet and numbered list rendering consistent across formats — code in `dd4ba44`; iPhone post-merge visual + audio verification done 2026-05-07. HTML/EPUB inject markers via `HTMLDocumentImporter.injectListMarkers`; DOCX detects `<w:numPr>` paragraphs (every list item bullet for v1); `SpeechPlaybackService.utteranceText` strips leading markers before AVSpeechSynthesizer; `SentenceSegmenter.mergeNumberedListMarkers` rejoins numbered-marker segments NLTokenizer splits. Mark confirmed by ear that markers don't pronounce. v1 limitations: DOCX numbered → bullet (numbering.xml not resolved), RTF lists deferred (parser hooks not in scope), PDF lists out of scope.
5. ✅ Empty-state messages on every modal sheet — TOC sheet (two-hardware verified), Voice picker (two-hardware verified via new `OPEN_VOICE_PICKER_SHEET` verb + `POSEY_DEBUG_VOICE_PICKER_EMPTY` launch-time env var), Notes/Saved Annotations (already had one), Audio Export (already had one), Preferences/Ask Posey (no empty-state concept). Antenna scaffolding lives in the codebase as durable test infrastructure.
6. ✅ TOC navigation + playback skip on DOCX/RTF — fully closed in `d030673`. `TOCSkipDetector` shared helper (handles "Contents" heading + dot-leader region + orphan dot-leader runs). `RTFDocumentImporter.advancePastDotLeaderRegion` fixes the title→offset shadow bug. New `TAP_TOC_ENTRY` and `GET_PLAYBACK_SKIP` antenna verbs. Verified two-hardware on synthetic + real DOCX (Proposal_Assistant) and synthetic + real RTF (AI Book Collaboration).
7. ✅ Saved Annotations preview shows note body — `b60bce9`. Three Hats + two hardware verified.

**Tier 1 complete.**

**Tier 2 — Visible bugs in shipped behavior**
8. ✅ PLAYBACK_RESTART → idle — verified two-hardware via new `DEBUG_FORCE_PLAYBACK_STATE` antenna verb. No code change needed.
9. ✅ RTF paragraph concatenation — verified two-hardware. plainText keeps `\n` boundary; sentence-row renderer puts each paragraph on its own row on both targets.
10. ✅ PDF citation marker — `PDFDocumentImporter.collapseWhitespaceInsideNumericBrackets` collapses any `[…digits + ws…]` token. Two-hardware verified.
11. ✅ HTML NBSPs — `HTMLDocumentImporter.normalize` strips `\u{00A0}`. Two-hardware verified (fresh import → 0 NBSPs).
12. ✅ RTF form-feed — `TextNormalizer.stripMojibakeAndControlCharacters` strips all C0 controls including U+000C. Two-hardware verified (RTF with `\page` → 0 form-feeds in plainText).

**Tier 2 complete.** Ready for Tier 3.

**Tier 3 — Polish**
13. ✅ Audio export UX redesigned and re-enabled (2026-05-08). New notification-based flow: export runs under `UIApplication.beginBackgroundTask`, notification permission requested in parallel, local notification fires on completion, tap routes back into the share-sheet path. Share sheet **never** auto-pops. "Done" dismisses the sheet without canceling the in-flight export. New antenna verbs: `BEGIN_AUDIO_EXPORT`, `AUDIO_EXPORT_NOTIFICATION_AUTH`, `AUDIO_EXPORT_NOTIFICATION_PENDING`, `AUDIO_EXPORT_SIMULATE_NOTIFICATION_TAP`. Both hardware verified including sim app-backgrounding test. (The 2× rate finding from the prior investigation is still real but the UX redesign supersedes the "is it shippable" question — users now control when/whether to deal with the audio file via an honest non-modal UI.)
14. ✅ Quick-actions in-sheet menu items reachable via TAP API — closed in `d030673`. Outer-sparkle `.remoteRegister` chain on `AskPoseyView.quickActionsMenu`.
15. ✅ Antenna defaults OFF in Release builds — `LocalAPIServer` 0 symbols, verb strings 0, support classes Release no-op stubs. Closed in `d030673`. (Note: ~67 inert support-class symbols still ship — strict zero would need ~70 call-site `#if DEBUG` guards.)
16. ⏳ App icon. Present at 1024×1024 source with light/dark/tinted variants. Mark needs to eyeball home-screen-scale on iPhone — antenna can't screenshot springboard.
17. ✅ qa_battery.sh full run — executed on iPhone 2026-05-07. 12/12 answers acceptable across AI Book / Copyright PDF / Internet Steps PDF; 4/4 not-in-doc cases produced honest non-answers (3× "the document doesn't say", 1× graceful guidance refusal). No hallucinations, citations attached where appropriate. See HISTORY entry.

**Large-document loading hint** (Mark's directive between Tiers 2 and 3) — closed in `d030673`. "Large document — this may take a few seconds." caption shown when `characterCount > 200_000`. Verified on 4-Hour Body EPUB (967K chars), both targets.

**Tier 4 — Needs Mark**
18. ✅ Accessibility audit (2026-05-08, autonomous) — touch-target + Reduce Motion + VoiceOver-label gaps closed; verified on both hardware including Dynamic Type at AccessibilityXXXL and AX-tree inspection of every fix. See HISTORY entry. One known limitation noted (sentence rows are StaticText not Button — chrome Play button is the canonical playback control).
19-20. Pending — privacy policy + App Store metadata + final submission, for Mark's session.

**Pre-submission stress sweep (2026-05-12, autonomous, sim + Catalyst):**
- All 7 reader formats render correctly; search + TOC verified (PDF on fresh import gives 38 outline entries).
- Notes + Bookmarks persist with body previews.
- Ask Posey seeded fixture round-trips through dismiss/reopen; composer keyboard fix verified with 28pt clearance.
- Audio Export notification flow verified including replace-by-docID semantics and dismiss-during-render survival.
- Library import edge cases handled (empty/whitespace rejected, single-char accepted, random-bytes-as-txt silently accepted — low-priority known).
- Catalyst Mac iPad mode builds, runs, opens docs in dark mode with proper window chrome.
- See HISTORY.md "Pre-submission Three Hats stress sweep" for full report.

**Open for Mark in the morning:**
- 5-minute iPhone smoke test (Ask Posey composer, Audio Export, Notes — all touched since iPhone was last verified)
- App icon eyeball (Tier 3 #16, springboard-only check)
- Privacy policy + App Store metadata (Tier 4 #19–20)
- Submit

---

## Pre-submission A-tier polish pass (2026-05-13, in flight)

Mark gave a no-pressure mandate to address real gaps before submit.
24-item list produced 2026-05-13; A-tier items in progress.

**A-tier completed (committed + pushed):**
- A1 ✅ Motion-aware non-text handling across PDF/EPUB/DOCX/HTML (`e5c28f3`)
- A1b ✅ Images tab in TOC sheet (`7491a4a`)
- A2/A7 ✅ Prompt rules for outside-entity grounding + paired-detail direction (`480eaf0`)

**A-tier remaining for after compaction:**
- A3 — indexing race live trigger verification on sim
- A4 — confirm M4A speed in standard player + caching + Preferences storage UI
- A5 — iPhone AX-tree rigorous verification
- A8 — long-doc background-export survival test

**Discovered during A-tier (surface for review):**
- EPUB chunker truncates at ~8500 chars on Alice (12% of doc indexed). v1 blocker for EPUB Ask Posey accuracy. See TESTING.md.
- Hal RAG patterns worth borrowing (B-tier): user-tunable relevance threshold, entity-variation query expansion, content-dedup. See TESTING.md.

**2026-05-11 pre-submission stress sweep** — autonomous; sim + Catalyst.
Two real bugs found and fixed:
- AskPosey composer obscured by keyboard — moved composer into `.safeAreaInset(edge: .bottom)` with `.regularMaterial` background and explicit padding. Verified on sim AX tree.
- PDF dimension artifacts ("3.8701 in" leaking from cover image) — new `stripPDFDimensionArtifacts` regex in PDFDocumentImporter, gated on 3+ fractional digits + unit. Re-import of Measure What Matters confirms clean cover text downstream (segments, search, bookmark anchor previews).

Open verification gaps before submission (each <30s on phone):
- iPhone-side keyboard composer visibility (sim verified; same code).
- iPhone-side PDF re-import to confirm dimension artifact strip.

---

## 2026-05-06 — Submission day pass: 7 of 7 complete

Mark's submission-day list, status of each:

1. **HTML mojibake** (Task 8 #41 / format parity): FIXED + verified on phone. Commit `0a2bed3`. NSAttributedString now gets explicit UTF-8 character encoding; em-dash, smart quotes, ellipsis, accented chars all render correctly across three test variants (no charset, explicit charset, multi-accent).
2. **Background audio lock-screen regression** (Task 8 + standing audio-session work): FIXED durably. Switched the project from `GENERATE_INFOPLIST_FILE = YES` + Run Script injection to an explicit committed `Info.plist` at the repo root with `UIBackgroundModes = ["audio"]` hardcoded. Verified: clean build + incremental rebuild both produce a binary with the key. The recurring regression caused by Xcode's incremental build cache dropping the script output is gone. Commit `cf8dd42`. **Mark verified end-to-end on phone**: started playback, locked screen, audio continued.
3. **Conversation reload on reopen**: FIXED. Commit `fb427f0` then refined `3d198f7`. Anchor card visible at top of viewport on reopen; prior conversation accessible by scrolling up. Verified with 15-turn TXT conversation on phone.
4. **TOC for MD/DOCX/PDF** (Task 8 #42): FIXED. Commit `8e87903`. MD extracts `# / ## / ###` headings; DOCX extracts `<w:pStyle Heading*>` paragraphs; PDF falls back to `outlineRoot` when text-pattern detector finds nothing. Verified on phone: MD test doc → 5 entries, DOCX test doc → 3 entries, Cryptography for Dummies PDF → 187 entries, TOC sheet renders correctly + tap navigation jumps the reader to the right offset.
   - **RTF**: closed in the 2026-05-06 afternoon parity pass. Direct RTF tokenizer (not NSAttributedString — iOS drops font attrs) detects heading paragraphs by `\fs` size ≥ 1.15× body baseline. AI Book Collaboration → 91 entries; Ch1 What is AI → 7 entries; synthetic test → 4 entries with exact offsets.
5. **Audio export hidden from UI** (Task 7 deferred for 1.0): DONE. Commit `fb94a94`. Removed the "Export to Audio File" button + entire Audio Export section from the Preferences sheet. Backend infrastructure (AudioExporter, RemoteAudioExportRegistry, EXPORT_AUDIO API verb) is intact and continues to work for testing. Coming-soon for users.
   - **Reasons for deferring user-facing UI**: (a) no progress indicator during long renders — RTF/EPUB exports take minutes and the user sees a static sheet; (b) the export speed observed in testing was ~3.6× faster than live playback, suggesting either rate or segment-concatenation differs from playback in a way that needs investigation before users see it.
6. **Ask Posey quality** (Task 4 #30 — fixes from Task 3 conversation testing): FIXED. Commit `1ff4f05` then `6539cc4`.
   - MD repetition (AFM padding "the four things" by repeating an item): mitigated with comma-list dedupe + numbered-list dedupe in `finalizeAssistantTurn`, plus a stronger prompt rule with worked FAILED/SUCCEEDED examples for both repetition and invention padding.
   - RTF false-negative on consciousness: now correctly answers (verified on phone — fixed by yesterday's RAG improvements; no change needed today).
   - EPUB subtitle missed: now correctly answers "Surviving the Information Glut" (verified on phone).
   - Trade-off: count-mismatch questions now sometimes produce shorter, more conservative answers instead of risking fabrication. Net win for grounding.
7. **Strip visual marker text** (Task 8 #43 deferral for 1.0): DONE. Commit `e67d8ed`. `[[POSEY_VISUAL_PAGE:0:<uuid>]]` marker tokens stripped from displayText for HTML, DOCX, EPUB; MD and RTF didn't emit markers (MD reduces image refs to alt text, RTF drops `\pict` silently). Bonus fix: `stripVisualPageMarkers` regex was failing silently because Swift `\u{HHHH}` raw-string syntax isn't ICU regex syntax — switched to `\x{HHHH}`. PDF visual pages stay intact (PDFKit thumbnail path renders correctly). Verified on phone with multi-image DOCX (3 images), HTML test doc, Illuminatus EPUB (large book with native images): zero marker tokens in displayText, clean prose rendering.

## Updated posey_task_sequence.md status

- **Task 0 (API Completeness)** — DONE.
- **Task 1 (Ask Posey UI Bug Fix)** — DONE.
- **Task 2 (Ask Posey Remaining UI Bugs)** — DONE. (Markdown rendering, sources persistence, citation chip redesign, motion-permission ordering all shipped over the past sessions.)
- **Task 3 (Ask Posey Deep Conversation Testing)** — DONE. The `submission/test-data-2026-05-06/` directory has 4-question multi-turn conversations across all 7 formats with cooldown.
- **Task 4 (Ask Posey Quality Fixes)** — DONE in spirit. Today's work closed the three findings (MD repetition / RTF consciousness / EPUB subtitle) plus the citation-chip / scroll-on-send / sub-40%-relevance fixes from the previous days.
- **Task 5 (Reader Deep Testing)** — DONE 2026-05-06 morning. Full report at `submission/test-results-2026-05-06.md` with 24 critical findings ranked, per-format pass/fail tables for every Task 5 item × every format.
- **Task 6 (Reader Quality Fixes)** — TODAY's items 1-7 closed the highest-priority findings from Task 5's report. Remaining lower-priority findings are documented below.
- **Task 7 (Audio Export)** — Backend complete (works via API). User-facing UI deferred for 1.0 per item 5 above; coming-soon.
- **Task 8 (Format Parity)** — Largely DONE. #41 (text normalization) ✓ shared `TextNormalizer` + today's HTML / RTF FF / DOCX heading offset pass. #42 (TOC) ✓ today (5 of 7 formats; RTF deferred). #43 (inline images) — image extraction works for DOCX/EPUB/PDF/HTML; inline rendering works for PDF only; for the other formats markers are now suppressed entirely. #46 (position persistence) ✓ verified per format. #47 (search) ✓ verified per format with real match counts. #48 (Ask Posey indexing) ✓ multi-turn conversations on all 7. #49 (audio export) ✓ all 7 formats produce m4a. #50 (Reading Style) ✓ Focus / Motion verified per format. #54 (tap-to-reveal-chrome) ✓ resolved much earlier.
- **Task 9 (Accessibility Pass)** — needs Mark's hands; prep complete in `submission/task9-accessibility-prep.md`. Not done.
- **Task 10 (Mac Catalyst)** — DONE earlier (commit `cebff38`).
- **Task 11 (App Icon)** — Not started; placeholder icon shipping for 1.0 if not addressed before final submit.
- **Task 12 (Share Feature)** — DONE earlier (`2ac7d78` Markdown export).
- **Task 13 (Pre-Submission Polish)** — Mostly DONE. #72 (antenna OFF default for release): need verification — antenna currently defaults ON during dev per CLAUDE.md, must flip to OFF for App Store builds. #79 (full qa_battery regression run): not done today. #80 (full reader test on all 7 formats): completed via Task 5 report.
- **Task 14 (Submission Prep)** — Mark present required for all of these. Privacy policy + App Store metadata draft already in `submission/`.

## Open items still on the board (post-submission-day)

Lower-priority findings from the test report at `submission/test-results-2026-05-06.md` not addressed today:

- RTF form-feed character (`\x0c`) leaks into plain text — TextNormalizer should strip but doesn't. Not user-visible during reading; would only matter if exposed to TTS.
- RTF paragraph-concatenation bug — "Section 1" merges with following body line into "Section 1is a paragraph...". Visible during reading. RTF importer's `\par` boundary handling needs work.
- HTML 519 NBSPs in plain text from un-normalized `&nbsp;` entities. Not visible visually (NBSP renders as space) but may affect search and Ask Posey retrieval boundaries.
- PDF citation `[26]` split across paragraph boundaries (paragraph segmentation broke mid-bracket on Cloud Copyright Law).
- TOC sheet has no empty-state message when count=0 (just blank). Cosmetic.
- Saved Annotations preview shows doc title for notes instead of body text (storage is correct; preview UI is wrong).
- PLAYBACK_RESTART leaves state="finished" instead of "playing"/"idle". Cosmetic state-label nit.
- Quick-actions in-sheet Menu items not reachable via API TAP (chrome-menu route works; in-sheet sparkle menu uses `.accessibilityIdentifier` only, not registered with RemoteTargetRegistry).
- Audio export progress indicator + rate parity with playback (gating issues for re-enabling user UI).
- Inline image rendering for DOCX/EPUB/HTML — fixed in 2026-05-06 afternoon parity pass via shared `VisualPlaceholderSplitter`; markers preserved in displayText, stripped from plainText. EPUB verified visually (Data Smog cover image). DOCX/HTML wired through same code path. MD/RTF remain deferred — RTF importer doesn't extract `\pict` blocks; MD parser doesn't resolve `![alt](url)` to image data.

## Future-release work (deferred from today)

- App icon (Task 11)
- Antenna OFF default for App Store release (Task 13 #72)
- qa_battery.sh full regression run (Task 13 #79)
- Accessibility pass (Task 9, Mark present)
- Final submission steps (Task 14, Mark present)

## 2026-05-05 (closing) — Ask Posey shipped end-to-end on phone

Tonight's late session locked down the Ask Posey citation rendering, the composer affordances, the scroll-on-send behavior (real one — `.contentMargins(.bottom, viewportHeight, for: .scrollContent)` paired with watching the latest user-message ID), the thinking-indicator visibility, and the sub-40% relevance filter on chunks going to AFM. All verified on Mark's iPhone with real AFM responses, multiple times, multiple test cases (short message, long message, multi-citation). See the HISTORY entries from this date for the per-fix breakdown.

The local API now has the verbs needed to drive every Ask Posey UI flow autonomously without Mark's eyes: `SUBMIT_ASK_POSEY`, `SCROLL_ASK_POSEY_TO_LATEST`, `LOGS`, `CLEAR_LOGS`, plus the previously-existing `SCREENSHOT`, `TAP`, `TYPE`, `READ_TREE`, `/open-ask-posey` (now idempotent on re-open).

Two new standing rules added to CLAUDE.md ("Two Standing Rules" section at the top): search before failing twice, two pieces of hardware + two screenshots before commit. They came directly out of how badly tonight went.

**The loop that should be standard practice now:** `CLEAR_ASK_POSEY_CONVERSATION` → `/open-ask-posey` → `SUBMIT_ASK_POSEY:<text>` → `SCREENSHOT` (during AFM) → wait → `SCREENSHOT` (after) → `LOGS` if anything's wrong. Took ~2 minutes per iteration tonight; should be the bar for any future Ask Posey change.

**Open items I deferred while fixing the chip/scroll/indicator regressions:**

- Phase 2 conversation-quality verification across content density (the morning's plan).
- Phase 3 Lock Screen + Dynamic Island debugging.
- Phase 4 reader deep test across 7 formats.
- Phase 5 reader fixes from Phase 4.
- Cosmetic: user message at the very top of sheet sits slightly under the translucent navigation chrome. Looks fine but a small `.safeAreaInset` adjustment would clean it up.
- Quick-actions menu items reachable through TAP chain — registered with accessibility IDs but iOS 26 Menu items only register with the registry once the menu is opened; not yet verified that the chain works end-to-end.
- The `tools/posey_test.py` help output should be updated to mention the new SUBMIT/SCROLL/LOGS verbs.
- User-facing app documentation / onboarding (still deferred from earlier in the day).
- Manual metadata-edit feature (still deferred).

## Earlier — 2026-05-04 (late evening) — Reader UX overhaul + background audio shipped; Task 5 next, plus a focused punch list.

The big additions tonight (post-MiniLM): Ask Posey re-scope UI (chrome menu surfaces 4 templated actions, inline first-use banner, sources strip restored, composer placeholder shapes workflow, detents fix for iPhone Plus), reader interaction model switched to single-tap-to-jump (genre standard) with mini-player persistence during chrome auto-fade, background audio fix (UIBackgroundModes via Run Script + AVSpeechSynthesizer.usesApplicationAudioSession = true), Preferences simplification (Standard + Immersive removed for 1.0; Motion Off/On/Auto collapsed to inline Auto toggle in Reading Style section). Plus the anchored-question quality batch (prompt reorder, asymmetric proximity, section clipping, skip-FM-on-anchor, grammatical-meta hint), confidence signal, recommendation + role short-circuits, polish call removal — many of which shipped earlier in the day.

**Where we are vs the 84-item task sequence:** roughly 70-75% to release. Done: Tasks 0, 1, 2, 3 (in spirit), 4 (in spirit, much further than original scope), 7, 10, 11, 12, 13, plus Task 14 prep. Remaining: Task 5 (reader deep test) never executed methodically; Task 6 depends on Task 5; Task 8 has format-parity items still open; Task 9 accessibility needs Mark's eyes; Task 14 final submit needs Mark's hands.

**Tomorrow's focused punch list (in priority order):**

1. **Ask Posey conversation memory stress test** (Mark's request). The re-scope changed retrieval order, skip-FM-on-anchor, grammatical-meta hint, and several other knobs. Need to verify multi-turn conversations across question types maintain consistent and persistent memory of prior turns. Real conversations on 2-3 docs, varying question types, follow-ups that explicitly reference earlier turns. Look for: turn-N references turn-(N-2) correctly; topic shifts don't lose the thread; the 60/25/15 verbatim/summary/RAG split works at scale.

2. **Lock Screen + Dynamic Island controls** (deferred from tonight). Background audio works; controls don't. Tried solo audio mode → controls appeared but audio stopped after the queued utterance window finished and metadata cleared. Hypotheses to investigate: (a) ReaderViewModel deinit'ing on background (NowPlayingController.clear() only fires in deinit); (b) AVSpeechSynthesizer + non-mixing-session interaction; (c) onDisappear firing on lock. Diagnostic dbgLog already in `SpeechPlaybackService.handleAudioSessionInterruption` and `speechSynthesizer didCancel`. Next pass should also instrument ReaderView.onDisappear.

3. **Task 5 — Reader deep test on 7 formats.** Methodical pass: every reader path on each of TXT / MD / RTF / DOCX / HTML / EPUB / PDF. Every button, every menu, every error path. Report findings only; no fixes during the pass.

4. **Task 6 — Reader fixes** for whatever Task 5 surfaces.

5. **Task 8 — Format parity remaining items** (in user-impact order):
   - PDF inline TOC chunking (the dot-leader-without-newlines case the chunkIsMostlyTOC heuristic misses)
   - DOCX TOC fields (Word-style auto-TOCs not parsed)
   - DOCX/HTML inline images (only EPUB and PDF currently extract them)
   - EPUB skip-until-offset (TOC playback-skip not wired)
   - Search per format (verify SEARCH/NEXT/PREVIOUS/CLEAR work cleanly across all 7)
   - Reading-styles per format (verify Focus/Motion render correctly across all 7)
   - Audio-export per format (some formats may have voice-gating issues)

6. **Task 9 — Accessibility pass (Mark present).** Prep done in `submission/task9-accessibility-prep.md`; full pass needs Mark to walk through with VoiceOver and Dynamic Type at AX5.

7. **Task 14 — Submission prep + final submit (Mark present).** Privacy policy + App Store metadata drafted in `submission/`. Screenshots TBD. Final submit needs Mark for irreversible steps.

**Known regressions / open items not blocking 1.0:**
- The double-tap-to-highlight gesture was removed (Task 8 #54 / superseded by single-tap-jump in tonight's work). Don't reintroduce; single-tap is the new standard.
- `tools/qa_battery.sh` hard-coded doc IDs — switch to title-based lookup via `LIST_DOCUMENTS` (carryover).
- The verbatim-phrase fallback retrieval added earlier today is now superseded by hybrid lexical+cosine in `searchHybrid` — the fallback function remains in `AskPoseyChatViewModel` as deprecated reference; can be removed in a cleanup pass.
- `idevicesyslog` device log capture is unreliable — works initially after pairing but loses connection over time per the iOS 17+ lockdown-service-restriction issue noted in CLAUDE.md. For lock-screen-controls debug tomorrow, may need to use Xcode's Console app on Mac for device log capture instead.

---

**Original 2026-05-04 (mid-day) — Layer 2 RAG fix + non-fiction scope landed; Task 5 next.**

Ask Posey 1.0 is now scoped to non-fiction. MiniLM (CoreML) replaces NLEmbedding as the retrieval embedder — non-fiction Three Hats clean rate **75%** (was 67% with NLEmbedding, 63% with NLContextualEmbedding). First-use notification ships explaining the strength/weakness. Fiction (EPUB Illuminatus) acknowledged as a known limitation; deferred post-1.0.

**Active migration.** Existing documents on user devices were indexed with NLEmbedding. They keep working under hybrid search (chunk's `embedding_kind` tags which embedder to use for queries) but won't get MiniLM's better cosine until re-indexed. Two paths:
- **Manual via API verb:** `REINDEX_DOCUMENT:<doc-id>` — used for the audit. Available in DEBUG builds via the antenna.
- **Future automatic migration:** on app launch, queue any doc whose chunks are `en-sentence` for background re-index under MiniLM. Not yet implemented — drop into NEXT-actionable list. Low priority because new imports already use MiniLM.

**Fiction support (post-1.0 scope):**
- EPUB Illuminatus surfaces three failure classes Layer 1+2+3 fixes don't address:
  1. AFM safety refusals on occult content ("What is the Law of Fives?" returns the friendly refusal error)
  2. Narrative-context failures (composing facts across chapters of a novel needs different retrieval than across sections of an essay)
  3. Source-layout artifacts in concatenated front matter (title page + appendix listing in same chunk)
- Likely needs: scene-level chunking, character-aware retrieval, narrative-summarization prompt frame. Out of scope for 1.0.

---

**2026-05-04 — Polish call removed; Task 5 next.** The Ask Posey two-call pipeline is collapsed to one call per Mark's directive. Voice-failure modes (recommendations, metaphors, sycophant openers, preamble announcements) are eliminated. Clean rate jumped from 14% (polish ON, six rounds of iteration) to 71% (polish OFF, no iteration). See HISTORY.md 2026-05-04 entry and DECISIONS.md polish-removal entry for full reasoning, sweep results, and restoration recipe.

**Grounded-path follow-ups surfaced by the polish-off sweep — defer until after Task 5 unless Mark prioritizes:**
- **RAG retrieval gaps on long/dense docs.** "Job displacement" appears verbatim in the DOCX at offset 37021 but RAG didn't surface that chunk; AFM said "doesn't mention." "Law of Fives" appears dozens of times in the 1.6M char Illuminatus EPUB; AFM said "doesn't mention." Likely fixes: hybrid keyword+embedding retrieval; larger RAG token budget for short questions; second-pass retrieval that reuses question keywords as exact-match probes when the embedding pass produces a refusal-shape grounded answer.
- **Hallucinated structure when RAG is partial.** MD Q2 listed 5 sections, 2 of them ("MLX HelPML Output Quality", "Design a Robust Parser") don't exist in the doc — actual sections are different. AFM "fills in" plausible structure when the chunks are partial. Possible mitigation: add a HARD RULE 6 to the grounded prompt ("If asked to list items, only list items whose names appear verbatim in the excerpts. If you can only see N of what looks like a longer list, say so explicitly.").
- **Incoherent grounded output on dense narrative text.** EPUB Q1 produced "Joseph Malik...accused of being a doctor" — word salad. Polish was masking grounded fragility on literary prose. Probably an AFM ceiling on dense narrative grounding; not a prompt fix.
- **Source-layout concatenation.** PDF Q2 "Anonymous Mark Friedlander" — the doc has "Information wants to be free.… - Anonymous Mark Friedlander Telecommunications Law…" with no delimiter between the quote attribution and the byline. Could be addressed in the import path (PDF byline detection) rather than the prompt.

**Original Task 4 / pairwise STM section follows below — unchanged from 2026-05-03 review.**



**2026-05-03 — Task 4 complete (#1–#10).** All ten fixes from Mark's Task 4 list are implemented and pushed. The verbatim STM pipeline is unchanged (production default); the new pairwise STM pipeline ships as an opt-in for testing. Both modes are fully exercisable via `/ask` with `summarizationMode: "verbatim"` (default) or `"pairwise"`. Per Mark's directive, default selection is deferred until Mark reviews the comparison data.

**Pairwise vs. verbatim STM — RECOMMENDATION 2026-05-03: KEEP VERBATIM AS DEFAULT.**

Ran real (non-scripted) conversations on three documents — Saint Helena geography, photosynthesis basics, jazz origins — in both modes. 4–5 turns per doc, identical questions per mode for clean comparison. Mac Catalyst antenna, AFM live, all responses captured with `pairwiseStats` for the pairwise side.

**Pairwise wins (where it actually beat verbatim):**
- **Jazz T5 co-reference**: "Who were the key musicians of *that style*?" (after a turn about bebop succeeding swing). Verbatim resolved "that style" to **swing** and gave Goodman/Basie/Miller — wrong. Pairwise resolved to **bebop** and gave Parker/Gillespie/Monk — correct. The user-questions-only narrative STM in verbatim mode lost the topic anchor; the per-pair summaries kept it.
- **Jazz T4 conciseness**: pairwise replied "Bebop." (one word). Verbatim produced a confused paragraph that called swing "jazz's swing" and mangled the bebop relationship.

**Pairwise losses (where verbatim was more reliable):**
- **Photosynthesis T4 fact loss**: "Did any of them win awards for it?" Verbatim correctly retrieved "Calvin received the Nobel Prize in Chemistry in 1961" verbatim from the document. Pairwise said **"Nope, no awards for them"** — explicit factual contradiction. The summarization compressed away the Calvin/Nobel association so the follow-up couldn't recover it. This is the opposite of what summarization should do.
- **Jazz T1 hallucination**: pairwise added "It's a genre that captures the spirit of resilience, creativity, and expression, and it's been a cornerstone of American music for generations" — none of that is in the source document. Citation [1] misattributed. This is a HARD RULE #1 violation (NEVER FABRICATE). Verbatim T1 stuck to source language.
- **Saint Helena T4 first-person drift**: pairwise said "*we* get a nice little subsidy from the British government" / "*we* finally got our own airport." Posey adopted the persona of a Saint Helena resident. The summaries somehow primed first-person identification with the document's subject. Verbatim stayed clean third-person.

**Net read:** for a focused reading companion where factual fidelity is the load-bearing property, verbatim is safer. Pairwise's coherence wins are real but its accuracy losses (fact dropping, hallucination, voice drift) are worse than the verbatim co-ref failure they would replace. Verbatim's worst case is "Posey gave a wrong answer to a follow-up because pronoun resolution failed"; pairwise's worst case is "Posey confidently invented something that isn't in the document." The first is a known limitation Mark can correct by re-asking; the second erodes trust in answers Mark might not double-check.

**Required before pairwise can be the default** — three concrete fixes pairwise needs first:
1. **Preserve key entities in summaries.** The summarization prompt currently allows compression to drop names/dates/prizes if they don't fit the sentence budget. Fix: rewrite the summarizer prompt to *require* preservation of any proper noun, year, prize, or numeric fact mentioned in the verbatim Q/A. Tier-1 (most-recent, 4 sentences) has the room; tier-2/3 should still preserve the headline entity even at 1 sentence.
2. **Tighten the third-person constraint.** Add an explicit "the summary must use third person — never 'we', 'our', 'us'" rule to the summarizer prompt. The Saint Helena drift came from Posey identifying with the document's subject after summary compression flattened the narrative.
3. **Re-apply the no-metaphor / no-editorial polish rule against the pairwise pipeline output.** The Jazz T1 "spirit of resilience" line was injected during the polish step against the pairwise-summarized context. The polish HARD RULE #5 (no metaphors) and HARD RULE #1 (NEVER FABRICATE) need to fire even when the input is a summary, not a verbatim grounded draft.

The mode flag stays in place; the toggle is one line in `apiAsk` plus the body field. Both pipelines remain shippable. When the three fixes above land, re-run the same 3-doc comparison and reassess.

**Done.** No further input needed from Mark on the comparison itself — recommendation made.
- **Anchor-scroll fix (carryover from 2026-05-02 afternoon).** Still awaiting Mark's screenshot to confirm symptom + decide sticky-pin design before touching scroll behavior.
- **Q3 too-terse follow-ups (carryover).** Deferred as a model-capability ceiling.
- **`tools/qa_battery.sh` hard-coded doc IDs (carryover).** Switch to title-based lookup via `LIST_DOCUMENTS`.

**Task 13 (release-build hygiene) — fully complete 2026-05-03.** Final audit:
- **13.1** `LocalAPIServer.swift` wrapped top-to-bottom in `#if DEBUG` (lines 10–413). Release ships zero HTTP server runtime.
- **13.2** Eight `#if DEBUG` guards in `LibraryView.swift` covering the property declaration + every call site (`toggleLocalAPI`, the auto-start in `body.onAppear`, `apiState`'s `connectionInfo`).
- **13.3** Three `NSLog` calls remain in the codebase — all inside `LocalAPIServer.swift` (which is itself `#if DEBUG`-only). Every other prior `NSLog` (31 of them) was converted to `dbgLog`, an `@inlinable` no-op in release. Release binary ships zero diagnostic output.
- **13.4** `UIDevice.orientationDidChangeNotification` observer in `ReaderView.swift:312` covers within-orientation rotations (landscape-left → landscape-right) that don't fire a sizeClass change. Existing sizeClass hooks remain.
- **13.5** Go-to-page UX polish landed in `ReaderView.swift:~3380–3460`: specific error wording (per-failure-type), accessibility labels reading the valid page range alongside the field name, Stepper alternative for users who prefer ±1 paging over typing.

Nothing in Task 13 requires Mark's input. All five sub-items are code-only and complete.

**Task 7 (Audio Export) — already complete in code; awaiting Mark's ears for final quality review.** Investigation question is already answered by the existing implementation:
- `AVSpeechSynthesizer.write(_:toBufferCallback:)` empirically does NOT capture Best-Available / Siri-tier voices on most devices. The `AudioExporter` already detects this case (no buffers come back from the first utterance, `currentIndex == 0 && !sawBuffer`) and surfaces `AudioExportError.voiceNotCapturable` with the clear user message: *"Best Available voices can't be captured to audio files. Switch to Custom voice in Preferences and try again."*
- M4A export is wired (`AVAudioFile` with `kAudioFormatMPEG4AAC`, medium quality), progress indicator + segment counter + cancel are in `AudioExportSheet`, ShareLink supports Save to Files + share, and the headless `RemoteAudioExportRegistry` exposes `EXPORT_AUDIO`/`AUDIO_EXPORT_STATUS`/`AUDIO_EXPORT_FETCH` for API-driven exports.
- **Needs Mark's ears**: subjective audio quality of the rendered M4A on a real device — the simulator doesn't ship the same voice catalog, so a final pass on iPhone with both Custom voices and a long document is the only meaningful quality gate.

**Task 10 (Mac Catalyst) — ENABLED + verified launch 2026-05-03.** `SUPPORTS_MACCATALYST = YES` added to both Debug and Release configurations of the main Posey app target via direct `project.pbxproj` patch. Catalyst destination now appears in `xcodebuild -showdestinations`. First Catalyst build succeeded on the first attempt with zero source-code changes required — Posey's iOS-only code paths (UIDocumentPicker via `.fileImporter`, AVSpeechSynthesizer voice list, AVAudioFile export, NWListener for the local API, AFM availability check) all compile and link clean against the Mac Catalyst SDK.

Launched and verified running on Mac (PID survived 30s + log shows no Posey-code errors — only benign Catalyst lifecycle warnings: `QuartzCore: cannot add handler to 4 from 1` is a known Catalyst noise; LaunchServices `_LSOpenExtractBackgroundLaunchReasonFromAppleEvent` is normal). The local-API antenna binds to port 8765 successfully on Mac (confirmed by collision when re-launching with the previous instance still alive).

Polish landed for Mac windowing: `WindowGroup` gets `frame(minWidth: 480, minHeight: 600)` and `defaultSize(width: 720, height: 900)` under `#if targetEnvironment(macCatalyst)` so the layout has room to breathe and starts at a reasonable size on first launch (was opening at the iPhone aspect ratio before).

**Findings — what works on Catalyst out of the box:**
- File picker (`.fileImporter`) — bridges to native macOS open panel.
- TTS voice list (`AVSpeechSynthesisVoice.speechVoices()`) — returns Mac's voice catalog. The new audio-export auto-fallback (Task 7) picks the highest-quality English voice on whatever device it runs on, so the same code works on Mac.
- Local API server (NWListener bind on port 8765). Triggers a one-time "Local Network" privacy prompt the first time Posey wants to listen — a Mac OS X 26 behavior matching iOS.
- Reader, Library, Notes, Ask Posey, TOC, Audio Export — all SwiftUI screens render via UIKit-on-Mac. Sheet detents (`.presentationDetents`) are silently ignored on Catalyst; sheets present full-height instead. Acceptable.
- AFM (Apple Foundation Models) availability check works — `model.availability` reports based on macOS support.

**Subjective items left for Mark's review when on a real Mac:**
- TTS voice quality: the Mac voice catalog ships premium voices that may sound different from Mark's iPhone selection. The export auto-fallback picks the best, but he may prefer a specific voice.
- Window resize behavior at extreme widths (>1200 px) — the reader column doesn't currently constrain to a max comfortable width; on a 27" display the text would stretch edge-to-edge.
- Sheet detent treatment — full-height sheets on Mac are conventional but Mark may want a constrained-width sheet style for Ask Posey specifically.

**BLOCKED — Task 10 (Mac Catalyst verification, OBSOLETE — kept for diff history).** Posey's Xcode project currently has neither `SUPPORTS_MACCATALYST` nor `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD` set. The project literally cannot run on Mac today; "verification" first requires enabling Catalyst as a target destination, which is a deliberate config change that:
  1. Edits `project.pbxproj` (touches iOS provisioning + entitlements).
  2. May force `#if targetEnvironment(macCatalyst)` branches for: file picker (`UIDocumentPickerViewController` works but feels native-broken on Mac), half-sheet detents (`.presentationDetents` are iOS-only — Mac needs different presentation), TTS voice list (Mac ships a different voice catalog than iPhone), local-API server bind address (Mac uses different network entitlements), window sizing, and AFM availability (FoundationModels ships on macOS too, but the Catalyst variant has its own gating).
  3. Risks regressions on the iPhone target if entitlements and code-signing aren't carefully separated.

  This is the kind of change Mark wants discussed first per CLAUDE.md ("Discussion before code… Large moves always need discussion"). Verification of "voice list differences on Mac, file picker behavior, half-sheet detents, window sizing, local API behavior on Mac" can begin once Catalyst is enabled. Awaiting Mark's go-ahead to enable + plan the verification pass.

**Autonomous task sequence in flight (Mark's 2026-05-03 directive while away):**

**COMPLETED 2026-05-03:**
- Task 7 (Audio Export) — already complete in code; documented findings.
- Task 8 #1 — PDFDocumentImporter delegates to TextNormalizer (full Unicode-aware passes); local duplicate helpers removed.
- Task 8 #6 — TOCSheet now uses `StoredTOCEntry.compositeID` (playOrder + offset + title) so synthesized EPUB TOCs with duplicate playOrder=0 stop crashing the sheet.
- Task 8 #7 — WORD-WORD space-hyphen artifact documented as deferred with rationale (TextNormalizer Block 05). Without font / glyph metrics we can't distinguish artifact from legitimate em-dash usage; rare in real-world reading.
- Task 13 #1 — Full LocalAPIServer compile-out in release. The HTTP server type, bearer-token Keychain handling, and port-bind code are wrapped in `#if DEBUG`; the `LibraryViewModel.localAPIServer` property and all six call sites are `#if DEBUG`-guarded. Release builds verified compile.
- Task 13 #2 — `#if DEBUG` guards added at every LocalAPIServer touch point; release-only fallbacks (`apiState` no longer surfaces `connectionInfo`).
- Task 13 #3 — Introduced `dbgLog(...)` (Posey/Services/Diagnostics/DebugLog.swift): `@inlinable` no-op in release. Replaced 31 chatty `NSLog` calls in AskPoseyService, DocumentEmbeddingIndex, AskPoseyChatViewModel, PDFDocumentImporter, and EPUBDocumentImporter. The remaining 3 `NSLog` calls live in LocalAPIServer (which itself is DEBUG-only). Release binary now ships zero diagnostic output.
- Task 13 #4 — Landscape centering: added `UIDevice.orientationDidChangeNotification` observer to catch within-orientation rotations (landscape-left → landscape-right) that don't fire a sizeClass change.
- Task 13 #5 — Go-to-page UX polish: better error wording (specific to the failure type), accessibility labels reading the valid page range alongside the field name, Stepper alternative for users who prefer ±1 paging over typing.

**DEFERRED items needing Mark's review:**
- **Task 8 #5 (blank visual stop suppression).** First attempt (suppress when `!pageHasImageXObjects(page)`) was wrong — vector-drawn pages (CGContext fill paths, no XObject) are not blank but have no image XObject either. Reverted. Real fix needs PNG-pixel-uniformity scoring: render the page, sample N pixels, score colour variance, suppress the visual stop when ≥99% of pixels match a single colour cluster within a tight delta. Antifa corpus has 11 verified-blank pages this would catch.
- **Task 8 #2 (EPUB TOC playback-skip-until-offset).** PDF importer detects TOC regions and sets `playback_skip_until_offset` so TTS skips past them. EPUB has separate nav/NCX *files* (referenced by package, not in spine), so playback already skips them by construction. The remaining gap is EPUBs where the TOC is rendered into a spine item (e.g. Calibre exports occasionally do this) — that case needs a similar dot-leader / TOC-pattern detector for HTML chapters. Punted because: real-world EPUBs in Mark's library don't seem to hit this; the spine item TOC pattern needs a sample to design against.
- **Task 8 #3 (DOCX TOC field detection).** Investigation: DOCX TOCs are typically MS Word `TOC` fields wrapped in `<w:fldSimple instr="TOC"/>` or `<w:fldChar fldCharType="begin"/> ... TOC instructions ... <w:fldChar fldCharType="end"/>` markers. Detecting requires extending `DOCXDocumentImporter` to walk the field-instruction stream and either skip the TOC region or treat it like PDF's dot-leader detector. Implementable but non-trivial — needs a real DOCX with a TOC field to design against.
- **Task 8 #4 (inline images for DOCX and HTML).** EPUB and PDF emit `[[POSEY_VISUAL_PAGE:N:uuid]]` markers for inline visuals. DOCX (XML+ZIP) and HTML (`<img>` tags) carry inline images, but the importers currently strip them. Implementation pattern: extract image bytes from `word/media/` (DOCX) or fetch `<img src=...>` referents (HTML), persist via the existing `document_images` table, emit visual markers at the right offset. Non-trivial because the offset accounting in both importers needs to interleave image markers correctly with text — same kind of work EPUB went through.
- Task 10 — Mac Catalyst verification (BLOCKED, see above).
- Task 7 — Audio Export (M4A) with progress + share.
- Task 8 — Code-only items: PDF normalizer parity check, EPUB TOC playback-skip, DOCX TOC field detection, inline images for DOCX/HTML, blank-visual-stop suppression, TOCSheet composite id, WORD-WORD space-hyphen artifact.
- Task 13 — Code-only items: full LocalAPIServer compile-out in release, complete `#if DEBUG` guards, no debug output in release, landscape centering, go-to-page UX polish.

**Open follow-ups for Ask Posey 2.0:**
- **Per-document-type citation thresholds.** The single global cosine threshold (`DocumentEmbeddingIndex.citationCosineThreshold = 0.50`, set 2026-05-02 from a 15-question battery) applies uniformly. Real data showed factual answers concentrate around 0.62–0.77, analytical 0.45–0.70, vague 0.27–0.51 — a per-type threshold (factual stricter, analytical looser, vague looser still) would be more selective without losing legitimate attributions. Deferred until we have larger ground-truth data on what user expectations are by question type. The constant + delta sit in one place (`DocumentEmbeddingIndex.swift` BLOCK 03) so a per-type table replaces them cleanly when we revisit.

**2026-05-02 (later evening):** Task 2 complete. Markdown rendering fixed (Text(.init(...)) markdown init). Sources persist across sheet open/close (translateStoredTurn now decodes chunks_injected JSON). Inline `[ⁿ]` superscript citations replace the old SOURCES pill strip — three layers of reliability: stronger prompt for grounded call, polish-skip for short answers with citations, embedding-based attribution fallback (NLEmbedding cosine, threshold 0.4, multi-cite delta 0.05, scores logged via NSLog for tunability). AFM-emitted markers take priority. Motion permission only ever prompts after explicit Auto selection (lazy CMMotionActivityManager init + auto-show consent sheet on Auto pick). Verified on device. Commits `1100a82`, `86279b7`, `b947682`. **Future quality pass — three-tier MicroDoc verifier pattern noted by Mark for evaluation later (cosine-keep / source-substitute / AFM-rewrite-with-strict-grounding, with bestIdx as the citation pointer rather than discarded).**

**2026-05-02 (evening):** Local API became the full remote-control surface. Per Mark's directive — "the API must be able to do everything a human can do that isn't blocked by Apple security policies" — the gap audit identified missing playback transport, sheet opens, preferences setters, search, page jump, audio export, library nav, and a generic TAP that worked on SwiftUI controls. All of those landed (commits `d10dd31` → `4e91291`). New file `RemoteControl.swift` houses the `RemoteTargetRegistry` and the `.remoteRegister(_:action:)` modifier — every Button across Library, Reader chrome + transport, Notes, Ask Posey anchors, Preferences (Audio Export, Motion Consent), TOC (Go button), and Search bar now registers its action under a stable id. `TAP:<id>` fires the registered closure (registry path verified end-to-end on device). Headless audio export driver in `RemoteAudioExportRegistry.swift` runs the full `AudioExporter` pipeline without the sheet open; `EXPORT_AUDIO` returns a job id and `AUDIO_EXPORT_STATUS` / `AUDIO_EXPORT_FETCH` cover progress + result retrieval. Step 7 scroll fix — Ask Posey opening from Notes-tap-conversation now lands on the correct anchor via three-stage scroll defeating LazyVStack realization race; verified on two distinct anchors. Full surface documented in `DECISIONS.md` ("Local API Is The Full Remote-Control Surface" + "RemoteTargetRegistry For Generic Tap Dispatch"). Standing rule: every PR adding a button/gesture/sheet ships its API verb in the same change.

**2026-05-02 (afternoon):** Integrated UI QA pass on real device shipped voice polish v2 + doc-scope orphan fix + /ask intent plumbing (commits `eeae1da`, `4624e05`). Mark called out that the morning's "Three Hats QA pass" had been API-only — never opened the actual sheet, never looked at a screenshot, never drove the integrated experience. This pass corrects that: drove `/ask` + `/open-ask-posey` on Mark's iPhone, traced 5 distinct bugs through code inspection, fixed 3 outright, tried + reverted 1 (Q3 terseness — over-tuning hit AFM ceiling), deferred 1 (anchor-scroll behavior — needs Mark's screenshot to confirm symptom + decide sticky-pin design before touching scroll behavior).

Voice now lands on substantive grounded answers ("Four contributors: Mark Friedlander, ChatGPT, Claude, Gemini" verbatim-matches the prompt example; Internet Steps Q1 reliably produces librarian-DJ texture). Terse factual answers stay tepid — polish can't manufacture voice from a six-word draft without padding. AFM-ceiling territory; revisit if it bothers Mark.

**Open from this pass:**
- **Anchor-scroll fix** — `.defaultScrollAnchor(.bottom)` fights `proxy.scrollTo(anchorRowID, .top)` on appear; once conversation continues, anchor scrolls out of view. Sticky-pin anchor outside ScrollView is the likely fix. Awaiting Mark's screenshot to confirm symptom before changing scroll behavior.
- **Q3 too-terse follow-ups** — *"It does."* on yes/no follow-ups when doc has more to say. Per Mark's AFM tuning-limits guidance, deferred as a model-capability ceiling.
- **`tools/qa_battery.sh` hard-coded doc IDs** — stale after re-imports. Switch to title-based lookup via `LIST_DOCUMENTS`.

**2026-05-02 (morning):** Three Hats QA pass shipped — real multi-turn conversations driven against AI Book / Copyright PDF / Internet Steps PDF surfaced and fixed 12 distinct quality bugs (front-matter retrieval miss, format imitation, token under-counting, anti-hallucination over-correction, role attribution, abstract cherry-picking, more — see HISTORY 2026-05-02). Two-call polish pipeline now runs (grounded @ 0.1 → polish @ 0.55 in Posey's voice); refusal retry with neutral rephrasing → informative-failure fallback; classifier-refusal silently falls back to `.general`; refusal-shape guard prevents polish from inventing facts when grounded says "doesn't say." Test-harness cooldown (2.5s ± 500ms) closes the AFM `Code=-1` instability under sustained load — final battery 12/12 PASS, zero AFM errors. Cascade-delete verified end-to-end across all 6 child tables; Mark can delete + re-import safely. **Caveat:** this morning's "QA pass" was API-only; afternoon's pass corrects that by driving the integrated UI experience.

**2026-05-01:** All of Mark's earlier autonomous queue is done and on device. Today's session also shipped: NavigationStack double-push fix (alert collision + `.task` re-fire guard), TOC hide-from-reader (segments + displayBlocks filtered at view-model init so the skip region is invisible by construction), shared `TextNormalizer` bringing TXT/MD parity with PDF, format-parity standing policy in CLAUDE.md, antenna default ON for dev, PDF TOC detection at import + auto-skip + entry parsing, simulator MCP setup with idb patch for Python 3.14, push-to-origin policy made explicit in CLAUDE.md, AFM availability verified on device + simulator, Hal blocks read and digested, implementation plan reviewed and approved by Mark with answers to 8 open questions, **Ask Posey Milestones 1–4 complete on device, M4 polish + pre-open hang fix shipped**.

**Ask Posey is in flight.** Plan: `ask_posey_implementation_plan.md` (approved 2026-05-01). Spec: `ask_posey_spec.md`. Architecture: `ARCHITECTURE.md` "Ask Posey Architecture" (rewritten in Milestone 1 to match the spec). Constitutional commitments: `CONSTITUTION.md` "Ask Posey" (rewritten in Milestone 1).

**Milestone status:**

- **Milestone 1 — Doc alignment + schema migration: DONE (2026-05-01).** ARCHITECTURE.md / CONSTITUTION.md rewritten to the spec; `ask_posey_conversations` and `document_chunks` tables migrated in via `addColumnIfNeeded`-style discipline; `idx_ask_posey_doc_ts` and `idx_document_chunks_doc` created; `ON DELETE CASCADE` verified by integration test; `AskPoseyAvailability` skeleton wraps `SystemLanguageModel.default.availability`; full PoseyTests suite passes on device with the new tests included.
- **Milestone 2 — Document embedding index: DONE (2026-05-01).** Service + DB helpers + hooks (`1ba5ea1`). Three follow-on fixes verified after the token-limit reset (commit pending — see latest): (a) `StoredDocumentChunk: Equatable`; (b) `nonisolated` on `DocumentEmbeddingIndex`, its public types, and `DocumentEmbeddingIndexConfiguration` — confirmed `nonisolated struct/enum` compiles fine in Swift 5 + approachable-concurrency. The MainActor-deinit-on-non-main-thread crash that surfaced during the first test run is gone (synthesised deinit no longer hops via `swift_task_deinitOnExecutorImpl`); (c) `tryIndex(_:)` helper on `DocumentEmbeddingIndex` so importer call sites are `embeddingIndex?.tryIndex(document)` — clean (no unused-`try?` warnings) and adds an NSLog breadcrumb on indexing failure so consistent failures don't go silent. All three M2 test suites green on simulator. Device regression pending Mark's go-ahead (per the no-surprise-device-install rule).
  - **Open follow-up:** retro-indexing of pre-existing imports needs to happen on first Ask Posey invocation — the index call is in place but the "Indexing..." UI state belongs in the sheet milestone (4).
- **Pre-M3 fix sweep: DONE (2026-05-01).** Mark's Illuminatus repro surfaced five issues, all addressed:
  - **#3 TOC button missing** — synthesized fallback from spine items when nav/NCX is empty (commit `f901b88`). Hocr-to-epub-style EPUBs ship empty `<navMap/>` / `<ol/>` placeholders; we now surface a "Page N" entry per spine item using `<title>` extraction.
  - **#2 Internet Archive disclaimer in opener** — confirmed it's EPUB content (notice.html spine item), not Posey-generated; new `EPUBFrontMatterDetector` sets `playbackSkipUntilOffset` past it via the same plumbing the PDF TOC detector uses (commit `d034eb7`). The reader's existing skip-region filter handles segment / display block exclusion automatically.
  - **#1 + #4 indexing indicator + AFM gate** — embedding moved off-main; new IndexingTracker + reader banner; banner hidden entirely when `AskPoseyAvailability.isAvailable == false` per spec (commit `daed324`).
  - **Indexing progress count** — Mark's follow-up after #1+#4: added `.documentIndexingDidProgress` notification posted every 50 chunks; banner shows "Indexing this document… / 847 of 3,300 sections" with a determinate progress ring (commit `c9b4867`).
  - **#5 Go-to-page input** — `DocumentPageMap` derived from existing on-disk data (no migration); PDF path walks form feeds, EPUB path harvests "Page N" TOC titles; new section in TOCSheet with number-pad input, format-honest accuracy footer, inline error UI (commit `4098815`).

**Ask Posey milestones (M3–M7) — feature work:**

- **Milestone 3 — Two-call intent classifier: DONE (2026-05-01).** `AskPoseyIntent` `@Generable` enum (`.immediate | .search | .general`) with raw-value pinning; `AskPoseyClassifying` protocol + live `AskPoseyService` with per-call session lifecycle; full `GenerationError` translation (all 9 cases including `.refusal`) into `AskPoseyServiceError` `.afmUnavailable / .transient / .permanent`; `AskPoseyPrompts` nonisolated for static defaults in init parameter positions. Tests: prompts (7), intent enum (3), on-device AFM probe (2 — both pass on Mark's iPhone 16 Plus at 0.7s and 1.0s, first end-to-end `@Generable` classification on real hardware). Commit `393a8f4`.
- **Milestone 4 — Modal sheet UI shell: DONE (2026-05-01).** `AskPoseyMessage` / `AskPoseyAnchor` value types (Sendable), `AskPoseyChatViewModel` (`@MainActor ObservableObject`, `@Published` messages/inputText/isResponding, `canSend` gating, `sendEchoStub` for M4, `Identifiable` for `sheet(item:)`, DEBUG-only `previewSeedTranscript`), `AskPoseyView` with anchor + chat history + composer all inside one LazyVStack, `defaultScrollAnchor(.bottom)`, composer auto-focus 250ms after present. ReaderView wires bottom-bar sparkle glyph (far left, `if AskPoseyAvailability.isAvailable`) + `sheet(item:)`. Verified on Mark's iPhone 16 Plus. Commit `110a487`. **M4 device-pass polish (commit `19af951`):** `.large`-only detent on iPhone (compact size class) since `.medium` left no visible document; anchor moved INTO LazyVStack as first row so it scrolls with the conversation; privacy lock indicator removed (confusing not reassuring); Notes draft no longer auto-populates (running headers in plainText were leaking in); `nonisolated deinit {}` on ReaderViewModel to fix the `swift_task_deinitOnExecutorImpl → TaskLocal::StopLookupScope → malloc abort` crash. **Pre-open hang fix (commit `cb2ac8a`):** ReaderViewModel content loading moved to `Task.detached(priority: .userInitiated)` with `isLoading` overlay; on Illuminatus the previous 5–10s blank screen is replaced by an immediate "Opening …" spinner. All 12 ReaderViewModelTests converted to `async throws` with `await viewModel.awaitContentLoaded()` synchronisation; full suite green on simulator (12/12).
- **Milestone 5 — Prose response loop with full prompt-builder architecture: DONE (2026-05-01).** Per Mark's architectural correction (2026-05-01): conversation history is permanent (not session-scoped) and lives in `ask_posey_conversations`; document RAG is load-bearing infrastructure that the prompt builder must accommodate from M5 even though M5 leaves chunks empty (M6 fills them); auto-summarization code path exists in M5 but doesn't fire (M6 activates it). Build `AskPoseyPromptBuilder` with **all sections present from day one** — system, anchor + surrounding, recent verbatim STM, conversation summary, document RAG chunks, user question — with explicit per-section token budgets and instrumented drop priority. **Token budget (starting values, tunable via local API):** 4096 context window; 512 response reserve; within the prompt ceiling: ~5% system/instructions (180 tokens, never dropped), ~10% anchor + immediate surrounding (360 tokens, never dropped), ~20% STM verbatim (720 tokens, ~3-4 turns), ~10% summary (360 tokens), ~50% RAG chunks (1800 tokens), user question protected. **Drop priority:** oldest RAG chunks → summary → oldest STM turns → surrounding → user question truncated; system + anchor non-droppable. **Conversation history is permanent:** every assistant turn writes to `ask_posey_conversations`; sheet-open queries the table for prior turns; the prompt builder reaches into SQLite invisibly. **UI:** prior turns surface above-the-fold (iMessage pattern — anchor + composer at bottom of sheet, prior conversation accessible by scrolling up, invisible unless looked for). **Per-call session lifecycle:** each prose call creates a fresh `LanguageModelSession` and dies when the function returns — no transcript reuse, app fully owns the context. Routes all three intents (`.immediate`, `.search`, `.general`) through the same builder; degraded answers in M5 for the latter two are acceptable until M6 populates RAG. **M5 follow-up from Mark's M4 device pass:** anchor pinned until first send, scrolls with conversation thereafter. Acceptance: ask a question with a real anchor on Mark's iPhone, see prose stream in, error path (force AFM unavailable) renders the translated `AskPoseyServiceError` cleanly, cancel-in-flight on dismiss leaves no zombie task, prior conversation visible above-the-fold across sheet opens.
- **Milestone 6 — Populate the empty M5 sections + document-scoped invocation: DONE (2026-05-01).** RAG retrieval + auto-summarization + document-scoped Menu all shipped. Two things M5 architecturally accommodates but doesn't activate; M6 lights both up. **(a) Document RAG retrieval — fills `documentChunks: []`.** Cosine search over `document_chunks` (already indexed in M2) keyed off the user question; top-K chunks dedup'd against STM + anchor + summary by cosine similarity (≥0.85 threshold); chunks ranked by relevance and trimmed to fit `ragBudgetTokens` (~1800). **(b) Auto-summarization of older conversation turns — fills `conversationSummary: nil`. THIS IS A HARD M6 BLOCKER and cannot slip — without it, M5's STM window quietly drops older turns from the model's view as the conversation grows past ~3-4 turns, and the "I remember everything we ever discussed" promise breaks.** Implementation: when fetching turns for STM, partition into "recent N (verbatim)" vs "older (needs summary)"; if older turns exist and no current summary covers them, kick off a background `AskPoseyService.summarizeConversation(turns:) async throws -> String` call (uses its own fresh `LanguageModelSession`); cache the summary by `summary_of_turns_through` watermark in `ask_posey_conversations` (`is_summary = 1` rows); next prompt build picks up the cached summary. Summary triggers the same way Hal's does — when STM window starts dropping turns, summarize the dropped ones. **Document-scoped glyph for `.general` invocation** also lands here (the bottom-bar glyph already exists from M4; M6 adds a second invocation entry point that doesn't capture an anchor, so the prompt builder gets `anchor: nil` and the surrounding section degrades to chunks-only).
- **Milestone 7 — Navigation pattern + auto-save + source attribution + indexing indicator (UI): DONE (2026-05-01).** All four features shipped: source attribution (pill strip), auto-save to notes, in-sheet indexing indicator, AND navigation cards (`.search` intent → `@Generable AskPoseyNavigationCardSet` → tap-to-jump via `onJumpToChunk`).

- **Three Hats QA pass + voice + retry: DONE (2026-05-02).** Real-conversation QA on three documents surfaced 12 distinct quality bugs; all fixed. Two-call pipeline shipped (grounded @ 0.1 → polish @ 0.55 in Posey's voice — librarian-DJ character prompt). Refusal-shape guard before polish prevents fact-invention on out-of-doc questions. Refusal retry with neutral-academic rephrasing → informative-failure fallback. Classifier-refusal silently falls back to `.general` intent. Test-harness AFM cooldown (`tools/qa_battery.sh` + `tools/posey_test.py ask`) closes `Code=-1` instability under sustained load — final battery 12/12 PASS, zero AFM errors. Cascade-delete verified end-to-end across all 6 child tables. **Open quality items** for follow-up after Mark's interactive testing:
  - Polish call sometimes elaborates beyond the grounded draft when the question implies general knowledge ("Alternative Dispute Resolution" → polish adds "mediation, arbitration, negotiation"). Strictly the rules say no, but the elaboration is accurate. Mark's call whether to tighten further.
  - Some Q3 follow-up answers stay terse when more substance would help (e.g. *"The paper discusses copyright disputes"*). The grounded call is short; the polish honors that. Could prompt the grounded call to be more substantive.
  - 2 AFM safety refusals out of 12 questions — both on synthesis-style questions involving philosophical/legal interpretation. AFM-side, opaque; UX-side fix already in (informative bubble).
- **Milestone 7 ORIGINAL SPEC (preserved for reference):** `.search` intent → Generable navigation cards → existing TOC jump infrastructure; auto-save to notes; track which RAG chunks contributed to each response and render a "Sources" strip under the assistant message (pills tap-jump to the cited offset via the existing offset-jump infrastructure); first-time "Indexing this document…" → "Indexed N sections." indicator wired into the sheet (the index work itself ships in M2; this is the in-sheet UX surface for it). Both source attribution and indexing indicator are spec'd in `ask_posey_spec.md` (sections "Source Attribution" and the indexing-indicator paragraph under "The Ask Posey Sheet UI"). Persistence: chunk references stored on the assistant turn in `ask_posey_conversations` so attribution survives across sessions.

**Post-Ask-Posey feature pass — M8:**

- **Reading Style preferences (Standard / Focus / Immersive / Motion).** New "Reading Style" section in the preferences sheet with four options. These are **preferences, not separate application modes** — discoverable, consistent, user-controlled. Per `DECISIONS.md` "Reading Style as Preferences not Modes" (2026-05-01).
  - **Standard** — current behavior. Single highlighted active sentence, surrounding text at full opacity.
  - **Focus** — dim every non-active sentence to ~40–50% opacity so the eye is naturally drawn to the brightest element. Functionally additive on top of the existing highlight tier; same data model, just a different render path.
  - **Immersive** — slot machine / drum roll scroll. Active sentence centered at full size and brightness; sentences above and below fade out and scale down slightly as they move away from center, creating a smooth rolling transition as playback advances. Higher implementation cost (custom layout + per-row transform driven by distance-from-center).
  - **Motion** — large single centered sentence, optimized for walking / driving / hands-free reading. Inherits the **three-setting Off / On / Auto behavior** described next.
- **Motion mode (Off / On / Auto).** When the Reading Style is set to Motion, three sub-settings let the user control when it activates:
  - **Off** — never use Motion mode regardless of the device's actual movement state. Always use the user's last non-Motion Reading Style.
  - **On** — Motion mode always. The user is intentionally using Motion mode regardless of device movement (e.g. a stationary reader with low vision who prefers the large centered sentence).
  - **Auto** — Posey monitors device movement via `CoreMotion` and automatically switches between Motion (when moving) and the user's last non-Motion Reading Style (when still). **Auto requires explicit user consent before enabling CoreMotion monitoring** — Posey shows a clear opt-in screen explaining why motion data is needed and that it stays on-device.
  - Per `DECISIONS.md` "Motion Mode Three-Setting Design" (2026-05-01).
- **Lock-screen + background audio support.** Two things, both load-bearing for the Motion-mode use case (listening in your pocket while walking, cycling, driving). Without this the locked-screen experience feels accidental.
  - **Verify background audio is configured correctly.** `AVAudioSession.sharedInstance().setCategory(.playback)` (or `.playback` with `.spokenAudio` mode for TTS) so iOS keeps Posey playing when the screen locks or another app comes forward. `UIBackgroundModes` in Info.plist must include `audio`. TTS should continue playing through `AVSpeechSynthesizer` while the app is suspended. Test specifically: lock screen mid-sentence, listen for at least one full segment to land on the next utterance, confirm playback continues seamlessly.
  - **Lock-screen controls via `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`.** Same mechanism Podcasts and Audiobooks use. Surface play, pause, previous sentence, next sentence as remote commands. Populate `MPNowPlayingInfoCenter.default().nowPlayingInfo` with the document title (`MPMediaItemPropertyTitle`), the current sentence text or position (`MPMediaItemPropertyArtist` or a custom field), and elapsed/total time if a meaningful "duration" can be derived for the current pass. Update on every sentence advance. Without this the lock screen shows a generic "audio playing" placeholder; with it, Posey looks like a first-class audio player.
- **Audio export to M4A.** Render document to audio file via the existing TTS pipeline, saveable to Files and shareable via the share sheet. **Investigation required first:** does `AVSpeechSynthesizer.write(_:toBufferCallback:)` capture Best Available (Siri-tier) voices? Apple may gate premium / accessibility-channel voices from third-party capture. Custom voices almost certainly are capturable. Concretely: before designing the UI, run a test that calls `write(_:toBufferCallback:)` on a known Siri-tier voice utterance and check whether the buffer callback ever fires. If it doesn't, the audio-export surface is "Custom voice mode only" and the export button is disabled (or the voice picker is overlaid) when the user is in Best Available mode. UX: progress indicator while rendering, "Save to Files" + share-sheet entry on completion.
- **Full format-parity audit across all 7 supported formats** (TXT, MD, RTF, DOCX, HTML, EPUB, PDF). Systematically verify every Posey capability behaves correctly in every format that can support it. For each capability that works in one format, implement in all supportable formats. Capabilities to audit:
  - Inline images and visual stops
  - TOC detection and navigation (PDF / EPUB done; need parity for DOCX TOC fields, etc.)
  - Text normalization (the shared `TextNormalizer` is canonical; verify every importer delegates)
  - Position persistence
  - Search (Tier 1 today; v2 includes notes)
  - Ask Posey indexing (M2 already covers all 7 formats; verify on real corpus)
  - Audio export
  - Accessibility labels and Dynamic Type
  - Reading Style preferences (Standard/Focus/Immersive/Motion all four formats? probably yes)
  Document any format-specific limitations with clear rationale (per the format-parity standing policy in CLAUDE.md).
- **Mac Catalyst verification.** Verify Posey runs correctly on Mac via Catalyst, fix any layout or behavior issues. Note differences in voice availability and Local API behavior on Mac. Mac Catalyst will surface differences in: AVSpeechSynthesizer voice list, file picker behavior, accessibility surfaces, window sizing assumptions, NSWindow vs UIWindow paths, half-sheet detents (Catalyst doesn't always honor `.medium` cleanly).
- **Multilingual embedding improvements.** Already shipped as part of M2 (`NLLanguageRecognizer.dominantLanguage` at import → matching `NLEmbedding.sentenceEmbedding(for:)` → English fallback → hash fallback). M8's task is to **verify** the multilingual path on the real corpus (Hugo French, Goethe German, the synthetic mixed-script fixtures) and tune any thresholds that surface poor retrieval on real questions.
- **Entity-aware multi-factor relevance scoring v2** — promotes the previously-tracked v2 candidate to first-class M8 work. Multi-factor formula: `cosine + (entity_overlap × 2× factor) + context_relevance` (clamped). Most of the parts already exist (`NLTagger` for entity extraction, chunk text in `document_chunks`, query string at search time). Implementation: extract entities at index time alongside the embedding, persist them in a sibling table or JSON column, score with the new formula at query time. Behavioral A/B against pure cosine on real questions.

**Polish pass — M9:**

- **Antenna default flipped to OFF for release: DONE (2026-05-01).** `localAPIEnabled` `@AppStorage` default flips DEBUG → true, RELEASE → false.
- **Dev tools invisible in release builds: PARTIAL (2026-05-01).** Antenna toolbar item wrapped in `#if DEBUG`; auto-start at launch wrapped in `#if DEBUG`. Release-config build verified clean. Remaining (deeper compile-out): the `LocalAPIServer` class itself + `LibraryViewModel.toggleLocalAPI` / `apiAsk` / `apiOpenAskPosey` / `executeAPICommand` etc. methods. With the user-facing surfaces gone (toolbar item + auto-start) the API can't start at runtime; the dormant class is still in the binary. Cleanup candidate when M10 prep tightens the release binary further.
- **Full accessibility pass with VoiceOver on device.** Final audit covering labels, navigation order, touch targets (44×44 minimum), Dynamic Type scaling, Reduce Motion respect across all surfaces. Per the accessibility-compliance commitment captured in `DECISIONS.md` (2026-05-01).
- **Landscape centering polish.** Today off by ~5.5 px in landscape (acceptable but improvable). Final pass to listen for orientation changes and re-fire `scrollToCurrentSentence` once layout has settled.
- **Go-to-page navigation polish.** Already shipped as part of pre-M3 fix sweep (commit `4098815`). M9's task is final UX polish: error message wording, accessibility audit on the page input, possibly a stepper alternative for users who don't want to type.
- **App icon.** Serif P with oversized librarian glasses integrated into the letterform, monochromatic palette with subtle warm tortoiseshell tint on the glasses as the only color. Generate at every required size (1024 down to 20pt for spotlight); evaluate at multiple home-screen scales before locking the design.

**Submission — M10:**

- **Privacy policy** document. Address: on-device-only processing for the core reader; Apple Intelligence (private by design, end-to-end encrypted Private Cloud Compute when used); no third-party AI services; no analytics; no network requests in the core path. Hosted at a stable URL referenced from the App Store listing.
- **App Store metadata.** Description (lead with the core loop: import → read → listen with synced highlight → take notes → resume), keywords, primary and secondary categories, age rating, "What's New" copy.
- **Screenshots.** Use the simulator MCP to capture key app states across iPhone and iPad sizes: empty library, populated library, reader with active highlight, TOC sheet with chapter list and Go-to-page input, Notes sheet, Preferences sheet (Reading Style, voice picker), Ask Posey sheet (passage-scoped, document-scoped, navigation results), accessibility-enabled appearance.
- **App Store Connect navigation via browser automation.** Supervised — Mark present for sensitive steps (signing in, two-factor codes, final submission button). Use `mcp__Claude_in_Chrome__*` to drive the upload metadata + screenshots + binary submission flow, but pause at every irreversible step.
- **Final submission.** Verify the build is the release configuration with all M9 cleanups in place. Submit. Monitor review feedback and respond.

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

**Major feature — Ask Posey (in flight, M1–M4 DONE):**

Tracked at the top of this file under "Milestone status" and "Ask Posey milestones (M3–M7)". M1 (doc + schema), M2 (embedding index), M3 (intent classifier), and M4 (sheet UI shell + polish + pre-open hang fix) are complete on device; M5 (prose response loop with real AFM `streamResponse`) is next. Plan: `ask_posey_implementation_plan.md`. Spec: `ask_posey_spec.md`. Architecture: `ARCHITECTURE.md` "Ask Posey Architecture". Constitutional commitments: `CONSTITUTION.md` "Ask Posey".

Three interaction patterns (per the spec — selection scope is M5+, document scope is M6, annotation scope is later):
- **Selection-scoped** — user selects text, contextual menu offers "Ask Posey", modal sheet opens with the selection quoted at top.
- **Document-scoped** — dedicated glyph far-left of the bottom transport bar, modal sheet opens with the current sentence quoted at top, full document used as context.
- **Annotation-scoped** — accessible from the Notes surface.

Constraints (from CONSTITUTION.md / ARCHITECTURE.md):
- Apple Foundation Models only. Fully on-device. Offline. **No network requests, ever.**
- Full modal sheet for all three patterns.
- Transient session: conversation lives while the sheet is open; user saves to notes or discards on close.
- AI-generated content is always clearly labeled. Never presented as if it were the source document.

**Future reader UX modes — superseded by M8 Reading Style preferences (2026-05-01):**
- "Dim surrounding text" → **Focus** option in the M8 Reading Style section.
- "Slot machine / drum roll scroll" → **Immersive** option in the M8 Reading Style section.
- "In-motion mode" → **Motion** option with three-setting Off/On/Auto behavior in the M8 Reading Style section.
- See M8 above for the consolidated design.

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
   - Ask Posey: Apple Foundation Models integration (on-device, offline) — **in flight, M1–M4 DONE; M5 next** (see milestone tracker at top of file)
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
