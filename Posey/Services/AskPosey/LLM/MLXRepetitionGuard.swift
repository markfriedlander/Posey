import Foundation

// ========== BLOCK 01: REPETITION GUARD - START ==========

/// In-stream runaway-loop brake for MLX text generation. Even with
/// `GenerateParameters.repetitionPenalty: 1.1` configured per-model
/// (see `ModelSettings.repetitionPenalty`), an MLX model
/// occasionally still drifts into a degenerate repetition loop deep
/// into a long generation — Gemma is the most prone in our catalog.
/// Without an in-stream check, the loop continues to the 4096-token
/// `maxTokens` cap, burning ~120 seconds of compute and shipping a
/// corrupt, looped response to the reader.
///
/// `MLXRepetitionGuard.detect` is called by `MLXService.streamChat`
/// every ~50 generated characters. On detection, the streaming loop
/// breaks early and `MLXRepetitionGuard.trim` cleans up the residue
/// before yielding the final response, appending one of six
/// in-Posey-voice closing phrases at random so the reader sees WHY
/// the answer ended where it did (transparency over silent cut-off).
///
/// **Rule 9 Part A — port lineage.** Faithful port of Hal Universal's
/// `detectRepetitionLoop` (Hal.swift:4625-4677), `trimTrailingRepetition`
/// (Hal.swift:4699-4790), and `repetitionStopPhrases` (Hal.swift:4685-4692).
/// Heuristic constants (200-char floor, 30..80 chunk sweep, 2..10
/// n-gram sweep, 4-match threshold, 60-char tail window) are
/// preserved exactly — Hal's were tuned on real corpora and changing
/// them here would invalidate that tuning. The closing phrases are
/// rewritten in Posey's quieter reading-companion register (Hal is
/// breezier; Posey is a calm reading partner).
enum MLXRepetitionGuard {

    /// True if the tail of `text` looks like a degenerate repetition
    /// loop. Conservative tuning bias — false negatives over false
    /// positives. Killing a real response mid-stream is worse than
    /// letting a few extra repeated tokens through.
    static func detect(in text: String) -> Bool {
        // Need enough text to make a confident call. 200 chars ≈ 30-40
        // words ≈ a couple of sentences — well past anything where
        // natural repetition could be confused with a loop.
        guard text.count >= 200 else { return false }

        // ── Paragraph-level: same chunk appears 3 times in a row at end. ──
        // Walk chunk sizes from 30 to 80 chars in steps of 10. For each
        // size, check if the last three chunks of that length are all
        // identical. Stride cap of 80 keeps comparisons bounded — longer
        // "repetitions" might be legitimate.
        for chunkSize in stride(from: 30, through: 80, by: 10) {
            guard text.count >= chunkSize * 3 else { continue }
            let endIndex = text.endIndex
            let third  = text.index(endIndex, offsetBy: -chunkSize)
            let second = text.index(endIndex, offsetBy: -chunkSize * 2)
            let first  = text.index(endIndex, offsetBy: -chunkSize * 3)
            let c3 = text[third..<endIndex]
            let c2 = text[second..<third]
            let c1 = text[first..<second]
            if c1 == c2 && c2 == c3 {
                return true
            }
        }

        // ── Token-level: same short n-gram repeated 4+ times at very end. ──
        // Catches "the the the the…" type degeneracy where the per-model
        // repetition penalty failed to discourage the pattern fully.
        let tail = String(text.suffix(60))
        for ngramSize in 2...10 {
            guard tail.count >= ngramSize * 4 else { continue }
            let pattern = String(tail.suffix(ngramSize))
            let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPattern.count < 2 { continue }

            var matches = 1
            var cursor = tail.count - ngramSize
            while cursor >= ngramSize {
                let start = tail.index(tail.startIndex, offsetBy: cursor - ngramSize)
                let end   = tail.index(tail.startIndex, offsetBy: cursor)
                if String(tail[start..<end]) == pattern {
                    matches += 1
                    cursor -= ngramSize
                    if matches >= 4 { return true }
                } else {
                    break
                }
            }
        }

        return false
    }

// ========== BLOCK 01: REPETITION GUARD - END ==========

// ========== BLOCK 02: TRIM TRAILING REPETITION - START ==========

    /// Strip the repetitive tail off a text where `detect` returned
    /// true, preserving one complete instance of the repeating content,
    /// then append a randomized in-voice closing phrase from
    /// `Self.closingPhrases`. The phrase is only appended when the
    /// trim actually removed visible content — a defensive guard so
    /// false-positive detections don't add a closing phrase to an
    /// otherwise complete response.
    static func trim(_ text: String) -> String {
        // Paragraph-level cleanup first.
        var working = text
        for chunkSize in stride(from: 30, through: 80, by: 10) {
            guard working.count >= chunkSize * 2 else { continue }
            let endIndex = working.endIndex
            let second = working.index(endIndex, offsetBy: -chunkSize)
            let first  = working.index(endIndex, offsetBy: -chunkSize * 2)
            let last  = working[second..<endIndex]
            let prior = working[first..<second]
            if last == prior {
                // Count consecutive identical chunks at the end, then
                // strip all but one — mirroring the token-level
                // matchCount-1 logic below. The naive "drop while tail
                // matches" approach ate the LAST few chars of the FIRST
                // instance when chunkSize misaligned with the natural
                // block boundary (Hal's Evolutionary_Salon_Report bug —
                // see Hal.swift:4715-4719 for the trace).
                var matchCount = 2  // last + prior already known to match
                var cursor = working.count - chunkSize * 2
                while cursor >= chunkSize {
                    let s = working.index(working.startIndex, offsetBy: cursor - chunkSize)
                    let e = working.index(working.startIndex, offsetBy: cursor)
                    if working[s..<e] == last {
                        matchCount += 1
                        cursor -= chunkSize
                    } else {
                        break
                    }
                }
                let cutCount = (matchCount - 1) * chunkSize
                working = String(working.dropLast(cutCount))
                break  // paragraph repetition handled
            }
        }

        // Token-level cleanup.
        let tail = String(working.suffix(60))
        for ngramSize in 2...10 {
            guard tail.count >= ngramSize * 4 else { continue }
            let pattern = String(tail.suffix(ngramSize))
            let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPattern.count < 2 { continue }

            var matchCount = 0
            var endCursor = working.count
            while endCursor >= ngramSize {
                let s = working.index(working.startIndex, offsetBy: endCursor - ngramSize)
                let e = working.index(working.startIndex, offsetBy: endCursor)
                if String(working[s..<e]) == pattern {
                    matchCount += 1
                    endCursor -= ngramSize
                } else {
                    break
                }
            }
            if matchCount >= 4 {
                let cutCount = (matchCount - 1) * ngramSize
                working = String(working.dropLast(cutCount))
                break
            }
        }

        // Append a randomized closing phrase only when the trim
        // actually removed content. A single-space separator so the
        // phrase reads as a continuation rather than running together.
        let cleaned = working.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalTrim = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count < originalTrim.count {
            let phrase = Self.closingPhrases.randomElement() ?? "\u{2026}"
            return cleaned + " " + phrase
        }
        return cleaned
    }

// ========== BLOCK 02: TRIM TRAILING REPETITION - END ==========

// ========== BLOCK 03: CLOSING PHRASES - START ==========

    /// Six in-Posey-voice closing phrases picked at random when the
    /// brake fires. Each starts with U+2026 (horizontal ellipsis) so
    /// the truncation marker is preserved, then continues in Posey's
    /// quiet reading-companion register. The reader sees WHY the
    /// answer ended where it did rather than encountering a silent
    /// cut-off.
    ///
    /// Voice register: calmer + more grounded than Hal's. Hal's
    /// phrases ("I'm catching myself in a loop", "I think I'm
    /// circling") are first-person-assistant chatty. Posey is a
    /// reading companion sitting next to the reader — the closings
    /// stay quieter, more like a thoughtful pause.
    static let closingPhrases: [String] = [
        "\u{2026} I notice I'm repeating myself there. Stopping here.",
        "\u{2026} I've drifted into a loop. Better to stop than continue.",
        "\u{2026} I'm circling on the same point. Pausing here.",
        "\u{2026} I notice I keep saying the same thing. Let me stop.",
        "\u{2026} I'm caught in a pattern. Pausing for now.",
        "\u{2026} that's gone in circles. Stopping here."
    ]

// ========== BLOCK 03: CLOSING PHRASES - END ==========
}
