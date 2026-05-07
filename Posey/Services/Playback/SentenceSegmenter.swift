import Foundation
import NaturalLanguage

// ========== BLOCK 01: SEGMENTATION ENTRY POINT - START ==========

struct SentenceSegmenter {

    /// Maximum character count for a single output segment.
    /// Segments produced by NLTokenizer or the paragraph fallback that exceed
    /// this limit are sub-split via the chain in `subsplit(_:into:)`.
    ///
    /// 250 chars ≈ 40 words ≈ ~15 seconds of speech at normal rate.
    /// Tighter than the 600-char cap that landed earlier — that cap kept the
    /// synthesizer responsive enough not to crash, but pause still felt
    /// laggy in practice because each utterance held that many seconds of
    /// pre-buffered audio. Smaller utterances mean each pre-buffered chunk
    /// is short, so pause + state transitions feel instant. Read-along
    /// highlighting also benefits — shorter segments mean tighter granularity
    /// of "the active sentence."
    private static let maxSegmentLength = 250

    func segments(for text: String) -> [TextSegment] {
        guard text.isEmpty == false else {
            return []
        }

        var rawSegments: [TextSegment] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard sentence.isEmpty == false else {
                return true
            }

            let startOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            let endOffset   = text.distance(from: text.startIndex, to: range.upperBound)

            rawSegments.append(
                TextSegment(id: rawSegments.count,
                            text: sentence,
                            startOffset: startOffset,
                            endOffset: endOffset)
            )
            return true
        }

        if rawSegments.isEmpty {
            rawSegments = fallbackParagraphSegments(for: text)
        }

        return capOversized(mergeNumberedListMarkers(rawSegments))
    }

    /// 2026-05-06 (parity #4) — Merge a segment that is just a numbered
    /// list marker ("1.", "2.", "10.", …) with the segment that
    /// follows it. NLTokenizer treats the period after a digit as a
    /// sentence terminator, so an injected list prefix like "1. First
    /// numbered item" splits into ["1.", "First numbered item"]. The
    /// merge restores the visual coherence: one row per list item.
    /// Applied generally — even user-authored "1." on its own line
    /// gets merged with the following sentence, which is the expected
    /// behavior for a list.
    private func mergeNumberedListMarkers(_ segments: [TextSegment]) -> [TextSegment] {
        guard segments.count > 1 else { return segments }
        let markerPattern = try? NSRegularExpression(pattern: #"^\d+\.$"#)
        guard let regex = markerPattern else { return segments }

        var merged: [TextSegment] = []
        merged.reserveCapacity(segments.count)
        var i = 0
        while i < segments.count {
            let seg = segments[i]
            let range = NSRange(seg.text.startIndex..., in: seg.text)
            let isMarker = regex.firstMatch(in: seg.text, range: range) != nil
            if isMarker, i + 1 < segments.count {
                let next = segments[i + 1]
                merged.append(TextSegment(
                    id: merged.count,
                    text: "\(seg.text) \(next.text)",
                    startOffset: seg.startOffset,
                    endOffset: next.endOffset
                ))
                i += 2
            } else {
                merged.append(TextSegment(
                    id: merged.count,
                    text: seg.text,
                    startOffset: seg.startOffset,
                    endOffset: seg.endOffset
                ))
                i += 1
            }
        }
        return merged
    }
}

// ========== BLOCK 01: SEGMENTATION ENTRY POINT - END ==========

// ========== BLOCK 02: PARAGRAPH FALLBACK - START ==========

extension SentenceSegmenter {
    /// Called when NLTokenizer finds no sentence boundaries at all.
    /// Splits on double-newlines (paragraph breaks), preserving offsets into
    /// the original text for accurate highlighting and position restore.
    private func fallbackParagraphSegments(for text: String) -> [TextSegment] {
        var segments: [TextSegment] = []
        var searchStart = text.startIndex

        for chunk in text.components(separatedBy: "\n\n") {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else {
                continue
            }

            guard let range = text.range(of: chunk, range: searchStart..<text.endIndex) else {
                continue
            }

            let startOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            let endOffset   = text.distance(from: text.startIndex, to: range.upperBound)

            segments.append(
                TextSegment(id: segments.count,
                            text: trimmed,
                            startOffset: startOffset,
                            endOffset: endOffset)
            )
            searchStart = range.upperBound
        }

        if segments.isEmpty {
            return [TextSegment(id: 0, text: text, startOffset: 0, endOffset: text.count)]
        }

        return segments
    }
}

// ========== BLOCK 02: PARAGRAPH FALLBACK - END ==========

// ========== BLOCK 03: OVERSIZED SEGMENT CAPPING - START ==========

extension SentenceSegmenter {
    /// Post-processing pass: sub-splits any segment whose character count
    /// exceeds `maxSegmentLength`, then re-assigns sequential IDs.
    /// Fast path: returns the input unchanged when no segment needs splitting.
    private func capOversized(_ segments: [TextSegment]) -> [TextSegment] {
        guard segments.contains(where: { $0.text.count > Self.maxSegmentLength }) else {
            return segments
        }
        var result: [TextSegment] = []
        result.reserveCapacity(segments.count * 2)
        for seg in segments {
            subsplit(seg, into: &result)
        }
        // Re-assign IDs to be contiguous from 0.
        return result.enumerated().map { i, seg in
            TextSegment(id: i, text: seg.text,
                        startOffset: seg.startOffset, endOffset: seg.endOffset)
        }
    }

    /// Recursively splits `segment` until every piece is ≤ `maxSegmentLength`.
    /// Split chain:
    ///   1. Line-breaks (\n) — respects source structure in EPUBs and HTML
    ///   2. Clause boundaries (em-dash, en-dash, semicolon)
    ///   3. Word-boundary midpoint — last resort, arbitrary but bounded
    private func subsplit(_ segment: TextSegment, into result: inout [TextSegment]) {
        guard segment.text.count > Self.maxSegmentLength else {
            result.append(segment)
            return
        }

        // ── 1. Line-break split ──────────────────────────────────────────────
        let lineParts = splitOnSeparator(segment, separator: "\n")
        if lineParts.count > 1 {
            for part in lineParts { subsplit(part, into: &result) }
            return
        }

        // ── 2. Clause-boundary split ─────────────────────────────────────────
        // Em-dash, en-dash, and semicolon are natural prosody pauses.
        // Tried in preference order; the first that actually splits the segment wins.
        for sep in [" \u{2014} ", " \u{2013} ", "; "] {
            let parts = splitOnSeparator(segment, separator: sep)
            if parts.count > 1 {
                for part in parts { subsplit(part, into: &result) }
                return
            }
        }

        // ── 3. Word-boundary split at maxSegmentLength (last resort) ─────────
        result.append(contentsOf: splitAtWordBoundary(segment))
    }
}

// ========== BLOCK 03: OVERSIZED SEGMENT CAPPING - END ==========

// ========== BLOCK 04: SPLIT HELPERS - START ==========

extension SentenceSegmenter {
    /// Splits `segment` at every occurrence of `separator`, returning all
    /// non-empty trimmed pieces with correctly adjusted offsets into the
    /// original document text.  Returns a single-element array (the original
    /// segment) when the separator is not found.
    private func splitOnSeparator(_ segment: TextSegment,
                                   separator: String) -> [TextSegment] {
        let text = segment.text
        var pieces: [TextSegment] = []
        var searchStart = text.startIndex

        while let sepRange = text.range(of: separator, range: searchStart..<text.endIndex) {
            let piece = String(text[searchStart..<sepRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.isEmpty == false {
                let pieceStart = segment.startOffset +
                    text.distance(from: text.startIndex, to: searchStart)
                let pieceEnd   = segment.startOffset +
                    text.distance(from: text.startIndex, to: sepRange.lowerBound)
                pieces.append(TextSegment(id: 0, text: piece,
                                          startOffset: pieceStart, endOffset: pieceEnd))
            }
            searchStart = sepRange.upperBound
        }

        // Remainder after the last separator.
        let tail = String(text[searchStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.isEmpty == false {
            let tailStart = segment.startOffset +
                text.distance(from: text.startIndex, to: searchStart)
            pieces.append(TextSegment(id: 0, text: tail,
                                      startOffset: tailStart, endOffset: segment.endOffset))
        }

        return pieces.count > 1 ? pieces : [segment]
    }

    /// Last-resort split at the word boundary nearest `maxSegmentLength`.
    /// Scans backward from the target position for a space; if none found,
    /// scans forward.  Returns the original segment unchanged only if no
    /// split point can be found at all (e.g., a single unbroken token).
    private func splitAtWordBoundary(_ segment: TextSegment) -> [TextSegment] {
        let text   = segment.text
        let target = text.index(text.startIndex,
                                offsetBy: Self.maxSegmentLength,
                                limitedBy: text.endIndex) ?? text.endIndex

        // Search backward from target for a space.
        var splitIdx = target
        while splitIdx > text.startIndex {
            let prev = text.index(before: splitIdx)
            if text[prev] == " " { break }
            splitIdx = prev
        }

        // If no space found before target, search forward.
        if splitIdx == text.startIndex {
            splitIdx = target
            while splitIdx < text.endIndex, text[splitIdx] != " " {
                splitIdx = text.index(after: splitIdx)
            }
        }

        // If still no usable split point, return as-is.
        guard splitIdx > text.startIndex, splitIdx < text.endIndex else {
            return [segment]
        }

        let firstText  = String(text[text.startIndex..<splitIdx])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let secondText = String(text[splitIdx...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard firstText.isEmpty == false, secondText.isEmpty == false else {
            return [segment]
        }

        let splitOffset = segment.startOffset +
            text.distance(from: text.startIndex, to: splitIdx)
        return [
            TextSegment(id: 0, text: firstText,
                        startOffset: segment.startOffset, endOffset: splitOffset),
            TextSegment(id: 0, text: secondText,
                        startOffset: splitOffset,         endOffset: segment.endOffset),
        ]
    }
}

// ========== BLOCK 04: SPLIT HELPERS - END ==========
