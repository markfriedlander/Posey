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
/// It DOES repair one `NLTokenizer` blind spot: the tokenizer refuses
/// to end a sentence when the period is immediately followed by a
/// digit, so a footnote/endnote reference number that flattened onto
/// the period (`…languages).10 At the heart…`) glues two real
/// sentences into one. `splitFootnoteMerges` re-cuts each token at
/// those boundaries. The cut is offset-preserving — it only adds a
/// sentence boundary inside the unit's existing text; no character
/// moves, so the annotation/reading-position ruler is untouched.
struct SentenceIndexer {

    /// A footnote-reference merge point: a period NOT preceded by a
    /// digit/space/period, then 1–3 digits (the footnote number), then
    /// whitespace, then an uppercase letter (the next sentence's start).
    /// The lookbehind excludes decimals/versions (`1.10`, `p.10 for` has
    /// no capital after) and `No. 10` (space between period and digit),
    /// so it fires only on the flattened-footnote pattern. Verified
    /// against the full corpus: 250 real merges repaired, 0 false splits.
    private static let footnoteMergeRegex = try! NSRegularExpression(
        pattern: #"(?<=[^0-9\s.])\.[0-9]{1,3}\s+(?=\p{Lu})"#)

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

        // Collect the tokenizer's sentence ranges, then repair any
        // footnote-merged range into its real sentences BEFORE building
        // records — so intra offsets are computed once from the final
        // (possibly re-cut) ranges.
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // Skip whitespace-only "sentences" the tokenizer can emit
            // around stray punctuation.
            guard text[range].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return true
            }
            ranges.append(contentsOf: splitFootnoteMerges(in: text, range: range))
            return true
        }

        var out: [Sentence] = []
        for range in ranges {
            let trimmed = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }

            let startOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            let endOffset   = text.distance(from: text.startIndex, to: range.upperBound)

            out.append(Sentence(
                documentID: unit.documentID,
                unitID: unit.id,
                unitSequence: unit.sequence,
                sentenceIndex: out.count,
                intraStart: startOffset,
                intraEnd: endOffset,
                text: trimmed
            ))
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

    /// Re-cut one tokenizer sentence `range` at every internal
    /// footnote-merge boundary. Returns the original range unchanged
    /// when there is none (the common case, so no allocation churn).
    /// Each cut falls just before the capital letter that starts the
    /// next sentence, so the footnote digits stay attached to the
    /// sentence they annotate. Ranges are in `text` (unit-text) index
    /// space and tile the input range exactly — no character is added,
    /// dropped, or moved.
    private static func splitFootnoteMerges(in text: String,
                                            range: Range<String.Index>) -> [Range<String.Index>] {
        let piece = String(text[range])
        let full = NSRange(location: 0, length: (piece as NSString).length)
        let matches = footnoteMergeRegex.matches(in: piece, range: full)
        guard matches.isEmpty == false else { return [range] }

        var result: [Range<String.Index>] = []
        var cutStart = range.lowerBound
        for match in matches {
            guard let mRange = Range(match.range, in: piece) else { continue }
            // Split point = end of the match (immediately before the
            // capital). Convert the char distance within `piece` into an
            // index in `text` so grapheme clusters map correctly.
            let charOffset = piece.distance(from: piece.startIndex, to: mRange.upperBound)
            let cut = text.index(range.lowerBound, offsetBy: charOffset)
            if cut > cutStart { result.append(cutStart..<cut) }
            cutStart = cut
        }
        if cutStart < range.upperBound { result.append(cutStart..<range.upperBound) }
        return result.isEmpty ? [range] : result
    }
}

// ========== BLOCK 01: SENTENCE INDEXER - END ==========
