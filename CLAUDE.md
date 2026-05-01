# CLAUDE.md — Posey
**Operational Reference for Claude Code**
**Last Updated: March 2026**

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
to verify correctness yourself:

- **Text content**: `GET_TEXT:<doc_id>` returns displayText. Check for
  visual page markers, correct structure, absence of artifacts.
- **Import results**: `LIST_DOCUMENTS` or `GET_TEXT` confirm what was
  stored — character count, title, file type, markers present.
- **Image storage**: Visual page markers in displayText (`[[POSEY_VISUAL_PAGE:N:uuid]]`)
  confirm the import path ran. The presence of a UUID (not just N) confirms
  `renderPageToPNG` succeeded and `saveImages` was called. If the marker
  has a UUID, the image is in `document_images`.
- **Rendering**: macOS has PDFKit too. To verify a PDF page renders
  correctly (not blank/white), render it locally using the same
  `PDFPage.thumbnail` call and inspect the output image.

Only escalate to Mark for things that genuinely require eyes on the
physical screen: subjective feel, motion behavior, layout at actual device
scale, accessibility, or anything that requires physically interacting with
the running app.

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
5. Commit to GitHub regularly so Claude (claude.ai) can stay in sync.

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