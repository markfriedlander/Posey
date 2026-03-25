# Posey Constitution

## Purpose

Posey is a lightweight personal reading companion for difficult documents.
Its job is to reduce friction in serious reading by combining local document reading, text-to-speech playback, read-along highlighting, notes, and reliable resume behavior.

Posey is not an audiobook marketplace, not an AI showcase, and not a broad document intelligence platform.

## Immutable Project Rules

1. Version 1 scope is fixed to local reading support for `TXT`, `MD`, `RTF`, `DOCX`, `HTML`, `EPUB`, and `PDF`, with implementation beginning from `TXT` only.
2. The first working milestone is end-to-end `TXT` support: load, read, play, highlight approximately by sentence, pause, resume, and reopen at the saved position.
3. The original document text must never be rewritten, summarized, paraphrased, or structurally altered for user-facing reading.
4. Reading flow takes priority over feature richness. If a choice improves capability but harms stability, simplicity, or focus, reject it.
5. The app must remain fully useful offline for all core Version 1 behavior.
6. Development must follow the LEGO block order:
   - Block 01: TXT reader + TTS
   - Block 02: Highlight sync
   - Block 03: Notes
   - Block 04: Markdown
   - Block 05: Lightweight rich text and document formats (`RTF`, `DOCX`, `HTML`) one at a time
   - Block 06: EPUB
   - Block 07: PDF
   - Block 08: Polish
7. Do not build future-format abstractions until the current block needs them.
8. Do not introduce third-party packages unless the current block cannot be completed reasonably without them.
9. Documentation is the source of truth. Code should follow the root documents, not drift from chat memory or speculative ideas.
10. Every meaningful design change must be recorded in `DECISIONS.md`, and every completed milestone must be reflected in `HISTORY.md` and `NEXT.md`.
11. Share-sheet import, Safari handoff, and any app-extension work are roadmap items only until the local file-ingestion blocks are stable.

## Explicit Non-Goals For Version 1

The following are out of scope unless the root documents are intentionally revised:

- AI summaries
- AI explanations
- glossary generation
- search
- cloud sync
- sharing
- export
- collaboration
- voice cloning
- OCR repair
- perfect word-level alignment
- advanced formatting reconstruction
- monetization systems
- share extensions or Safari-specific ingest during the active local-format blocks

## Engineering Principles

- Prefer direct, readable code over clever abstractions.
- Prefer native Apple frameworks before adding dependencies.
- Prefer deterministic local persistence over network-backed state.
- Make failure states obvious and recoverable.
- Optimize for quick manual testing on a real sample `TXT` file.
- Keep modules small and responsibilities clear enough for another engineer to inherit.

## Anti-Drift Rules

- If work does not directly support the current block or a documented prerequisite, defer it.
- If a new idea increases scope, record it outside the active plan rather than implementing it.
- If a format is valuable but not active yet, place it on the roadmap with an explicit sequence instead of beginning implementation immediately.
- If an abstraction exists only for future formats, remove or avoid it.
- If a feature complicates reading flow, it does not belong in Version 1.
- `NEXT.md` must always reflect the smallest sensible next slice of work.
