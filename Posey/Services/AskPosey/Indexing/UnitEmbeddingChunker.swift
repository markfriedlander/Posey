import Foundation

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
/// **Window sizing:** mirrors the legacy adaptive sizing — 500 chars
/// with 50-char overlap for short/medium docs, 1000 chars with
/// 100-char overlap for documents over 200K chars. Hal-shaped (Hal
/// uses a single ~400-token window) — Posey keeps the adaptive
/// split because Hal's QA showed long documents benefit from
/// scene-level chunks while short ones benefit from precision.
///
/// 2026-05-23 — introduced as part of the Hal-based Ask Posey
/// rebuild (Step 8b).
struct UnitEmbeddingChunker {

    // MARK: - Configuration

    struct Configuration: Sendable {
        let chunkSize: Int
        let chunkOverlap: Int

        static let `default` = Configuration(chunkSize: 500, chunkOverlap: 50)
        static let longDocument = Configuration(chunkSize: 1000, chunkOverlap: 100)
        static let longDocumentThresholdChars: Int = 200_000

        /// Pick the right config for a document by total prose
        /// length. Mirrors `DocumentEmbeddingIndexConfiguration
        /// .adaptive(forCharacterCount:)` exactly so users see the
        /// same chunk granularity they're used to.
        static func adaptive(forCharacterCount count: Int) -> Configuration {
            count >= longDocumentThresholdChars ? .longDocument : .default
        }
    }

    // MARK: - Public surface

    /// Build the chunk set for `documentID` given its ordered unit
    /// list. Returns chunks with `embedding = nil`. Callers persist
    /// via `DatabaseManager.replaceAllUnitEmbeddingChunks` then
    /// fill in embeddings asynchronously.
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

        // ── 2. Slide a window of `chunkSize` chars with
        //   `chunkOverlap` overlap and emit chunks. Step =
        //   chunkSize - chunkOverlap; defensive minimum of 1 so we
        //   always make progress.
        let step = max(config.chunkSize - config.chunkOverlap, 1)
        let totalChars = flatText.count
        var chunks: [StoredUnitEmbeddingChunk] = []
        var chunkIndex = 0
        var cursor = 0

        while cursor < totalChars {
            let endExclusive = min(cursor + config.chunkSize, totalChars)
            let startCharIdx = flatText.index(flatText.startIndex, offsetBy: cursor)
            let endCharIdx = flatText.index(flatText.startIndex, offsetBy: endExclusive)
            let slice = String(flatText[startCharIdx..<endCharIdx])

            let startUnitID = unitIDPerChar[cursor]
            let startIntra = intraOffsetPerChar[cursor]
            let endUnitID = unitIDPerChar[endExclusive - 1]
            let endIntra = intraOffsetPerChar[endExclusive - 1]

            chunks.append(StoredUnitEmbeddingChunk(
                id: UUID(),
                documentID: documentID,
                chunkIndex: chunkIndex,
                startUnitID: startUnitID,
                startIntraOffset: startIntra,
                endUnitID: endUnitID,
                endIntraOffset: endIntra,
                text: slice,
                embedding: nil
            ))
            chunkIndex += 1

            if endExclusive >= totalChars { break }
            cursor += step
        }

        return chunks
    }
}

// ========== BLOCK 01: UNIT EMBEDDING CHUNKER - END ==========
