import Foundation

// ========== BLOCK 01: SENTENCE CHUNKER - START ==========

/// Splits a sentence into card-sized pieces for Teleprompter read-along mode
/// (Mark, 2026-07-12). Each chunk becomes both a display CARD and a spoken
/// UTTERANCE, so a card advances on the reliable per-utterance signal (no
/// within-sentence guessing).
///
/// The split prefers natural CLAUSE boundaries (comma / semicolon / colon /
/// em- or en-dash), falling back to WORD boundaries, and only ever hard-splits
/// if a single "word" somehow exceeds the cap. Chunks are BALANCED — aimed at an
/// even share of the sentence — so we never leave a tiny orphan card
/// ("fecundity." alone). Verified against real prose (prototype, 2026-07-12).
enum SentenceChunker {

    /// Split `text` into pieces no longer than `maxChars`, at natural boundaries.
    /// A sentence at or under the cap returns as a single chunk.
    static func chunks(_ text: String, maxChars: Int) -> [String] {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count > maxChars, maxChars > 0 else { return s.isEmpty ? [] : [s] }
        var result: [String] = []
        var rem = s[...]
        while rem.count > maxChars {
            let remainingChunks = (rem.count + maxChars - 1) / maxChars   // ceil
            let target = rem.count / remainingChunks
            let idx = splitPoint(rem, target: target, maxChars: maxChars)
            let head = String(rem[..<idx]).trimmingCharacters(in: .whitespaces)
            let before = rem.count
            rem = rem[idx...]
            while let f = rem.first, f == " " { rem = rem.dropFirst() }
            if !head.isEmpty { result.append(head) }
            if rem.count >= before { break }   // no-progress safety
        }
        let tail = String(rem).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result.isEmpty ? [s] : result
    }

    /// The best index to cut `rem`: the clause boundary nearest `target` (preferred),
    /// else the word boundary nearest `target`, else a hard cut at `maxChars`. Won't
    /// cut before ~0.35·maxChars so we don't make a tiny card.
    private static func splitPoint(_ rem: Substring, target: Int, maxChars: Int) -> String.Index {
        let clausePunct: Set<Character> = [",", ";", ":", "—", "–"]
        let minPos = max(1, maxChars * 7 / 20)
        var clauseCands: [(idx: String.Index, dist: Int)] = []
        var wordCands: [(idx: String.Index, dist: Int)] = []
        var i = rem.startIndex
        var pos = 0
        while i < rem.endIndex, pos < maxChars {
            let c = rem[i]
            let next = rem.index(after: i)
            if clausePunct.contains(c), pos + 1 >= minPos {
                clauseCands.append((next, abs((pos + 1) - target)))
            }
            if c == " ", pos >= minPos {
                wordCands.append((i, abs(pos - target)))
            }
            i = next; pos += 1
        }
        if let best = clauseCands.min(by: { $0.dist < $1.dist }) { return best.idx }
        if let best = wordCands.min(by: { $0.dist < $1.dist }) { return best.idx }
        return i   // hard split at the cap
    }
}

// ========== BLOCK 01: SENTENCE CHUNKER - END ==========
