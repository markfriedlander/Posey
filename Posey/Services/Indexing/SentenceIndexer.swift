import Foundation
import NaturalLanguage

// ========== BLOCK 01: SENTENCE INDEXER - START ==========

/// Produces `Sentence` rows from `ContentUnit`s by running
/// `NLTokenizer` on each prose-bearing unit's text. This is the
/// "pre-segment at import" half of the architecture rebuild — what
/// used to be the slow `NLTokenizer` pass at reader-open time now
/// runs once at import time and persists, so the open path is
/// sub-second on any-size document.
///
/// The indexer is intentionally simple. It does not attempt the
/// merge-numbered-list-markers or cap-oversized-segments work that
/// the legacy `SentenceSegmenter` did — content units already
/// carry list markers as metadata (the marker isn't in the text
/// stream), and each unit is one paragraph so oversized segments
/// are vanishingly rare. If a unit's text contains no sentence
/// boundaries `NLTokenizer` finds, the entire unit becomes a single
/// sentence — appropriate fallback for one-line paragraphs and
/// short headings.
///
/// 2026-05-23 — introduced as part of the architecture rebuild.
struct SentenceIndexer {

    /// Run `NLTokenizer` over one unit's text and return the
    /// sentence records that should be persisted. Sentences are
    /// 0-indexed within the unit. `intra_start` / `intra_end` are
    /// character offsets within `unit.text`.
    ///
    /// For non-prose-bearing units (image / page break / horizontal
    /// rule) this returns an empty array — those units don't
    /// contribute to the playback queue.
    static func sentences(for unit: ContentUnit) -> [Sentence] {
        guard unit.kind.carriesProseText else { return [] }
        guard !unit.text.isEmpty else { return [] }

        let text = unit.text
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var out: [Sentence] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let raw = text[range]
            // Skip whitespace-only "sentences" the tokenizer can emit
            // around stray punctuation.
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return true }

            let startOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            let endOffset   = text.distance(from: text.startIndex, to: range.upperBound)

            out.append(Sentence(
                documentID: unit.documentID,
                unitID: unit.id,
                unitSequence: unit.sequence,
                sentenceIndex: out.count,
                intraStart: startOffset,
                intraEnd: endOffset,
                text: String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            return true
        }

        // Fallback: tokenizer found no boundaries. Treat the whole
        // unit text as one sentence. Common for one-line paragraphs,
        // short headings, list items.
        if out.isEmpty {
            out.append(Sentence(
                documentID: unit.documentID,
                unitID: unit.id,
                unitSequence: unit.sequence,
                sentenceIndex: 0,
                intraStart: 0,
                intraEnd: text.count,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return out
    }

    /// Convenience: index every unit in the given list and return
    /// the concatenated sentence array. Sentences are emitted in
    /// (unit-sequence, sentence-index) order — the same order
    /// `DatabaseManager.sentences(for:)` returns when reading back.
    static func sentences(for units: [ContentUnit]) -> [Sentence] {
        var out: [Sentence] = []
        for unit in units {
            out.append(contentsOf: sentences(for: unit))
        }
        return out
    }
}

// ========== BLOCK 01: SENTENCE INDEXER - END ==========
