# Posey Decisions

## 2026-05-01 — Commit to Full Accessibility Compliance

- Status: Accepted
- Decision: Posey will target full iOS accessibility compliance before App Store submission.
- Rationale: Posey's core loop — import a document, listen while text is highlighted, never lose your place — is genuinely valuable for people with visual impairments, dyslexia, and other reading difficulties. Building compliance in from the start rather than retrofitting it later is both easier and more honest. If this app can help someone who struggles to read, that matters.
- What this means in practice:
  - All custom controls have descriptive VoiceOver accessibility labels (play, pause, antenna, restart, etc.)
  - VoiceOver navigation order follows the natural reading and interaction flow
  - All touch targets meet Apple's 44×44pt minimum guideline
  - Dynamic Type is respected — font sizes scale with system accessibility settings
  - Reduce Motion system setting is respected — chrome fade and scroll animations suppressed when enabled
  - Sufficient color contrast maintained throughout (monochromatic palette already helps here)
- Alternatives considered:
  - Defer accessibility until after launch: rejected — retrofitting is harder and the people who need this most shouldn't have to wait

## 2026-05-01 — Why Centering The Active Sentence Is Non-Negotiable

- Status: Accepted (product principle)
- Decision: The active sentence is always centered in the visible reading area, regardless of font size, sentence length, screen orientation, or chrome state. Centering is treated as an inviolable acceptance criterion for any reader work — never a "nice to have," never something to compromise for layout convenience.
- Rationale: The eye learns a fixed position. Like the upper-left corner of a page, or a teleprompter line. When the active sentence is always in the same place, the eye stops hunting — it just looks. That repetition is what lets the reader sustain attention on difficult material without fatigue. If the position drifts even a little — top one moment, middle the next, slightly off-center after that — the eye has to actively track, and the reading flow breaks. So "always centered" is not aesthetics; it's a load-bearing piece of the reading experience.
- Implication: Any future reader work (custom layouts, slot-machine scroll mode, dim-surrounding mode, in-motion mode, font scaling, orientation handling, chrome restyling) must preserve the fixed-center invariant. If a feature would compromise it, the feature loses, not the centering.

## 2026-05-01 — Center Within The Persistent Reading Area, Not The Conservative Scroll Envelope

- Status: Accepted (supersedes the same-day decision below)
- Decision: Both top chrome and bottom transport are floating overlays. Only the search bar uses `safeAreaInset(.top)`, and only while it's active. The scroll content area thus equals the *persistent* perceived reading area — nav-bar bottom to home-indicator top — and `anchor: .center` lands the active sentence at the true visual center in both orientations and across all chrome states.
- Rationale: The previous fix (top chrome in `safeAreaInset(.top)`) made the scroll viewport equal `(viewport − chrome insets)`, which centered cleanly within the chrome-visible state. But that scroll envelope also excluded the home-indicator strip (claimed by the bottom safeAreaInset). In portrait the strip is ~3.5 % of screen height — invisible offset. In landscape the same strip is a much larger fraction of a much shorter screen, and the perceived center shifts visibly off. Mark caught it in landscape acceptance: "loses centering — gets disorienting." The right anchor is the always-visible reading area, defined by the chrome elements that *don't* fade (nav bar, home indicator). Chrome capsules briefly overlay the top/bottom edges when visible, but the active sentence is well clear of those edges in both orientations, so it stays fully visible.
- Tradeoff: Surrounding sentences (one or two above/below the highlight) get partially overlaid by chrome when chrome is briefly visible. Acceptable since chrome auto-fades within 3 seconds and the active sentence itself stays clear.
- Alternatives considered:
  - Keep `safeAreaInset(.top)` for chrome (the previous fix): rejected — works in portrait but fails in landscape because the bottom safeAreaInset's home-indicator claim is a much larger fraction of landscape's vertical extent.
  - Dynamic `contentMargins(_:_:for:)` that toggles with chrome visibility: rejected — changing scroll content area mid-scroll causes visible jumps as content reflows.
  - Custom UnitPoint anchor compensated per-orientation/per-chrome-state: rejected — too many variables, fragile to font size and screen size changes.

## 2026-05-01 — Top Chrome Claims Permanent Layout Space; Trade Reading Area For Centering Stability (Superseded)

- Status: **Superseded** by "Center Within The Persistent Reading Area" (2026-05-01) after landscape regression
- Decision: The top chrome controls (search/TOC/preferences/notes buttons) move from a floating `.overlay` to a top `.safeAreaInset` that always claims its content's vertical space. The chrome still fades visually via opacity, but its layout footprint is permanent — matching the bottom transport's existing pattern.
- Rationale at the time: The active sentence is always centered in the visible reading area, regardless of chrome state. With the floating overlay, `proxy.scrollTo(_, anchor: .center)` centered within a viewport that included the chrome's overlapped region — putting the highlight ~37–62 px above visual center depending on chrome visibility. The safeAreaInset approach made the scroll viewport equal the actual visible reading area when chrome was visible, so `.center` was genuinely centered.
- Why superseded: Worked in portrait, failed in landscape. The bottom safeAreaInset's claim included the home-indicator strip (invisible to user but counted as not-reading-area by the centering math). In portrait that strip is unnoticeable; in landscape the same strip is a much larger fraction of the screen and the visible-center shift was perceptible. Reverted to overlay-based chrome anchored on the always-visible reading area (nav bar + home indicator).

## 2026-04-30 — Cold Launch Reopens The Last-Read Document

- Status: Accepted
- Decision: At cold launch, Posey automatically reopens the document the user was last reading, restoring both the navigation state and the in-document reading position. The preference (`PlaybackPreferences.lastOpenedDocumentID`) is set whenever the user navigates into a reader and cleared whenever they back out to the library — so explicit "back to library" is honored as "I'm done with this one for now."
- Rationale: Per-document position memory was already correct, but losing the navigation state at every cold launch made it feel as if Posey forgot where the user was. This closes that gap without changing the underlying position-restore semantics. The product brief explicitly promises "come back later and resume exactly where you left off"; that should mean reopening to the same screen the user left, not just the same offset within a document they have to manually re-find.
- Alternatives considered:
  - Always reopen the last document, even after the user explicitly backs out: rejected — backing out is a clear "give me the library" signal and overriding it would feel pushy.
  - Only restore navigation when playback was active at last close: rejected — the user often pauses for a moment then closes the app; that shouldn't drop them back at the library.
  - Persist last-document at the database layer instead of UserDefaults: rejected — the preference is per-installation/per-user, not per-document, so UserDefaults alongside `voiceMode` and `fontSize` is the right home.

## 2026-04-30 — Reader Display Is A Continuous Stream; Page Numbers Are Metadata Only

- Status: Accepted
- Decision: The PDF reader display does not emit "Page N" headings or any other page-boundary chrome. Page boundaries continue to be preserved as metadata (form-feed separators in `displayText` and per-block `startOffset` values), but they never appear as visible elements that interrupt the reading flow. Chapter and section headings from structured documents (Markdown H1–H6, EPUB nav) are still preserved because they aid orientation and come from the source document, not from Posey's pagination.
- Rationale: The reader is a quiet, continuous reading environment. Page numbers belong in document metadata for any future feature that needs them, not in the reading flow that the user is trying to focus on.
- Alternatives considered:
  - Keep page headings but make them visually subtle: rejected — even a subtle heading is a chrome interruption every time the eye reaches a page break, and it has no purpose for a reflowable reader where the page boundary is an artifact of the source layout.
  - Drop page boundaries from `displayText` entirely: rejected — losing the metadata would foreclose future features (e.g., "jump to page 47", "show page number in chrome on demand") for no gain.

## 2026-04-30 — iOS Simulator Approved As A Verification Tool, Not A Deployment Target

- Status: Accepted
- Decision: The connected iPhone is the default for all deployment, TTS verification, and final acceptance testing. The iOS Simulator is approved for accessibility tree inspection, screenshot verification, and UI automation work — the things the device cannot easily provide to Claude Code. Anything verified only in the simulator is not yet verified for Mark, and TTS quality must always be judged on device.
- Rationale: The previous policy (simulator is a last resort) was correct for *deployment* but cut Claude Code off from cheap structural verification. The accessibility tree gives precise element coordinates and state at a fraction of the token cost of screenshots, and UI automation needs an addressable surface the device doesn't expose to Claude. Treating the simulator as a verification tool — not as a substitute for the device — captures both benefits without lowering the acceptance bar.
- Alternatives considered:
  - Keep simulator as last resort only: rejected — Claude Code loses the cheapest tool for structural UI verification and is forced to ask Mark for visual confirmation on questions Mark shouldn't have to answer.
  - Switch to simulator-as-primary: rejected — TTS quality, real-world performance, and the user's actual reading environment can only be evaluated on the device.

## 2026-03-22 — Establish Documentation As Source Of Truth

- Status: Accepted
- Decision: Use the six root documents in the repository root as the control layer for scope, architecture, decisions, progress, and next steps.
- Rationale: The project is at day zero, and the main current risk is scope drift rather than technical debt. A visible control layer gives future implementation passes a stable reference point.
- Alternatives considered:
  - Rely on chat context only: rejected because it is fragile and easy to lose.
  - Use only inline code comments and commit history: rejected because product intent and scope boundaries would remain too implicit.

## 2026-03-22 — Build Version 1 In LEGO Blocks Starting With TXT

- Status: Accepted
- Decision: Follow the product brief block order and start implementation with a working `TXT` ingestion and reader pipeline before touching `MD`, `EPUB`, or `PDF`.
- Rationale: The highest-value path is proving the reading loop quickly with the lowest parsing complexity. `TXT` isolates core reader, playback, highlighting, and persistence behavior.
- Alternatives considered:
  - Implement all file types behind a generic importer first: rejected as premature.
  - Start with `PDF`: rejected because format complexity would obscure the core reading loop.

## 2026-03-22 — Use SQLite For Version 1 Persistence

- Status: Accepted
- Decision: Use SQLite with a small database manager and repositories for documents, reading positions, notes, and bookmarks.
- Rationale: The schema is simple, explicit, relational, and local-first. SQLite offers transparent debugging and lower conceptual overhead for offset-based text anchors than Core Data at this stage.
- Alternatives considered:
  - Core Data: viable, but rejected for Version 1 because it adds framework ceremony without solving a current problem.
  - Flat files or `UserDefaults`: rejected because notes, positions, and document metadata merit structured storage.

## 2026-03-22 — Use Sentence-Level TTS Synchronization For Initial Highlighting

- Status: Accepted
- Decision: Segment text into sentences and drive playback and highlighting from sentence indices plus character offsets.
- Rationale: Sentence-level sync is accurate enough for Version 1, simple to reason about, and easy to resume after pause or relaunch.
- Alternatives considered:
  - Word-level timing: rejected as unnecessary complexity.
  - Paragraph-only timing: rejected because it would feel too coarse for read-along use.

## 2026-03-22 — Store Extracted Plain Text In The Document Record

- Status: Accepted
- Decision: Persist normalized plain text for each imported document rather than reparsing the source file on every open.
- Rationale: This improves startup simplicity, supports reliable text-offset anchoring, and decouples reading flow from repeated file parsing.
- Alternatives considered:
  - Re-read the source file every time: rejected because it complicates resume behavior and later note anchoring.

## 2026-03-22 — Render Block 01 Reader As Sentence Rows

- Status: Accepted
- Decision: Render the `TXT` reader as a scrollable list of sentence segments instead of one large rich text surface.
- Rationale: This makes sentence highlighting, scroll targeting, and resume behavior straightforward with the minimum amount of custom text system work.
- Alternatives considered:
  - One attributed text surface: postponed because it would add complexity before the first loop was proven.
  - `TextEditor`: rejected because it is a worse fit for read-along highlighting.

## 2026-03-22 — Persist Imported TXT Contents Directly In SQLite

- Status: Accepted
- Decision: For Block 01, store normalized imported `TXT` contents directly in the document table rather than maintaining a separate copied file cache.
- Rationale: This keeps ingestion simple, makes the library self-contained, and supports reopen and resume behavior without additional file management.
- Alternatives considered:
  - Copy imported files into app storage and re-read later: rejected for Block 01 because it adds file lifecycle work without improving the first milestone.

## 2026-03-22 — Treat Matching TXT Re-Imports As Updates

- Status: Accepted
- Decision: If the user imports a `TXT` file whose file name, file type, and normalized text content already match an existing document, update that document instead of creating a duplicate entry.
- Rationale: This keeps the Block 01 library stable and avoids clutter during repeated manual testing.
- Alternatives considered:
  - Always create a new document on import: rejected because it adds noise without helping the single-reader Version 1 flow.

## 2026-03-22 — Restore Reader Position By Character Offset First

- Status: Accepted
- Decision: When reopening a document, resolve the initial sentence from the saved character offset first and use the saved sentence index only as a fallback.
- Rationale: The character offset is the stronger persistence anchor and makes resume behavior more robust if sentence boundaries shift slightly.
- Alternatives considered:
  - Restore only from sentence index: rejected because it is less resilient and throws away the more precise saved anchor.

## 2026-03-22 — Add Launch-Configured Test Hooks For Autonomous QA

- Status: Accepted
- Decision: Support test-mode launch arguments and environment configuration for database reset, custom database location, fixture preloading, and playback mode selection.
- Rationale: This makes the current app loop scriptable and repeatable without introducing user-facing product scope.
- Alternatives considered:
  - Depend on manual import flows in UI tests: rejected because file importer automation is brittle and environment-dependent.

## 2026-03-22 — Use Simulated Playback For Automated Reader Tests

- Status: Accepted
- Decision: Add a simulated playback mode to the existing playback service for deterministic automated validation while preserving `AVSpeechSynthesizer` for normal runtime behavior.
- Rationale: UI automation needs stable, observable sentence advancement without depending on real audio timing or simulator speech behavior.
- Alternatives considered:
  - Mock the entire reader stack in tests: rejected because it would validate less of the real app flow.
  - Drive UI tests with live speech synthesis only: rejected because it would be too environment-sensitive.

## 2026-03-25 — Start Notes With Sentence-Anchored Annotations

- Status: Accepted
- Decision: Implement the first note and bookmark flow by anchoring annotations to the current sentence row instead of building arbitrary text-range selection.
- Rationale: The reader already renders stable sentence segments with character offsets, so sentence-anchored annotations add useful note-taking with very little additional complexity or drift.
- Alternatives considered:
  - Delay all note work until a richer text-selection surface exists: rejected because the current architecture can support a minimal useful note flow now.
  - Build freeform text selection first: rejected because it would force broader reader refactoring before it is clearly needed.

## 2026-03-25 — Support Markdown With Dual Text Forms

- Status: Accepted
- Decision: For `MD` documents, preserve lightweight visual structure for reading while also storing a normalized plain-text form for playback, highlighting, notes, and persistence.
- Rationale: Markdown readers rely on headings, bullets, numbering, and spacing to stay oriented. Posey should preserve those cues on screen without letting Markdown syntax pollute TTS or offset-based reader logic.
- Alternatives considered:
  - Treat Markdown exactly like TXT: rejected because raw Markdown markers would degrade the reading experience.
  - Build a full rich Markdown renderer first: rejected because it adds too much complexity for the next incremental format step.

## 2026-03-25 — Use Direct Device Smoke As The Primary Hardware Validation Path

- Status: Accepted
- Decision: Treat the Malcome-style direct smoke harness as the primary real-device validation path for Posey, while keeping on-device unit tests and leaving Parker optional.
- Rationale: The smoke harness validates the real app on hardware without depending on fragile on-device automation mode, and it stays closer to the user's preferred workflow.
- Alternatives considered:
  - Depend on on-device XCUITest for every hardware validation pass: rejected for now because automation mode has not been reliable enough.

## 2026-03-25 — Add RTF, DOCX, And HTML To The Version 1 Roadmap

- Status: Accepted
- Decision: Add `RTF`, `DOCX`, and `HTML` to the planned Version 1 format roadmap, while leaving `.webarchive` as an optional later candidate rather than an active commitment.
- Rationale: These formats are common in real reading and writing workflows and materially improve Posey's usefulness for the user's actual document mix.
- Alternatives considered:
  - Keep the original four-format list only: rejected because it underrepresents the formats the app is expected to help with in practice.
  - Commit to `.webarchive` immediately as well: rejected because its value is less certain and it can stay roadmap-only until real usage proves it worthwhile.

## 2026-03-25 — Sequence Future Format Work From Smaller Parsers To Bigger Containers

- Status: Accepted
- Decision: After the current `TXT` + `MD` stabilization work, prefer adding formats in this general order: `RTF`, `DOCX`, `HTML`, `EPUB`, `PDF`, with `.webarchive` only if justified later.
- Rationale: This keeps momentum high by adding the smallest practical parsing blocks before the more complex container and layout formats.
- Alternatives considered:
  - Jump directly to `PDF`: rejected because it is valuable but heavier and more likely to force reader changes early.
  - Implement all remaining formats together: rejected because it would create unnecessary drift and debugging surface area.

## 2026-03-25 — Add RTF With Native Text Extraction First

- Status: Accepted
- Decision: Implement `RTF` using native attributed-text document reading and store the extracted readable string directly in the existing document model.
- Rationale: `RTF` is a common authored text format and can be added with very little architectural change, making it the cleanest next step after `MD`.
- Alternatives considered:
  - Skip `RTF` and jump to `DOCX`: rejected because `RTF` is the smaller, lower-risk validation step for this importer style.
  - Preserve full rich-text styling in the reader immediately: rejected because stable readable text matters more than styling fidelity right now.

## 2026-03-25 — Add DOCX With A Small Native Zip/XML Extractor

- Status: Accepted
- Decision: Implement `DOCX` by reading the `.docx` zip container directly, extracting `word/document.xml`, and converting paragraph text into the existing document model without adding a third-party package.
- Rationale: Native attributed-string loading did not reliably decode `DOCX` on iPhone hardware, while a small explicit extractor keeps the scope honest, offline, and easy to validate against real files.
- Alternatives considered:
  - Keep relying on `NSAttributedString` auto-detection: rejected because real-device tests showed it was not a trustworthy DOCX path.
  - Add a zip/document package immediately: rejected because the current need is narrow and the smaller native path is sufficient.

## 2026-03-25 — Put Safari Share-Sheet Import On The Later Roadmap

- Status: Accepted
- Decision: Record Safari and share-sheet import as a future ingestion feature to be considered after the local file-format blocks are stable, most likely through a Share Extension.
- Rationale: Sending an article directly from Safari would materially improve real-world usefulness, but app-extension work is a separate complexity layer and should not interrupt the current local-format implementation path.
- Alternatives considered:
  - Ignore the workflow until after Version 1: rejected because it is valuable enough to keep visible on the roadmap.
  - Start the Share Extension now: rejected because it would jump ahead of the current format blocks and broaden scope too early.

## 2026-03-25 — Preserve Non-Text Elements In Richer Formats And Pause At Them By Default

- Status: Accepted
- Decision: For richer formats such as `HTML`, `DOCX`, `EPUB`, and `PDF`, preserve non-text elements visually when the source exposes them reasonably, keep them inline in reading order, and pause playback at them by default until the reader chooses to continue.
- Rationale: Serious reading often depends on figures, tables, and charts. Posey should not strip those out of the reading experience, and autoplay should not rush the reader past them.
- Alternatives considered:
  - Ignore non-text elements and keep extracting text only: rejected because it would break comprehension for many real documents.
  - Attempt to narrate those elements immediately: rejected because preserving them visually matters more than reading them aloud perfectly right now.

## 2026-03-25 — Opening Notes Should Pause Playback And Seed Context Automatically

- Status: Accepted
- Decision: Opening Notes should pause playback by default, seed note capture from explicit selection when available, and otherwise capture the active highlighted reading context with a short lookback window so the reader does not have to race the moving text.
- Rationale: Note-taking should support concentration, not compete with the read-along flow. Automatic context capture makes the notes affordance usable under real reading conditions.
- Alternatives considered:
  - Require the reader to pause manually and copy text manually first: rejected because it adds friction at exactly the wrong moment.
  - Keep playback running while Notes opens by default: rejected because it forces the reader to chase moving text.

## 2026-03-25 — Keep Playback Controls And In-Motion Mode On The Near Roadmap

- Status: Accepted
- Decision: Keep adjustable speech rate and basic voice selection on the near roadmap, and treat a future "in motion mode" as a user-facing setting group for walking or driving with different interruption and presentation behavior such as not pausing at visual elements and enlarging key UI affordances.
- Rationale: Real listening utility depends on playback comfort, and the pause behavior that helps deep reading is not always right when the user is moving.
- Alternatives considered:
- Leave speech behavior fixed and revisit later: rejected because users will vary widely in preferred speed and voice.
- Hide motion-specific behavior in scattered toggles: rejected because it is better framed as an intentional mode later on.

## 2026-03-25 — Split Reader Controls Into Primary Chrome And A Preferences Sheet

- Status: Accepted
- Decision: Keep the primary reader chrome limited to previous, play or pause, next, restart, and Notes, and move font size plus speech rate into a separate preferences sheet that can be opened when needed.
- Rationale: The reader needs fast transport controls without letting chrome dominate the screen. A split control model keeps the reading surface calmer on phone-sized displays while still surfacing the settings that materially affect comfort.
- Alternatives considered:
  - Keep font size and future playback settings in the always-visible primary bar: rejected because it steals space from the document and makes the reading surface feel heavier.
  - Hide all controls behind a single modal panel: rejected because transport controls are used too often and need faster access.

## 2026-03-25 — Keep Reader Chrome Glyph-First And Make Restart A True Rewind

- Status: Accepted
- Decision: Keep the primary reader chrome glyph-first, visually restrained, and mostly monochrome, and make restart rewind to the beginning without autoplaying again.
- Rationale: The reading surface should stay visually calm and text-first on a phone-sized screen. Restart is better treated as a deliberate repositioning action than as an immediate playback command.
- Alternatives considered:
  - Use text labels in the primary chrome: rejected because they compress poorly on smaller screens and compete with the document.
  - Make restart immediately autoplay again: rejected because it makes it too easy to lose the top of the document before the reader is ready.

## 2026-03-25 — Add EPUB Through Readable Spine Extraction First

- Status: Accepted
- Decision: Implement `EPUB` by reading the zip container directly, resolving the package manifest and spine, and extracting readable XHTML chapter text into the existing document model before attempting full rich-content block preservation.
- Rationale: `EPUB` is valuable and common, but a readable spine-text pass gets Posey to a useful offline reading loop quickly without forcing a large renderer expansion ahead of `PDF`.
- Alternatives considered:
  - Add a third-party EPUB package immediately: rejected for now because the current goal is a small, testable first pass.
  - Delay EPUB until a full mixed-content renderer exists: rejected because readable text-first support is still useful and keeps progress moving.

## 2026-03-25 — Add PDF Through Text Extraction First And Keep OCR Explicitly Later

- Status: Accepted
- Decision: Implement `PDF` first through native `PDFKit` text extraction, support text-based PDFs only in this slice, and reject scanned or image-only PDFs with an explicit unsupported-for-now error rather than silently importing empty content.
- Rationale: PDF is too important to delay, but OCR would substantially expand complexity, performance cost, and failure surface. A text-based first pass keeps Posey useful now while staying honest about what is not complete yet.
- Alternatives considered:
  - Treat first-pass PDF support as complete without OCR messaging: rejected because users may not know what kind of PDF they have and silent mismatch would be painful.
  - Add OCR in the first PDF slice: rejected because it is a materially larger offline feature and deserves its own pass.

## 2026-03-25 — Favor Stable Spoken Content Voice Over In-App Voice And Speed Controls

- Status: **Superseded** by "Voice Mode Split: Best Available vs Custom" (2026-03-25)
- Decision: Restore Apple Spoken Content or assistive voice behavior for default playback and remove both in-app speech-rate and in-app voice-selection controls for now.
- Rationale at the time: Real-device testing showed that forcing Posey-owned speech controls caused regressions in both voice quality and control reliability.
- Why superseded: Further empirical research clarified the exact mechanism — `prefersAssistiveTechnologySettings = true` is what delivers Siri-tier voice quality, and removing the flag is what caused the regression. With that understood, it became possible to build a two-mode architecture that preserves the Siri-tier default while offering an explicit opt-in to controllable voices without deceiving the user about the quality tradeoff.

## 2026-03-25 — Voice Mode Split: Best Available vs Custom

- Status: Accepted
- Decision: Replace "Spoken Content only, no controls" with two explicit modes the user chooses between: Best Available (Siri-tier voice, no in-app rate control) and Custom (user-selected voice from `speechVoices()`, in-app rate slider 75–150%).
- Rationale: Empirical hardware testing established that `prefersAssistiveTechnologySettings = true` is the mechanism delivering Siri-tier voice quality — a quality tier not accessible through `AVSpeechSynthesisVoice.speechVoices()` at all. Hiding this behind a single system-controlled path denies users real control. Surfacing the tradeoff explicitly — Siri quality with no in-app rate control vs. lower-quality voice with full control — is more honest and more useful.
- Key empirical findings:
  - `prefersAssistiveTechnologySettings = true` accesses voices not returned by `speechVoices()`. The flag cannot be removed without an audible quality regression.
  - `utterance.rate` set explicitly overrides the Spoken Content rate slider. Best Available mode must not set `utterance.rate` so the system slider remains functional.
  - Custom voice quality degrades above roughly 125–150% speed. Rate slider capped at 150%.
- Alternatives considered:
  - Keep system-only path: rejected because it denies users rate control entirely and offers no path to improvement.
  - Force one mode for all users: rejected because the quality/control tradeoff is genuinely subjective — dense non-fiction benefits from lower speed and maximum quality; familiar or lighter material may be fine at higher speed with a slightly different voice.

## 2026-03-25 — Use 50-Segment Sliding Window For Utterance Queue

- Status: Accepted
- Decision: Pre-enqueue a window of 50 utterances at playback start, then extend by one as each utterance finishes rather than pre-enqueuing the entire remaining document.
- Rationale: Long documents could queue thousands of utterances. The sliding window bounds memory use while keeping the queue deep enough that the synthesizer never starves. On mode or rate change, only the window needs to be rebuilt rather than the full document tail.
- Alternatives considered:
  - Pre-enqueue all remaining segments: rejected because memory use is unbounded for long documents and mode changes are expensive.
  - On-demand single-utterance enqueue: rejected because a queue depth of 1 risks audible gaps between sentences on slower hardware.

## 2026-03-26 — Store PDF Visual Page Images As BLOBs In SQLite

- Status: Accepted
- Decision: Store rendered PDF page images as BLOBs in a `document_images` table in the existing SQLite database rather than as files on disk.
- Rationale: One file for the whole app — backup, iCloud sync, and migration are all handled by moving a single `.sqlite` file. No orphaned image files if a document is deleted. `ON DELETE CASCADE` guarantees cleanup automatically.
- Alternatives considered:
  - Files on disk in the app container: rejected because it creates a separate file lifecycle to manage, risk of orphaned files, and more complexity for backup/sync.

## 2026-03-26 — Use PNG At 2× Scale For Visual Page Images

- Status: Accepted
- Decision: Render visual PDF pages to PNG at 2× scale using `PDFPage.thumbnail(of:for:)`.
- Rationale: PNG is lossless — JPEG compression artifacts are unacceptable for detailed artwork like Escher prints, which is the primary use case this feature was designed around. 2× scale provides retina-quality fidelity on device. `PDFPage.thumbnail(of:for:)` is Apple's purpose-built, thread-safe page renderer; the earlier manual CGContext + `page.draw(with:to:)` path had threading ambiguity on device.
- Alternatives considered:
  - JPEG: rejected because compression artifacts on detailed illustrations would degrade the reading experience.
  - 1× scale: rejected because retina displays would render images soft.
  - Manual CGContext rendering: replaced by `thumbnail(of:for:)` after threading concerns on device.

## 2026-03-26 — Full-Screen Sheet With ZoomableImageView For Tap-To-Expand

- Status: Accepted
- Decision: Tapping an inline image opens a full-screen sheet with a `UIScrollView`-backed `ZoomableImageView` (pinch-to-zoom up to 6×, double-tap to zoom in/out).
- Rationale: Inline gesture zoom inside a ScrollView creates gesture recognizer conflicts. A full-screen sheet sidesteps all of that, gives the image the whole screen, and is the natural iOS pattern for image viewing.
- Alternatives considered:
  - Inline pinch-to-zoom within the reader scroll view: rejected due to gesture recognizer conflicts.
  - No zoom at all: rejected because detailed artwork (diagrams, Escher prints) needs to be inspectable.

## 2026-03-26 — Monochromatic Palette As Standing Standard

- Status: Accepted
- Decision: All Posey UI uses a monochromatic palette (blacks, whites, grays via `Color.primary` opacity tiers and `.tint(.primary)`). No accent colors, blues, or yellows unless there is a specific, deliberate product reason.
- Rationale: The reading environment should feel like a quiet, physical reading tool. Accent colors feel like app chrome competing with the text. `Color.primary.opacity(0.14)` for TTS highlight, `0.10`/`0.28` for search matches — these are subtle enough to guide the eye without pulling focus.
- Alternatives considered:
  - System accent color: replaced because it produced blue/yellow highlights that broke the calm reading surface.

## 2026-03-26 — Global Font Size Persistence Via PlaybackPreferences

- Status: Accepted
- Decision: Font size is a single global preference persisted in `UserDefaults` via `PlaybackPreferences.shared`, alongside voice mode. It is not per-document.
- Rationale: Font size is a reader comfort setting for the person, not the document. The same logic applies as for voice mode — you want the same comfortable size everywhere.
- Alternatives considered:
  - Per-document font size: rejected because the preference is about the reader's eyes, not the content.

## 2026-03-26 — Build A Local HTTP API For Direct CC Interaction With The Running App

- Status: Accepted
- Decision: Build a local HTTP API server inside Posey (NWListener, port 8765, bearer-token auth) so Claude Code can interact directly with the running app on device — importing documents, reading extracted text, querying the DB, and eventually conversing with Ask Posey.
- Rationale: Eliminates the human-relay loop for testing and tuning. CC can now run a full text-quality audit across 10 test files without Mark relaying a single screenshot. The same API will be the interface for tuning Ask Posey responses interactively. Pattern taken directly from Hal Universal where it proved out the architecture.
- Alternatives considered:
  - Mac-side script using PDFKit: adequate for text quality but can't test real device behavior, can't measure performance, and can't interact with the LLM.
  - File-polling harness (Hal's legacy fallback): works but adds latency per turn and can't handle binary import.

## 2026-03-26 — Store API Token In Keychain, Default Server Off

- Status: Accepted
- Decision: The API token is generated once, stored in the iOS Keychain, and persists across app launches. The server is off by default and must be explicitly enabled via the antenna toggle.
- Rationale: Security (token never hardcoded, never regenerated), trust (no port opens unless user enables it), and consistency with Hal's proven approach. Default-off matters for App Store review and user trust.
- Alternatives considered:
  - Hardcoded token: rejected — unacceptable security practice.
  - Regenerate token each launch: rejected — breaks the one-time setup workflow.

## 2026-03-25 — Expand V1 Scope To Include Ask Posey, In-Document Search, And OCR

- Status: Accepted
- Decision: Add Ask Posey (Apple Foundation Models, on-device), in-document search (three tiers starting with string match), and OCR for scanned PDFs (Apple Vision) to the V1 scope as deliberate additions.
- Rationale: All three use only Apple frameworks, work fully offline, and extend the core reading loop without adding network dependencies or third-party services. Ask Posey in particular is a meaningful reading-assistance feature that fits the product's purpose and is uniquely available now through on-device models. Keeping them out of scope would mean documenting them as explicit exclusions, which felt wrong given how naturally they fit.
- Scope boundaries held:
  - cloud sync: still out of scope
  - third-party AI services: still out of scope
  - export: still out of scope
  - share extension: still roadmap-only
