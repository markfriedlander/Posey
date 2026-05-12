# App Store Connect — Submission Checklist

Use this when logging in at https://appstoreconnect.apple.com to create the Posey 1.0 listing. Every field below is pre-filled with the exact text to paste. The seven screenshots in this folder (`01-empty-library.png` through `07-ask-posey.png`) are sized for the 6.9" iPhone (1320×2868) — the only screenshot size Apple requires for a single-device listing.

## App Information

| Field | Value |
|---|---|
| App name | Posey |
| Subtitle | Your reading companion |
| Primary category | Books |
| Secondary category | Reference |
| Age rating | 4+ |
| Privacy nutrition label | Data Not Collected |
| Privacy policy URL | https://markfriedlander.github.io/Posey/privacy |
| Support URL | https://markfriedlander.github.io/Posey/support |
| Marketing URL | (leave blank) |
| Copyright | Mark Friedlander |

The GitHub Pages site is live and serving — both URLs return HTTP 200 as of 2026-05-12 (Pages enabled via API in commit `07772a0`).

## Pricing and Availability

| Field | Value |
|---|---|
| Price | Free |
| Availability | All territories |
| Pre-order | No |

## App Privacy

Select **Data Not Collected**. Posey does not collect, store, transmit, or share any personal data of any kind. All reading activity, notes, bookmarks, and Ask Posey conversations are stored exclusively on the device. There are no servers, no accounts, no analytics, and no advertising.

If Apple asks about Apple Intelligence specifically: Ask Posey uses Apple Intelligence (on-device + Private Cloud Compute). Posey itself collects no data; Apple's PCC is privacy-preserving by Apple's design. No data leaves the user's device under Posey's control.

## Description

Paste this as the App Store description:

```
Posey is a reading companion for iPhone. Import PDFs, EPUBs, Word files, Markdown, HTML, RTF, or plain text and read or listen in a clean, focused environment. Ask questions about what you're reading using Apple Intelligence. Everything stays on your device.

Tap to read. Tap to listen. Tap a passage to ask about it.

READ AND LISTEN TOGETHER
Posey highlights each sentence as it's read aloud, keeping your eyes and ears in sync. Commuting, walking, or too tired to hold a book — Posey reads with you. Choose Best Available for your device's highest-quality voice, or Custom to pick any voice and set your own reading speed.

ASK POSEY
Tap any passage and ask what it means, define a term in context, or find related passages in the document. Powered by Apple Intelligence — most requests run entirely on your device, and when they don't, Apple's Private Cloud Compute ensures your data is never stored or seen by anyone. Ask Posey works best with non-fiction: legal documents, academic papers, essays, and reference material.

SEVEN FORMATS, ONE EXPERIENCE
PDF, EPUB, DOCX, MD, HTML, RTF, TXT. Import from Files, iCloud, or any app that supports sharing. Posey extracts the text, preserves the structure, and opens everything in a consistent reading environment.

NOTES AND BOOKMARKS
Annotate any passage. Notes and bookmarks stay anchored to their position and appear in a unified view sorted by where they occur. Tap any annotation to return to the passage.

NO SUBSCRIPTION. NO ACCOUNT. NO DATA COLLECTION.
Posey is free. There are no servers, no analytics, no advertising, and no tracking of any kind.

She knows where everything is.
```

## Promotional Text

```
Read and listen to your documents. Ask questions using Apple Intelligence. Free, no subscription, no account required.
```

## Keywords

```
reading,epub,pdf,listen,tts,notes,document,ai,study,focus,ebook,reader,text,audiobook,annotate
```

## What's New (Version 1.0)

```
Welcome to Posey. Read and listen to documents in seven formats. Ask questions about what you're reading using Apple Intelligence. Take notes anchored to any passage. Free, no account required.
```

## Screenshots (6.9" iPhone — required)

Upload in this exact order. All seven files in `submission/`:

| # | File | What it shows |
|---|---|---|
| 1 | `01-empty-library.png` | Fresh-install empty state, Import File affordance |
| 2 | `02-populated-library.png` | Library with 4 real-titled documents |
| 3 | `03-reader-highlight.png` | Mid-document reading with active-sentence highlight |
| 4 | `04-reader-toc.png` | Table of Contents sheet with chapter list |
| 5 | `05-reader-notes.png` | Notes + bookmarks anchored to passages |
| 6 | `06-reader-preferences.png` | Reading style, voice mode, audio export |
| 7 | `07-ask-posey.png` | Ask Posey conversation with citation chips |

5.5" and 6.5" iPhone screenshots are not required when 6.9" assets are provided (per App Store Connect rules).

## Build Upload

1. Run a clean Release archive in Xcode (Product → Archive).
2. Validate the archive in the Organizer.
3. Upload to App Store Connect.
4. Wait for processing (5–15 minutes typically).
5. Select the processed build for the listing.

The archive symbol check from commit `4f670e8` confirms the antenna and all developer-test infrastructure are fully compiled out of Release builds (0 antenna verb literals, 0 PoseyAPI log strings, 0 LocalAPIServer symbols).

## Review Information

| Field | Value |
|---|---|
| Sign-in required | No (no accounts) |
| Demo account | N/A |
| Notes for reviewer | Posey is a local-only reading app. No backend, no accounts. Apple Intelligence is used for Ask Posey (on-device + Private Cloud Compute by Apple's design). All user content stays on device. Test by importing any supported file (PDF, EPUB, DOCX, MD, HTML, RTF, TXT) from Files. |
| Contact First name | Mark |
| Contact Last name | Friedlander |
| Contact email | markfriedlander@yahoo.com |
| Contact phone | (your number) |

## Version Release

Recommend: **Manually release this version** — gives you control over the public-launch moment after Apple approves the build.

## Pre-Submission Status

Code is at commit `ad95b0f` on `origin/main` as of 2026-05-12.

**Completed and verified autonomously (commit hashes):**
- Audio stop-block test: PLAYBACK_STOP_BLOCK_TEST PASS on iPhone (`6884c0c`)
- Audio export lock test: AUDIO_EXPORT_LOCK_TEST PASS both phases (`6884c0c`)
- Antenna fully compiled out of Release archive (`4f670e8`) — verified by symbol check
- Accessibility audit complete and re-verified on iPhone
- Indexing race UX fixed — "Still learning this document" message instead of canned refusal (`b6cd48e`)
- Image-stress fixtures in repo (`e52e396`)
- qa_battery final run: 12/12 PASS
- GitHub Pages live (`07772a0`): /privacy + /support both 200 OK
- README.md (`21b6631`)
- 7 App Store screenshots at 1320×2868 (`ad95b0f`)
- Image support deep-tested across DOCX, HTML, EPUB, PDF with both synthetic and real photographic JPEGs (`347cba8`)
- Keyboard composer fix verified on both hardware (`71cb22f`)
- Three Hats stress sweep (`949a504`)

**You verify before pressing submit:**
- TestFlight install + 5-minute smoke test (open a doc, read, listen, ask a question, take a note)
- Privacy/Support URLs render correctly in a real browser
- Build successfully uploads and processes in App Store Connect

That's it. Code is in a submittable state.
