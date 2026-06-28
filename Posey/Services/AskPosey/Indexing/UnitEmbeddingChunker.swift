import Foundation
import NaturalLanguage

// ========== BLOCK 01: UNIT EMBEDDING CHUNKER - START ==========

/// Builds the retrieval chunk set for a document by walking its
/// `ContentUnit` list (the canonical content store after the
/// architecture rebuild) and emitting overlap-windowed slices
/// anchored to `(start_unit_id, start_intra_offset, end_unit_id,
/// end_intra_offset)` coordinates.
///
/// **Why this shape:** the legacy chunker sliced
/// `documents.plain_text`, anchoring chunks to character offsets
/// in a derived string. That held the legacy `plain_text` column
/// in the critical path for RAG. Unit-anchored chunks let us
/// drop the derived column in Step 10 and give Tier 2/3 enhancement
/// a precise per-unit regeneration scope (instead of "rebuild
/// every chunk for the document").
///
/// **Embeddings:** the chunker emits chunks with `embedding = nil`.
/// Filling them in is the next caller's responsibility — typically
/// `enqueueIndexing` posts the chunks then walks back through
/// `unitEmbeddingChunksNeedingEmbedding` to embed under the active
/// `EmbeddingProvider` backend. This keeps the chunking transaction
/// short and lets the embedding work happen off the DB's
/// single-thread.
///
/// **Window sizing:** 400 **chars** / 50-char overlap, sentence-aware, for ALL
/// document sizes (see `Configuration.default`). Matches Hal's proven
/// `createMentatChunks` value — which is 400 *characters* (verified: Hal
/// measures `sentence.count`), NOT tokens. **CAVEAT (Mark, 2026-06-19):** Hal's
/// 400 is proven for chunking *conversations* (short, self-contained turns);
/// Posey chunks *documents* (continuous prose where meaning spans paragraphs),
/// so the size is genuinely OPEN for our domain — a first-class variable to
/// MEASURE in the retrieval-tuning phase (alongside the embedder + small-to-big
/// retrieval expansion), not inherit. See NEXT.md.
///
/// 2026-05-23 — introduced as part of the Hal-based Ask Posey
/// rebuild (Step 8b).
struct UnitEmbeddingChunker {

    // MARK: - Configuration

    struct Configuration: Sendable {
        let chunkSize: Int
        let chunkOverlap: Int

        // 2026-05-30 — sentence-aware sizing. Hal's proven `createMentat
        // Chunks` value is 400 chars / 50 overlap for ALL document sizes.
        // The prior adaptive 1000-char window for long docs was MEASURED
        // (RAG_DEBUG + FIND_CHUNK on Pride & Prejudice) to dilute key
        // passages — the famous Darcy "tolerable" line was buried, intact,
        // inside a 1000-char chunk and never ranked for the natural
        // question. Sentence-aware chunking makes size far less
        // length-dependent (a chunk is a small group of whole sentences
        // regardless of doc length), so a single tight size is correct.
        static let `default` = Configuration(chunkSize: 400, chunkOverlap: 50)
        static let longDocumentThresholdChars: Int = 200_000

        /// All document sizes use the same sentence-aware 400/50 config now.
        /// `adaptive` is retained for call-site compatibility.
        static func adaptive(forCharacterCount count: Int) -> Configuration {
            _ = count
            return .default
        }
    }

    // MARK: - Public surface

    /// Build the chunk set for `documentID` given its ordered unit
    /// list. Returns chunks with `embedding = nil`. Callers persist
    /// via `DatabaseManager.replaceAllUnitEmbeddingChunks` then
    /// fill in embeddings asynchronously.
    /// Exclude front matter + editorial prose from the RAG/embedding chunk pool.
    ///
    /// ════════════════════════════════════════════════════════════════════════
    /// THE POSITION RULE (decided 2026-06-28, Mark + CC) — the law this obeys:
    ///   **Between layers, a position is referenced by IDENTITY — the content
    ///   unit's UUID + its `sequence` order — NEVER by a raw character offset.**
    ///   A character offset is legal ONLY *inside one unit* (e.g. a word range
    ///   for read-along), never as the currency that crosses between the
    ///   importer / chunker / reader. Offsets are derived projections (which
    ///   units count as prose, the "\n\n" join) and DRIFT per document when two
    ///   layers recompute them differently — that drift destroyed Dracula's
    ///   chapters 14–27 (the back-trim, removed 2026-06-28). A unit's identity
    ///   does not drift. See ASK_POSEY_TUNING_PLAN.md "THE RULER PROBLEM".
    /// ════════════════════════════════════════════════════════════════════════
    ///
    /// 2026-06-28 — Front-skip is now IDENTITY-based. We drop prose units ordered
    /// before `skipUnitID` (the importer's stored content-start anchor — the SAME
    /// anchor the reader windows on, `ReaderView` filtering sentences by
    /// `unitSequence < skipUnitSequence`). So the RAG pool's content-start now
    /// matches the reader's EXACTLY, for every format, by construction — no
    /// importer-space-vs-chunker-space offset arithmetic. (Replaces the old
    /// `skipOffset`/`skipSource` path, which compared the importer's plainText
    /// offset against the chunker's prose-join walk — the front cousin of the
    /// back-trim bug.) `skipUnitID == nil` (e.g. Markdown, read-from-beginning)
    /// drops no front matter, matching the reader.
    ///
    /// `editorialUnitIDs` (by `EditorialFrontMatterDetector`) additionally drops
    /// EDITORIAL prose — a critic's/publisher's preface discussing the book + its
    /// author (e.g. Saintsbury's P&P preface) — wherever it sits. Also identity.
    /// Authorial front matter (Frankenstein's Letters, Moby's Etymology) scores
    /// ~0 and is never in the set, so it stays.
    ///
    /// The trailing Project Gutenberg license will be dropped by a future
    /// content-based trailer detector (identity, like the editorial one). Until
    /// then it may leak into the pool — the lesser evil vs. deleting real chapters.
    nonisolated static func excludingFrontMatter(
        _ units: [ContentUnit],
        skipUnitID: UUID?,
        editorialUnitIDs: Set<UUID> = []
    ) -> [ContentUnit] {
        // Resolve the content-start anchor (identity) to its order. Units before
        // it are front matter; the anchor unit itself is the first real content.
        let skipSequence: Int? = skipUnitID.flatMap { id in
            units.first(where: { $0.id == id })?.sequence
        }
        let doEditorial = !editorialUnitIDs.isEmpty
        guard skipSequence != nil || doEditorial else { return units }
        var kept: [ContentUnit] = []
        kept.reserveCapacity(units.count)
        for unit in units {
            // Front: drop prose units ordered before the content-start unit.
            // (Non-prose pre-skip units produce no chunks, so they pass through.)
            if let s = skipSequence, unit.kind.carriesProseText, unit.sequence < s {
                continue
            }
            // Editorial: drop prose units inside a detected editorial block.
            if doEditorial && editorialUnitIDs.contains(unit.id) { continue }
            kept.append(unit)
        }
        return kept
    }

    static func chunks(
        for documentID: UUID,
        units: [ContentUnit],
        configuration: Configuration? = nil
    ) -> [StoredUnitEmbeddingChunk] {
        // ── 1. Project units onto a flat character ribbon, tracking
        //   which unit each character belongs to and its intra-offset
        //   inside that unit. Only prose-bearing units contribute
        //   (image/pageBreak/horizontalRule add no text and don't
        //   anchor chunks).
        var flatText = ""
        var unitIDPerChar: [UUID] = []
        var intraOffsetPerChar: [Int] = []

        var totalProseChars = 0
        for unit in units where unit.kind.carriesProseText {
            totalProseChars += unit.text.count
        }

        let config = configuration
            ?? Configuration.adaptive(forCharacterCount: totalProseChars)

        flatText.reserveCapacity(totalProseChars + units.count * 2)
        unitIDPerChar.reserveCapacity(totalProseChars + units.count * 2)
        intraOffsetPerChar.reserveCapacity(totalProseChars + units.count * 2)

        var first = true
        for unit in units where unit.kind.carriesProseText {
            // Separate units with `\n\n` (matches the persister's
            // plainText join). The separator characters get
            // associated with the unit they BELONG TO for offset
            // purposes — i.e. the separator that precedes a unit
            // is owned by the *previous* unit's end. This keeps
            // boundary-spanning chunks well-defined.
            if !first {
                let prevUnitID = unitIDPerChar.last!
                let prevIntra = intraOffsetPerChar.last! + 1
                flatText.append("\n\n")
                unitIDPerChar.append(prevUnitID)
                intraOffsetPerChar.append(prevIntra)
                unitIDPerChar.append(prevUnitID)
                intraOffsetPerChar.append(prevIntra + 1)
            }
            first = false

            let text = unit.text
            flatText.append(text)
            for i in 0..<text.count {
                unitIDPerChar.append(unit.id)
                intraOffsetPerChar.append(i)
            }
        }

        guard !flatText.isEmpty else { return [] }

        // ── 2. SENTENCE-AWARE windowing (2026-05-30).
        //
        // Previously a pure character-offset sliding window cut chunks at
        // exact `chunkSize` positions — mid-sentence, even mid-word — and
        // long docs used a 1000-char window. RAG_DEBUG + FIND_CHUNK on
        // Pride & Prejudice showed the cost: the famous "She is tolerable,
        // but not handsome enough to tempt me" line lived INTACT inside a
        // 1000-char chunk alongside the Bingley/Darcy lead-in, an embedded
        // "[Copyright 1894...]" artifact, and the aftermath — so the
        // chunk's averaged embedding washed the key sentence's signal out;
        // it ranked #1 only when queried with its own words, and vanished
        // for the reader's natural question. Hal's proven strategy
        // (`createMentatChunks`: ~400 chars, sentence-aware, whole-sentence
        // overlap) isolates a passage into a tighter, less-diluted unit.
        // Ported here onto Posey's unit-anchored ribbon: cut at sentence
        // boundaries; map each chunk's char span to (unit, intra-offset)
        // via the same per-char arrays, so jump-back / enhancement scope
        // are unchanged. Smaller chunks also help BM25 precision and let
        // AFM's scarce ~2-chunk budget hold tighter passages.
        let totalChars = flatText.count

        // Sentence boundaries in flat-ribbon char-offset space. Offsets
        // accumulate between consecutive token ranges so the whole pass is
        // O(n), not O(n²) on distance(from:).
        var sentenceBounds: [(start: Int, end: Int)] = []
        do {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = flatText
            var prevIndex = flatText.startIndex
            var prevOffset = 0
            tokenizer.enumerateTokens(in: flatText.startIndex..<flatText.endIndex) { range, _ in
                let startOff = prevOffset + flatText.distance(from: prevIndex, to: range.lowerBound)
                let endOff = startOff + flatText.distance(from: range.lowerBound, to: range.upperBound)
                if endOff > startOff { sentenceBounds.append((startOff, endOff)) }
                prevIndex = range.upperBound
                prevOffset = endOff
                return true
            }
        }
        // Degenerate fallback: no sentence structure → one chunk for the
        // whole ribbon (rare; e.g. a single token-less unit).
        if sentenceBounds.isEmpty {
            sentenceBounds = [(0, totalChars)]
        }

        let target = config.chunkSize
        let overlap = config.chunkOverlap
        var chunks: [StoredUnitEmbeddingChunk] = []
        var chunkIndex = 0
        var i = 0

        func emit(_ startOff: Int, _ endOff: Int) {
            let s = max(0, startOff)
            let e = min(endOff, totalChars)
            guard e > s else { return }
            let startCharIdx = flatText.index(flatText.startIndex, offsetBy: s)
            let endCharIdx = flatText.index(flatText.startIndex, offsetBy: e)
            let slice = String(flatText[startCharIdx..<endCharIdx])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !slice.isEmpty else { return }
            chunks.append(StoredUnitEmbeddingChunk(
                id: UUID(),
                documentID: documentID,
                chunkIndex: chunkIndex,
                startUnitID: unitIDPerChar[s],
                startIntraOffset: intraOffsetPerChar[s],
                endUnitID: unitIDPerChar[e - 1],
                endIntraOffset: intraOffsetPerChar[e - 1],
                text: slice,
                embedding: nil
            ))
            chunkIndex += 1
        }

        while i < sentenceBounds.count {
            let chunkStart = sentenceBounds[i].start
            // Grow the chunk one whole sentence at a time up to `target`.
            // Always include at least the first sentence (a single
            // over-long sentence becomes its own chunk).
            var j = i
            while j + 1 < sentenceBounds.count,
                  sentenceBounds[j + 1].end - chunkStart <= target {
                j += 1
            }
            let chunkEnd = sentenceBounds[j].end
            emit(chunkStart, chunkEnd)

            if j + 1 >= sentenceBounds.count { break }

            // Overlap: next chunk begins with the trailing whole sentences
            // of this one that fit within `overlap` chars. Bounded below by
            // i+1 so we always advance.
            var k = j + 1
            while k - 1 > i, chunkEnd - sentenceBounds[k - 1].start <= overlap {
                k -= 1
            }
            // 2026-06-19 (Mark) — FORWARD-PROGRESS GUARD (fixes duplicate
            // micro-chunks). Without this, a short heading sentence ("CHAPTER
            // I.") followed by a long sentence (Dickens's famous opening run-on)
            // produced DUPLICATE chunks: this chunk could grow no further than
            // the heading (the next sentence overflows `target`), then the
            // overlap pulled the start back onto that same heading, and the
            // following chunk REPLAYED the identical short sentences — observed
            // on A Tale of Two Cities, where "CHAPTER I.\nThe Period" was emitted
            // 2+ times. Hal never hit this: it carries overlap FORWARD as a
            // prefix and always consumes NEW sentences, whereas our index-based
            // window could step backward onto an already-emitted run. (And this
            // is a DOCUMENT problem — headings interleaved with long prose — that
            // barely arises in Hal's short conversational turns.)
            //
            // Fix: the next chunk MUST extend beyond sentence j (this chunk's
            // last). If sentence j+1 won't fit within `target` starting from the
            // overlap point k, the overlap would only replay [k…j] as a redundant
            // subset — so drop the overlap and start the next chunk AT j+1 (the
            // long sentence becomes its own chunk; the heading stays only here).
            // This makes chunk END offsets strictly increasing → no chunk is a
            // subset of another → no duplicates.
            if sentenceBounds[j + 1].end - sentenceBounds[k].start > target {
                k = j + 1
            }
            i = k
        }

        return chunks
    }
}

// ========== BLOCK 01: UNIT EMBEDDING CHUNKER - END ==========
