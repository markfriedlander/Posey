import Foundation

// ========== BLOCK 01: HEADING KEY MODEL - START ==========

/// The derived "key" for ONE book: what a chapter heading looks like *in this
/// book*. PDF rebuild (2026-06-29, Mark's method): there is no universal heading
/// rule, so we DERIVE the rule per book by consensus across its own chapters.
///
/// Mark's derivation: each chapter title appears several times in the document
/// (contents list, the real body heading, sometimes a running header or the
/// index). For each of several titles we gather ALL appearances and keep the
/// WEIGHTIEST (most typographically prominent — that's the real heading, never
/// the small contents-list or index copy). If the weightiest appearances of
/// independent chapters AGREE on a signature, that agreement IS the key.
struct HeadingKey: Equatable {
    /// Representative heading font size for this book (rounded to 0.5pt).
    let fontSize: Double
    /// Whether this book's headings are bold.
    let isBold: Bool
    /// Whether this book's headings are ALL-CAPS.
    let isAllCaps: Bool
    /// How many of the sampled chapter titles' weightiest appearances voted for
    /// this signature (the consensus strength).
    let votes: Int
    /// How many titles we were able to locate at all (the denominator).
    let sampled: Int

    /// The body font this heading sits against (for relative checks downstream).
    let bodyFontSize: Double
}

/// A single located appearance of a title, with its prominence score.
struct TitleAppearance {
    let line: PDFTextLine
    let score: Double
}

// ========== BLOCK 01: HEADING KEY MODEL - END ==========

// ========== BLOCK 02: KEY DERIVER - START ==========

enum PDFHeadingKeyDeriver {

    /// Derive this book's heading key from its own chapters (Mark's method).
    /// - titles:   known chapter titles (from outline / printed-TOC detection).
    /// - allLines: reconstructed lines across the whole document.
    /// Returns the consensus key, or nil if too few titles could be located to
    /// agree (caller then falls back / flags — never fail silently).
    static func derive(titles: [String], allLines: [PDFTextLine]) -> HeadingKey? {
        guard !titles.isEmpty, !allLines.isEmpty else { return nil }
        let bodyFont = bodyFontSize(of: allLines)

        // For each title, find its weightiest appearance — but only let it VOTE
        // for the key if that appearance actually STANDS OUT from body text
        // (Mark: ignore plain body-text mentions, which otherwise outvote the one
        // real heading we found). A title whose only appearances are body-font
        // mentions contributes no heading vote rather than a false body-font vote.
        var votingLines: [PDFTextLine] = []
        var located = 0
        for title in titles {
            let appearances = appearances(of: title, in: allLines, bodyFont: bodyFont)
            guard let top = appearances.max(by: { $0.score < $1.score }) else { continue }
            located += 1
            if standsOut(top.line, bodyFont: bodyFont) { votingLines.append(top.line) }
        }
        guard votingLines.count >= 2 else { return nil }

        // Vote on the signature (fontSize bucket, bold, caps) of the standout
        // appearances. The signature the most chapters agree on is the key.
        var tally: [Signature: Int] = [:]
        for line in votingLines { tally[Signature(line), default: 0] += 1 }
        guard let (sig, votes) = tally.max(by: { $0.value < $1.value }), votes >= 2 else { return nil }

        return HeadingKey(fontSize: sig.fontSize, isBold: sig.isBold, isAllCaps: sig.isAllCaps,
                          votes: votes, sampled: located, bodyFontSize: bodyFont)
    }

    /// All lines that plausibly render `title`, scored by prominence. A line
    /// matches if it shares ≥60% of the title's words (tolerant of wrap-splits,
    /// leading chapter numbers, and OCR garble — we are NOT requiring an exact
    /// substring, which the probes showed fails on real books).
    static func appearances(of title: String, in lines: [PDFTextLine], bodyFont: Double) -> [TitleAppearance] {
        let titleWords = words(title)
        guard !titleWords.isEmpty else { return [] }
        let titleSet = Set(titleWords)
        var out: [TitleAppearance] = []
        for line in lines {
            let lw = Set(words(line.text))
            guard !lw.isEmpty else { continue }
            let overlap = Double(titleSet.intersection(lw).count) / Double(titleSet.count)
            if overlap >= 0.6 {
                out.append(TitleAppearance(line: line, score: prominence(line, bodyFont: bodyFont)))
            }
        }
        return out
    }

    /// Prominence = how much this line "stands out" as a heading. Font size is
    /// the spine; bold / caps / a gap above / being a short standalone line all
    /// add weight. This is what makes the real body heading the "weightiest"
    /// appearance over the small contents-list and index copies (Mark).
    static func prominence(_ line: PDFTextLine, bodyFont: Double) -> Double {
        var s = (line.fontSize - bodyFont) * 2.0      // bigger-than-body dominates
        if line.isBold { s += 3 }
        if line.isAllCaps { s += 1.5 }
        if line.gapAbove > 12 { s += 1.5 }
        if line.text.count <= 60 { s += 1 }            // short standalone line
        return s
    }

    /// The set of lines that ARE chapter headings — each known title's weightiest
    /// appearance, kept only if it stands out from body (Mark's "small prequalified
    /// pool": choose among a title's own appearances, never scan blind). The unit
    /// builder marks exactly these lines as `.heading` units, anchoring each
    /// chapter to its real heading by identity. (Outline-first / profile path;
    /// fuzzy + numbering modes layer on later.)
    static func headingLines(titles: [String], allLines: [PDFTextLine]) -> Set<PDFTextLine> {
        Set(resolveHeadings(titles: titles, allLines: allLines).map { $0.line })
    }

    /// Resolve each known title to its heading LINE (weightiest standout
    /// appearance), preserving the title→line mapping so the importer can anchor
    /// each TOC entry to the heading unit that line becomes. A title with no
    /// standout appearance is omitted (caller decides the fallback — never fail
    /// silently). The line is returned once even if two titles resolve to it.
    static func resolveHeadings(titles: [String], allLines: [PDFTextLine]) -> [(title: String, line: PDFTextLine)] {
        let bodyFont = bodyFontSize(of: allLines)
        var out: [(title: String, line: PDFTextLine)] = []
        var used: Set<PDFTextLine> = []
        for title in titles {
            let apps = appearances(of: title, in: allLines, bodyFont: bodyFont)
            guard let top = apps.max(by: { $0.score < $1.score }),
                  standsOut(top.line, bodyFont: bodyFont),
                  !used.contains(top.line) else { continue }
            used.insert(top.line)
            out.append((title, top.line))
        }
        return out
    }

    /// Does this line stand out from body text — i.e. could it be a heading at
    /// all? Bigger font, OR bold, OR ALL-CAPS. A plain body-font, non-bold,
    /// non-caps line is a mention, not a heading, and must not vote for the key.
    static func standsOut(_ line: PDFTextLine, bodyFont: Double) -> Bool {
        line.fontSize > bodyFont + 0.5 || line.isBold || line.isAllCaps
    }

    // MARK: - helpers

    private struct Signature: Hashable {
        let fontSize: Double; let isBold: Bool; let isAllCaps: Bool
        init(_ l: PDFTextLine) {
            fontSize = (l.fontSize * 2).rounded() / 2     // 0.5pt buckets
            isBold = l.isBold; isAllCaps = l.isAllCaps
        }
    }

    /// Body font = the most common font size across all lines.
    static func bodyFontSize(of lines: [PDFTextLine]) -> Double {
        var counts: [Double: Int] = [:]
        for l in lines { counts[(l.fontSize * 2).rounded() / 2, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key ?? 0
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased()
         .components(separatedBy: CharacterSet.alphanumerics.inverted)
         .filter { $0.count >= 2 }      // drop 1-char noise / lone chapter numbers
    }
}

// ========== BLOCK 02: KEY DERIVER - END ==========
