# CLAUDE.md — Posey
**Operational Reference for Claude Code**
**Last Updated: May 2026**

---

## Two Standing Rules — Read Before Anything Else

These two rules came out of a long, painful session on 2026-05-05 where I burned hours of Mark's time guessing at solutions and shipping commits that weren't actually verified. Both are non-negotiable. Both apply on every change, every session, every task.

### Rule 1 — Search Before You Fail Twice

If you don't know how to solve something, **search the web for the proven pattern before your second failed attempt**. Do not write a third guess. Do not iterate on your own intuition past the second attempt. The second failure is the signal that you don't know the answer; the response is to find it, not to keep guessing.

This applies to:
- SwiftUI / UIKit / iOS framework behavior you're not 100% certain on (scroll behavior, layout, gestures, lifecycle, observable propagation, etc.)
- Apple framework usage (AVFoundation, FoundationModels, NaturalLanguage, PDFKit, etc.)
- Common UX patterns other apps have already solved (chat scrolling, citation rendering, message lists, transitions)
- Any "I think this is how it works" hunch that turns out to be wrong once

The pattern that triggered this rule: I tried five different scroll-on-send fixes in a row (three-pass timing tweaks, character-count branches, anchor-y heuristics, force nil-then-reassign, inline trailing Color.clear spacers) before Mark made me web-search. The proven answer (`.contentMargins(.bottom, viewportHeight, for: .scrollContent)` paired with watching the latest user-message ID instead of `messages.count`) was documented in WWDC23 and every public SwiftUI chat tutorial. I should have found it after attempt #2.

The cost of one extra web search is seconds. The cost of three more wrong commits is the rest of Mark's evening.

### Rule 2 — Two Pieces of Hardware, Two Screenshots, Before You Commit

Do not commit any change that touches user-visible behavior until you have:

1. **Run the change on at least two pieces of hardware** — typically the connected iPhone AND the iOS Simulator (or Mac Catalyst when available). Don't ship a fix that only worked on one. Different runtimes hit different layout, timing, and lifecycle code paths; "works on the simulator" has never meant "works on the phone."
2. **Captured a screenshot from each piece of hardware** showing the change behaving correctly. Use the `SCREENSHOT` local-API verb on the phone (returns base64 PNG; decode and view it). Use the simulator MCP screenshot tool on the simulator. **You must look at both images** and confirm the behavior matches the spec before you stage the commit.
3. **Verified that the screenshot shows the behavior actually working**, not just that the app didn't crash. If the change is "user message scrolls to top on send," the screenshot must show the user message at the top with prior content scrolled off above. "I see a sheet" is not verification.

The specific anti-pattern this rule kills:
- Editing code, running `/ask` (data API), seeing JSON come back, assuming the UI rendered correctly, and committing.
- Verifying on simulator only because the simulator can run AFM today (it can't on this machine, but even if it could) and skipping the phone.
- Calling a fix "verified" because the build succeeded.

If the local API is missing a verb you need to drive the test (e.g., couldn't fire scroll-on-send via the API → couldn't screenshot the result), **add the verb first**, then test, then commit. Don't commit "I think this works" code because the test loop is inconvenient.

If a change genuinely doesn't touch user-visible behavior (pure refactor of internal types, comment-only changes, doc updates), Rule 2 doesn't apply — but be honest with yourself about what "user-visible" means. A change to a view model is user-visible. A change to a layout helper is user-visible. A change to a data structure that any view reads is user-visible.

### Rule 3 — Resize Screenshots Before Reading Them Into Context

**All screenshots must be resized to under 800px wide before being read into context.** Never read a full-resolution device or simulator screenshot directly — they are very large images and accumulating them in conversation context will exceed the API's image-dimension limit and crash the session.

Standing procedure: after any `SCREENSHOT` verb or simulator screenshot, immediately run `sips -Z 800 <file>.png` (in-place resize, preserves aspect ratio) before invoking the Read tool on it. This rule cost a previous CC instance an entire session — do not repeat it.

---

## Three Hats — Developer, QA, and User

Before declaring any feature or milestone done, you must wear three hats — not just one. This applies to every feature on this project, not just Ask Posey.

**Hat 1 — Developer:** Did it build? Do the tests pass? Is the architecture correct? Is the code clean?

**Hat 2 — QA:** Does it actually work? Did I try to break it? Did I test the edges, the error cases, the unexpected inputs? Did I verify it visually on device or simulator, not just in logs?

**Hat 3 — User:** Would I actually want to use this? Does it feel right? Is the answer good enough that I'd trust it? Is the interaction natural? Would a real person find this useful or would they be frustrated?

All three questions must be answered yes before the feature is done. A feature that compiles and passes tests but gives bad answers or feels awkward is not done. A feature that gives good answers but looks broken in the UI is not done. The bar is: would a real user be satisfied?

This is a standing requirement. It applies in every session, for every feature, regardless of whether Mark explicitly asks. It is not sufficient to be a good developer. You must also be a rigorous QA engineer and a demanding user — simultaneously, on every piece of work you ship.

**For Ask Posey specifically**, the three-hats requirement means:

Before declaring any Ask Posey milestone done, have genuine multi-turn conversations on at least three different documents using the `/ask` endpoint. Not smoke tests. Not plumbing verification. Real conversations the way a user would have them.

For each document:
- Ask questions that require finding specific facts — authors, dates, definitions
- Ask questions that require connecting information from different parts of the document
- Ask follow-up questions that reference previous answers
- Ask something not in the document — verify Posey says so honestly rather than hallucinating

Evaluate every answer against what the document actually contains. Wrong, vague, or incomplete answers when the information is available are failures. Find the root cause — RAG retrieval? Prompt construction? Context budget? Temperature? — and fix it before moving on.

Use the simulator MCP to verify the UI after each response. Formatting renders correctly. Sources appear and persist after navigation. Conversation layout is correct.

The standard: if Mark picked up the phone and asked the same question, would he get a genuinely useful, trustworthy answer presented in a UI that feels right? That is the bar.

### AFM Cooldown — Standing Test-Harness Requirement

Sequential `/ask` calls without pacing push Apple Foundation Models on the device into a `Code=-1 (null)` error state where every subsequent call fails until Posey is relaunched. **This is a testing infrastructure issue, not an app bug.** Real users naturally pause between questions; the test harness must imitate that pacing.

Standing requirement: when driving sequential `/ask` calls (any test that asks more than one question in a row), insert a **2.5s ± 500ms jittered cooldown** before each `/ask`. Treat AFM exactly like any rate-limited third-party API.

Implementation:
- `tools/posey_test.py ask` automatically applies the cooldown unless `POSEY_TEST_NO_COOLDOWN=1`. Tunable via `POSEY_TEST_COOLDOWN_SECONDS` and `POSEY_TEST_COOLDOWN_JITTER`.
- `tools/qa_battery.sh` is the canonical Three Hats QA driver — runs the standard 4-question pattern across three documents with cooldown built in. Use it (or follow its pattern) for any future Q&A regression sweep.
- Ad-hoc one-shot tests (single `/ask`, no follow-up) can disable cooldown via `POSEY_TEST_NO_COOLDOWN=1`. Only do this when you're certain there's no sequential pressure.

Do not "fix" this by adding rate-limiting to the app itself. The app is correct; the harness is the place to add politeness.

---

## Read This First

You are not just a code-writing tool on this project. You are a collaborator.

Read this file at the start of every session. Together with the other root 
documents — ARCHITECTURE.md, CONSTITUTION.md, DECISIONS.md, HISTORY.md, 
NEXT.md, REQUIREMENTS.md, and TESTING.md — this is your complete orientation.

When you see something we've missed, say so. When you disagree with an 
approach, say so. When you have a better idea, bring it. We want your honest 
read and independent judgment, not polite confirmation.

---

## What Posey Is

Posey is a personal reading companion for serious documents — named after 
Parker Posey's character in Party Girl.

The core value proposition: take any document, make it reflowable and 
readable, add high-quality text-to-speech with synchronized read-along 
highlighting, and make it easy to keep notes anchored to the source material. 
The goal is to help one person read deeply, listen while commuting or walking, 
stay focused on difficult material, and never lose their place.

Posey is not an audiobook marketplace, not an AI showcase, and not a document 
intelligence platform. It is a focused reading tool.

**Supported formats for Version 1:**
- TXT, MD, RTF, DOCX, HTML, EPUB, PDF

**Core loop (the thing everything else serves):**
1. Import a document
2. Read it in a clean, distraction-free reader
3. Listen with synchronized highlighting
4. Take notes anchored to the text
5. Come back later and resume exactly where you left off

---

## The Three-Party Collaboration

This project has three active participants:

**Mark Friedlander** — creator, product owner, final decision maker on all 
product and direction questions. Deep domain knowledge about what good reading 
tools feel like from a user perspective.

**Claude (Anthropic, claude.ai)** — strategic and architectural collaborator. 
Has full context on the project history, product decisions, and design 
rationale. Acts as the connective tissue between sessions and the primary 
advisor on architecture and product direction. Mark and Claude typically make 
design and architectural decisions together.

**You (Claude Code)** — hands-on technical implementation partner. You write 
the code. You also have a genuine voice in design and architecture — use it. 
Your perspective on the codebase, the implementation choices, and the product 
is valued and actively solicited. Don't just follow instructions; push back 
when you have strong opinions, especially on technical approach.

**The rhythm that works:**
- Mark brings questions and direction
- Claude (claude.ai) and Mark discuss architecture and design
- You implement, and flag anything that looks wrong or could be better
- You commit to GitHub so Claude (claude.ai) can stay current via file fetches
- Nobody works in the dark — keep the other parties informed

**On disagreement:** Say so directly. Mark has final say. Your judgment will 
be considered seriously. Silent compliance is not what we want.

---

## Codex Context

A significant portion of the existing code was written by OpenAI Codex in an 
earlier session. Codex is a capable tool but thinks narrowly and tends toward 
conservative, constrained implementations. You may have opinions about what 
was written — that's fine and expected.

**Rules for engaging with existing Codex code:**
- Read before rewriting. Understand what it does before changing it.
- Don't reinvent working code without a clear reason.
- If you think something should be redesigned, say so and explain why before 
  touching it.
- Large moves need discussion. Small improvements can proceed with a note.
- Codex may still contribute to this project when needed. Don't assume you own 
  everything exclusively. Keep changes documented so any contributor can orient 
  quickly.

---

## Current State Of The Project

The app runs on a real iPhone. That's the baseline.

What has been validated on hardware:
- TXT import, read, play, highlight, pause, resume, restore position
- MD import with preserved display structure
- RTF import via native text extraction
- DOCX import via zip/XML paragraph extraction
- HTML import via native text extraction
- EPUB import via container/spine extraction
- PDF import (text-based only) via PDFKit

**Important caveat on format depth:** The breadth above is real but some 
formats are shallow. EPUB and PDF in particular have known gaps. Treat the 
current multi-format support as "first pass ingestion works" not "fully 
supported." Deeper format fidelity is a real next step.

**TTS voice and speed controls: Complete** (2026-03-25).
Two persisted modes (UserDefaults via `PlaybackPreferences`):
- **Best Available**: `prefersAssistiveTechnologySettings = true`, Siri-tier voice, system Spoken Content rate applies.
- **Custom**: user-selected voice from `AVSpeechSynthesisVoice.speechVoices()`, in-app rate slider 75–150%.

Mode and rate changes take effect at the next sentence boundary. Voice picker groups by language and quality tier. See HISTORY.md for full implementation history.

---

## Non-Text Elements — A Priority Feature

One of the most important product features not yet implemented is graceful 
handling of non-text content inline in documents.

The goal: when playback reaches an image, chart, table, or other non-text 
element that cannot be spoken, Posey should pause, present the visual element 
to the reader, and wait for the reader to manually continue. This keeps reading 
and listening in sync even when documents contain mixed content.

This is more important than LLM integration and should be treated as a 
near-term priority once the core format ingestion stabilizes.

Current partial implementation: visual-only PDF pages are preserved as stop 
blocks and pause playback. That pattern should eventually generalize to inline 
figures and tables in EPUB, DOCX, and HTML.

---

## Architecture Overview

Five layers:
- **App** — entry point, dependency wiring
- **Features** — SwiftUI screens (Library, Reader)
- **Domain** — plain models (Document, ReadingPosition, Note, TextSegment, 
  DisplayBlock)
- **Services** — importers, playback, sentence segmentation
- **Storage** — SQLite via DatabaseManager

Persistence: raw SQLite, no Core Data. Small schema, explicit, debuggable.

TTS: AVSpeechSynthesizer, sentence-level segmentation via NLTokenizer.

Reader: sentence-row model for Block 01. Each sentence is a row, making 
highlight targeting and auto-scroll straightforward.

See ARCHITECTURE.md for full detail.

---

## Hardware Testing

Build and test on Mark's connected iPhone (the real device). The device is
always available via `xcrun devicectl`. Note that `xcode-select` points at
`/Library/Developer/CommandLineTools` on this Mac, which has no device
support — every build/test/install/launch command must export
`DEVELOPER_DIR="/Applications/Xcode Release.app/Contents/Developer"`
(the Xcode bundle is named "Xcode Release.app", not "Xcode.app").

Standard deploy sequence:

```
DEVELOPER_DIR="/Applications/Xcode Release.app/Contents/Developer" \
  xcodebuild -scheme Posey -destination 'id=<device-id>' \
  -derivedDataPath /tmp/PoseyDeviceDerived -quiet build

DEVELOPER_DIR="/Applications/Xcode Release.app/Contents/Developer" \
  xcrun devicectl device install app --device <device-id> \
  /tmp/PoseyDeviceDerived/Build/Products/Debug-iphoneos/Posey.app

DEVELOPER_DIR="/Applications/Xcode Release.app/Contents/Developer" \
  xcrun devicectl device process launch \
  --device <device-id> --terminate-existing \
  com.MarkFriedlander.Posey
```

Current device ID: `D24FB384-9C55-5D33-9B0D-DAEBFA6528D6` (iPhone 16 Plus,
"Marks Bigger Ass Fon 16"). Verify with `xcrun devicectl list devices` if
it ever changes.

**The connected iPhone is the default for all deployment, TTS verification,
and final acceptance testing.** Build, install, and exercise the app on
device for any change that touches playback, position memory, or anything
the user will feel in real reading.

**The iOS Simulator is approved as a verification tool — not as a
deployment target.** It is the right tool for:

- Inspecting the SwiftUI accessibility tree (structured element data,
  positions, labels, states) — the cheapest way to confirm what the UI
  is actually presenting.
- Capturing screenshots when the question is "what does this look like."
- Driving UI automation (taps, scrolls) that the device can't easily
  expose to Claude Code.

This is a deliberate exception. Device remains the acceptance standard:
anything verified only in the simulator is not yet verified for Mark.
Simulator findings should be confirmed on device before a task is
considered complete, and TTS quality must always be judged on device.

**Simulator MCP — installed 2026-04-30, global config.**

The `ios-simulator` MCP server is installed and registered globally in
`/Users/markfriedlander/.claude.json` — it's available in any Claude Code
session, not just Posey. Components installed:

- `idb-companion` (Facebook iOS Development Bridge) via Homebrew →
  `/opt/homebrew/Cellar/idb-companion/1.1.8`
- `fb-idb` Python client v1.1.7 via `pip3` — note: `main.py` patched
  for Python 3.14 (replaced removed `asyncio.get_event_loop()` with
  `asyncio.new_event_loop()`); without the patch, every idb command
  crashes. If `fb-idb` is reinstalled, re-apply the one-line patch in
  `/opt/homebrew/lib/python3.14/site-packages/idb/cli/main.py:353`.
- `node` via Homebrew (the MCP server runs through `npx`, which
  requires Node).
- `ios-simulator` MCP server via:
  ```
  "/Users/markfriedlander/Library/Application Support/Claude/claude-code/2.1.121/claude.app/Contents/MacOS/claude" \
    mcp add ios-simulator npx ios-simulator-mcp
  ```

A Claude Code session restart is required after installing the MCP for
the `mcp__ios_simulator__*` tools to become callable in-session. New MCP
tools do not hot-reload into a running session.

When the MCP is loaded:

- Prefer the **accessibility tree** over screenshots whenever the question
  is structural (which buttons exist, where, what state, what label).
  The tree returns precise element coordinates and state at a fraction of
  the token cost of an image.
- Use **screenshots** only when the question is genuinely visual ("does
  this look right at the device size", "is the highlight visible").
- The simulator is a verification tool — it does not replace the device
  for TTS quality, real-world performance, or final acceptance.

To remove later if ever needed:
```
"/Users/markfriedlander/Library/Application Support/Claude/claude-code/2.1.121/claude.app/Contents/MacOS/claude" \
  mcp remove ios-simulator
brew uninstall idb-companion
brew untap facebook/fb     # only if no other formulae use the tap
pip3 uninstall fb-idb
```

**Autonomous verification via the local API — standing practice:**

Before asking Mark to relay what the screen shows, use the available tools
to verify correctness yourself. The local API exposes everything needed to
exercise the running app on the connected iPhone (or simulator) without
Mark's eyes or hands.

**Data verbs** (no UI involvement)
- `GET_TEXT:<doc_id>`, `LIST_DOCUMENTS`, `LIST_CHUNKS`, `GET_DOCUMENT_METADATA`,
  `RAG_FIND`, `EMBED_QUERY` — inspect stored content + retrieval state.
- `RESET_ALL`, `DELETE_DOCUMENT:<id>`, `CLEAR_ASK_POSEY_CONVERSATION:<id>` —
  put the app in a known state.
- `/import` (POST) — push a file from disk to the device.
- `/ask` (POST) — run the full Ask Posey pipeline end-to-end including AFM,
  return JSON with `response`, `chunksInjected`, `intent`, token breakdown.
  **Note**: bypasses the open view model — does NOT fire the UI's
  `messages.count` onChange. Use `SUBMIT_ASK_POSEY` instead when you need
  to test scroll-on-send or thinking-indicator visibility.
- `LIST_REFUSED_CHUNKS`, `LIST_ENHANCED_CHUNKS`, `PHASE_B_STATUS` — Phase B
  RAG enhancement state.

**UI driving**
- `/open-ask-posey` (POST `{documentID, scope}`) — navigate to a doc and
  open the Ask Posey sheet. Idempotent; safe to call when the sheet is
  already open.
- `SUBMIT_ASK_POSEY:<text>` — drive the live `submit()` path on the open
  Ask Posey sheet's view model. This is what fires the messages.count
  onChange + scrollToLatestUserMessage + thinking indicator. Use this for
  any test that needs to exercise the UI submit flow rather than just the
  AFM call.
- `SCROLL_ASK_POSEY_TO_LATEST` — three-pass scroll to the bottom of the
  open conversation thread.
- `READER_GOTO:<doc-id>:<offset>`, `READER_DOUBLE_TAP:<doc-id>:<offset>`,
  `READER_TAP`, `READER_CHROME_STATE`, `READER_STATE` — drive the reader.
- Playback verbs (play/pause/next/prev/restart), preferences setters
  (voice mode, rate, font size, reading style, motion).
- `OPEN_NOTES_SHEET`, `DISMISS_SHEET`, `CREATE_BOOKMARK`, `CREATE_NOTE`.
- `TAP:<accessibility-id>`, `TYPE:<text>` — generic UI tap + text input
  via the RemoteTargetRegistry (every interactive element wired with
  `.remoteRegister(_:action:)` is tappable by id).
- `TAP_CITATION:<n>`, `TAP_ASKPOSEY_ANCHOR:<storage-id>`,
  `TAP_SAVED_ANNOTATION:<id>`, `SCROLL_NOTES:<id>` — intent-level
  dispatch for surfaces where SwiftUI's accessibility bridging is unreliable.
- `SEED_ASK_POSEY_FIXTURE:<doc-id>` — seed a fixture user/assistant turn
  pair (with a multi-citation pattern) into a doc's persisted Ask Posey
  conversation. For testing chip rendering on the simulator without AFM
  model assets.

**Inspection**
- `READ_TREE` — JSON dump of the live UIView/accessibility hierarchy across
  every active window + presented controller.
- `SCREENSHOT` — UIWindow snapshot of the active key window, returned as
  base64 PNG. Decode with Python and Read with the screenshot tool to
  inspect what's actually on screen. **This works on the connected iPhone**
  — not just the simulator.
- `LOGS:<limit>:<sinceEpochMs>`, `CLEAR_LOGS` — recent log lines from the
  in-app circular buffer (DEBUG only). `dbgLog(...)` calls append here.
  Diagnostic for debugging without Console.app/Xcode.

**The standing practice:**

1. Use `SCREENSHOT` to see what the user sees. Compare against expected.
2. Use `READ_TREE` to verify structural state (which sheet is presented,
   which buttons exist, what their labels say).
3. Use `LOGS` after a failed expectation to see what the app saw.
4. Use the appropriate UI-driving verb (`SUBMIT_ASK_POSEY`, `READER_GOTO`,
   etc.) to exercise the path under test, then `SCREENSHOT` again.
5. Only escalate to Mark for things that truly need eyes you don't have —
   subjective feel, motion smoothness, anything physically interactive.

**Anti-pattern (do not repeat):** Marking a fix "done" after editing the
code and running `/ask` to verify the data side, without ever rendering
the UI through the changed code path. The `/ask` JSON tells you what AFM
returned — it does NOT tell you what the user sees, what scrolled where,
whether the indicator appeared, or whether the chips rendered. Take the
screenshot.

---

## Test Tooling

A few Python scripts in `tools/` exist to keep the test loop fast:

- `tools/posey_test.py` — local-API test runner. Talks to the antenna
  server inside the running app. Configure once with
  `python3 tools/posey_test.py setup <ip> 8765 <token>`; the IP and
  token are printed to the device console when the antenna is enabled.
  As of 2026-05-01 the antenna defaults to ON during development —
  fresh installs auto-enable it, and DEBUG builds force it on at
  launch even if a previous session toggled it off. This default
  must flip back to OFF before App Store submission so end users opt
  in explicitly.
- `tools/generate_test_docs.py` — produces 47 synthetic edge-case
  documents (TXT, MD, HTML, RTF) covering soft hyphens, NBSP, ZWSP,
  BOM, spaced letters/digits, ligatures, mixed scripts, RTL, empty,
  one-char, long-no-punct, dot-leader TOCs, and more. Default output
  `~/.posey-corpus`. Each generator targets ONE artifact class so
  regressions can be located precisely.
- `tools/verify_synthetic_corpus.py` — drives Posey through the
  synthetic corpus end-to-end. RESET_ALL → import every doc → fetch
  plain + display text → run per-doc assertions → PASS/FAIL summary.
  Requires the antenna to be on. Two specs (empty, whitespace-only)
  are configured to expect rejection, and the verifier checks that
  the rejection happened.
- `tools/fetch_gutenberg.py` — downloads a curated 28-book sample
  from Project Gutenberg via the Gutendex API across nine categories
  (prose, nonfiction, poetry, drama, technical, illustrated, short
  stories, multilang, longform). Caches by default; `--refresh` to
  re-download. Writes `manifest.json` recording author, language,
  subjects, and source URL for each.
- `tools/verify_images.py` — pixel-comparison harness for verifying
  that PDF visual pages match macOS PDFKit reference renders.

All scripts are dependency-free (Python stdlib only) so they run on
any Python 3.10+. Output directories default to `~/.posey-*` so the
fixtures don't pollute the project tree.

## Engineering Principles

- Prefer direct, readable code over clever abstractions.
- Prefer native Apple frameworks before adding dependencies.
- Prefer deterministic local persistence over network-backed state.
- Make failure states obvious and recoverable.
- Keep modules small and responsibilities clear.
- No third-party packages unless something genuinely cannot be done without
  them.
- The app must work fully offline for all core behavior.

---

## Quality Standard

When evaluating text extraction, rendering, highlighting, or any feature that
touches document content, do not limit analysis to known issues or visible
artifacts. Actively look for edge cases, foreseeable failure modes, and quality
problems that real-world documents at scale would surface. Fix what you see.
Anticipate what you don't.

---

## Format Parity Is Standing Policy

When a quality fix lands in one document format, ask immediately whether it
applies to the others. The default answer is **yes — apply it everywhere it
fits**. This is not a nice-to-have. The same reading experience must work the
same way regardless of whether the source was TXT, MD, RTF, DOCX, HTML, EPUB,
or PDF.

Examples of fixes that **must** apply uniformly across all supported formats:

- Normalization (soft hyphens, NBSP, ZWSP, BOM, tabs, line-break hyphens, dot
  leaders, spaced letters/digits, ¬ markers, etc.) — the shared
  `TextNormalizer` is the canonical surface; new passes go there and every
  importer delegates to it.
- TOC detection / skip-on-playback / TOC navigation surface — once we know
  how to handle TOCs in one format, the others should use the same plumbing
  (`document_toc` table, `playback_skip_until_offset` column, ReaderViewModel
  filtering).
- Inline images, visual stops, mixed-content page handling.
- Reader UX (centering, search, notes anchoring, auto-restore, position
  persistence) — these are format-agnostic by construction; new affordances
  must remain so.

**When a fix can't apply uniformly**, document the reason explicitly in
DECISIONS.md or NEXT.md. "I only had time for PDF" is not a reason; "EPUB
TOCs aren't typically dot-leader-based, so the PDF detector's heuristic
needs an EPUB-specific variant" is. The principle is: every format gets the
same care, or we know exactly why it doesn't.

Treat this as a checklist the moment a fix lands:

1. Which formats have an equivalent surface this fix could apply to?
2. Does the same fix work as-is, with refactoring, or with a format-specific
   variant?
3. If it doesn't apply yet, what's the followup task? Add it to NEXT.md.

This avoids the slow drift Posey has had to clean up before — fixes that
lived only in the PDF importer and quietly missed every other format until
the synthetic-corpus verifier caught them.

---

## The LEGO Block System

All Swift files use clearly bounded, numbered sections:
```swift
// ========== BLOCK [N]: [DESCRIPTION] - START ==========
[code]
// ========== BLOCK [N]: [DESCRIPTION] - END ==========
```

Maximum ~100 lines per block. Optimal 50-75. This enables surgical edits and 
prevents corruption in large files. Preserve this in all new files and when 
editing existing ones.

---

## How We Work Together

**Golden rules:**
1. Discussion before code — explain your plan, discuss, get approval, then
   implement. Small moves are an exception; large moves always need discussion.
2. Complete implementations only — no stubs, no placeholders.
3. No assumptions. Ever. If something is unclear, ask. Do not fill gaps with
   guesses and proceed. This applies to technical state, user intent, what the
   user has or hasn't done, and anything else that is not directly observable.
4. Read the relevant code before proposing changes to it.
5. Commit and push to GitHub. Every commit gets pushed to `origin/main`
   immediately — "commit and push" is one action, not two. Local-only commits
   are invisible to Claude (claude.ai), invisible to anyone else who picks up
   the repo, and one bad day away from being lost. There are no exceptions:
   if you committed it, you push it. If a push fails, fix the cause now and
   push before moving on.

**Starting a session:**
1. Read this file
2. Read the root docs — especially NEXT.md and HISTORY.md for current state
3. Ask Mark what we're working on, or share your own read of what needs 
   attention
4. If touching existing code, read it before proposing anything
5. Explain your plan before writing code
6. Wait for explicit go-ahead before implementing consequential changes

**After every meaningful commit:**
- Update HISTORY.md with what was done and why it matters
- Update DECISIONS.md with any architectural or product decisions made
- Update NEXT.md if the status of any planned item changed
- These updates are part of the commit, not optional housekeeping afterward
- A commit without corresponding doc updates is an incomplete commit
- **Push to `origin/main` immediately.** Commit and push are one action.
  Don't queue commits locally and "push later" — push every time.

**Ending a session:**
- Confirm HISTORY.md, DECISIONS.md, and NEXT.md are current before closing
- Commit and push to GitHub so the repo stays current

**On the docs:**
The root documents are the source of truth. If something in the docs conflicts 
with what the code does, the docs win and the code needs updating — or the 
docs need a deliberate revision. Do not let the code drift silently from the 
documented intent.

Some of the existing documentation reflects constraints from the previous 
Codex session that may be overly narrow. If something reads as a false 
constraint rather than a real one, flag it and we'll revise it together.

---

## What We Don't Want

- Wholesale rewrites when surgical changes would do
- Code written before direction is agreed on consequential changes
- Assumptions — about state, intent, what the user has done, or anything not
  directly observable. Ask instead.
- Partial implementations or stubs
- Silent compliance when you think something is wrong
- Scope creep into AI features, cloud sync, search, or export — those are 
  explicitly out of scope for Version 1

---

## A Note On What This Project Actually Is

Posey exists because serious reading is hard and most tools don't help. 
Difficult books, dense papers, technical documents — the kind of material that 
rewards slow careful attention but is easy to lose focus on, easy to abandon, 
easy to forget where you were.

The app should feel like a quiet, focused reading environment. Not a feature 
showcase. Not a productivity tool. A place where the document is the whole 
point and everything else gets out of the way.

Keep that in mind when making decisions. When there is a choice between 
something that adds capability and something that protects focus, protect focus.

---

**Status:** Living document. Update as the project evolves.