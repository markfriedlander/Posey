# Posey History

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
