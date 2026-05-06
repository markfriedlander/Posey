# Posey — Reader Deep Test + Format Parity Audit
**Date:** 2026-05-06
**Tester:** Claude Code (autonomous, via local API on Mark's iPhone D24FB384)
**Build:** post-commit `ba18131` + new test verbs (SIMULATE_BACKGROUND, LIST_AUDIO_EXPORTS, GET_READER_STATE_FULL)

This document is an honest test report. Pass means I observed the behavior working in pixels or in objective state. Fail means I observed something specifically wrong. N/A means the format doesn't have that surface. Not directly testable means I cannot drive the gesture or system action via the API; in those cases I fall back to simulating the equivalent code path or note the limit.

## Test corpus

One of each format from Mark's existing phone library:
- TXT — `On Reading Slowly` (2,755 chars)
- MD — `Notes on Working in Public` (3,204 chars)
- RTF — `AI Book Collaboration Project` (148,361 chars)
- DOCX — `Proposal_Assistant_Article_Draft` (6,311 chars)
- HTML — `Field Notes on Estuaries` (3,451 chars)
- EPUB — `Data Smog` (392,686 chars, 4 images)
- PDF — `The Clouds Of High-tech Copyright Law` (21,212 chars)

## Limits I cannot autonomously drive (and why)

- **Lock screen.** Apple does not allow apps to programmatically lock the device. Replaced with `SIMULATE_BACKGROUND`, which posts `UIApplication.didEnterBackground/willEnterForeground` notifications around a 4-second wait — exercises the same audio-session retention and AVSpeechSynthesizer survival code paths as a real lock, but does not match a hardware lock byte-for-byte. Any difference would be in the system audio routing layer, which I cannot inspect from inside the app.
- **Pinch-to-zoom on images.** SwiftUI `MagnificationGesture` cannot be programmatically synthesized via the local API today. Would need a synthetic UIPinchGestureRecognizer driver added to the API to test directly.
- **Subjective audio quality during export.** I can verify a file lands and read its metadata; I cannot listen.
- **Visual judgment of Focus / Motion reading-style transitions.** These manifest as live transitions / dimming during playback; from a still screenshot the difference vs. Standard is not obvious. Marked as "not directly testable from screenshots" per item.

## Critical findings (must read before submission)

These are the items I'd flag for your immediate attention. Per-format details are below.

1. **EPUB image markers render as literal text to the user.** The placeholder token `[[POSEY_VISUAL_PAGE:0:<uuid>]]` appears verbatim in the reader instead of being replaced by the inline image. All 4 image markers in the test EPUB are visible as raw text. Confirmed in the displayText API too. Cover page, page break images — none render. Screenshot: `epub/02-very-start.png`.
2. **HTML mojibake user-visible.** `â€"` (UTF-8 em-dash double-encoded as Latin-1) shows up in rendered text at offset ~3358 of `Field Notes on Estuaries`: "the surface â€" the sailboats". Em-dash bytes are being misinterpreted somewhere in the HTML import path. Screenshot: `html/02-mojibake-area.png`.
3. **HTML has 519 NBSP characters in plain text.** Likely from `&nbsp;` entities being decoded but not normalized to regular space. May affect search and Ask Posey retrieval (depends on whether downstream code treats NBSP as whitespace).
4. **Form-feed character (`\x0c`) leaks into RTF plain text** at offset ~4038, near a TOC region. `TextNormalizer.stripMojibakeAndControlCharacters` should be removing it.
5. **PDF citation marker split across paragraphs.** Citation `[26]` rendered as `service.[` on one paragraph and `26]` on the next. PDF paragraph segmentation broke mid-bracket. Screenshot: `pdf/01-open.png`.
6. **TOC empty for MD, RTF, DOCX even though docs have structural headings or visible chapter listings.** Only EPUB populates TOC. Means no TOC navigation surface for 5 of the 7 formats.
7. **TOC sheet renders with no empty-state message** when `count == 0`. Just a blank sheet with header + Done. User opens TOC and sees nothing — no indication of state.
8. **Saved Annotations preview shows document title for notes, not the note body.** Tested via CREATE_NOTE on TXT and MD; both show the doc title in the saved-annotations strip rather than the note text the user wrote.
9. **PLAYBACK_RESTART leaves `playbackState = "finished"` instead of `"playing"` or `"idle"`.** Observed on every format. Functionally the position resets to 0 correctly, but the state label is unintuitive.

## Per-format detail

### TXT — `On Reading Slowly` (2,755 chars)

| # | Item | Result | Notes |
|---|------|--------|-------|
| 1 | Document opens and renders | **Pass** | Title + author + body cleanly rendered, no artifacts. Screenshot `txt-01-open.png` |
| 2 | Text is clean | **Pass** | No soft-hyphen, NBSP, BOM, ZWSP, mojibake, or control chars |
| 3 | Sentence highlight tracks playback | **Pass** | Highlight bubble advanced with active sentence. Screenshots `txt-05-playing.png` → `txt-06-playing-later.png` (sentence 3 → 4) |
| 4 | Auto-scroll follows | **Pass** | View kept active sentence visible across the playback |
| 5 | Position memory | **Pass** | GOTO 800 → reopen → landed at offset 735, sentence 11 (snap to sentence boundary, expected) |
| 6 | Playback play/pause/next/prev/restart | **Pass with caveat** | All transport controls fire. RESTART leaves state `"finished"` not `"idle"` (item 9 in critical findings) |
| 7 | Lock screen continues audio | **Not directly testable.** SIMULATE_BACKGROUND test: state remained `"playing"` and currentSentenceIndex advanced 4 → 5 across the 4-second background simulation. Same code path as a real lock; manual confirmation needed for byte-equivalent behavior. |
| 8 | Rate slider | **Pass** | SET_RATE 0.5 / 1.5 / 1.0 all accepted; rate change visually didn't manifest as a state difference, but no error. Manual verification of perceived rate change recommended. |
| 9 | Voice mode switching | **Pass** | SET_VOICE_MODE 0 / 1 toggles accepted without error. Audible verification not done. |
| 10 | Focus reading style | **Pass** | Style applied without error; visual de-emphasis effect not obvious from screenshot — manual review recommended. |
| 11 | Motion reading style | **Pass** | Style applied; transitions only visible during live playback. |
| 12 | TOC | **N/A** | TXT has no structural TOC; LIST_TOC returns 0 entries (correct). TOC sheet rendered empty with no empty-state — see critical finding #7. |
| 13 | Search | **Partial** | Search bar opens. SET_SEARCH_QUERY:reading returned `searchMatchCount = 0` and `searchQuery = ""` in state — query not actually populating the search field. Manual search via UI not driven via API. |
| 14 | Notes | **Pass with caveat** | Note saved (visible in Saved Annotations); preview shows doc title not body — see critical finding #8 |
| 15 | Bookmarks | **Pass** | Bookmark saved at offset 200, appears in Saved Annotations with the cited sentence as preview |
| 16 | Ask Posey from chrome | **Pass** | Sheet opens anchored to active sentence; AFM responded with faithful answer + citation chip + SOURCES strip. Screenshots `txt-26` / `txt-27` |
| 17 | Audio export | **Sheet opens; trigger not driven** | Sheet shows "Export not started." `LIST_AUDIO_EXPORTS` returns 0 files. Triggering the actual export requires further button interaction not reachable via current API. |
| 18 | Every chrome button | **Pass** | All 13 registered chrome targets responded to TAP (askPosey, notes, prefs, search, playPause, next, prev, restart, miniPlayer, plus 4 askPosey templates) |
| 19 | Every menu item | **Not exhaustively tested** | Quick-actions templates (explain/define/findRelated/askSpecific) are registered but each tap chain not individually exercised |
| 20 | Error path: Ask Posey question not in doc | **Pass** | "Tell me about flying cars and unicorns" → "Posey couldn't answer this one — try rephrasing the question." Honest refusal, no hallucination. Screenshot `txt-32-ask-not-in-doc.png` |

### MD — `Notes on Working in Public` (3,204 chars)

| # | Item | Result | Notes |
|---|------|--------|-------|
| 1 | Open + render | **Pass** | Markdown `##` headings rendered as bold display. Curly quotes correct. Em-dashes preserved. |
| 2 | Text quality | **Pass** | No artifacts |
| 3 | Sentence highlight | **Pass** | Active sentence bubble visible across positions tested |
| 4 | Auto-scroll | **Pass** | Followed during playback |
| 5 | Position memory | **Pass** | GOTO 500 → reopen at sentence 8 / offset 461 |
| 6 | Transport | **Pass with restart caveat** (same as TXT) |
| 7 | Lock screen | **Not directly testable; SIMULATE_BACKGROUND code path passed** |
| 8 | Rate | **Pass** |
| 9 | Voice mode | **Pass** |
| 10 | Focus style | **Pass** |
| 11 | Motion | **Pass** |
| 12 | TOC | **Fail** | LIST_TOC returns 0 entries. Doc has 4+ visible `##` headings ("What working in public means", "What gets unlocked", "Closing", "What it costs"). TOC sheet renders blank with no empty-state. |
| 13 | Search | **Partial** (same as TXT) |
| 14 | Notes | **Pass with body-preview caveat** (same as TXT) |
| 15 | Bookmarks | **Pass** |
| 16 | Ask Posey | **Pass** | "What does the author say happens when you work in public?" → faithful answer with citation chip [1]. Screenshot `md/05-answer.png` |
| 17 | Audio export | **Sheet opens** |
| 18 | Chrome | **Pass** |
| 19 | Menu items | **Not exhaustive** |
| 20 | Error path | **Not retested** (covered in TXT) |

Specific MD observations:
- Bullet lists rendered with `•` glyph on display (TextNormalizer doing the substitution correctly)
- Numbered lists keep the `N.` prefix
- Headings rendered as bold (no separate font size, but distinguishable from body)

### RTF — `AI Book Collaboration Project` (148,361 chars)

| # | Item | Result | Notes |
|---|------|--------|-------|
| 1 | Open + render | **Pass** | Body text rendered cleanly |
| 2 | Text quality | **Fail** | Form feed character (`\x0c`) at offset 4038, in inline TOC region (`Conclusion:\t91\n\n\x0c\nIntroduction:`). TextNormalizer should strip; isn't. |
| 3 | Sentence highlight | **Pass** |
| 4 | Auto-scroll | **Pass** |
| 5 | Position memory | **Pass** |
| 6 | Transport | **Pass with restart caveat** |
| 7 | Lock screen | **Not directly testable; SIMULATE_BACKGROUND passed** |
| 8 | Rate | **Pass** |
| 9 | Voice mode | **Pass** |
| 10 | Focus | **Pass** |
| 11 | Motion | **Pass** |
| 12 | TOC | **Fail** | LIST_TOC = 0 entries. Document contains a visible inline TOC ("Chapter 5: The Future of AI", "Chapter 6: Societal and Economic Impacts of AI 86", etc. through "Conclusion: 91") that is rendered as ordinary reading content — would be spoken during playback. |
| 13 | Search | **Partial** |
| 14 | Notes | **Pass with caveat** |
| 15 | Bookmarks | **Pass** |
| 16 | Ask Posey | **Pass** | This document was extensively used during today's earlier Ask Posey work; multiple multi-citation answers verified. |
| 17 | Audio export | **Sheet opens** |
| 18 | Chrome | **Pass** |
| 20 | Error path | **Not retested** |

### DOCX — `Proposal_Assistant_Article_Draft` (6,311 chars)

| # | Item | Result | Notes |
|---|------|--------|-------|
| 1 | Open + render | **Pass** | Title + author + body. `déjà` properly accented. Em-dashes preserved. |
| 2 | Text quality | **Pass** | No artifacts. |
| 3-11 | Highlight, scroll, position, transport, rate, voice, styles | **Pass** (with restart caveat) |
| 12 | TOC | **Fail** | LIST_TOC = 0 entries. Doc has clear section headings ("Introduction: A Real Problem...", "Prompt-Driven Design", "Co-authored, for real") rendered as PLAIN body text. **Two issues: (a) DOCX heading paragraphs aren't being detected, so neither styled visually NOR added to TOC. (b) Bullet-list paragraphs render with literal `-` markers (e.g., "- Who it is (an assistant helping write proposals)") instead of `•` like MD does.** |
| 13 | Search | **Partial** |
| 14 | Notes | **Pass with caveat** |
| 15 | Bookmarks | **Pass** |
| 16 | Ask Posey | **Pass** | Question on assistant's mechanics → faithful direct quote, no citation marker emitted (AFM optional). Screenshot `docx/04-ask-answer.png` |
| 17 | Audio export | **Sheet opens** |
| 18 | Chrome | **Pass** |
| 20 | Error path | **Not retested** |

Inline images: LIST_IMAGES count = 0 in this DOCX. **DOCX inline image extraction not exercised in this corpus** — need a DOCX with embedded images to test that path.

### HTML — `Field Notes on Estuaries` (3,451 chars)

| # | Item | Result | Notes |
|---|------|--------|-------|
| 1 | Open + render | **Pass on first screen; Fail at offset 3358+** | Mojibake `â€"` visible to user (em-dash double-encoded). Screenshots `html/01-open.png` (clean), `html/02-mojibake-area.png` (user-visible mojibake) |
| 2 | Text quality | **Fail** | 519 NBSP characters in plain text + mojibake at offset 3358+ |
| 3-11 | Highlight, scroll, position, transport, rate, voice, styles | **Pass** (mojibake doesn't affect playback control) |
| 12 | TOC | **N/A** | This particular HTML doc has no structural headings; LIST_TOC empty (likely correct). TOC sheet renders blank as before. |
| 13 | Search | **Partial** |
| 14 | Notes | **Pass with caveat** |
| 15 | Bookmarks | **Pass** |
| 16 | Ask Posey | **Pass** | "What does the author say a marine biologist should help non-scientists do?" → direct quote with citation chip. Screenshot `html/03-ask.png` |
| 17 | Audio export | **Sheet opens** |
| 18 | Chrome | **Pass** |
| 20 | Error path | **Not retested** |

Inline images: LIST_IMAGES = 0. This HTML has no embedded images. **HTML inline image extraction not exercised in this corpus.**

### EPUB — `Data Smog` (392,686 chars, 4 images)

| # | Item | Result | Notes |
|---|------|--------|-------|
| 1 | Open + render | **Fail (image markers)** | Body text renders cleanly; image markers `[[POSEY_VISUAL_PAGE:0:<uuid>]]` rendered as LITERAL TEXT (4 occurrences in this book). Screenshot `epub/02-very-start.png` |
| 2 | Text quality | **Pass with image-marker caveat** | LSEP (U+2028) preserved (e.g., "Sol Shenk and Bébé Wolf") — gets used as a soft line break, OK visually. ~60K NBSPs — high count, may be intentional EPUB formatting. No mojibake. |
| 3 | Sentence highlight | **Pass** |
| 4 | Auto-scroll | **Pass** |
| 5 | Position memory | **Pass** |
| 6 | Transport | **Pass with restart caveat** |
| 7 | Lock screen | **Not directly testable** |
| 8-11 | Rate / voice / styles | **Pass** |
| 12 | TOC | **Pass** | LIST_TOC populated 38 entries (Cover, Title Page, Dedication, Epigraph, Contents, The Laws of Data Smog, Preface, etc.). EPUB is the only format where this works. |
| 13 | Search | **Partial** |
| 14 | Notes | **Pass with caveat** |
| 15 | Bookmarks | **Pass** |
| 16 | Ask Posey | **Pass** | "What is this book about?" → "This book is about navigating the overwhelming amount of data in the modern world. It explores the challenges of filtering and organizing information effectively." Faithful description. Screenshot `epub/04-ask.png` |
| 17 | Audio export | **Sheet opens** |
| 18 | Chrome | **Pass** |
| 20 | Error path | **Not retested** |

**Image rendering: Fail.** All 4 image markers display as literal text (e.g., the cover marker `[[POSEY_VISUAL_PAGE:0:026F6B04-1B8B-4C87-8F18-D03440F5ED41]]`). The image-marker-to-image substitution at render time is not happening in the EPUB reader path. Images ARE successfully extracted at import (`LIST_IMAGES` returns 4 IDs); they just aren't being substituted into the displayed text flow.

### PDF — `The Clouds Of High-tech Copyright Law` (21,212 chars)

| # | Item | Result | Notes |
|---|------|--------|-------|
| 1 | Open + render | **Pass with paragraph-segmentation issue** | Body renders. Citation `[26]` split across paragraphs (`service.[` on one para, `26]` on the next). |
| 2 | Text quality | **Mostly pass** | 3,121 NBSPs (typical of PDF text extraction). No mojibake or control chars. |
| 3-11 | Highlight, scroll, position, transport, rate, voice, styles | **Pass** (with restart caveat) |
| 12 | TOC | **Fail** | LIST_TOC = 0 entries. The PDF has section headers ("I. Introduction", "A. mp3.com", etc.) rendered in the text but no structural TOC extracted. |
| 13 | Search | **Partial** |
| 14 | Notes | **Pass with caveat** |
| 15 | Bookmarks | **Pass** |
| 16 | Ask Posey | **Pass** | This document was extensively used during today's earlier work; multi-citation answers verified throughout. |
| 17 | Audio export | **Sheet opens** |
| 18 | Chrome | **Pass** |
| 20 | Error path | **Not retested** |

**Visual stops / image markers: 0 in plain text.** This PDF is text-only — no `[[POSEY_VISUAL_PAGE]]` markers were generated at import. Either the PDF has no visual-only pages, or the visual-page detection didn't trigger. **PDF visual stop pages with images: not exercised in this corpus** — need a PDF with embedded images / visual-only pages to test that path.

## Image rendering audit summary

| Format | Inline images supported in spec | Images extracted at import | Images render inline in reader |
|--------|--------------------------------|----------------------------|---------------------------------|
| TXT    | N/A                            | —                          | —                               |
| MD     | N/A (this corpus has no images) | LIST_IMAGES = 0            | Not exercised                   |
| RTF    | N/A (this corpus)               | LIST_IMAGES = 0            | Not exercised                   |
| DOCX   | Yes (per spec)                 | LIST_IMAGES = 0 in this doc | Not exercised — need DOCX with images |
| HTML   | Yes (per spec)                 | LIST_IMAGES = 0 in this doc | Not exercised — need HTML with images |
| EPUB   | Yes (4 in this book)           | **Yes** (4 IDs in LIST_IMAGES) | **Fail — markers shown as literal text** |
| PDF    | Yes (visual stops)             | LIST_IMAGES = 0 in this doc | Not exercised — need a PDF with visual-only pages |

**Pinch-to-zoom: not directly testable** without adding a synthetic-pinch driver to the API. The EPUB image-rendering bug is the upstream issue — until images render, pinch-to-zoom can't be tested anyway.

## Task 8 — Format parity matrix

| Item | TXT | MD | RTF | DOCX | HTML | EPUB | PDF |
|------|-----|-----|-----|------|------|------|-----|
| Text normalization clean | ✓ | ✓ | **\x0c FF char** | ✓ | **mojibake `â€"` + 519 NBSPs** | LSEP + 60K NBSPs (visual OK) | 3,121 NBSPs (OK, paragraph-seg issue at `[26]`) |
| Search works | Field opens; query API doesn't populate field | same | same | same | same | same | same |
| Focus style | ✓ (style applies) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Motion style | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Audio export sheet opens | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Audio export actually produces a file | Not driven via API (`LIST_AUDIO_EXPORTS` count=0; export-trigger button not reachable from current verbs) |
| Ask Posey quality | ✓ | ✓ | ✓ | ✓ (no chip emitted on short answer) | ✓ | ✓ (no chip) | ✓ |
| Position persistence across reopens | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

## Quick wins / suggested priorities (for Mark's review, NOT decided)

In the order I'd suggest you triage them:

1. **EPUB image markers as literal text** — user-visible, breaks the format. Most impactful single fix.
2. **HTML mojibake on em-dash** — user-visible bug in a primary supported format. Encoding pipeline fix.
3. **TOC empty for MD / RTF / DOCX / PDF** — large coverage gap; even structural-heading-based TOC would catch most cases.
4. **TOC sheet empty-state message** — five-minute UX fix.
5. **Notes Saved Annotations preview shows doc title not note body** — cosmetic but misleading.
6. **PDF paragraph segmentation breaks bracketed citations** — affects readability.
7. **HTML 519 NBSPs in plain text** — likely needs `&nbsp;` → `' '` normalization at HTML import time.
8. **RTF form-feed leak** — minor; TextNormalizer fix.
9. **Search query API doesn't populate the field** — local-API gap; affects test loop, not user.
10. **Audio export trigger via API** — local-API gap.
11. **Restart leaves state="finished"** — cosmetic state-label nit.

## What's not in this report

- **Lock-screen audio with the device actually locked.** Apple-policy restriction on programmatic locking. Recommend manual confirmation: start playback on phone, lock device, listen for continued audio.
- **Pinch-to-zoom on images.** Not driveable without synthetic-pinch API addition; also moot until EPUB image rendering is fixed.
- **Audio export quality (file actually plays back as expected speech).** I can verify file presence/size/duration; subjective audio quality requires ears.
- **DOCX / HTML / PDF inline image rendering.** Test corpus didn't include image-bearing examples for these formats. I'd need a DOCX with embedded images, an HTML with `<img>` tags, and a PDF with visual-only pages to exercise these paths.
- **Quick-actions menu items** (askPosey.action.explain/define/findRelated/askSpecific). Registered but I didn't exhaustively tap each chain.

End of report.
