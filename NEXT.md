# Next

## Current Target

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
- **Milestone 7 — Navigation pattern + auto-save + source attribution + indexing indicator (UI):** `.search` intent → Generable navigation cards → existing TOC jump infrastructure; auto-save to notes; track which RAG chunks contributed to each response and render a "Sources" strip under the assistant message (pills tap-jump to the cited offset via the existing offset-jump infrastructure); first-time "Indexing this document…" → "Indexed N sections." indicator wired into the sheet (the index work itself ships in M2; this is the in-sheet UX surface for it). Both source attribution and indexing indicator are spec'd in `ask_posey_spec.md` (sections "Source Attribution" and the indexing-indicator paragraph under "The Ask Posey Sheet UI"). Persistence: chunk references stored on the assistant turn in `ask_posey_conversations` so attribution survives across sessions.

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

- **Antenna default flipped to OFF for release.** Today's default is `true` for development convenience; before App Store submission this MUST flip to `false` so users opt in explicitly. Tracked in `LibraryView` `@AppStorage("localAPIEnabled")`.
- **Dev tools invisible in release builds.** All development infrastructure — Local API server, antenna icon, dev toggles, test harnesses, AFM probe, hardcoded device IDs, test mode environment variables — must be **compiled out** of the release binary entirely, not merely defaulted off. Use `#if DEBUG` (or a separate build configuration) so a user picking up Posey from the App Store has no idea any of this exists. All code remains available in the codebase for development builds. Per `DECISIONS.md` "Dev Tools Invisible in Release Builds" (2026-05-01).
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
