# Posey Constitution

## Purpose

Posey is a lightweight personal reading companion for difficult documents.
Its job is to reduce friction in serious reading by combining local document reading, text-to-speech playback, read-along highlighting, notes, and reliable resume behavior.

Posey is not an audiobook marketplace, not an AI showcase, and not a broad document intelligence platform. Ask Posey, the planned on-device AI reading assistance feature, is a deliberate and bounded exception that serves the reading flow directly rather than making AI the product. It is grounded in the source document, runs entirely on-device, and never requires a network connection.

## Immutable Project Rules

1. Version 1 scope is fixed to local reading support for `TXT`, `MD`, `RTF`, `DOCX`, `HTML`, `EPUB`, and `PDF`, with implementation beginning from `TXT` only.
2. The first working milestone is end-to-end `TXT` support: load, read, play, highlight approximately by sentence, pause, resume, and reopen at the saved position.
3. The original document text must never be modified, substituted, or silently replaced in the reading surface. AI-assisted content from Ask Posey is always presented in a separate, clearly labeled surface and is never displayed as if it were the source document.
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

- cloud sync
- sharing
- export
- collaboration
- voice cloning
- perfect word-level alignment
- advanced formatting reconstruction
- monetization systems
- share extensions or Safari-specific ingest during the active local-format blocks

## Deliberate Scope Revisions

The following items were previously listed as non-goals and have been intentionally removed from that list as of March 2026. Their inclusion in the project is now deliberate and documented here to make clear that these decisions were considered, not missed.

**Ask Posey — on-device AI reading assistance via Apple Foundation Models**

Ask Posey is a planned V1 feature. The authoritative product specification is `ask_posey_spec.md`; this section captures the constitutional commitments. The detailed architecture is in `ARCHITECTURE.md` "Ask Posey Architecture."

There is **one Ask Posey surface** with intelligent intent routing. Two entry points in v1 (a third deferred):

1. Passage-scoped — the user selects text or relies on the currently highlighted sentence, then chooses "Ask Posey" from the contextual menu. The selected passage plus 2–3 sentences of surrounding context becomes the anchor.
2. Document-scoped — a dedicated glyph far left of the bottom reader bar opens Ask Posey with the active sentence as anchor and the full document available via the embedding index.
3. Annotation-scoped — deferred to a later pass. Persistent conversations make this pattern less urgent than it appeared in earlier drafts.

All entry points use Apple Foundation Models for on-device, offline inference. Ask Posey is never a network feature. (Apple's Private Cloud Compute may be used for complex requests; this is end-to-end encrypted and Apple cannot read prompts or responses. The user-facing description is "private by design" rather than "100% on-device" because the latter is imprecise.)

The Ask Posey surface is a half-sheet: the document remains visible behind it so the reader always knows where they are. (The half-sheet vs. full-modal decision is a design risk to validate on device with real documents during implementation; if the half-sheet feels cramped during real reading, the fallback is a full modal sheet.) The active sentence or selection is quoted at the top of the sheet.

**Conversations are persisted per document** in a new SQLite table, `ask_posey_conversations`. Opening Ask Posey on a document later restores recent turns and exposes prior exchanges as a threaded chat history. Conversations never cross documents. Every exchange is auto-saved — passage-scoped exchanges are also surfaced as notes anchored to the invocation offset; document-scoped exchanges are surfaced as document-level notes. Notes use the existing edit/delete behavior; no special cases for AI-authored content.

Older turns are summarized via a rolling-summary tier (Hal MemoryStore pattern) so long-running conversations remain in budget without losing earlier context. Document content beyond the model's context window is selected via a multilingual semantic embedding index built at import time for every supported format (`NLLanguageRecognizer` for detection, `NLEmbedding.sentenceEmbedding(for: <lang>)` for the index, English fallback when a language has no shipped sentence-embedding model).

When AFM is unavailable on a device, the Ask Posey entry points are hidden entirely — no degraded experience, no error messages, no upsell.

**In-document search — planned in three tiers**

1. String match search — near term. Find bar behavior, jumps between matches, highlights in the sentence-row reader. The existing character offset model makes jump-to-match natural.
2. Notes-inclusive search — same effort as tier 1, wider scope. Search document text and note bodies together in one result set from SQLite.
3. Semantic search via Ask Posey — later. Natural language queries such as "find where the author talks about grief" even when the word does not appear. Natural extension of the AFM layer.

Only tier 1 is near-term implementation work. Tiers 2 and 3 are roadmap.

**OCR for scanned PDFs via Apple Vision framework**

OCR is a planned near-term feature. The current behavior — rejecting scanned or image-only PDFs with an explicit error — is the right first-pass behavior, but a large portion of serious reading material exists only as scanned documents. Apple's Vision framework provides `VNRecognizeTextRequest` which is on-device, requires no dependencies, and fits the native-frameworks-first principle. OCR extends the existing PDF import pipeline and does not require changes to the reader, playback, or persistence model.

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
