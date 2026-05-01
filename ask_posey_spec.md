# Ask Posey — Feature Specification
**Status:** Planned V1 Feature  
**Last Updated:** 2026-05-01  
**Author:** Mark Friedlander + Claude

---

## What It Is

Ask Posey is an on-device AI reading assistant built on Apple Foundation Models (AFM). It lets the user ask questions about what they're reading, find sections by meaning rather than exact words, and get help understanding difficult material — all without leaving the reading flow and without any network requests to third-party services.

It is a proof of concept for now. The models will improve. The architecture should be built correctly so quality follows naturally as they do.

---

## Core Principles

**Privacy by design.** AFM runs on-device. Conversations are never sent to third-party servers. Apple's Private Cloud Compute may be used for complex requests — this is end-to-end encrypted and Apple cannot see the content. Describe this to users as "private by design" not "100% on-device" — the latter is imprecise.

**Document-scoped memory.** Ask Posey remembers everything you've asked about a document across all sessions. Conversation history is persisted in SQLite and available to future sessions on the same document via RAG retrieval. Memory is never shared across documents.

**Honest about limitations.** Large documents cannot be fully summarized with current models. Posey is transparent about this and does its best with the most relevant sections rather than silently producing an incomplete summary without acknowledgment.

**One interface, intelligent routing.** There are not multiple "modes." There is one Ask Posey surface. What changes is what context gets sent to the model, determined by a lightweight intent classification call before the main response.

---

## Invocation Points

### 1. Passage-scoped (primary)
The user taps a word or sentence and the contextual menu offers "Ask Posey." The selected passage — or the currently highlighted sentence if nothing is explicitly selected — is quoted at the top of the Ask Posey sheet as the context anchor. Default context: selected passage plus 2-3 sentences on each side.

### 2. Document-scoped
A dedicated glyph on the far left of the bottom reader bar opens Ask Posey with the current sentence as context anchor. The user's question can be about anything in the document. Context is determined by intent routing (see below).

### 3. Navigation-scoped
The user asks Posey to find something: "Take me to the section about recursion" or "Where does the author discuss Escher?" This is not a separate mode — it's the same interface, but the intent classifier routes it to a navigation response rather than a text response. If a matching section is found, Posey offers to jump there.

*(Note: Annotation-scoped invocation from the Notes surface is planned for a future pass after the core feature stabilizes.)*

---

## Intent Classification — The Two-Call Pattern

Every Ask Posey query uses two AFM calls:

**Call 1 — Intent classification (lightweight)**  
A small prompt asking AFM to classify the question into one of three buckets:
- `immediate` — question is about the passage currently being read; send current sentence + surrounding context
- `search` — question requires finding something elsewhere in the document; run semantic RAG retrieval
- `general` — question requires broad document understanding; use summary + RAG

This call is fast and cheap. It determines what context the second call receives.

**Call 2 — Response generation**  
The user's question plus the context determined by Call 1 is sent to AFM for a full response.

This pattern keeps responses relevant without flooding every query with the entire document context.

---

## Context Management — Porting Hal's Architecture

Posey's long-document context management is adapted directly from Hal. Do not invent this from scratch — read Hal.swift Blocks 02-07 (MemoryStore) and Blocks 17-22 (ChatViewModel summarization and prompt history) before writing any code.

### Document context tiers

**Small documents** (under ~8,000 chars): send the full plainText. No RAG needed.

**Medium documents** (8,000–100,000 chars): send a rolling summary plus RAG retrieval of the most relevant sections for the specific question.

**Large documents** (over 100,000 chars): RAG retrieval only — pull the most semantically relevant sections based on the question. Include a brief high-level summary if one exists. Be transparent with the user: display a small note like "Working from the most relevant sections of this document."

**Very large documents** (GEB, Feeling Good — over 500,000 chars): same as large, but also surface a clear message explaining that complete summarization is not possible and that Posey is doing its best with the most relevant material.

### Conversation memory

All Ask Posey exchanges for a document are stored in SQLite in a new `ask_posey_conversations` table: `(id, document_id, timestamp, role, content)`.

When a new session opens for a document:
- Recent exchanges (last N turns, where N keeps total under ~2,000 chars) are injected verbatim into the prompt
- Older exchanges are summarized using the same summarization pattern as Hal — batch summarization at a configurable depth interval
- The summary is prepended to the prompt on every turn
- RAG retrieval deduplicates against what's already in the prompt (cosine similarity check, same as Hal) to avoid the model seeing the same content multiple times

Context budget allocation (approximate):
- Document context (RAG results): 60% of available tokens
- Conversation history (recent + summary): 25%
- System prompt + user question: 15%

These are starting values — tune empirically once the feature is running.

### Embeddings

Use Apple's `NLEmbedding` (already in Hal) for semantic search over both document sections and conversation history. Index document sections at import time using plainText chunks of ~500 chars with 50-char overlap. Index conversation turns at save time.

---

## Note Saving

Ask Posey conversations are saved automatically. No explicit save action required.

**Passage-scoped invocation:** The exchange is saved as a note anchored to the character offset of the invocation point — it appears in the Notes list at the correct position in the document.

**Document-scoped invocation:** The exchange is saved as a document-level note that appears at the top of the Notes list for that document, separate from position-anchored notes. It represents a document-wide conversation rather than a passage-specific one.

**Navigation invocation:** If the user asks Posey to find something and jumps to a section, no note is saved unless the user explicitly asks a follow-up question at the destination.

---

## The Ask Posey Sheet UI

A half-sheet that slides up from the bottom, anchored to the document behind it. The user can drag it taller. The document remains visible behind it — this is intentional, the user should always know where they are in the document.

**Sheet contents (top to bottom):**
1. Context anchor — the passage or sentence that was active at invocation, displayed in a subtle quoted style at the top. This is what Posey is working from.
2. Conversation history — previous exchanges in this session, scrollable
3. Current response — streaming text as AFM generates it
4. Input field — user types their question here

**Privacy indicator:** A small lock icon or "Private" label near the top of the sheet. Tapping it shows a brief explanation of Apple's privacy model.

**Transparency indicator:** For large documents, a small info line below the context anchor: "Working from the most relevant sections." Tapping it explains the limitation.

**Indexing indicator (first-time per document):** When Ask Posey opens on a document that has not yet been indexed (a pre-existing import from before the embedding-index landed, or a freshly imported document where indexing happened in the background), show a simple "Indexing this document…" line in the sheet while it builds. When complete, replace it with a brief "Indexed N sections." confirmation that fades after a few seconds. This sets expectations for the small one-time cost and builds trust by being visible about the work.

---

## Source Attribution

Every Ask Posey response carries attribution to the document chunks that contributed to it. This is distinct from the navigation pattern (which proposes destinations to jump to) — attribution shows the user which sources the model actually drew from when answering.

**What gets tracked.** When the prompt builder injects RAG chunks into a Call 2 prompt, the IDs and offsets of those chunks are recorded as the *candidate sources* for that turn. After Call 2 returns, the `[1]`, `[2]`, `[3]`… reference markers Posey emits in the response (and any direct quotation it produces) are mapped back to the candidate chunks.

**How it surfaces in the UI.** Below each assistant message in the threaded chat, Posey renders a small "Sources" strip — a horizontally scrollable row of compact pills, one per cited chunk. Each pill shows a short preview (first ~30 chars of the chunk text or the section title if available) and the page or character offset. Tapping a pill dismisses the sheet and scrolls the reader to that offset, the same way navigation cards do. Source attribution and navigation share the existing offset-based jump infrastructure.

**When a response has no RAG context** (the `.immediate` intent path, where the answer comes from the anchor passage and surrounding sentences only), the Sources strip shows the anchor passage itself as the single source. Honest, never empty: every answer points back to where it came from.

**Implementation notes.**
- Affects the prompt builder: the assembled `RAGSnippet` array for a turn must be retained alongside the response so the UI can render attribution after the model returns.
- Affects the message model: `AskPoseyMessage` (or whatever the v1 chat-message struct ends up named) needs an array of contributing-chunk references — at minimum `(chunk_index, start_offset, end_offset, text_preview)`.
- Persisted in `ask_posey_conversations` so attribution survives across sessions: store the chunk references as a JSON column on the assistant turn, or as a sibling table if we need joins later.
- Honesty principle: attribution is *what was injected*, not *what the model claims*. If the model paraphrases or hallucinates, the user can verify against the cited source by tapping through. This is load-bearing for the trust contract.

---

## Navigation Response Pattern

When intent classification routes to `search`, the response is different from a text answer:

1. AFM returns the most likely matching section(s) with a brief description
2. The sheet shows the result as a navigable card: "Found: Chapter 3 — The MU Puzzle (page 47)" with a "Jump there" button
3. Tapping "Jump there" dismisses the sheet and scrolls the reader to that position
4. If multiple sections match, show up to 3 as separate cards

This reuses the existing `jumpToTOCEntry` infrastructure CC already built.

---

## TOC and Structure Integration

Ask Posey is aware of document structure. When a navigation question arrives:
- Check the `document_toc` table first (fast, no AFM call needed for exact TOC matches)
- If not found in TOC, run semantic search over document sections
- If still not found, run the full two-call AFM pattern

This tiered approach keeps navigation fast for common cases.

---

## What Ask Posey Will Struggle With (Be Honest)

- **Summarizing very large documents completely** — physically impossible with current context windows. Be transparent.
- **Questions requiring reasoning across widely separated passages** — RAG retrieval helps but is not perfect.
- **Highly technical or specialized content** — AFM is a general model. It may not understand domain-specific material well.
- **Precise quotation** — AFM may paraphrase rather than quote exactly. Always show the source passage so the user can verify.

These limitations are acceptable for V1. The architecture is correct. Quality follows as models improve.

---

## Format Parity Note

Ask Posey works the same way regardless of document format. The plainText field is the input — it doesn't matter whether the source was a PDF, EPUB, DOCX, or TXT. Format differences are handled at import time, not at Ask Posey time.

---

## Implementation Order

1. Confirm Apple Foundation Models is available and working on device and in the simulator
2. Read Hal.swift Blocks 02-07 and 17-22 thoroughly before writing any code
3. Build the SQLite schema (`ask_posey_conversations`, embeddings for document sections)
4. Build the two-call intent classifier with hardcoded context selection (no RAG yet)
5. Build the sheet UI with streaming response display
6. Wire passage-scoped invocation (contextual menu)
7. Wire document-scoped invocation (reader bar glyph)
8. Add conversation memory (recent turns verbatim)
9. Add RAG retrieval using NLEmbedding
10. Add conversation summarization (Hal pattern)
11. Add navigation response pattern
12. Add document-scoped note saving
13. Add transparency indicators for large documents
14. Add source attribution: track injected RAG chunks per turn, render a "Sources" strip under each assistant message, wire pills to the existing offset-jump infrastructure, persist attribution in `ask_posey_conversations`
15. Add the indexing indicator: "Indexing this document…" → "Indexed N sections." for any document where the embedding index is being built on first invocation

**Do not skip steps.** Do not build the full RAG before the basic two-call pattern works. Verify each step on device before proceeding.

**Discuss the implementation plan with Mark and Claude before writing any code.** This is a consequential feature.

---

## Resolved Design Decisions

**1. Context budget split:** Start with 60/25/15 (document context / conversation history / system + question). Do not expose these as user-adjustable settings in V1 — the audience for that control is too small and the confusion cost too high. Instrument what's actually happening, tune empirically, revisit in V2 if evidence demands it.

**2. Size thresholds:** Start with the estimates in this spec. Tune empirically once Ask Posey is running on real documents. CC has the tools to talk to Posey directly — use them.

**3. Conversation history visibility:** Yes — visible as a threaded chat view. Previous interactions appear above the current input field, each showing the question, Posey's response, and a link back to the passage in the document that was active at invocation. Tapping the passage link jumps the reader to that position. Build order: threaded chat view first, passage links in a subsequent pass. Don't let the links block shipping the conversation view.

**4. Notes:** Ask Posey responses save like any other note — same edit and delete behavior, no special cases. Consistent with the rest of the notes system.

**5. AFM unavailable:** Hide the Ask Posey interface entirely on unsupported devices. No degraded experience, no error messages — just absence. Users on supported devices get the feature. Others don't see it exists. Clean and honest.
