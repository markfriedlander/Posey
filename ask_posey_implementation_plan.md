# Ask Posey — Implementation Plan
**Status:** Draft — for review by Mark and Claude (claude.ai) before any code lands
**Date:** 2026-05-01
**Author:** Claude Code (CC)

---

## Pre-Read

This plan presupposes you've read:
- `ask_posey_spec.md` — the v1 feature spec, including Mark's resolved decisions
- `ARCHITECTURE.md` (esp. "Ask Posey Architecture")
- `CONSTITUTION.md` (esp. "Ask Posey — on-device AI reading assistance")
- `Hal.swift` Blocks 02–07 (MemoryStore, embeddings, RAG search) and 17–22 (ChatViewModel, summarization, prompt assembly, send-message flow)

If you're picking this up cold, read those first. The plan below references their primitives by name and assumes the reader knows what `searchUnifiedContent`, `generateEmbedding`, `cosineSimilarity`, `injectedSummary`, `effectiveMemoryDepth`, and the priority-ordered prompt builder do.

---

## 1. Step 1 outcome — AFM availability is confirmed

A diagnostic XCTest (`PoseyTests/FoundationModelsAvailabilityProbe.swift`) exercises three pieces:

1. `SystemLanguageModel.default.availability` returns a value
2. `LanguageModelSession(model:instructions:)` instantiates without throwing
3. `try await session.respond(to: "Say the single word: ready.")` returns a non-empty `.content`

| Surface | Framework loads | `availability` reports OK | Session instantiates | Actual inference round-trip |
|---|---|---|---|---|
| **iPhone 16 Plus** (Mark's device, iOS 26.x) | ✅ | ✅ | ✅ (0.015s) | ✅ (1.541s) |
| **iPhone 17 Pro Max sim** (iOS 26.3) | ✅ | ✅ | ✅ (0.20s) | ❌ (31s timeout — assets not installed in sim image) |

**Conclusion.** AFM is fully usable on device. The simulator can run AFM-using code paths up to but not including actual model invocation — which is fine, because device is the acceptance standard for Posey. Simulator-side, we either short-circuit on `availability != .available` or accept that the response call will fail. Per Mark's resolved decision **"AFM unavailable: hide the Ask Posey interface entirely"**, the same gate handles both cases (sim with broken assets and unsupported devices in the wild).

The probe file lives in `PoseyTests/FoundationModelsAvailabilityProbe.swift`. Once we've confirmed the broader feature works, the third test (round-trip) can be removed from the standard suite to avoid a 1.5s+ tax on every CI run, or kept under a `#if RELEASE_PROBE`.

---

## 2. AFM API surface we'll use

From `FoundationModels.framework`'s public Swift interface in iOS 26.4 SDK:

```swift
@available(iOS 26.0, *)
public final class SystemLanguageModel: Sendable {
    public static var `default`: SystemLanguageModel { get }
    public var availability: Availability { get }
    public var isAvailable: Bool { get }
    public func supportsLocale(_ locale: Locale = .current) -> Bool

    public enum Availability: Equatable, Sendable {
        case available
        case unavailable(UnavailableReason)
        public enum UnavailableReason: Equatable, Sendable {
            case deviceNotEligible
            case appleIntelligenceNotEnabled
            case modelNotReady
        }
    }
}

@available(iOS 26.0, *)
public final class LanguageModelSession: @unchecked Sendable, Observable {
    public convenience init(
        model: SystemLanguageModel = .default,
        tools: [any Tool] = [],
        instructions: String? = nil
    )
    public var isResponding: Bool { get }
    public func respond(to prompt: String, options: GenerationOptions = .init())
        async throws -> Response<String>
    public func streamResponse(to prompt: String, options: GenerationOptions = .init())
        -> ResponseStream<String>  // AsyncSequence of Snapshot
}
```

The `@Generable` macro and `respond<Content: Generable>(...)` overloads let us declare a Swift type whose schema AFM is constrained to fill — this is the right tool for the **intent classifier** (Call 1), which we want to return a small enum, not free text.

---

## 3. Architecture overview

Five new modules, each in its own folder under `Posey/Features/AskPosey/` or `Posey/Services/AskPosey/`. Names are proposals; bikeshed welcome.

```
Posey/
├── Features/AskPosey/
│   ├── AskPoseyView.swift              (the modal sheet)
│   ├── AskPoseyViewModel.swift         (orchestration, state)
│   └── AskPoseyMessageBubble.swift     (chat-bubble row view)
└── Services/AskPosey/
    ├── AskPoseyAvailability.swift      (SystemLanguageModel + simctl gating)
    ├── AskPoseyService.swift           (LanguageModelSession lifecycle)
    ├── AskPoseyIntentClassifier.swift  (Call 1: @Generable enum)
    ├── AskPoseyPromptBuilder.swift     (the priority-ordered prompt; Hal Block 20.1 in miniature)
    ├── DocumentEmbeddingIndex.swift    (NLEmbedding chunking + cosine search)
    └── AskPoseyConversationStore.swift (SQLite read/write for ask_posey_conversations)
```

Why split it this way:

- **`AskPoseyAvailability`** is the single chokepoint for "should this feature even be visible?" Used by `ReaderView` to hide the chrome glyph and the contextual-menu entry on unsupported devices.
- **`AskPoseyService`** wraps `LanguageModelSession`. The session is per-sheet, not per-app — every time the user opens the sheet, we instantiate a fresh session with the right instructions. We don't keep one alive for the app lifetime because session state isn't meaningful between unrelated user questions.
- **`AskPoseyIntentClassifier`** is a thin wrapper: take user question + minimal context, return an `Intent` enum (`.immediate | .search | .general`) using a Generable type.
- **`AskPoseyPromptBuilder`** is the analog of Hal's Block 20.1 `buildPromptHistory`. Same priority discipline (system → recent history → summary → RAG → metadata → user input), same per-tier token estimation and dropping when the budget is exceeded. **We adapt Hal's pattern, not its code.** The shapes are similar but the data model differs (Posey's notion of "conversation" is per-document; Hal's is global).
- **`DocumentEmbeddingIndex`** uses `NLEmbedding.sentenceEmbedding(for: .english)`, exactly as Hal does in Block 05. Indexing happens at document-import time and stores `(document_id, chunk_offset, chunk_text, embedding)` in a new SQLite table.
- **`AskPoseyConversationStore`** owns the new `ask_posey_conversations` table.

---

## 4. Schema additions (DatabaseManager)

Two new tables and one new column. Both follow the existing `addColumnIfNeeded` / `CREATE TABLE IF NOT EXISTS` migration discipline used for `playback_skip_until_offset`, `document_toc`, etc.

### 4.1 `ask_posey_conversations`
```sql
CREATE TABLE IF NOT EXISTS ask_posey_conversations (
    id           TEXT PRIMARY KEY,                      -- UUID
    document_id  TEXT NOT NULL,
    timestamp    INTEGER NOT NULL,                      -- epoch seconds, like other tables
    role         TEXT NOT NULL,                         -- 'user' | 'assistant'
    content      TEXT NOT NULL,
    invocation   TEXT NOT NULL,                         -- 'passage' | 'document' | 'navigation' | 'annotation'
    anchor_offset INTEGER,                              -- character offset of the active sentence/selection at invocation; NULL for document-scoped
    summary_of_turns_through INTEGER NOT NULL DEFAULT 0,-- if this row is itself a summary, the highest turn index it covers; else 0
    is_summary   INTEGER NOT NULL DEFAULT 0,            -- 0 = real turn, 1 = rolling summary
    FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_ask_posey_doc_ts
    ON ask_posey_conversations(document_id, timestamp);
```

### 4.2 `document_chunks`
Indexed at import time. One row per ~500-char chunk with 50-char overlap.

```sql
CREATE TABLE IF NOT EXISTS document_chunks (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    document_id  TEXT NOT NULL,
    chunk_index  INTEGER NOT NULL,                      -- 0-based ordinal within document
    start_offset INTEGER NOT NULL,                      -- char offset in plainText
    end_offset   INTEGER NOT NULL,
    text         TEXT NOT NULL,
    embedding    BLOB NOT NULL,                         -- [Double] (NLEmbedding output) packed little-endian
    FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_document_chunks_doc
    ON document_chunks(document_id, chunk_index);
```

### 4.3 No new column on `notes` for v1

Mark's resolved decision: "Ask Posey responses save like any other note — same edit and delete behavior, no special cases." So we save a conversation transcript as a single `Note` body, anchored to the invocation offset. No schema change needed; if we discover we need a `source: 'ask_posey'` flag later, we add the column then.

---

## 5. The two-call intent + response flow

### 5.1 Intent classification (Call 1)

```swift
@Generable
enum AskPoseyIntent {
    /// The user is asking about the passage being shown — answer from the
    /// quoted anchor and a small surrounding window.
    case immediate
    /// The user wants to find a specific section elsewhere in the document
    /// — search the document, return navigation cards.
    case search
    /// The user wants broader understanding — pull RAG and summary.
    case general
}
```

Build a tiny instruction prompt:

> You are Posey, an offline reading assistant. Classify the user's question
> into exactly one of three buckets. Reply with only the bucket name.
>
> - immediate: the question is about the passage shown above.
> - search: the question is asking where in the document something appears.
> - general: the question requires broader document knowledge.

Send that with the user's question + the anchor passage via `respond(to:generating: AskPoseyIntent.self)`. AFM returns one of three cases; we route the second call accordingly.

This call is cheap (small input, small output) and runs every turn.

### 5.2 Response generation (Call 2)

Per intent, the prompt builder selects context:

| Intent | Document context | Notes |
|---|---|---|
| `.immediate` | Anchor passage + 2–3 sentences each side | No RAG, no summary |
| `.search` | Top-K (≤3) RAG snippets by cosine similarity | Output uses Generable struct with title/offset/snippet so we can render navigable cards |
| `.general` | RAG snippets up to 60% budget + rolling summary | Most expensive; only path that summons summarization |

Then call `respond(to: prompt)` for prose answers, or `respond(to: prompt, generating: NavigationResults.self)` for navigation.

Streaming via `streamResponse(to:)` is the right UI behavior; the spec calls for "streaming text as AFM generates it." We use it for `.immediate` and `.general`. `.search` returns a structured object (cards) so it's a non-streaming `respond(to:generating:)` call.

---

## 6. Prompt builder — the Hal Block 20.1 analog

Adapt the priority discipline directly. Token budgets per the spec: **60 / 25 / 15** (document context / conversation history / system + question). Hardcoded for v1; instrumented per Mark's resolved decision so we can tune later.

Priority order, dropping each tier when the running total would exceed the budget:

1. **System prompt** (the Ask Posey instructions). Always included. ~5% of budget.
2. **Anchor passage** (the quoted selection or current sentence). Always included for non-`.general` intents. ~5–10%.
3. **Recent verbatim conversation turns for THIS document** — most recent N where N keeps total under 25% of budget. (Hal calls this short-term memory.)
4. **Rolling summary** of older turns for this document, if any. If history exceeds the recent-verbatim window, we summarize older turns into a single string the same way Hal does in Block 18 (`generateAutoSummary`). Persist the summary to `ask_posey_conversations` with `is_summary=1` so it survives across sessions.
5. **RAG snippets** (intent-dependent), deduplicated against everything already in the prompt via cosine similarity ≥ `ragDedupSimilarityThreshold` (Hal default ~0.85). Up to 60% of budget.
6. **User question** — always last, never dropped.

We instrument every assembly with a `TokenBreakdown`-style struct so we can see what got included or dropped during Mark's first real-document tests.

**Token estimator.** Hal uses 1 token ≈ 4 characters as a rough heuristic (Block 16 `TokenEstimator`). AFM doesn't expose a tokenizer publicly, so we copy that approach. Good enough for budgeting; we'll calibrate empirically once we see real responses.

---

## 7. Embedding index lifecycle

### 7.1 Build at import time
A new step at the end of every importer's pipeline (TXT, MD, RTF, DOCX, HTML, EPUB, PDF — **format-parity standing policy applies here**, not just PDF):

1. Take `plainText`.
2. Walk it with a 500-char window and 50-char overlap (per spec).
3. For each chunk, call `NLEmbedding.sentenceEmbedding(for: .english)?.vector(for: chunk)`.
4. Persist `(documentID, chunkIndex, startOffset, endOffset, text, embedding)` in `document_chunks`.

Cost estimate: a 100k-char document → ~220 chunks → ~220 embedding calls. Hal does this synchronously in its document import path; we'll do the same. If a real document makes import unacceptably slow we'll move it to a background `Task` post-import, but that introduces "is the index ready yet?" complexity and I'd rather start simple.

**Failure mode.** If `NLEmbedding` returns nil for a chunk (it sometimes does for very short or non-English text), we fall back to Hal's hash-embedding (Block 05). The index is best-effort; Ask Posey still works without it (it'd just go straight to general for every question). **This keeps the feature available even when the embedding tier fails.**

### 7.2 Query at Ask Posey time
1. Embed the user's question.
2. Cosine-similarity scan all chunks for the current `documentID` (already filtered in SQL by `document_id`, fast for typical documents — single-document scan, not cross-document).
3. Sort, take top-K (typically 5–10 per spec).
4. Trim to fit RAG budget; emit annotated snippets with offsets so we can render "jump to" links.

---

## 8. UI surface

### 8.1 Invocation points
- **Passage-scoped**: extend the existing reader's contextual menu (text-selection menu) with an "Ask Posey" item. When nothing is selected but a sentence is highlighted, the highlighted sentence becomes the anchor.
- **Document-scoped**: a new chrome glyph far-left of the bottom transport bar (per `ARCHITECTURE.md`). Existing transport stays centered.
- **Navigation-scoped**: not a separate entry point — same modal sheet, just routed differently by the intent classifier.
- **Annotation-scoped**: deferred per spec (future pass).

### 8.2 Modal sheet structure
A `.sheet`-presented `AskPoseyView`. Half-sheet by default with detents `.medium` and `.large`. Layout top-to-bottom:

1. **Header strip**: privacy lock icon, title "Ask Posey", close button, AFM availability badge if relevant.
2. **Anchor passage**: the selected text or active sentence in a quoted style.
3. **Threaded chat history**: scrollable, oldest at top, newest at bottom. Each user/assistant pair shows the question, the response, and (per spec, in a follow-up pass) a small "jump to passage" link. **Per Mark's resolved decision: build the threaded view first; passage links are a later pass and don't block shipping.**
4. **Streaming response area**: appears below history while a response is being generated.
5. **Input field**: composer anchored to the bottom of the sheet.

Navigation results render as a card stack inline with the chat history, each with a "Jump there" button that dismisses the sheet and calls the existing `jumpToTOCEntry`-style infrastructure.

### 8.3 Hide-on-unavailable behavior
`AskPoseyAvailability.shared.isAvailable` is queried at view-render time. When false:
- The bottom-bar glyph is omitted entirely (not greyed out).
- The contextual-menu "Ask Posey" item is omitted.
- No banner, no error UI, no upsell. Per Mark: "clean and honest."

---

## 9. Threading and concurrency

All AFM calls are `async throws`. The view model is `@MainActor`. The prompt builder, embedding index, and conversation store can run off-main; they hand results back to the view model on `MainActor`.

`LanguageModelSession` is `@unchecked Sendable` — usable across actors but Apple notes it's `@unchecked` for a reason. We treat each session as owned by exactly one Task at a time. The view model holds a single optional session that's replaced on each new question (we don't reuse sessions across turns for now; if multi-turn AFM "session memory" turns out to be useful for instruction continuity, we revisit).

We rely on AFM's own throttling (`isResponding`, `concurrentRequests` error) rather than building our own queue.

Streaming: the `ResponseStream<String>.Snapshot` async sequence yields cumulative text. The view model appends each snapshot's `content` delta to the in-flight assistant message. Same pattern Hal uses for its faux-streaming UI in Block 21.

---

## 10. Persistence semantics

Per Mark's resolved decision: **conversations are saved automatically; no explicit save action.**

| Invocation | What we save | Where |
|---|---|---|
| `.immediate` (passage-scoped) | Each user/assistant turn pair | `ask_posey_conversations` with `invocation='passage'`, `anchor_offset=<sentence offset>`. Also surfaces as an entry in the existing Notes list at that offset. |
| `.general` / `.search` (document-scoped) | Each turn pair | `ask_posey_conversations` with `invocation='document'`, `anchor_offset=NULL`. Surfaces as a document-level entry in the Notes list (top of list, separate from position-anchored notes). |
| `.search` resulting in a navigation jump with no follow-up | Nothing | Pure navigation — no conversation worth saving. |

The Notes integration is the "save like any other note" path: we write a `Note` row whose body is the Q/A transcript and whose `documentId` and offset match the invocation. The `ask_posey_conversations` table is the *complete* record for retrieval; the `notes` row is the *user-visible* representation.

This dual-store is necessary because the spec asks for two different views of the same data: notes need stable, edit-friendly text; conversations need turn-level granularity for RAG retrieval and summarization.

---

## 11. Test plan

Per CLAUDE.md: device is the acceptance standard. Tests we plan to write:

**Unit tests (PoseyTests):**
- `AskPoseyConversationStoreTests`: write/read/delete turns, summary roll-up, document-cascade delete.
- `DocumentEmbeddingIndexTests`: chunking with overlap is deterministic; cosine similarity returns expected order on a fixture; hash fallback when `NLEmbedding` fails.
- `AskPoseyPromptBuilderTests`: budget enforcement; priority order honored when over budget; injection of summary vs. recent turns.
- `AskPoseyIntentClassifierTests`: synthetic Generable round-trip with a stub session (we may need a mockable session protocol).

**Integration tests on device:**
- End-to-end: import a small TXT, ask a question scoped to the current sentence, verify response arrives. (Manual.)
- End-to-end large doc: import a Gutenberg book, ask a navigation-style question, verify the navigation card lands on a real offset. (Manual; may need a tighter assertion.)

**Synthetic corpus harness extension:**
- Add a per-doc Ask Posey sanity check: after import, embed `"Hello, what is this document about?"`, classify to `.general`, and assert we don't crash on any doc in the synthetic + Gutenberg corpus.

---

## 12. Open questions before any code

These are the things I think still need an answer or a decision before I start writing the implementation. Calling these out now per CLAUDE.md "no assumptions" rule.

### 12.1 Doc discrepancy — spec vs. ARCHITECTURE.md/CONSTITUTION.md
The spec (2026-05-01) says **conversations persist across sessions and auto-save** to a new `ask_posey_conversations` table.

`ARCHITECTURE.md` "Ask Posey Architecture" and `CONSTITUTION.md` "Ask Posey — on-device AI reading assistance" both currently describe a **transient session model** where "when the sheet closes the exchange is either saved as a note by the user or discarded" and "persistent conversation history is explicitly deferred."

Per CLAUDE.md: "If something in the docs conflicts with what the code does, the docs win and the code needs updating — or the docs need a deliberate revision. Do not let the code drift silently from the documented intent."

The spec is dated, intentional, and resolves the open questions Mark raised earlier the same day. **My read: the spec supersedes ARCHITECTURE.md/CONSTITUTION.md on this point.** Before any code lands, the architecture doc and constitution should be updated to match the spec. **Will Mark and Claude confirm this is the right read?** If yes, I'll update those docs as part of the same commit that lands the schema migration so we don't have drift. If no, the spec needs revision instead.

### 12.2 Cross-session document scoping for embeddings
The spec implicitly assumes embeddings index every document. Concretely: **do we want to retro-index existing imports the first time the user invokes Ask Posey on them, or do we accept that pre-existing imports just don't have a chunk index until they're re-imported?** I lean toward retro-indexing on first invocation per document (one-time cost, displayed as a brief "Indexing this document..." state) so existing libraries don't feel broken. Want to confirm.

### 12.3 Embedding language
Hal hardcodes English (`NLEmbedding.sentenceEmbedding(for: .english)`). Posey explicitly supports multilingual content (Gutenberg corpus has French, German). For v1, do we accept English-only embeddings (graceful degradation: cosine similarity still works on multilingual text but is poor) or do we detect document language at import and pick the right `NLEmbedding`? Recommendation: English-only for v1, ship the obvious multilingual fix as a follow-up. Want to confirm.

### 12.4 Sheet vs. inline
`ARCHITECTURE.md` is explicit that all three patterns use a full modal sheet. The spec says half-sheet with drag to expand. **Half-sheet (`.medium` detent default, `.large` available) is more reading-friendly because the document remains visible behind it — that's also exactly what the spec says.** Confirm we go with half-sheet rather than full modal? If yes, ARCHITECTURE.md needs updating on this point too.

### 12.5 Streaming visualization
Hal does **fake** streaming (chunks the final response and types it out at ~100 chars/sec) for visual smoothness. AFM has real streaming via `streamResponse`. **Do we want real streaming (jaggier, but accurate to model speed) or Hal-style fake streaming for consistency with how Mark already experiences AI responses?** Recommend real streaming for Posey — it's truthful and Mark hasn't built up an expectation on this surface yet.

### 12.6 Privacy indicator copy
Spec says "private by design" not "100% on-device." Confirm exact copy for the lock-icon-tap explanation. Suggested text:

> Posey runs Apple's on-device language model. For complex requests, your
> question may use Apple's Private Cloud Compute, which is end-to-end
> encrypted — Apple cannot read your prompts or responses. Posey never sends
> your conversations to third-party AI services.

### 12.7 What "very large document" message looks like
Spec says: a small note like "Working from the most relevant sections of this document." Confirm exact copy and where it appears (below anchor passage, per spec — sounds right).

### 12.8 Order of work — does the v1 must include navigation?
The spec's implementation order puts navigation at step 11. Mark, are you OK with the modal sheet shipping with prose answers first (steps 1–10) and navigation as a follow-up commit, or do you want navigation to land in the same milestone? My instinct: ship prose first, navigation second. Easier to verify each independently.

---

## 13. Proposed milestones

If the open questions all resolve and we go ahead, the work breaks into roughly seven commits, each independently verifiable on device.

| # | Commit | What lands | Acceptance test |
|---|--------|------------|-----------------|
| 1 | Doc alignment + schema migration | Update ARCHITECTURE.md/CONSTITUTION.md to match the spec; `ask_posey_conversations` and `document_chunks` tables; `AskPoseyAvailability` skeleton | App boots, schema migrations apply, no behavior change |
| 2 | Document embedding index | Build chunks at import time for all formats; `DocumentEmbeddingIndexTests` passes | Re-import a doc, verify chunks land in SQLite via the antenna |
| 3 | Two-call intent classifier | `AskPoseyIntentClassifier` + `AskPoseyService` minimal session lifecycle | Unit tests for the classifier; manual on-device probe |
| 4 | Modal sheet UI shell | `AskPoseyView` with anchor + composer, no AFM yet (echo back the question) | Sheet opens from passage and bottom-bar glyph; close dismisses |
| 5 | Prose response loop | Wire intent → prompt builder → AFM `streamResponse` → bubble updates; passage-scoped invocation only | Ask a passage-scoped question on device, get a streamed response |
| 6 | Document-scoped invocation + RAG | Bottom-bar glyph; `.general` intent; RAG retrieval against the chunk index; rolling summary support | Ask a document-scoped question on a Gutenberg book, get a relevant answer |
| 7 | Navigation pattern + auto-save | `.search` intent → Generable navigation cards → existing TOC jump infrastructure; auto-save to notes | Ask "where does X appear" — get cards — tap one — reader scrolls to that offset |

Each commit pushes to `origin/main` immediately per the new CLAUDE.md push policy.

---

## 14. Things this plan deliberately does not do

To keep v1 tight per the spec and Mark's resolved decisions:

- **No user-tunable token budget.** 60/25/15 is hardcoded.
- **No multi-turn AFM session reuse.** Each user question gets a fresh `LanguageModelSession`.
- **No cross-document RAG.** The chunk index is queried with a `WHERE document_id = ?`. Memory never crosses documents.
- **No multilingual embeddings.** English `NLEmbedding`, hash fallback otherwise.
- **No degraded experience on AFM-unavailable devices.** Feature is hidden, not crippled.
- **No third-party AI services.** AFM only. CONSTITUTION.md is explicit.
- **No edit/delete special cases for Ask Posey notes.** They use the same notes infrastructure.
- **No tools (Wikipedia/web/etc.).** AFM has a `tools:` parameter; we pass `[]`.

---

## 15. Awaiting

- Mark and Claude (claude.ai) review of this plan.
- Resolutions to the eight open questions in Section 12.
- Confirmation the sequencing in Section 13 is what you want.

Once those are settled, I'll start with Milestone 1.
