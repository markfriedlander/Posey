# Posey — App Store Metadata Draft

_For Mark to review and finalize before submission. Edit freely._

## App Name (30 char max)
**Posey: Reading Companion**

## Subtitle (30 char max)
**Read deeply. Listen anywhere.**

## Promotional Text (170 char max — appears above the description)
A quiet, focused reading companion for the documents that matter.
Reflowable layout, synced read-aloud, anchored notes. On-device.
No accounts. No tracking.

## Description

**Posey is a reading tool for documents that deserve real attention.**

Import a paper, a chapter, an article, a book — TXT, MD, RTF, DOCX,
HTML, EPUB, or PDF — and Posey turns it into a clean, reflowable
reading surface. Tap a sentence to start synchronised read-aloud
with on-device text-to-speech. Take notes anchored to the exact
sentence you were reading. Bookmark a passage. Ask follow-up
questions about what you just read.

When you come back to a document the next day, Posey opens at the
exact sentence you left off at. No "where was I?" Ever.

**Built for serious reading, not browsing.**

- Distraction-free reader. Controls fade when you're reading;
  tap to bring them back.
- Synchronised highlight tracks the spoken sentence in real time.
- Notes and bookmarks anchor to specific sentences so they
  survive re-imports and edits.
- Search inside the document. Jump to any page (PDF, EPUB).
- Export your annotations as Markdown — yours to keep, in any
  app that opens text.

**On-device. Private. No accounts.**

Posey runs entirely on your iPhone. No sign-in. No cloud sync. No
analytics. No third-party AI services. The optional "Ask Posey"
assistant uses Apple Intelligence (on-device Apple Foundation
Models) to answer questions about your documents — your text
never leaves your phone.

**Why Posey exists.**

Difficult books, dense papers, technical documents — the kind of
material that rewards slow careful attention but is easy to lose
focus on, easy to abandon, easy to forget where you were.
Posey is a quiet place to read that material at the pace it
deserves.

## What's New (4000 char max — for first release)

Welcome to Posey 1.0.

This first release includes:
- Seven document formats: TXT, Markdown, RTF, DOCX, HTML, EPUB, PDF.
- Reflowable reader with synchronised read-aloud.
- Two voice modes: Best Available (system Spoken Content) and
  Custom (in-app voice picker, adjustable rate).
- Notes and bookmarks anchored to sentences.
- Optional Ask Posey conversational assistant for the documents
  you've imported (requires Apple Intelligence-eligible device).
- Document position auto-restore on every open.
- In-document search.
- Audio export to M4A.
- Markdown export of all annotations + Ask Posey conversations
  per document.

## Keywords (100 char max — comma-separated, no spaces after commas)

reader,reading,book,pdf,epub,docx,read aloud,tts,notes,bookmark,
study,research,textbook,paper

(Mark — pick a final 100-char selection. Above is ~140 chars
unselected; you'll trim. iOS App Store keyword strategy: avoid
words already in the title/subtitle, prioritise high-volume
search terms users actually type.)

## Primary Category
**Productivity**

(Alternative: Books. Productivity is closer to Posey's actual
positioning — a tool for serious reading, not a bookstore — but
Books would put Posey alongside reading apps users browse for.
Productivity gets less reading-app-specific browse traffic but
positions Posey as a tool, not a book reader. Recommend
Productivity primary, Books secondary.)

## Secondary Category
**Books**

## Age Rating
**4+**

Justification: Posey is a reading-and-listening tool for
user-imported documents. The app itself contains no objectionable
content. Imported document content is the user's responsibility
and not subject to App Store age-rating guidelines.

## Support URL
TBD — Mark to provide.

## Marketing URL (optional)
TBD — Mark may skip.

## Privacy Policy URL (required)
**TBD — host the file at `submission/privacy-policy.md` at a
stable HTTPS URL.** GitHub Pages, a personal site, or even a
Notion public page would all work. Apple does NOT accept
file:// URLs or unstable Google Doc share links.

## Privacy Practices Questionnaire (App Store Connect)

Apple asks each app to declare what data it collects. Posey's
answers:

- **Does this app collect data from this app?** No.
  (No data is collected; everything stays on the user's device.)

This single answer drives the rest of the questionnaire to "no
data collected" responses.

Tracking question: **No, this app does not track users.**

## Screenshots (required for each iPhone size class)

Per CLAUDE.md / posey_task_sequence.md Task 14, screenshots
should cover key states:

1. **Empty library** — first-launch experience.
2. **Populated library** — 3-4 documents listed.
3. **Reader with active highlight** — sentence highlighted during
   playback.
4. **TOC sheet** — Table of Contents open with chapter list.
5. **Notes sheet** — Saved Annotations list with notes,
   bookmarks, conversations mixed.
6. **Preferences sheet** — Reading Style picker open.
7. **Ask Posey sheet (passage-scoped)** — anchor visible at
   top, response below.
8. **Ask Posey sheet (document-scoped)** — document title as
   anchor, conversation thread.
9. **Ask Posey navigation results** — search-intent response
   with tappable section cards.

iPhone sizes required by App Store Connect: 6.5" (iPhone 11 Pro
Max class), 6.7" (iPhone 14 Pro Max class), and the smaller
iPhone 8 Plus class if supported. iPad screenshots optional but
recommended.

Capture via simulator MCP per CLAUDE.md guidance OR via
SCREENSHOT API verb on a real device.

## Review Notes (private to Apple, not user-facing)

- Posey runs entirely on-device. No backend service.
- Apple Foundation Models / Apple Intelligence is the only
  third-party SDK and it's first-party Apple framework.
- TTS uses AVSpeechSynthesizer (first-party Apple framework).
- The local-network-API code path that exists in DEBUG builds
  for development is compiled out of release builds (verified
  via `nm` — no `LocalAPIServer` symbols in the release binary).
- No login. No accounts. No payment.
- Test account not needed.
