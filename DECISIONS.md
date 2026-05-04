# Posey Decisions

## 2026-05-04 — Ask Posey: MiniLM (CoreML) Replaces NLEmbedding for RAG

- Status: Accepted
- Decision: Document chunks are now embedded via a bundled CoreML build of `sentence-transformers/all-MiniLM-L6-v2` (43MB fp16 .mlpackage shipped in `Posey/Resources/MiniLM/`). Replaces Apple's `NLEmbedding.sentenceEmbedding(_:)` for new indexing. Apple's `NLEmbedding` and `NLContextualEmbedding` paths remain selectable via the `EmbeddingProvider` UserDefaults flag for benchmarking and fallback.
- Rationale: Per Mark's RAG-pipeline audit directive 2026-05-04, A/B tested all three embedders end-to-end on the same 24-question non-fiction Three Hats sweep:
  - **NLEmbedding** (current): 16/24 = 67% clean. Cosine scores 0.07–0.30 — too uniformly low to discriminate. Apple trained NLEmbedding for clustering/classification; not for retrieval. Per WWDC25, Apple recommends NLContextualEmbedding for retrieval.
  - **NLContextualEmbedding** (BERT, mean-pool): 15/24 = 63% clean. Higher absolute scores (0.85–0.88) but very weak discrimination — top-5 results cluster within 0.005 of each other. Vanilla BERT mean-pooling is a known-weak retrieval baseline.
  - **MiniLM CoreML** (sentence-transformers all-MiniLM-L6-v2): 18/24 = 75% clean. Purpose-built for retrieval (MTEB-trained on query-passage pairs). Cosine scores 0.25–0.40 with meaningful spread. Surfaces correct chunks (e.g. DOCX "What chapter covers ethics?" → chunk 320 "Chapter 4: Ethical Considerations in AI" at rank 3 cosine alone, no lexical fallback needed).
- Implementation:
  - Bundled assets: `MiniLML6v2.mlpackage` (43MB fp16), `minilm-vocab.txt` (30,522 tokens), `minilm-tokenizer-config.json`. Auto-included via Xcode 15+ filesystem-synchronized groups; Xcode auto-compiles `.mlpackage` to `.mlmodelc` at build time.
  - `MiniLMEmbedder` (new): `@MainActor` singleton wraps `MLModel` + tokenizer. Lazy load on first `embed(_:)` call. Mean-pools `last_hidden_state` with attention mask, L2-normalizes (matches sentence-transformers semantics), returns 384-dim `[Double]`.
  - `BertWordPieceTokenizer` (new): hand-written WordPiece (BasicTokenizer + WordpieceTokenizer) matching `bert-base-uncased` semantics. ~280 lines, no third-party deps. Reads vocab.txt at init.
  - `EmbeddingProvider` enum: `.nlSentence | .nlContextual | .coreMLMiniLM`. UserDefaults-backed via `Posey.AskPosey.embeddingProvider`. Default flipped to `.coreMLMiniLM`.
  - `embeddingKind` tag: chunks store `"en-minilm"` so query-side knows which embedder to use. Mixed-kind support preserved (a doc indexed under one provider can be searched while still indexed; old NLEmbedding chunks keep working until re-indexed).
  - Sync bridge: `embedMiniLMSync(_:)` dispatches to main actor for the `MiniLMEmbedder` singleton. Indexing runs on a background queue; the per-chunk dispatch is fast (5–15ms on Neural Engine) and serializes naturally per document.
- Constraints respected:
  - **No third-party Swift packages.** Tokenizer is hand-written. `swift-transformers` SPM was considered and rejected per CLAUDE.md.
  - **On-device only.** No network. Model ships in the bundle.
  - **iOS 17+** for `.mlpackage` runtime compilation and `MLModelConfiguration.computeUnits = .all` (Neural Engine where available).
- Tradeoffs accepted:
  - **+43MB app bundle.** Visible but well under App Store norms. Posey was small before; this is now the dominant footprint.
  - **Re-index cost.** ~25s per 148K-char doc, ~75s for the 1.6M-char EPUB. Done lazily on next-open for existing docs; new imports are unaffected.
  - **Max sequence length 128 tokens** (the bundled model's shape range). Posey's 500–1000-char chunks are 100–250 tokens; we truncate at 128. The lost tail is acceptable for retrieval — the head of each chunk carries the topic signal.
- Restoration if MiniLM ships a regression: set provider via `SET_EMBEDDING_PROVIDER:nlSentence` (API verb) and `REINDEX_DOCUMENT` per doc. Old code paths and chunk kinds remain wired.
- Source: Mark's directive 2026-05-04 — "test both NLContextualEmbedding and MiniLM/DistilBERT via CoreML or another like model / models, and use whichever performs better."

## 2026-05-04 — Ask Posey: Optimized For Non-Fiction; Fiction Out Of Scope For 1.0

- Status: Accepted
- Decision: Ask Posey is a non-fiction reading assistant. All RAG tuning, prompt iteration, and conversation-quality testing target essays, articles, reference material, legal documents, academic papers, and similar. Fiction (novels, narrative prose) is acknowledged as a weaker case and will not be optimized for in 1.0. Existing infrastructure (importers, position memory, TTS, notes, search) continues to support fiction documents — only Ask Posey conversational quality is scoped.
- Rationale: Three Hats sweeps across 7 formats showed Ask Posey produces clean answers ~75% of the time on non-fiction (post-MiniLM, post-Layer-1-cleanup). The same pipeline on the EPUB Illuminatus Trilogy (1.6M-char satirical fiction) hits AFM safety refusals on occult content, narrative-context failures (model can't compose facts across chapters of a novel the way it can across sections of an essay), and generally lower clean rates that don't respond to the same fixes that work on non-fiction. Optimizing fiction would require a different retrieval strategy (scene-level vs. paragraph-level chunking; character-aware retrieval; longer context windows) and likely a different prompt frame (narrative summarization rather than fact lookup). Out of scope for 1.0.
- Surface to user:
  - First-use notification (`AskPoseyFirstUseSheet`, shown once ever, dismissal stored in UserDefaults under `Posey.AskPosey.firstUseNoticeDismissed`) sets expectations explicitly: "I do my best work with non-fiction. Essays, articles, reference material — that's where I shine. Fiction is trickier for me, but give it a try if you're curious." One-tap "Got it" dismissal.
  - No format-level gating — the user can still open Ask Posey on a novel; they're just informed first.
- Test policy: the 7-format Three Hats sweep contracts to a 6-format non-fiction sweep (TXT/MD/RTF/DOCX/HTML/PDF). EPUB Illuminatus stays in the corpus for import / TTS / notes regression testing but is excluded from Ask Posey clean-rate scoring.
- Future work: fiction-specific retrieval and prompt strategies are deferred to a post-1.0 milestone. Logged in NEXT.md.
- Source: Mark's directive 2026-05-04.

## 2026-05-04 — Ask Posey: Polish Call Removed (Temporary)

- Status: Accepted (temporary — revisit when AFM improves)
- Decision: The two-call Ask Posey pipeline collapses to a single call. The grounded call streams to the user verbatim. The polish call — previously a second `LanguageModelSession` that rewrote the grounded draft in "Posey's voice" — is removed from the runtime path. The polish prompt, the `polishTemperature` field, the `stripPolishPreamble` regex chain, and the `polishInstructions` static remain in the codebase as inert reference for the eventual restoration. No call site invokes them.
- Reasoning:
  - Three Hats QA across all 7 supported formats (Task 3 v1 and v2) showed the polish call leaking voice antipatterns in roughly half of all answers regardless of how aggressively the polish prompt and post-strip were tightened. Six rounds of prompt iteration and five rounds of regex strips improved the rate but never closed it. The on-device Apple Foundation Model the polish call runs against (AFM, Apple Intelligence) does not consistently honor the polish prompt's HARD RULES.
  - The specific failure modes are enumerated below. Several of them — recommendations (HARD RULE 4) and "X is like Y" metaphors (HARD RULE 5) — are flatly forbidden in the polish prompt and still get emitted. Sycophant openers ("Sure!", "Great question!") still leak past the no-preamble rule. When the polish call refuses entirely (it sometimes does), we fall back to grounded; but the asymmetry — grounded is reliable, polish is a coin flip — means polish is net-negative on quality.
  - The grounded call has its own remaining failure modes (over-cautious refusals on questions the document does answer; rare attribute hallucinations). Polish removal does not fix those — they need separate work on the grounded prompt and retrieval. But polish removal eliminates an entire class of failures cleanly.
  - Trade-off accepted: Posey's tone becomes more clinical. The earlier position ("a robotic Posey is a failed Posey regardless of factual accuracy" — Mark, 2026-05-02) is explicitly walked back. A correct, slightly flat answer is better than a warm answer with invented facts, ungrounded recommendations, or jarring metaphors. Voice is something we can revisit when the model layer can deliver it consistently; correctness is non-negotiable today.
- Posey's voice — the target we're stepping back from, not abandoning:
  - Warm, direct, slightly irreverent. Like a smart librarian who's read everything. Not sycophantic. Not slangy. Not metaphor-heavy. A smart friend.
  - Sentence rhythm, contractions, restructured clauses ("X is Y" → "It's Y."). Natural openers when they fit ("So,…", "Yeah,…"). No forced personality.
  - When AFM (or its successor on this device class) can honor a polish prompt with this discipline reliably (>90% clean across the 7-format Three Hats sweep), we restore the polish call. Until then we ship the grounded answer directly.
- Polish failure modes observed across Task 3 / Task 4 QA:
  - **Sycophant openers**: "Sure!", "Of course!", "Great question!", "Absolutely!", "Yeah, so:", "Okay so" — all forbidden by HARD RULE 3, emitted anyway.
  - **Outside-of-document recommendations**: "I'd definitely recommend this book", "great companion for X", "perfect for beginners", "worth your time" — flatly forbidden by HARD RULE 4, emitted on roughly 1 in 4 "should I read this?" / "is this good?" questions even with the rule reinforced. (The query-level recommendation short-circuit in `AskPoseyChatViewModel.send()` catches the obvious phrasings; the polish call still injects recommendation language into other answers.)
  - **Metaphors describing document people / topics / events**: "Mark Friedlander is like the DJ in the room", "the methodology is like a dance", "it's a wild party of legal arguments", "narrates the opening like a Greek chorus" — forbidden by HARD RULE 5, emitted regularly. The polish model treats metaphors as "voice" even when explicitly told not to.
  - **Slang / over-casual register**: "no cap", "wild", "vibes", "kinda", "hella" — not in the prompt's positive examples, drifts in anyway.
  - **Preamble announcements**: "Here is a rewrite of the draft answer in the requested voice:", "Below is the rewritten answer:", "Rewritten in your voice:" — forbidden by HARD RULE 3 with three explicit FAILED/SUCCEEDED examples, still emitted.
  - **Length inflation**: "Match the draft's length" (HARD RULE 6) is inconsistently honored. A six-word grounded answer becomes a three-paragraph polish answer roughly 20% of the time.
  - **HARD RULE leak into output**: in rare cases (~3%) the polish output literally contains the strings "FAILED:" / "SUCCEEDED:" — the model is treating the rule examples as part of the response template. We had to add a post-strip pass to repair this before the answer reached the user.
- Pipeline architecture being preserved (so restoration is a one-commit revert when the model improves):
  - **Two-call pipeline**:
    - **Call 1 — Classifier (intent)**: a low-temperature `LanguageModelSession` decides whether the user's question is `.immediate` (anchored to the current passage), `.search` (looking for a location in the document), or `.general` (broad question about the document). Drives `surroundingWindowTokens(for:)` and downstream RAG sizing. **Still active.**
    - **Call 2 — Grounded (factual)**: `LanguageModelSession(model:instructions: AskPoseyPromptBuilder.proseInstructions)` at `groundedTemperature: 0.1`. Sees the full prompt envelope from `AskPoseyPromptBuilder` — system framing, anchor, surrounding context, RAG chunks, conversation history, the user question. Produces the factual answer. **Still active. Now streams to the user verbatim.**
    - **Call 3 — Polish (voice)** [REMOVED]: a second `LanguageModelSession(model:instructions: AskPoseyPromptBuilder.polishInstructions)` at `polishTemperature: 0.35` (was 0.65, lowered late in iteration). Took the grounded draft as input via `polishPromptBody(question:groundedDraft:)` and rewrote it in Posey's voice. Streamed to the user. On polish failure, fell back to the grounded draft. **This call is the one we removed.**
  - **Restoration recipe**: in `AskPoseyService.streamProseResponse`, replace the post-grounded streaming block (currently "stream `groundedFinal` verbatim") with the previous `if refusalShapeFinal { stream grounded } else { polish }` structure. Both branches still exist as commented-out reference at the call site. The polish prompt, polish temperature field, polish prompt-body builder, polish-preamble strip, and the inert `polishInstructions` static remain available — nothing to rebuild.
- `AskPoseyPromptBuilder.polishInstructions` (verbatim, preserved for restoration):

  ```
  Rewrite the draft answer below in Posey's voice — warm, direct, slightly irreverent without being snarky. The output text is what the user sees.

  **HARD RULES — non-negotiable. A reply that violates any of these is a FAILED reply.**

  1. **Don't add facts.** Don't change facts, don't invent specifics (dates, names, counts, prices, page numbers, roles) that aren't in the draft. If the draft says "the moderator", don't upgrade to "main author."

  2. **Don't echo the question.** FAILED: "How does fair use relate to the technology? Fair use is a legal concept that…" SUCCEEDED: "Fair use is a legal concept that…"

  3. **No preamble.** No "Here is a rewrite", "Below is the rewritten answer", "Here's my version", "Rewritten in your voice", "Sure!", "Of course!", "Great question!", "Absolutely!" Start the reply with the answer's first sentence.
  FAILED: "Here is a rewrite of the draft answer in the requested voice: The contributors are…"
  SUCCEEDED: "The contributors are…"

  4. **No outside-of-document recommendations.** The user can ask "would you recommend this book?" but the document can't answer that — neither can you. Stick to what the document says.
  FAILED: "Yeah, I'd definitely recommend this book."
  SUCCEEDED: "The document doesn't make a recommendation. It does cover X, Y, and Z if those interest you."

  5. **No metaphors describing the document's people, topics, or events.** This is the single most common voice failure.
  FAILED: "Mark Friedlander is like the DJ in the room"
  FAILED: "the methodology is like a dance"
  FAILED: "it's a wild party of legal arguments"
  Voice comes from sentence rhythm, not "X is like Y."

  6. **Match the draft's length.** A six-word draft becomes a six-to-twelve-word voice rewrite, not three paragraphs. Voice doesn't need more words.

  7. **Don't soften certainty.** If the draft is confident, you're confident. No "I think…" when the draft is sure.

  8. **Preserve any inline `[N]` citation markers.** They're load-bearing UI elements — keep them on the same factual claim.

  HOW TO HIT THE VOICE:
  - Use contractions ("It's", "doesn't").
  - Restructure sentences for rhythm: "X is Y" → "It's Y." or "Y — that's what X is."
  - Natural openers when they fit: "So,…", "Yeah,…", "Basically,…", "It's…", "There's…". Don't force them.
  - Mirror the draft's structure: list-of-six → list-of-six.
  - Don't use markdown headers; lists are fine when the draft is a list.

  Three good rewrites:

  Draft: "The methodology needs a moderator because it involves sequential questioning and a two-round response process."
  Voice: "It's because the methodology runs on sequential questioning and a two-round response process — somebody has to keep that on track."

  Draft: "The authors are Mark Friedlander, ChatGPT, Claude, and Gemini."
  Voice: "Four contributors: Mark Friedlander, ChatGPT, Claude, Gemini."

  Draft: "Mark Friedlander describes his role as a moderator and is referred to as Your Humble Moderator in the document."
  Voice: "He calls himself the moderator — specifically, 'Your Humble Moderator.'"

  Each rewrite changes sentence shape WITHOUT inventing facts, padding, metaphors, or preamble.

  Write the answer.
  ```

- `AskPoseyPromptBuilder.proseInstructions` (verbatim, the grounded prompt that now ships answers to the user directly — must carry voice burden going forward):

  ```
  You are Posey, a quiet, focused reading companion answering questions about a specific document.

  **HARD RULES — non-negotiable. A reply that violates any of these is a FAILED reply.**

  1. **NEVER FABRICATE.** Your only sources are the excerpts below and the conversation history. If the answer isn't there, say "The document doesn't say." DO NOT guess names, dates, places, organizations, characters, prices, page numbers, or quotes. Inventing something plausible is the worst possible failure mode — it sounds right but isn't.

  2. **NEVER USE OUTSIDE KNOWLEDGE.** If the user asks "who is Joe Malik" and the excerpts don't establish that, say so. Don't fall back to what you might know from training data about a similarly-named person. Confusing a fictional character with a real-world person of the same name is a common failure.

  3. **NAMES IN YOUR ANSWER MUST APPEAR IN THE EXCERPTS.** If you mention a person, place, or organization, that name must appear verbatim in the DOCUMENT EXCERPTS (or the conversation history, if the user mentioned it earlier). If you can't ground a name, drop it.

  3a. **DON'T INVENT RELATIONSHIPS, BUT DO REPORT STATED ONES.** If the excerpts EXPLICITLY assert a relationship in plain language ("X is a Y", "X presented at Y", "X published by Y", "X causes Y", "X because Y"), report it directly — that's the answer. Don't refuse out of caution when the relationship is on the page. What's forbidden: inferring a relationship that isn't asserted. Two names appearing near each other do not automatically have a relationship; a chapter/section title that resembles a thing does not make that thing exist. FAILED: question "what conference was this presented at?" → answer "presented at the 'Embracing Collaboration' conference" when "Embracing Collaboration" is just a section heading. SUCCEEDED: "The document doesn't mention a conference." ALSO SUCCEEDED: question "why did the team stop tightening the prompt?" → answer "Six iterations confirmed they had hit the ceiling." when the doc literally says that. Don't refuse just because the question contains the word "why."

  4. **DON'T ECHO THE PROMPT.** No section labels in the output. No "ANSWER:" tags. Just the answer.

  5. **NEVER RECOMMEND.** If the user asks "should I read this?" or "is this worth reading?" or "would you recommend this?" — you cannot answer that. The document doesn't make a recommendation about itself, and neither can you. Don't say "you should read this", "this is a fantastic introduction", "great companion for X", "perfect for beginners", "worth your time". REQUIRED form: "The document doesn't make a recommendation. It does cover [X, Y, Z from the actual text] if those interest you." — list real topics from the excerpts. This rule overrides any urge to be helpful — being honest is more helpful here.

  Reply in plain prose. The user's question may use different vocabulary from the document (e.g. "authors" when the document says "contributors") — map to the closest concept the excerpts establish. Front matter (title, abstract, TOC, contributor list) usually answers "who wrote this" / "what is this about" — use it when present. If the user is following up on an earlier exchange, use the conversation history. Use lists only when the question is structurally asking for one.
  ```

- Revisit when:
  - AFM (Apple Foundation Models) ships a model revision with materially better instruction-following on style/voice prompts. Check the OS minor releases of iOS 19 / 20 etc. for AFM model bumps.
  - OR a third-party on-device model becomes available (Apple opens up other models, or a competing on-device LLM with better voice fidelity ships) — at which point the polish call could route to that model instead of AFM.
  - OR the polish prompt gets a fundamentally different design (e.g. few-shot pattern matching against a curated voice corpus rather than rule enumeration). Open question; not pursued now.
- Source: Mark's directive 2026-05-04. "Remove the polish call entirely. The voice layer is not consistently achievable with the current model and is actively harming answer quality. This is not a permanent decision — it's the right call for now."

## 2026-05-02 — Local API Is The Full Remote-Control Surface

- Status: Accepted
- Decision: The local API exposed by `LocalAPIServer` and dispatched by `LibraryViewModel.executeAPICommand` must be able to do anything a human user can do that isn't blocked by Apple security policies. This is a standing standard, not a one-time goal — every new user-visible action ships with a corresponding API verb the same session it lands.
- Rationale: Mark's directive 2026-05-02 — "The API must be able to do everything a human can do that isn't blocked by Apple security policies. That includes moving the reader to a specific position, scrolling, tapping any button, and reading the screen. If those endpoints don't exist, build them. That is your first job before any verification. Do not work around missing API capability — fix it." Without this standard, autonomous verification (the testing infrastructure that lets Claude Code drive end-to-end checks instead of asking Mark to tap things) silently degrades into "verified what was easy, deferred what wasn't." The API surface IS the verification surface.
- Surface (current verbs):
  - Reader navigation: `READER_GOTO`, `READER_DOUBLE_TAP`, `READER_STATE`, `JUMP_TO_PAGE`, `OPEN_DOCUMENT`, `LIBRARY_NAVIGATE_BACK`
  - Playback transport: `PLAYBACK_PLAY`, `PLAYBACK_PAUSE`, `PLAYBACK_NEXT`, `PLAYBACK_PREVIOUS`, `PLAYBACK_RESTART`, `PLAYBACK_STATE`
  - Sheet opens: `OPEN_NOTES_SHEET`, `OPEN_PREFERENCES_SHEET`, `OPEN_TOC_SHEET`, `OPEN_AUDIO_EXPORT_SHEET`, `OPEN_SEARCH_BAR`, `DISMISS_SHEET`
  - Annotations: `CREATE_NOTE`, `CREATE_BOOKMARK`, `LIST_SAVED_ANNOTATIONS`, `TAP_SAVED_ANNOTATION`, `TAP_JUMP_TO_NOTE`, `SCROLL_NOTES`
  - Ask Posey: `/ask`, `/open-ask-posey`, `TAP_ASKPOSEY_ANCHOR`, `CLEAR_ASK_POSEY_CONVERSATION`
  - Preferences: `SET_VOICE_MODE`, `SET_RATE`, `SET_FONT_SIZE`, `SET_READING_STYLE`, `SET_MOTION_PREFERENCE`
  - Search: `SEARCH`, `SEARCH_NEXT`, `SEARCH_PREVIOUS`, `SEARCH_CLEAR`
  - Audio export: `EXPORT_AUDIO`, `AUDIO_EXPORT_STATUS`, `AUDIO_EXPORT_FETCH` (all headless — no UI surface required)
  - Discovery / observability: `LIST_DOCUMENTS`, `GET_TEXT`, `GET_PLAIN_TEXT`, `LIST_TOC`, `LIST_IMAGES`, `GET_IMAGE`, `LIST_REMOTE_TARGETS`, `READ_TREE`, `SCREENSHOT`, `DB_STATS`, `state`
  - Generic interaction: `TAP`, `TYPE`
  - Lifecycle: `RESET_ALL`, `DELETE_DOCUMENT`, `ANTENNA_OFF` (re-enable is user-consent-only)
- Architecture: every verb posts a `NotificationCenter` intent with a documented `userInfo` shape. The matching SwiftUI view observes the intent via `.onReceive` and performs the equivalent of the user action — same path a tap would take. Notification names live in `RemoteControl.swift`. State (`READER_STATE`, `PLAYBACK_STATE`) reads from `RemoteControlState.shared`, a `@MainActor` cache that observed views write into.
- Standing rule: every PR adding a user-visible button, gesture, slider, or sheet must include the matching verb. "Tested manually" is not a substitute. The audit gate (CLAUDE.md "Three Hats") is satisfied only when API verification passes alongside on-device verification.

## 2026-05-02 — RemoteTargetRegistry For Generic Tap Dispatch (Option C)

- Status: Accepted
- Decision: A central `@MainActor` registry (`RemoteTargetRegistry.shared`) maps stable string ids to `() -> Void` action closures. The SwiftUI view modifier `.remoteRegister(_:action:)` registers on `.onAppear`, unregisters on `.onDisappear`, and sets `.accessibilityIdentifier(_:)` for VoiceOver / UI-test parity. The `TAP:<id>` API verb fires the registered closure first; falls back to UIView-tree accessibility-id walk for any UIKit-level elements that didn't register through the modifier.
- Rationale: SwiftUI's `.accessibilityIdentifier(_:)` does not reliably bridge through to either the underlying UIView's `accessibilityIdentifier` property or the `accessibilityElements` chain on iOS 26 — empirically the live UIView tree returns 0 surfaced ids despite 304 nodes walked. Walking the tree to find views by identifier therefore can't drive SwiftUI buttons. Three options were considered:
  - **(A) Keep building intent-specific verbs forever.** Works for known actions but doesn't scale — the API ends up needing a new verb every time a button ships, and "every button" is the standard.
  - **(B) Use UIAccessibilityCustomActions.** Heavier, requires per-view setup, doesn't expose action discoverability.
  - **(C) Custom registry where each tappable view registers itself with a stable id.** Decouples the dispatch surface from SwiftUI's accessibility plumbing entirely. Discoverable via `LIST_REMOTE_TARGETS`. Selected.
- Implementation: every Button replaces `.accessibilityIdentifier("foo")` with `.remoteRegister("foo") { sameClosureTheButtonFires() }` — same closure, same semantics, registered under the same id the accessibility identifier used to be. Non-tap controls (sliders, pickers, text fields, status labels) keep `.accessibilityIdentifier` because they have dedicated SET_* / TYPE / READ_TREE verbs for value changes; registering a tap closure for them would be semantically wrong.
- Standing rule: every interactive control ships with `.remoteRegister` matching its accessibility id. New buttons: registry-first.

## 2026-05-02 — libimobiledevice and pymobiledevice3 — Installed But Not In Active Use

- Status: Accepted (informational)
- Decision: During Task 1 setup we attempted to enable autonomous device screenshots so Claude Code could capture verification artifacts from Mark's iPhone without manual intervention. Two tools were installed during that attempt; neither is in active use. We are documenting them so a future contributor (or a future Claude Code session) can find and remove them if desired.
- Tools installed:
  - `libimobiledevice` — installed via `brew install libimobiledevice`. Provides `idevicescreenshot`, `ideviceinfo`, `ideviceimagemounter`, etc. Location: `/opt/homebrew/bin/`.
  - `pymobiledevice3` — installed via `pipx install pymobiledevice3` (after `brew install pipx`). Modern Apple-aligned Python tooling for iOS 17+ device interaction. Location: `~/.local/bin/pymobiledevice3`.
- Why neither works for our use case:
  - `idevicescreenshot` returns "Could not start screenshotr service: Invalid service" on iOS 17+. Apple moved the screen-capture service out of the lockdown-service surface; the legacy service no longer exists on the device.
  - `pymobiledevice3 developer dvt screenshot` requires `pymobiledevice3 remote tunneld` to be running, which itself requires `sudo` to bind privileged ports. Claude Code's bash sandbox cannot run `sudo` non-interactively, so tunneld can't be started autonomously.
- What's currently in use instead: simulator screenshots (via the `ios-simulator` MCP) for layout verification, `qa_battery.sh` + `/ask` for AFM pipeline verification, and Mark's own eyes on the iPhone for final visual sign-off. This hybrid approach was chosen over the alternatives of (a) requiring Mark to start `sudo tunneld` interactively each session, or (b) installing tunneld as a `LaunchDaemon` for persistent root operation.
- Inert status: neither tool started any background services, modified system files, installed launchd entries, or required keychain credentials. They sit on disk doing nothing.
- To remove if desired:
  - `brew uninstall libimobiledevice` (and optionally its dependencies: `libimobiledevice-glue`, `libplist`, `libusbmuxd`, `libtatsu`, `libtasn1`)
  - `pipx uninstall pymobiledevice3` (and optionally `brew uninstall pipx` if not needed elsewhere)
- Source: Mark's directive 2026-05-02 — "Drop the autonomous device screenshot pursuit. We're going with the hybrid approach… Document the install in DECISIONS.md."

## 2026-05-01 — Ask Posey: App Owns The Context, Not The Model

- Status: Accepted
- Decision: For every Ask Posey call, the `LanguageModelSession` is constructed fresh, used once, and discarded. The app assembles the entire prompt body via `AskPoseyPromptBuilder` from explicit inputs; AFM never carries a transcript across calls. Even within a single sheet open, no state accumulates inside the model — the prompt builder rebuilds the full envelope per turn.
- Rationale: Complete control and observability. We know exactly what the model sees on every turn — every byte traces back to either an explicit caller input or a section the builder generated from one. We know the per-section token budget, what got dropped, which RAG chunks contributed. None of that is possible if AFM manages its own session context. This makes the 60/25/15 budget split (or whatever it tunes to) meaningful and enforceable, enables fact-verification (checking AFM's claims against the chunks actually injected), and makes the local-API tuning loop's "what did the model see, what got dropped, where did answers fall short" view possible.
- Implementation:
  - Per-call lifecycle: `AskPoseyService.streamProseResponse` constructs `LanguageModelSession(model:instructions:)`, runs one `streamResponse` round-trip, returns when the stream terminates. The session goes out of scope and is deallocated.
  - All conversation history flows through the prompt builder. Recent verbatim turns load from `ask_posey_conversations` (M5+); older turns will summarize into a cached `is_summary = 1` row (M6); even older turns become semantically retrievable (M6+).
  - `AskPoseyPromptOutput.combinedForLogging` records exactly what the model effectively saw — instructions + body — for the local-API tuning loop. Persisted as `full_prompt_for_logging` per assistant turn.
  - Drop priority is explicit: oldest RAG chunks first → conversation summary → oldest STM turns → surrounding context → user-question truncation. System framing + anchor are non-droppable. Each drop records a `DroppedSection` with section identifier and human-readable reason.
- Alternatives considered:
  - Persistent `LanguageModelSession` reused across turns within a sheet: rejected — AFM's transcript management is opaque, would couple our context-window enforcement to whatever AFM decides to keep, and would silently break the "we know exactly what the model sees" property the moment AFM's policy shifts.
  - "Context manager middleware" that wraps a persistent session and decides per-call what to inject: rejected — same opacity problem one layer up. The trustworthy boundary is "every prompt is built from scratch, by us, every call."
  - Letting the model decide what context it needs (function-calling pattern): rejected for v1 — adds a round-trip + cognitive cost the focused passage-grounded use case doesn't need. Reconsider when the surface widens beyond passage / document / annotation.
- Source: Mark's directive 2026-05-01 ("Kill the LanguageModelSession after every response. Do not use a persistent session and rely on AFM's own context management."). Hal blocks 17 / 18 / 20.1 / 21 / 7.5 served as the proven example of this approach at scale; Posey adapts the principle without copying the code (Posey is per-document, not global; budget split differs; RAG is over document chunks, not conversation memory).

## 2026-05-01 — Ask Posey: Conversation History Is Permanent, Not Session-Scoped

- Status: Accepted
- Decision: Prior Ask Posey conversations for a document persist in `ask_posey_conversations` indefinitely. Closing the sheet does not discard the conversation. Reopening the sheet for the same document reaches into the table and loads recent verbatim turns into the prompt builder; older turns summarize (M6); even older are semantically retrievable (M6+).
- Rationale: A reading companion has to remember. The product promise — Posey is a friend who read the same book and never loses the thread, even if you put it down for a week and pick it up at a different chapter — depends on history that survives across sessions. Without persistence, every sheet open is a stranger, and the prompt builder's STM window has nothing to fill it with. The 60/25/15 budget split is meaningful only if we can actually fill the verbatim/summary/RAG slots from real history.
- Implementation:
  - Schema: `ask_posey_conversations` carries 14 columns (M1's 9 + M5's 5: `intent`, `chunks_injected`, `full_prompt_for_logging`, `embedding`, `embedding_kind`). `ON DELETE CASCADE` on the document_id FK ensures rows die when the document is removed; otherwise they live forever.
  - View model: `AskPoseyChatViewModel.init(documentID:...)` queries `askPoseyTurns(for:limit:)` on init; `historyBoundary` marks where prior history ends and this-session additions begin.
  - UI: prior conversation renders above an "Earlier conversation" divider; anchor at the boundary; this-session messages below — iMessage pattern. The user lands on the anchor; prior context is above the fold, scroll up to find it. Invisible unless looked for, always there if wanted.
  - Persistence: every send writes the user turn immediately (so a crash mid-stream preserves what was asked); every successful stream completion writes the assistant turn with full metadata (chunks JSON + full prompt body for the local-API tuning loop).
- Alternatives considered:
  - Session-scoped chat (M4 default): rejected — breaks the product promise.
  - History stored only per-thread (a "thread" surface like Hal's): deferred — passage-scoped invocation in M5 is naturally per-document; threading within a document can return as a UX layer in a later milestone if the conversation volume warrants it. The schema accommodates threading (timestamp + metadata) without restructuring.
- Source: Mark's correction 2026-05-01 ("Conversation history is permanent, not session-scoped").

## 2026-05-01 — Ask Posey: Document RAG Is M5 Infrastructure, Not An M6 Enhancement

- Status: Accepted
- Decision: The full prompt-builder architecture — including the `documentChunks` slot, the RAG section rendering, the cosine-dedup hooks, and the drop priority for chunks — ships in M5, even though M5 leaves `documentChunks: []` and the RAG section renders empty. M6 turns retrieval on and fills the slot; the builder doesn't change. Same applies to `conversationSummary` — M5 accepts nil cleanly, M6's auto-summarizer fills it.
- Rationale: Document RAG is load-bearing infrastructure for Ask Posey's value, not an enhancement. Without it, the model has the anchor + a few sentences of surrounding context — that's enough to look up a word but not to answer "wait, didn't the author address this earlier?" Building the architecture in M5 means M6 is "fill in the data" rather than "restructure the system" — the builder, the budget enforcement, the drop priority, the source-attribution metadata, the test coverage all exist before the data is wired. M7's source-attribution UI reads from the same `chunksInjected` field the builder already populates.
- Implementation:
  - Builder: `RetrievedChunk` value type, `documentChunks: [RetrievedChunk]` input, MEMORY_LONG section renderer with budget enforcement and drop tracking, `chunksInjected` output. M5 always passes empty array; the section silently skips, no overhead.
  - Budget: `ragBudgetTokens: 1800` (largest allocation by design — RAG is what makes answers accurate).
  - Drop priority: oldest chunks dropped first when the budget overflows; chunks come pre-ranked by relevance (highest first), so "drop oldest" preserves the most relevant by construction.
  - Persistence: `chunks_injected` JSON column carries which chunks went in per assistant turn (M5 always `'[]'`; M6 fills); M7 reads back to render "Sources" attribution pills.
  - Auto-summarization: `AskPoseyPromptInputs.conversationSummary: String?` accepts nil cleanly; the section is rendered only when populated. M6 implements the background summarizer that fills it. **This is an explicit hard M6 blocker recorded in NEXT.md** because without it, the M5 STM window silently drops turns past ~3-4 and the "remembers everything" promise breaks at scale.
- Alternatives considered:
  - Wait for M6 to add the chunk slot, summary slot, and drop priority: rejected — this is the "fix it later" pattern that produces architectural debt. Building the right shape from M5 costs an extra evening of work and saves a refactor.
  - Skip the RAG slot in M5 entirely, add it as a single block in M6: rejected — same problem, plus the M5 token budget would tune around an empty RAG slot and need re-tuning when chunks land.
- Source: Mark's correction 2026-05-01.

## 2026-05-01 — Reading Style Is A Preferences Section, Not Separate Application Modes

- Status: Accepted
- Decision: The four reading styles — Standard, Focus, Immersive, Motion — live as options in a new "Reading Style" section of the preferences sheet. They are user-selectable preferences, not separate application modes. Switching between them updates the active reader's render path; nothing else (data model, position memory, playback semantics, notes, search, Ask Posey) changes.
- Rationale: Treating these as application modes (e.g. a top-level switcher in the chrome) would imply they're orthogonal experiences with different rules — and that's misleading, because they aren't. Each is a different way to display the same reading flow. Putting them under preferences makes them discoverable, consistent across the app, and easy to combine with other style choices (font size, voice mode) the user has already calibrated. It also keeps the reader chrome glyph-first and visually restrained per the existing reader principle.
- Implementation:
  - **Standard** — current behavior. Single highlighted active sentence, surrounding text at full opacity. Default for new users.
  - **Focus** — dim every non-active sentence to ~40–50% opacity so the eye is drawn to the brightest element. Functionally additive on top of the existing highlight tier; same data model, just a different render-path opacity rule per row.
  - **Immersive** — slot machine / drum roll scroll. Active sentence centered at full size and brightness; sentences above and below fade out and scale down with distance from center. Higher implementation cost (custom layout + per-row transform driven by distance-from-center).
  - **Motion** — large single centered sentence optimized for walking / driving / hands-free reading. Inherits the three-setting Off / On / Auto behavior captured in the next decision.
- Alternatives considered:
  - Cycle through styles via a chrome glyph: rejected — adds chrome surface for a setting users don't change often, and obscures discoverability for new users.
  - Make them per-document: rejected — most users want a consistent reading style across their library; per-document settings invite forgetting which doc has which style. Per-doc font size already exists; bundling reading style with it would expand a per-doc surface that should stay narrow.

## 2026-05-01 — Motion Mode Three-Setting Design (Off / On / Auto, With Consent)

- Status: Accepted
- Decision: When the Reading Style is set to Motion, three sub-settings let the user control when it activates: **Off** (never), **On** (always), **Auto** (Posey monitors device motion via CoreMotion and switches automatically between Motion and the user's last non-Motion style). Auto requires explicit user consent before enabling CoreMotion monitoring — a clear opt-in screen explains why motion data is needed and that it stays on-device.
- Rationale: Different users want different things from a "motion mode."
  - Some want the large-single-sentence presentation regardless of whether they're moving (low vision, hands-free preference).
  - Some want it only when they're physically moving and the standard reader becomes hard to track.
  - Some never want it and prefer their chosen style at all times.
  A single auto-detect setting can't serve all three. Three explicit settings respect each user's preference fully — manual use while still, manual use while moving, or fully automatic switching — without forcing one model on everyone.
- Consent semantics: Auto is the only setting that activates CoreMotion. The opt-in screen is shown the first time the user picks Auto and never again unless the user revokes consent in Settings. Posey reads only the high-level "device is moving" signal; raw acceleration / orientation data never leaves the app. CoreMotion monitoring is paused when the app is backgrounded and resumed on foreground; battery cost is negligible at the polling rate needed for "is the user walking?" detection.
- Alternatives considered:
  - Two settings (Off / Auto) with no manual-On: rejected — denies the use case of users who want Motion as their default style regardless of movement.
  - One global "Motion mode toggle" outside the Reading Style: rejected — Motion mode IS a reading style, not orthogonal to one. Putting it elsewhere would invite "what happens if Motion is on AND I'm in Focus" confusion.
  - Auto without opt-in: rejected — silently enabling motion data collection without explicit consent is a privacy violation. Even though the data stays on-device, the user must understand and agree before Posey starts reading from CoreMotion.

## 2026-05-01 — Dev Tools Compiled Out Of Release Builds, Not Just Defaulted Off

- Status: Accepted
- Decision: All development infrastructure — Local API server, antenna icon, dev toggles, test harnesses, AFM probe, hardcoded device IDs, test mode environment variables, anything else added for development convenience — must be **compiled out** of the release binary entirely via `#if DEBUG` guards (or a separate build configuration that excludes those source files). Users picking up Posey from the App Store must have no idea this infrastructure exists. All code remains in the codebase for development builds.
- Rationale:
  - **Security.** A reachable Local API server in the release binary is a real attack surface even if defaulted off. A malicious app could try to flip the toggle, scan for the listener, or exploit any parsing bug. Compiled-out means no listener code runs, ever, in release.
  - **Professionalism.** Hidden toggles, antenna icons, hardcoded device IDs, and "TEST MODE" overlays signal "internal-build software," not a polished product. Even if users never find them, the code shipping with them is shipping baggage.
  - **App Store integrity.** Apple's review explicitly looks for development affordances in release builds. Local API servers in particular have triggered rejections.
  - **Predictability.** With a `#if DEBUG` discipline, developers know that `release == what users see`. No "I forgot to disable that toggle" classes of bug.
- Implementation:
  - Wrap dev-only code in `#if DEBUG` ... `#endif` so it doesn't reach the release binary.
  - Where a feature has a debug surface AND a release surface (e.g. the antenna's `localAPIEnabled` `@AppStorage`), the AppStorage entry stays but the code that observes it and starts the listener is `#if DEBUG`-only.
  - The AFM probe XCTest stays in the test target — XCTest bundles aren't shipped to users — so no special handling needed there.
  - Document each guarded surface in the file with a brief comment so the next contributor knows why the gate exists.
- Alternatives considered:
  - Default-off with a hidden toggle: rejected — code still ships, surface still exists, attack surface still exists. Mark called this out specifically: "Antenna default flipped to OFF for release" is necessary but not sufficient.
  - Separate "Development" target: rejected as M9's mechanism — adds maintenance overhead (every code change needs to think about target membership). `#if DEBUG` is simpler and gets the same outcome.
  - Server-side feature flags: rejected — Posey is offline. There IS no server.

## 2026-05-01 — Every Commit Pushes To origin/main Immediately

- Status: Accepted (operational policy)
- Decision: Every commit gets pushed to `origin/main` immediately — "commit and push" is one action, not two. There are no exceptions: if you committed it, you push it. If a push fails, fix the cause now and push before moving on.
- Rationale: At one point this session there were 21 commits sitting locally, ahead of `origin/main`. Local-only commits are invisible to Claude (claude.ai), invisible to anyone else who picks up the repo, and one bad day away from being lost. The cost of pushing every commit is nearly zero; the cost of not pushing is permanently losing work or coordination context. This is also load-bearing for the three-party collaboration model: Claude (claude.ai) syncs from GitHub, so unpushed commits make CC's work invisible to the rest of the team in practice.
- Implementation: CLAUDE.md "Golden Rules" rule 5 spells this out, and the "After every meaningful commit" checklist now ends with "Push to `origin/main` immediately."

## 2026-05-01 — Ask Posey Embeddings Are Multilingual From Day One

- Status: Accepted
- Decision: The Ask Posey embedding index detects each document's language at import time using `NLLanguageRecognizer` and selects the matching `NLEmbedding.sentenceEmbedding(for:)`. English is the fallback when the detected language has no shipped sentence-embedding model; Hal's hash embedding is the final fallback so import never silently breaks. Multilingual support is part of v1, not a follow-up.
- Rationale: Mark's revised answer to plan question 12.3 — "Posey already supports multilingual documents, AFM is multilingual, and the fix is not complicated. English-only is a shortcut that creates unnecessary technical debt. Don't take it." Posey's Gutenberg corpus already includes French and German samples; the synthetic corpus has Latin/Cyrillic/Greek/Arabic/CJK fixtures; ignoring that at the embedding layer would build in a known regression on day one.
- Implementation: Per-row `embedding_kind` column on `document_chunks` records which model produced each embedding (`en-sentence`, `fr-sentence`, ..., `hash-fallback`) so a future model upgrade can re-index just the rows that need it.
- Alternatives considered:
  - English-only with a follow-up multilingual pass: rejected per Mark's direction. The follow-up never feels urgent because it isn't broken-broken; the cost is a permanent quality ceiling on non-English material.
  - One universal embedding model: rejected — `NLEmbedding` is per-language. No universal option in the native stack.

## 2026-05-01 — Ask Posey Spec Supersedes Earlier ARCHITECTURE/CONSTITUTION Wording On Persistence

- Status: Accepted (confirmed by Mark 2026-05-01 in approval of `ask_posey_implementation_plan.md`)
- Decision: When `ask_posey_spec.md` (2026-05-01) and the older Ask Posey sections in `ARCHITECTURE.md` / `CONSTITUTION.md` disagree, the spec wins. Conversations persist per document in a new `ask_posey_conversations` SQLite table and auto-save to notes. ARCHITECTURE.md "Ask Posey Architecture" and CONSTITUTION.md "Ask Posey — on-device AI reading assistance" have been rewritten to match the spec (Milestone 1 commit, 2026-05-01).
- Rationale: CLAUDE.md is explicit that "the docs win and the code needs updating — or the docs need a deliberate revision. Do not let the code drift silently from the documented intent." A persisted, auto-saving model is materially different from a transient one — different schema, different UI affordances, different RAG capabilities. The spec is the deliberate, dated revision; the older docs were superseded.

## 2026-05-01 — TOC Region Is Completely Hidden From The Reading View

- Status: Accepted
- Decision: Any region marked by `playbackSkipUntilOffset` (today: PDF Tables of Contents) is completely invisible in the reader's data model — not in `segments`, not in `displayBlocks`, not reachable by playback, scroll, search, or restart-from-beginning. The region is not "skipped past on first open"; it's never present in the reading flow at all. The TOC remains accessible only via the navigation sheet (chrome TOC button), which surfaces parsed entries.
- Rationale: Mark's spec was unambiguous: "completely invisible … never scrollable, never read aloud, never reachable via navigation including rewind." A first-open-only skip was half a fix — rewind, search, scroll, and any other path back into the region kept producing the same poor listening experience the skip was meant to prevent. Filtering at the data-model boundary makes the invariant impossible to violate by construction.
- Implementation: filter `segments` and `displayBlocks` in `ReaderViewModel.init` based on `document.playbackSkipUntilOffset`. Segment IDs are re-numbered 0-based to preserve the rest of the view-model's "segment.id is an array index" assumption. Character offsets on remaining segments/blocks are kept in the original plainText coordinate space so position persistence is unchanged. `restoreSentenceIndex` migrates saved offsets that land inside the hidden region to segment 0 (first body sentence).
- Alternatives considered:
  - Keep TOC visible but mark it as a "skip-on-playback" region only: rejected — half-fix per Mark's spec.
  - Render TOC as a collapsed/hidden expandable section in the reader: rejected — adds UI complexity for a region whose purpose is navigation, not reading.

## 2026-05-01 — Detect PDF Tables of Contents at Import; Skip on Playback, Surface as Navigation

- Status: Accepted
- Decision: PDFs that contain a Table of Contents on an early page (anchor phrase + high dot-leader density) are detected at import time. The TOC region's character offset range is persisted on the document, and the reader auto-skips past it on first open so TTS doesn't read the TOC aloud. Detected entries populate the existing TOC sheet for navigation.
- Rationale: Reading a TOC aloud is a uniformly poor listening experience — "Table of Contents I. Introduction. Three. Two. Technology. Six…" is just noise. The TOC has a clear structural purpose (navigation surface) but no value as audio. Detecting it at import lets us deliver something useful: open a PDF, hear the body content, navigate the chapter list visually when needed.
- Heuristics chosen for precision over recall: a page is only a TOC page if it has BOTH the anchor phrase ("Table of Contents" or standalone `Contents`) AND at least 5 dot-leader entries. False-positives — silently skipping real content — are far worse than missing an unusual TOC, so the detector errs toward leaving content alone when in doubt. Limit search to the first 5 pages for the same reason.
- Entry parsing is best-effort. The regex tolerates roman numerals, capital letters, digits, and lowercase letters as outline labels; embedded dots in titles ("RIAA v. mp3.com") are accepted. Exotic formats may produce partial titles or be skipped; that's acceptable because the skip-on-playback behavior is the primary value and entries are a secondary navigation aid.
- Alternatives considered:
  - Skip the TOC without parsing entries: rejected — leaves the user with a non-functional TOC button when entries are present.
  - Mark TOC as a "visual stop" so playback pauses and the user manually advances: rejected — that just reverses the problem (now playback always halts at the TOC instead of always reading it).
  - Detect TOC only by header text and skip the entire first page unconditionally: rejected — many PDFs have title pages, copyright pages, or front-matter that's not a TOC; we'd silently drop real content.

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
