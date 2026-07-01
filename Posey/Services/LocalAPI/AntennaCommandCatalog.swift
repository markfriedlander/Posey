// ===== BLOCK 01: ANTENNA COMMAND CATALOG - START =====
//
// 2026-06-19 — Self-describing catalog of every /command verb, so CC
// (and any future operator) can DISCOVER the full antenna surface at
// runtime via the HELP verb instead of grepping source. Built after a
// live failure: GET_ENHANCEMENT_STATUS existed but was unfindable among
// 150+ verbs, so a diagnosis went temporarily blind. A drift guard
// (tools/check_antenna_catalog.sh) asserts this list matches the actual
// switch cases, so the API can never silently grow a verb HELP omits.
//
// This is documentation data, not behavior — adding/removing a verb in
// LibraryView REQUIRES a matching edit here (the guard enforces it).

import Foundation

nonisolated enum AntennaCommandCategory: String, Sendable, CaseIterable {
    case annotations
    case ask_posey
    case audio_export
    case control
    case document
    case enhancement
    case indexing
    case models
    case prefs
    case reader
    case retrieval
    case system
    case tts
    case ui_nav
}

nonisolated struct AntennaCommand: Sendable {
    let verb: String
    let category: AntennaCommandCategory
    let usage: String
    let summary: String
    init(_ verb: String, _ category: AntennaCommandCategory, _ usage: String, _ summary: String) {
        self.verb = verb; self.category = category; self.usage = usage; self.summary = summary
    }
}

nonisolated enum AntennaCommandCatalog {
    /// Every /command verb. Keep in sync with the LibraryView dispatch
    /// switch — tools/check_antenna_catalog.sh fails the gate otherwise.
    static let all: [AntennaCommand] = [
        .init("HELP", .system, "HELP | HELP:<verb> | HELP:<category-or-substring>", "Self-describing catalog of every /command verb. Start here when you don't know which verb to use."),
        .init("LIST_COMMANDS", .system, "LIST_COMMANDS", "Alias of HELP — full verb catalog."),
        .init("LIST_DOCUMENTS", .document, "LIST_DOCUMENTS", "List every imported document with id + title."),
        .init("GET_TEXT", .document, "GET_TEXT", ""),
        .init("GET_PLAIN_TEXT", .document, "GET_PLAIN_TEXT", "Return a document's full plain text."),
        .init("EXTRACT_METADATA", .enhancement, "EXTRACT_METADATA", ""),
        .init("DELETE_DOCUMENT", .document, "DELETE_DOCUMENT", ""),
        .init("RESET_ALL", .system, "RESET_ALL", ""),
        .init("SEED_ASK_POSEY_FIXTURE", .ask_posey, "SEED_ASK_POSEY_FIXTURE:<doc-id>", ""),
        .init("SET_LLM", .models, "SET_LLM:<modelID> or SET_LLM:<alias>", "Switch the active answer model. Alias: gemma|qwen|llama|dolphin (or full id)."),
        .init("GENERATE", .models, "GENERATE:<prompt>", "Raw active-LLM generation: NO retrieval, NO grounding, NO doc — the prompt is one user turn through the model's chat template. For HyDE Phase-1c (on-device hypothetical-answer generation) + direct model-behavior probes."),
        .init("MEMORY_STATS", .system, "MEMORY_STATS", "Read-only: available process memory + which embedder backends are resident + active LLM/embedder. For the sustained-generation jetsam investigation (confirm embedder+LLM co-residency, measure EVICT deltas)."),
        .init("EVICT_EMBEDDER", .system, "EVICT_EMBEDDER[:<nl|nomic|mxbai|all>]", "Release loaded embedder bundle(s) to drop peak memory (proposed jetsam fix: free the embedder after retrieval, before generation). Lazy-reloads on next embed. Reports reclaimed MB."),
        .init("GET_LLM", .models, "GET_LLM", "The active answer model (id, display name, context window)."),
        .init("SET_PROMPT_VARIANT", .ask_posey, "SET_PROMPT_VARIANT:current|rebalanced", "Flip the Ask Posey prose variant for the A/B (in-memory; resets on relaunch)."),
        .init("GET_PROMPT_VARIANT", .ask_posey, "GET_PROMPT_VARIANT", "The active Ask Posey prose variant (current|rebalanced)."),
        .init("SET_NEIGHBOR_EXPANSION", .retrieval, "SET_NEIGHBOR_EXPANSION:<0-10>", "Small-to-big retrieval radius — chunks expanded on each side of a retrieved winner (0 = off). In-memory; a knob for the embedder A/B/C sweep."),
        .init("GET_NEIGHBOR_EXPANSION", .retrieval, "GET_NEIGHBOR_EXPANSION", "Current small-to-big neighbor radius + the model-derived RAG token budget, the sweep override (if any), and the effective value."),
        .init("SET_RAG_TOKEN_BUDGET", .retrieval, "SET_RAG_TOKEN_BUDGET:<200-16000|auto>", "A/B/C sweep knob: force the neighbor-expansion RAG token ceiling independent of the active model; ':auto' clears it back to the model-derived budget. In-memory."),
        .init("SET_QUERY_EXPANSION", .retrieval, "SET_QUERY_EXPANSION", ""),
        .init("SET_EMBEDDING_PROVIDER", .retrieval, "SET_EMBEDDING_PROVIDER", ""),
        .init("GET_EMBEDDING_PROVIDER", .retrieval, "GET_EMBEDDING_PROVIDER", "Active embedding backend (Nomic / fallback)."),
        .init("CANCEL_EMBEDDING_MIGRATION", .retrieval, "CANCEL_EMBEDDING_MIGRATION", ""),
        .init("EMBEDDING_COVERAGE", .retrieval, "EMBEDDING_COVERAGE[:docs]", "Per-backend column coverage (filled/missing/total) across the corpus; :docs adds per-document gaps. Read-only."),
        .init("VALIDATE_EMBEDDINGS", .retrieval, "VALIDATE_EMBEDDINGS[:<nl|nomic|mxbai|all>]", "Read-only health spot-check on STORED vectors: samples up to 200 random rows per backend and reports dim/all-finite/zero-norm/min-max-norm + healthy flag. Proves the backfill wrote real embeddings, not garbage."),
        .init("SEARCH_CHUNKS", .retrieval, "SEARCH_CHUNKS:<documentID>|<query words>", "Read-only BM25 search over ONE document's stored chunk text; returns the actual indexed text of the top matches. For A/B answer-key authoring (pull verbatim defining-passages from Posey's own extraction, esp. PDFs) + harness debugging."),
        .init("ASK_POSEY_TURN_STATS", .retrieval, "ASK_POSEY_TURN_STATS:<documentID>", "Read-only: user/assistant turn count for a doc vs. how many carry an active-backend embedding. Verifies the conversation-memory embed-at-save."),
        .init("RECALL_TURNS", .retrieval, "RECALL_TURNS:<documentID>|<query>", "Read-only probe of the hybrid conversation-turn recall (Part B): embeds the query + runs cosine+BM25 RRF over the doc's past turns, no STM exclusion. Returns the recalled turns + rrf scores."),
        .init("SET_MEMORY_DEPTH", .retrieval, "SET_MEMORY_DEPTH:<1-50|auto>", "Override the verbatim STM depth in EXCHANGES (':auto' = per-model default). Makes conversation-recall testable with short conversations + sweepable in the A/B/C. In-memory."),
        .init("BACKFILL_EMBEDDINGS", .retrieval, "BACKFILL_EMBEDDINGS:<nl|nomic|mxbai|all>", "Fill an INACTIVE backend's column for the whole corpus, non-locking + paced (Ask Posey stays up on the active backend). Prereq for embedder A/B/C. Poll BACKFILL_STATUS."),
        .init("BACKFILL_STATUS", .retrieval, "BACKFILL_STATUS", "Current backfill phase (running/done/error/idle) + processed/total."),
        .init("CANCEL_BACKFILL", .retrieval, "CANCEL_BACKFILL", "Cancel an in-flight embedding backfill; still-NULL rows stay NULL and resume on a later BACKFILL_EMBEDDINGS."),
        .init("EMBEDDER_LOADTEST", .retrieval, "EMBEDDER_LOADTEST[:<hf-repo-id>]", "GATE: headlessly load a candidate embedder via swift-embeddings' Bert path (default mxbai) and verify a finite normalizable vector + dim, before building a backend. Poll EMBEDDER_LOADTEST_STATUS."),
        .init("EMBEDDER_LOADTEST_STATUS", .retrieval, "EMBEDDER_LOADTEST_STATUS", "Result of the last EMBEDDER_LOADTEST (state/dim/allFinite/l2Norm/sample/loadMs/encodeMs/error)."),
        .init("DOWNLOAD_MODEL", .models, "DOWNLOAD_MODEL:<modelID> (full repo path).", ""),
        .init("DELETE_MODEL", .models, "DELETE_MODEL:<known-model-id>", ""),
        .init("MODEL_DOWNLOAD_STATE", .models, "MODEL_DOWNLOAD_STATE:<model-id>", "Download/availability state for an MLX model id."),
        .init("SET_SPOILER_CATCHER_ENGINE", .ask_posey, "SET_SPOILER_CATCHER_ENGINE:<mlx|afm>", ""),
        .init("GET_SPOILER_CATCHER_ENGINE", .ask_posey, "GET_SPOILER_CATCHER_ENGINE", "Active spoiler-catcher engine (mlx|afm)."),
        .init("SET_SPOILER_PROTECTION", .ask_posey, "SET_SPOILER_PROTECTION:<doc-id>:<on|off>", "Toggle spoiler protection for a doc."),
        .init("SET_READING_POSITION", .control, "SET_READING_POSITION:<doc>:<offset>", "Force a doc's reading/furthest offset (spoiler-line tests)."),
        .init("REINDEX_DOCUMENT", .indexing, "REINDEX_DOCUMENT:<doc-id>", "Re-chunk + re-embed a doc directly (bypasses PDF enhancement). The fast path to (re)build the index."),
        .init("REPARSE_PDF", .indexing, "REPARSE_PDF:<doc-id>", "Re-run the IMPORT (unit-construction) phase on a PDF from its saved source, replacing units/sentences/TOC in place (same id). Verifies importer fixes without re-sending the file. Pairs with REINDEX_DOCUMENT (embeddings) + REBUILD_RAPTOR_TREE."),
        .init("RESET_DOCUMENT_METADATA", .enhancement, "RESET_DOCUMENT_METADATA", ""),
        .init("EXTRACT_METADATA_NOW", .enhancement, "EXTRACT_METADATA_NOW", ""),
        .init("RUN_METADATA_CHAIN", .enhancement, "RUN_METADATA_CHAIN", ""),
        .init("INDEXING_STATE", .indexing, "INDEXING_STATE", "In-flight embed/RAPTOR progress per doc (the serial queue's view)."),
        .init("THERMAL_STATE", .system, "THERMAL_STATE", "Device thermal state (nominal/fair/serious/critical)."),
        .init("HALT_INDEXING", .indexing, "HALT_INDEXING", "Escape switch: halt all background indexing + clear the suspect index."),
        .init("REBUILD_INDEXING", .indexing, "REBUILD_INDEXING", "Re-enqueue all pending docs through the paced queue (after a halt)."),
        .init("SET_BACKGROUND_PREP", .indexing, "SET_BACKGROUND_PREP:<on|off>", "Gentle, NON-destructive pause/resume of background prep (same master toggle as the board switch; NOT the heavy HALT). Quiet the phone before an install/screenshot, then resume."),
        .init("SET_KEEP_ORIGINALS", .indexing, "SET_KEEP_ORIGINALS:<on|off>", "Toggle 'Keep original documents' (Advanced screen). ON retains a PDF's saved source after enhancement so any phase can be re-run (REPARSE_PDF etc.)."),
        .init("GET_KEEP_ORIGINALS", .indexing, "GET_KEEP_ORIGINALS", "Current 'Keep original documents' state (on|off)."),
        .init("ENHANCE_CHUNK_NOW", .enhancement, "ENHANCE_CHUNK_NOW", ""),
        .init("RETRY_REFUSED", .retrieval, "RETRY_REFUSED", ""),
        .init("LIST_REFUSED_CHUNKS", .document, "LIST_REFUSED_CHUNKS", ""),
        .init("LIST_ENHANCED_CHUNKS", .enhancement, "LIST_ENHANCED_CHUNKS", ""),
        .init("LIST_UNITS_SUMMARY", .document, "LIST_UNITS_SUMMARY:<doc-id>", "Unit kind-counts (prose/heading/image/page_break) + samples. Confirms a doc parsed into units."),
        .init("READER_OBSERVATION", .reader, "READER_OBSERVATION", ""),
        .init("GET_ENHANCEMENT_STATUS", .enhancement, "GET_ENHANCEMENT_STATUS:<doc-id>", "PDF enhancement state: status, tier2/tier3 progress, queue position, error. Read this to see why a PDF sits at 'Preparing'."),
        .init("LIST_AFM_CORRECTIONS", .retrieval, "LIST_AFM_CORRECTIONS:<doc-id>", ""),
        .init("HEAVY_LANE_STATUS", .indexing, "HEAVY_LANE_STATUS", "Heavy-work lane concurrency + completed count."),
        .init("HEAVY_LANE_RESET", .indexing, "HEAVY_LANE_RESET", ""),
        .init("LIST_PAGE_FLAGS", .document, "LIST_PAGE_FLAGS", ""),
        .init("GET_DOCUMENT_METADATA", .document, "GET_DOCUMENT_METADATA", "Read a doc's bibliographic metadata (title/authors/year)."),
        .init("LIST_SYNTHETIC_CHUNKS", .document, "LIST_SYNTHETIC_CHUNKS", ""),
        .init("LIST_UNIT_CHUNKS", .document, "LIST_UNIT_CHUNKS:<doc-id>", "Per-doc chunk totals + embeddings filled/null. The truth for embedding progress."),
        .init("LIST_CHUNKS", .document, "LIST_CHUNKS", ""),
        .init("BUILD_RAPTOR_TREE", .indexing, "BUILD_RAPTOR_TREE:<doc-id>:<k>:<maxChunks>", "Build the RAPTOR summary tree for a doc (DEBUG slice: first <maxChunks> leaves, k clusters). For a faithful full rebuild use REBUILD_RAPTOR_TREE."),
        .init("RAPTOR_SUMMARIZE_TEST", .indexing, "RAPTOR_SUMMARIZE_TEST:<doc-id>:<k>:<maxChunks>", ""),
        .init("DUMP_RAPTOR_TREE", .retrieval, "DUMP_RAPTOR_TREE:<doc-id>[,<doc-id>...] | all", "Read-only FULL-TEXT dump of every RAPTOR summary node for one doc, a comma-separated GROUP, or all — audit trees for contamination (front-matter / other-book leakage) + factual errors. No model, no query."),
        .init("RAPTOR_TREE_STATS", .retrieval, "RAPTOR_TREE_STATS", "Read-only library-wide audit: per-document embedded-leaf + RAPTOR summary-node counts. Triage which docs have trees before dumping one."),
        .init("CLEAR_RAPTOR_TREE", .indexing, "CLEAR_RAPTOR_TREE:<doc-id>[,<doc-id>...] | all", "Remove ALL RAPTOR summary nodes for one doc, a GROUP, or all (leaves untouched) + cancel any in-flight build. Clean slate to test a front-matter fix before REBUILD."),
        .init("REBUILD_RAPTOR_TREE", .indexing, "REBUILD_RAPTOR_TREE:<doc-id>[,<doc-id>...] | all", "Clear then enqueue the PRODUCTION RaptorTreeService build for one doc, a GROUP, or all (serial + thermally paced; not the debug slice). Then BACKFILL_EMBEDDINGS:all for other embedder columns."),
        .init("EXPORT_EMBEDDINGS", .retrieval, "EXPORT_EMBEDDINGS:<doc-id>[:<maxCount>]", ""),
        .init("LIST_HEADINGS", .document, "LIST_HEADINGS:<doc-id>", ""),
        .init("FIND_CHUNK", .retrieval, "FIND_CHUNK", ""),
        .init("EMBED_QUERY_CONTEXTUAL", .retrieval, "EMBED_QUERY_CONTEXTUAL", ""),
        .init("EMBED_QUERY", .retrieval, "EMBED_QUERY", "Embed a query string and return its vector."),
        .init("RAG_TRACE", .retrieval, "RAG_TRACE", "Full retrieval trace for a query (BM25+semantic RRF fusion, scores)."),
        .init("RAG_FIND", .retrieval, "RAG_FIND", ""),
        .init("RAG_DEBUG", .retrieval, "RAG_DEBUG", "Retrieved chunks for a query against a doc."),
        .init("RAG_EVAL", .retrieval, "RAG_EVAL:<doc-id>:<query>", "Embedder A/B/C Phase-1 (model-free): runs the EXACT chat retrieval path (active embedder + SET_NEIGHBOR_EXPANSION radius + model-aware budget + 0.40 floor) and returns the FULL stitched context the model would read, for answer-key substring hit-testing. No LLM, no heat, no AFM cooldown."),
        .init("RAG_DEBUG_EXPANDED", .retrieval, "RAG_DEBUG_EXPANDED", ""),
        .init("GET_ASK_POSEY_HISTORY", .ask_posey, "GET_ASK_POSEY_HISTORY:<doc-id>[:<limit>]", "The persisted Ask Posey conversation turns for a doc."),
        .init("LIST_CONVERSATION_CITED_PASSAGES", .ask_posey, "LIST_CONVERSATION_CITED_PASSAGES:<doc-id>", "Read-only: every passage a conversation CITED for a doc (offset + owning conversation storage id). The data behind the bidirectional conversation glyphs."),
        .init("RESOLVE_GLYPHS", .ask_posey, "RESOLVE_GLYPHS:<doc-id>", "Read-only: for every glyph (note/bookmark/anchor/cited) report stored offset (raw) vs the offset AnchorRefinder re-finds it to (refined) + moved. Run before/after SIMULATE_FUSION_FIX to prove each glyph tracks its words (the one placement system)."),
        .init("CLEAR_NOTES", .annotations, "CLEAR_NOTES:<doc-id>", "Wipe ALL notes + bookmarks for a doc (clean slate for testing; does not touch conversations)."),
        .init("SIMULATE_ANNOTATE_SELECTION", .annotations, "SIMULATE_ANNOTATE_SELECTION:<surfaceStart>:<surfaceLen>:<note|bookmark|ask>", "TEST: set the open reader's text selection to that SURFACE range and fire the REAL selection-menu path (Note/Bookmark/Ask Posey). Verify with RESOLVE_GLYPHS that the new glyph's anchorText == the SELECTED words (WYSIWYG selection anchoring)."),
        .init("SET_NOTE_DRAFT", .annotations, "SET_NOTE_DRAFT:<text>", "TEST: populate the open note editor's draft WITHOUT jumping (preserves a stashed selection anchor) → then TAP:notes.save persists a note on the selection."),
        .init("DB_STATS", .system, "DB_STATS", "Database row counts across tables."),
        .init("CLEAR_ASK_POSEY_CONVERSATION", .ask_posey, "CLEAR_ASK_POSEY_CONVERSATION", "Wipe a doc's Ask Posey conversation (clean memory between A/B arms)."),
        .init("GET_IMAGE", .document, "GET_IMAGE", ""),
        .init("LIST_IMAGES", .document, "LIST_IMAGES", ""),
        .init("LIST_TOC", .document, "LIST_TOC", ""),
        .init("GET_PLAYBACK_SKIP", .tts, "GET_PLAYBACK_SKIP", ""),
        .init("LIST_SEGMENTS_MATCHING", .document, "LIST_SEGMENTS_MATCHING:<regex>", ""),
        .init("LIST_DISPLAY_BLOCKS_MATCHING", .document, "LIST_DISPLAY_BLOCKS_MATCHING:<regex>", ""),
        .init("READER_GOTO", .reader, "READER_GOTO:<docID>:<offset>", ""),
        .init("READER_DOUBLE_TAP", .reader, "READER_DOUBLE_TAP:<docID>:<offset>", ""),
        .init("EXPORT_ANNOTATIONS", .annotations, "EXPORT_ANNOTATIONS:<docID>", ""),
        .init("READER_TAP", .reader, "READER_TAP", ""),
        .init("OPEN_FIRST_IMAGE", .ui_nav, "OPEN_FIRST_IMAGE", ""),
        .init("SET_APPEARANCE", .prefs, "SET_APPEARANCE", ""),
        .init("GET_APPEARANCE", .prefs, "GET_APPEARANCE", ""),
        .init("DEBUG_SKIP", .tts, "DEBUG_SKIP:<docID>", ""),
        .init("DEBUG_ANNOTATIONS", .annotations, "DEBUG_ANNOTATIONS:<docID>", ""),
        .init("READER_CHROME_STATE", .reader, "READER_CHROME_STATE", ""),
        .init("READER_STATE", .reader, "READER_STATE", "Current reader doc + offset + visible range."),
        .init("OPEN_NOTES_SHEET", .ui_nav, "OPEN_NOTES_SHEET", ""),
        .init("RESPOND_SKIP_PROMPT", .tts, "RESPOND_SKIP_PROMPT", ""),
        .init("DISMISS_SHEET", .ui_nav, "DISMISS_SHEET", ""),
        .init("SIMULATE_BACKGROUND", .system, "SIMULATE_BACKGROUND", ""),
        .init("LIST_AUDIO_EXPORTS", .audio_export, "LIST_AUDIO_EXPORTS", ""),
        .init("GET_READER_STATE_FULL", .reader, "GET_READER_STATE_FULL", "Comprehensive reader state dump."),
        .init("LOGS", .system, "LOGS", "Recent in-app log buffer (ring; last ~200 lines)."),
        .init("CLEAR_LOGS", .system, "CLEAR_LOGS", ""),
        .init("SUBMIT_ASK_POSEY", .ask_posey, "SUBMIT_ASK_POSEY:<text>", "Drive the LIVE Ask Posey sheet's send (streams on screen as a real tap). Sheet must be open."),
        .init("SCROLL_ASK_POSEY_TO_LATEST", .ask_posey, "SCROLL_ASK_POSEY_TO_LATEST", ""),
        .init("CREATE_BOOKMARK", .annotations, "CREATE_BOOKMARK:<docID>:<offset>", ""),
        .init("CREATE_NOTE", .annotations, "CREATE_NOTE:<docID>:<offset>:<base64-body>", ""),
        .init("TAP", .ui_nav, "TAP:<accessibilityID>", ""),
        .init("TYPE", .ui_nav, "TYPE:<text>", ""),
        .init("READ_TREE", .ui_nav, "READ_TREE", "Dump the live UI VIEW hierarchy (windows + presented sheets) for tap-target discovery. NOTE: this is the UIKit view tree, NOT the RAPTOR summary tree — for that use DUMP_RAPTOR_TREE."),
        .init("SCREENSHOT", .system, "SCREENSHOT", "Capture the current screen (returns image)."),
        .init("SCREENSHOT_STABLE", .system, "SCREENSHOT_STABLE", "Capture the screen AFTER it stops moving — waits out chrome fade, search-bar slide, scroll, any in-flight animation, then snaps. Use for ALL UI verification; a plain SCREENSHOT can catch a mid-transition composite no user sees."),
        .init("SCREENSHOT_REAL", .system, "SCREENSHOT_REAL", "REAL photo of the display via ReplayKit video frames (actual composited pixels) — NOT a drawHierarchy re-render, so it can't false-green a black/frozen screen. First call starts the capture session (tap 'Allow recording' once on the phone) and may block until you do; reuses the TTS capture session if already warm; end with TTS_VERIFY_CAPTURE_STOP. DEBUG-only."),
        .init("TAP_CITATION", .ui_nav, "TAP_CITATION:<n>", ""),
        .init("TAP_ASKPOSEY_ANCHOR", .ui_nav, "TAP_ASKPOSEY_ANCHOR:<storageID>", ""),
        .init("TAP_SAVED_ANNOTATION", .annotations, "TAP_SAVED_ANNOTATION:<entryID>", ""),
        .init("SCROLL_NOTES", .ui_nav, "SCROLL_NOTES:<entryID>", ""),
        .init("TAP_JUMP_TO_NOTE", .ui_nav, "TAP_JUMP_TO_NOTE:<entryID>", ""),
        .init("PLAYBACK_PLAY", .tts, "PLAYBACK_PLAY:<docID>", ""),
        .init("PLAYBACK_PAUSE", .tts, "PLAYBACK_PAUSE:<docID>", ""),
        .init("PLAYBACK_NEXT", .tts, "PLAYBACK_NEXT:<docID>", ""),
        .init("PLAYBACK_PREVIOUS", .tts, "PLAYBACK_PREVIOUS:<docID>", ""),
        .init("PLAYBACK_RESTART", .tts, "PLAYBACK_RESTART:<docID>", ""),
        .init("PLAYBACK_STATE", .tts, "PLAYBACK_STATE", "TTS playback state for the active doc."),
        .init("OPEN_PREFERENCES_SHEET", .ui_nav, "OPEN_PREFERENCES_SHEET", ""),
        .init("SCROLL_PREFS_TO_LLM", .models, "SCROLL_PREFS_TO_LLM", ""),
        .init("SCROLL_PREFS_TO_ASK_POSEY", .ask_posey, "SCROLL_PREFS_TO_ASK_POSEY", ""),
        .init("OPEN_MODEL_LIBRARY", .models, "OPEN_MODEL_LIBRARY", ""),
        .init("OPEN_TOC_SHEET", .ui_nav, "OPEN_TOC_SHEET", ""),
        .init("OPEN_VOICE_PICKER_SHEET", .ui_nav, "OPEN_VOICE_PICKER_SHEET", ""),
        .init("TAP_TOC_ENTRY", .ui_nav, "TAP_TOC_ENTRY:<playOrder>", ""),
        .init("DEBUG_FORCE_PLAYBACK_STATE", .tts, "DEBUG_FORCE_PLAYBACK_STATE:<idle|playing|paused|finished>", ""),
        .init("OPEN_AUDIO_EXPORT_SHEET", .audio_export, "OPEN_AUDIO_EXPORT_SHEET", ""),
        .init("OPEN_SEARCH_BAR", .reader, "OPEN_SEARCH_BAR", ""),
        .init("OPEN_DOCUMENT", .ui_nav, "OPEN_DOCUMENT:<docID>", "Open the reader on a doc from any UI state."),
        .init("SCROLL_SURFACE", .ui_nav, "SCROLL_SURFACE:<fraction 0..1>", "DEBUG: scroll the open one-surface reader to a fraction of its content (frame any part for capture)."),
        .init("SIMULATE_DRAG", .ui_nav, "SIMULATE_DRAG", "TEST: simulate a user drag on the open reader → re-reveals the auto-fading chrome (scroll-to-reveal, no physical gesture needed)."),
        .init("CHROME", .ui_nav, "CHROME:<pin|fade|auto>", "TEST: pin holds the reader chrome visible (its buttons stay registered so TAP:reader.* works), fade hides it, auto restores normal auto-fade."),
        .init("SET_READALONG_LEVEL", .ui_nav, "SET_READALONG_LEVEL:<word|line|sentence|paragraph>", "TEST: set the read-along highlight granularity dial on the open reader (word/line/sentence/paragraph)."),
        .init("SURFACE_TAP_IMAGE", .ui_nav, "SURFACE_TAP_IMAGE", "TEST: tap the first image/table on the open reader → opens the full-screen viewer (image-zoom restore)."),
        .init("TAP_AT", .ui_nav, "TAP_AT:<x>,<y>", "General human-equivalent tap (points): routes to the glyph button / image / text under the point on the open reader."),
        .init("SURFACE_FONT", .ui_nav, "SURFACE_FONT:<pointSize>", "DEBUG: rebuild the open one-surface reader at a new body point size (E2 annotation re-flow durability test)."),
        .init("SIMULATE_ANCHOR_DRIFT", .ui_nav, "SIMULATE_ANCHOR_DRIFT:<docID>:<shift|break|restore>", "TEST (E2 R8): mutate the most-recent annotation's host-unit text to prove the durable anchor re-finds (shift) / flags (break), reversibly (restore). Reopen the surface after."),
        .init("SURFACE_ANNOTATE", .ui_nav, "SURFACE_ANNOTATE:<note|bookmark>:<phrase>", "TEST (E2 R8): annotate the first occurrence of a phrase in the open one-surface reader (no interactive selection needed)."),
        .init("SIMULATE_FUSION_FIX", .ui_nav, "SIMULATE_FUSION_FIX:<docID>:<original>:<corrected>", "TEST (annotation precise-repair): run the real Tier-3 replaceTokenInUnits swap to exercise its in-transaction note re-anchor."),
        .init("LIBRARY_NAVIGATE_BACK", .ui_nav, "LIBRARY_NAVIGATE_BACK", ""),
        .init("ANTENNA_OFF", .system, "ANTENNA_OFF", ""),
        .init("SET_VOICE_MODE", .tts, "SET_VOICE_MODE:<best|custom>", ""),
        .init("SET_RATE", .tts, "SET_RATE:<percentage 50..200>", ""),
        .init("SET_FONT_SIZE", .prefs, "SET_FONT_SIZE:<14..44>", ""),
        .init("SET_IMAGE_HANDLING", .prefs, "SET_IMAGE_HANDLING:<pause|skip>", ""),
        .init("JUMP_TO_PAGE", .reader, "JUMP_TO_PAGE:<docID>:<page>", ""),
        .init("SEARCH", .reader, "SEARCH:<query>", ""),
        .init("SEARCH_NEXT", .reader, "SEARCH_NEXT", ""),
        .init("SEARCH_PREVIOUS", .reader, "SEARCH_PREVIOUS", ""),
        .init("SEARCH_MATCHES", .reader, "SEARCH_MATCHES", ""),
        .init("SEARCH_CLEAR", .reader, "SEARCH_CLEAR", ""),
        .init("EXPORT_AUDIO", .audio_export, "EXPORT_AUDIO:<docID>", ""),
        .init("EXPORT_AUDIO_RANGE", .audio_export, "EXPORT_AUDIO_RANGE:<docID>:<startOffset>:<endOffset>", ""),
        .init("AUDIO_EXPORT_STATUS", .audio_export, "AUDIO_EXPORT_STATUS:<jobID>", ""),
        .init("AUDIO_EXPORT_FETCH", .audio_export, "AUDIO_EXPORT_FETCH:<jobID>", ""),
        .init("TTS_VERIFY_CAPTURE_START", .tts, "TTS_VERIFY_CAPTURE_START", ""),
        .init("TTS_VERIFY_CAPTURE_STOP", .tts, "TTS_VERIFY_CAPTURE_STOP", ""),
        .init("TTS_CAPTURE_PROBE_ENGINE", .tts, "TTS_CAPTURE_PROBE_ENGINE", ""),
        .init("TTS_VERIFY_RUN", .tts, "TTS_VERIFY_RUN:<docID>:<startSentenceIndex>:<numSentences>", ""),
        .init("TTS_VERIFY_STATUS", .tts, "TTS_VERIFY_STATUS", ""),
        .init("TTS_VERIFY_FETCH", .tts, "TTS_VERIFY_FETCH", ""),
        .init("ACTIVE_LINE_FRAME", .reader, "ACTIVE_LINE_FRAME", ""),
        .init("SELECT_TEST", .ui_nav, "SELECT_TEST", ""),
        .init("LIST_AUDIO_CACHE", .audio_export, "LIST_AUDIO_CACHE", ""),
        .init("DELETE_AUDIO_CACHE", .audio_export, "DELETE_AUDIO_CACHE:<docID>", ""),
        .init("DELETE_AUDIO_CACHE_ALL", .audio_export, "DELETE_AUDIO_CACHE_ALL", ""),
        .init("SIMULATE_AUDIO_EXPORT_BG_EXPIRATION", .audio_export, "SIMULATE_AUDIO_EXPORT_BG_EXPIRATION", ""),
        .init("BEGIN_AUDIO_EXPORT", .audio_export, "BEGIN_AUDIO_EXPORT:<docID>", ""),
        .init("AUDIO_EXPORT_NOTIFICATION_AUTH", .audio_export, "AUDIO_EXPORT_NOTIFICATION_AUTH", ""),
        .init("AUDIO_EXPORT_NOTIFICATION_PENDING", .audio_export, "AUDIO_EXPORT_NOTIFICATION_PENDING", ""),
        .init("AUDIO_EXPORT_SIMULATE_NOTIFICATION_TAP", .audio_export, "AUDIO_EXPORT_SIMULATE_NOTIFICATION_TAP:<filePath>", ""),
        .init("LIST_UTTERANCES", .tts, "LIST_UTTERANCES", ""),
        .init("RESET_UTTERANCE_LOG", .tts, "RESET_UTTERANCE_LOG", ""),
        .init("SIMULATE_FOREGROUND", .system, "SIMULATE_FOREGROUND", ""),
        .init("PLAYBACK_STOP_BLOCK_TEST", .tts, "PLAYBACK_STOP_BLOCK_TEST:<docID>", ""),
        .init("AUDIO_EXPORT_LOCK_TEST", .audio_export, "AUDIO_EXPORT_LOCK_TEST:<docID>", ""),
        .init("LIST_REMOTE_TARGETS", .system, "LIST_REMOTE_TARGETS", ""),
        .init("LIST_SAVED_ANNOTATIONS", .annotations, "LIST_SAVED_ANNOTATIONS:<docID>", ""),
    ]

    /// Render the catalog as JSON-ready text. `filter` matches a category
    /// name, a verb name, or a substring; nil → everything, grouped.
    static func help(filter: String?) -> [String: Any] {
        let f = filter?.trimmingCharacters(in: .whitespaces).uppercased()
        func matches(_ c: AntennaCommand) -> Bool {
            guard let f, !f.isEmpty else { return true }
            return c.verb.contains(f)
                || c.category.rawValue.uppercased().contains(f)
                || c.summary.uppercased().contains(f)
        }
        let hits = all.filter(matches)
        // Detail view: an exact verb match returns the single full entry.
        if let f, let exact = all.first(where: { $0.verb == f }) {
            return ["verb": exact.verb, "category": exact.category.rawValue,
                    "usage": exact.usage, "summary": exact.summary]
        }
        var byCat: [String: [[String: String]]] = [:]
        for c in hits.sorted(by: { $0.verb < $1.verb }) {
            byCat[c.category.rawValue, default: []].append(
                ["verb": c.verb, "usage": c.usage, "summary": c.summary])
        }
        return ["count": hits.count, "categories": byCat,
                "hint": "HELP:<verb> for one entry; HELP:<category-or-substring> to filter."]
    }
}
// ===== BLOCK 01: ANTENNA COMMAND CATALOG - END =====
