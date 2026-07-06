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
    private static let minResolvePurity = 0.5
    private static let fontlessPureShortLinePurity = 0.9
    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "before", "between", "but",
        "by", "for", "from", "in", "into", "is", "it", "of", "on", "or", "the",
        "to", "under", "which", "with"
    ]

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
        let titleWords = matchWords(title)
        guard !titleWords.isEmpty else { return [] }
        var out: [TitleAppearance] = []
        for line in lines where titleMatches(title: title, text: line.text) {
            out.append(TitleAppearance(line: line, score: prominence(line, bodyFont: bodyFont)))
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

    /// Resolve each known title to its heading LINE — as an ORDER-AWARE ALIGNMENT,
    /// not an independent per-title beauty contest.
    ///
    /// The old code took each title's single weightiest heading-shaped appearance
    /// ANYWHERE in the document, independently. That scrambles books whose titles
    /// repeat: a chapter printed prominently in the front matter (GEB's contents /
    /// per-chapter synopses) or the back-of-book index could out-score its real body
    /// heading and win — so a chapter anchored to the front or back of the book and
    /// the navigator went out of order.
    ///
    /// MEASURED across the corpus (GEB / Crypto / Attention / ResNet / a novel,
    /// 2026-07-03): real chapter headings appear in the BODY in reading ORDER, spread
    /// across the document; the repeated copies cluster in the front matter (contents,
    /// synopses) and the trailing index. So we choose the assignment of titles→
    /// heading-shaped lines whose positions run STRICTLY INCREASING in document order,
    /// maximizing (first) how many titles are placed and (then) their prominence — a
    /// weighted 2-D increasing subsequence. A title with no in-order heading-shaped
    /// candidate is SKIPPED — never force-fit, never dragged forward into the index —
    /// and the caller reports the count so the reader is told some chapters couldn't be
    /// placed (never fail silently, never invent a title).
    ///
    /// `bodyStartIndex` fences off the front matter (contents / synopses) by ignoring
    /// candidate lines before it; `bodyEndIndex` (default = end) fences off a trailing
    /// index. Order-alignment alone can still be fooled by a front/back cluster that is
    /// itself in order, so these fences are load-bearing, not optional polish.
    ///
    /// (Antifa small-caps headings, CC#22: still handled — they're heading-shaped via
    /// `isAllCaps`, so they're candidates; the count-first objective means a real
    /// heading is placed even when its prominence score is low/negative.)
    static func resolveHeadings(titles: [String], allLines: [PDFTextLine],
                                bodyStartIndex: Int = 0,
                                bodyEndIndex: Int = .max) -> [(title: String, line: PDFTextLine)] {
        let bodyFont = bodyFontSize(of: allLines)
        let hasFontSignal = allLines.contains { $0.fontSize > 0 }
        let endIndex = min(bodyEndIndex, allLines.count)

        // PERF (Mark, 2026-07-05): the heading-title cluster ranges around each
        // line are TITLE-INDEPENDENT, yet the inner loop recomputed them for every
        // (title × line) — ~40 × 32,000 times on the 814-page CBA = ~110s, the
        // single biggest cost of the whole import. They depend only on (index,
        // allLines, bodyFont, bodyStartIndex, hasFontSignal), all fixed for this
        // call, so compute them ONCE per line and reuse across every title. Pure
        // memoization of a deterministic function → byte-identical headings out
        // (proven by an A/B check on CBA/GEB/Attention/Antifa: opt==inline, 2026-07-05).
        var clusterRangesByIndex = [[[Int]]](repeating: [], count: allLines.count)
        for pos in max(0, bodyStartIndex)..<endIndex {
            clusterRangesByIndex[pos] = headingTitleClusterRanges(
                around: pos, allLines: allLines, bodyFont: bodyFont,
                bodyStartIndex: bodyStartIndex, hasFontSignal: hasFontSignal)
        }

        // Per title (in TOC / outline order) gather its heading-SHAPED candidate lines
        // within the body fence, each with its position (index in document order) and a
        // placement weight. Weight = a large placement base + prominence, so the aligner
        // prefers to PLACE another chapter over squeezing prominence (a low-prominence
        // small-caps heading must still be placed), and prominence only breaks ties among
        // a title's own in-order candidates.
        struct Cand {
            let t: Int
            let pos: Int
            let line: PDFTextLine
            let weight: Double
            let titleHeadsLine: Bool
        }
        let placementBase = 1000.0
        var cands: [Cand] = []
        for (t, title) in titles.enumerated() {
            let titleWords = matchWords(title)
            guard !titleWords.isEmpty else { continue }
            // A title's leading SECTION NUMBER is its disambiguator among near-identical
            // titles. `words()` drops the 1-char number, so word-matching alone can't tell
            // "7. Theatrical…" from "4. Theatrical…" (CBA) or "9.3 Conservation of Linear
            // Momentum" from "9.1 Linear Momentum" (OpenStax) — the later section collides
            // onto the earlier one and the navigator shows it out of order. So: if BOTH the
            // title and a candidate line carry a section number, they must MATCH. Arabic
            // only (clean); roman is left to word-match (OCR-garble risk, and it works).
            let titleNum = leadingSectionNumber(title)
            var titleCandidates: [Cand] = []
            for pos in max(0, bodyStartIndex)..<endIndex {
                let line = allLines[pos]
                let match = bestCandidateMatchQuality(
                    title: title,
                    at: pos,
                    allLines: allLines,
                    clusterRanges: clusterRangesByIndex[pos]
                )
                let titleHeadsLine = titleHeadsLine(title: title, text: line.text)
                guard match.matches else { continue }
                if isContentsLeaderLine(line.text) { continue }
                guard titleHeadsLine || match.linePurity >= minResolvePurity else { continue }
                if let tn = titleNum, let ln = leadingSectionNumber(line.text), ln != tn { continue }
                if let tn = titleNum,
                   leadingSectionNumber(line.text) == nil,
                   candidateInheritsConflictingSectionNumber(
                    for: pos,
                    titleNum: tn,
                    title: title,
                    allLines: allLines,
                    bodyFont: bodyFont,
                    bodyStartIndex: bodyStartIndex,
                    hasFontSignal: hasFontSignal
                   ) {
                    continue
                }
                let precededByHeadingLabel = previousLineIsHeadingLabel(
                    before: pos,
                    in: allLines
                )
                if headingCandidateLooksValid(
                    line,
                    match: match,
                    bodyFont: bodyFont,
                    hasFontSignal: hasFontSignal,
                    titleHeadsLine: titleHeadsLine,
                    precededByHeadingLabel: precededByHeadingLabel
                ) {
                    let start = earliestHeadingStart(for: pos, title: title, titleNum: titleNum,
                                                     allLines: allLines, bodyFont: bodyFont,
                                                     bodyStartIndex: bodyStartIndex,
                                                     hasFontSignal: hasFontSignal)
                    let startLine = allLines[start]
                    // Purity decides WHICH matching heading line we trust; prominence only
                    // breaks ties among equally-pure candidates.
                    let weight = placementBase
                        + headingClusterBonus(at: pos, title: title, allLines: allLines)
                        + (titleHeadsLine ? 120 : 0)
                        + (precededByHeadingLabel ? 40 : 0)
                        + match.linePurity * 100
                        + prominence(line, bodyFont: bodyFont)
                    titleCandidates.append(
                        Cand(
                            t: t,
                            pos: start,
                            line: startLine,
                            weight: weight,
                            titleHeadsLine: titleHeadsLine
                        )
                    )
                }
            }
            if titleCandidates.contains(where: \.titleHeadsLine) {
                cands.append(contentsOf: titleCandidates.filter(\.titleHeadsLine))
            } else {
                cands.append(contentsOf: titleCandidates)
            }
        }
        guard !cands.isEmpty else { return [] }
        ImportTrace.shared.event("  resolveHeadings: candidates built = \(cands.count) (over \(endIndex) lines × \(titles.count) titles); chain DP begin")

        // Weighted 2-D increasing subsequence: choose candidates with STRICTLY
        // increasing title order AND strictly increasing position, maximizing total
        // weight. Because titles are used at most once and in order, this places each
        // chapter at most once, in reading order, skipping any that don't fit the chain.
        // Sorted by (title, position) so every valid predecessor of i precedes it.
        let sorted = cands.sorted { $0.t != $1.t ? $0.t < $1.t : $0.pos < $1.pos }
        let n = sorted.count
        var dp = sorted.map { $0.weight }
        var prev = [Int](repeating: -1, count: n)
        for i in 0..<n {
            for j in 0..<i where sorted[j].t < sorted[i].t && sorted[j].pos < sorted[i].pos {
                if dp[j] + sorted[i].weight > dp[i] {
                    dp[i] = dp[j] + sorted[i].weight
                    prev[i] = j
                }
            }
        }
        ImportTrace.shared.event("  resolveHeadings: chain DP done (n=\(n))")
        var best = 0
        for i in 1..<n where dp[i] > dp[best] { best = i }
        var chainRev: [Int] = []
        var k = best
        while k >= 0 { chainRev.append(k); k = prev[k] }
        return chainRev.reversed().map { (titles[sorted[$0].t], sorted[$0].line) }
    }

    /// A flat-layout academic heading carries its prominence in its NUMBERING, not
    /// its font: the Transformer paper's "3.1 Encoder and Decoder Stacks" is
    /// body-size and non-bold, so `standsOut` misses it and the section never
    /// becomes a heading unit. When a KNOWN outline title resolves to a line that
    /// opens with a section number ("1", "3.1", "3.2.1", optional trailing dot) and
    /// is short/standalone, the numbering is sufficient evidence it's the real
    /// heading. This only ever CONFIRMS a title we already have (via `appearances`'
    /// ≥60% word match) — it never scans blind, so a numbered prose/list line that
    /// doesn't match a section title is not affected.
    static func isNumberedSectionLine(_ line: PDFTextLine) -> Bool {
        guard line.text.count <= 80 else { return false }
        return line.text.range(of: #"^\s*\d{1,3}(?:\.\d{1,3}){0,3}\.?\s+\p{L}"#,
                               options: .regularExpression) != nil
    }

    static func isContentsLeaderLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 140 else { return false }
        return trimmed.range(of: #"\.{3,}\s*\d{1,4}\s*$"#, options: .regularExpression) != nil
            || trimmed.range(of: #"[·•]{3,}\s*\d{1,4}\s*$"#, options: .regularExpression) != nil
    }

    static func isHeadingLabelLine(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^(?i:chapter|part|section|appendix|article|book)\s+[ivxlcdm\d]{1,8}\b[.:]?$"#,
                   options: .regularExpression) != nil
    }

    static func isNumericHeadingLabelLine(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^\d{1,3}(?:\.\d{1,3}){0,3}[.:]?$"#,
                   options: .regularExpression) != nil
    }

    /// Does this line stand out from body text — i.e. could it be a heading at
    /// all? Bigger font, OR bold, OR ALL-CAPS. A plain body-font, non-bold,
    /// non-caps line is a mention, not a heading, and must not vote for the key.
    static func standsOut(_ line: PDFTextLine, bodyFont: Double) -> Bool {
        line.fontSize > bodyFont + 0.5 || line.isBold || line.isAllCaps
    }

    private static func headingCandidateLooksValid(
        _ line: PDFTextLine,
        match: MatchQuality,
        bodyFont: Double,
        hasFontSignal: Bool,
        titleHeadsLine: Bool,
        precededByHeadingLabel: Bool
    ) -> Bool {
        if standsOut(line, bodyFont: bodyFont) || isNumberedSectionLine(line) { return true }
        if isNumericHeadingLabelLine(line.text) { return true }
        if precededByHeadingLabel,
           match.titleCoverage >= 0.9,
           looksLikeHeadingClusterFragment(line.text) {
            return true
        }
        if match.titleCoverage >= 0.9,
           line.gapAbove >= 16,
           looksLikeHeadingClusterFragment(line.text) {
            return true
        }
        if titleHeadsLine, precededByHeadingLabel, line.text.count <= 120 { return true }
        if titleHeadsLine, line.gapAbove >= 16 { return true }
        guard !hasFontSignal else { return false }

        let wordCount = line.text.split(separator: " ").count
        if line.gapAbove >= 14, wordCount <= 14, line.text.count <= 120 { return true }
        return match.linePurity >= fontlessPureShortLinePurity && wordCount <= 10 && line.text.count <= 80
    }

    private static func headingClusterBonus(
        at index: Int,
        title: String,
        allLines: [PDFTextLine]
    ) -> Double {
        guard allLines.indices.contains(index) else { return 0 }
        let current = allLines[index]
        var bonus = 0.0

        if index > 0 {
            bonus += neighboringHeadingBonus(
                neighbor: allLines[index - 1],
                current: current,
                title: title
            )
        }
        if index + 1 < allLines.count {
            bonus += neighboringHeadingBonus(
                neighbor: allLines[index + 1],
                current: current,
                title: title
            )
        }

        return bonus
    }

    private static func neighboringHeadingBonus(
        neighbor: PDFTextLine,
        current: PDFTextLine,
        title: String
    ) -> Double {
        guard linesAreAdjacent(neighbor, current) else { return 0 }
        if isHeadingLabelLine(neighbor.text) { return 80 }

        let quality = matchQuality(title: title, text: neighbor.text)
        if quality.matches {
            return 60 + quality.linePurity * 20
        }

        let wordCount = neighbor.text.split(separator: " ").count
        if quality.linePurity >= 0.8, wordCount <= 4, neighbor.text.count <= 40 {
            return 45
        }

        return 0
    }

    /// Does `text` (a candidate heading line / unit) match `title`? Two ways:
    /// (a) the text covers ≥60% of the TITLE's words — short titles whose heading
    /// is the whole title ("3. Strikes" → "3. STRIKES"); or (b) the text is (the
    /// start of) a long WRAPPED title — ≥3 words and ≥80% of the text's words are
    /// in the title. A 20-word legal title (§4) has a single-line body heading
    /// carrying only its first ~7 words; (a) misses it (7/20<0.6) but the line is
    /// fully contained in the title, so (b) catches it on the line side.
    static func titleMatches(title: String, text: String) -> Bool {
        matchQuality(title: title, text: text).matches
    }
    static func titleMatches(titleSet: Set<String>, text: String) -> Bool {
        matchQuality(titleSet: titleSet, text: text).matches
    }

    struct MatchQuality {
        let matches: Bool
        let titleCoverage: Double
        let linePurity: Double
    }

    static func matchQuality(titleSet: Set<String>, text: String) -> MatchQuality {
        let lw = Set(matchWords(text))
        guard !titleSet.isEmpty, !lw.isEmpty else {
            return MatchQuality(matches: false, titleCoverage: 0, linePurity: 0)
        }
        let inter = titleSet.intersection(lw).count
        let titleCoverage = Double(inter) / Double(titleSet.count)
        let linePurity = Double(inter) / Double(lw.count)
        let matches = titleCoverage >= 0.6
            || (lw.count >= 3 && inter >= 3 && linePurity >= 0.8)
        return MatchQuality(matches: matches, titleCoverage: titleCoverage, linePurity: linePurity)
    }

    static func matchQuality(title: String, text: String) -> MatchQuality {
        titleWordVariants(for: title)
            .map { matchQuality(titleSet: Set($0), text: text) }
            .max { lhs, rhs in
                if lhs.titleCoverage != rhs.titleCoverage { return lhs.titleCoverage < rhs.titleCoverage }
                return lhs.linePurity < rhs.linePurity
            } ?? MatchQuality(matches: false, titleCoverage: 0, linePurity: 0)
    }

    /// `clusterRanges` are the heading-title cluster ranges around `index`.
    /// They depend ONLY on the line's position + font context (NOT on the
    /// title), so the caller precomputes them ONCE per line and reuses them
    /// across all titles — this removes the titles×lines recomputation that was
    /// ~110s of an 814-page import (Mark, 2026-07-05). Behavior-identical: the
    /// ranges are the same values `headingTitleClusterRanges` produced inline.
    private static func bestCandidateMatchQuality(
        title: String,
        at index: Int,
        allLines: [PDFTextLine],
        clusterRanges: [[Int]]
    ) -> MatchQuality {
        guard allLines.indices.contains(index) else {
            return MatchQuality(matches: false, titleCoverage: 0, linePurity: 0)
        }

        var best = matchQuality(title: title, text: allLines[index].text)

        for range in clusterRanges where range.count >= 2 {
            let text = range.map { allLines[$0].text }.joined(separator: " ")
            let candidate = matchQuality(title: title, text: text)
            if candidate.titleCoverage > best.titleCoverage
                || (candidate.titleCoverage == best.titleCoverage && candidate.linePurity > best.linePurity) {
                best = candidate
            }
        }

        return best
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

    private static func earliestHeadingStart(
        for pos: Int,
        title: String,
        titleNum: String?,
        allLines: [PDFTextLine],
        bodyFont: Double,
        bodyStartIndex: Int,
        hasFontSignal: Bool
    ) -> Int {
        var start = pos
        var cursor = pos
        while cursor > bodyStartIndex {
            let prev = allLines[cursor - 1]
            let cur = allLines[cursor]
            guard prev.pageIndex == cur.pageIndex else { break }
            guard linesAreAdjacent(prev, cur) else { break }
            guard !isContentsLeaderLine(prev.text) else { break }
            let prevMatch = matchQuality(title: title, text: prev.text)
            let prevLooksLikeHeading = headingCandidateLooksValid(
                prev,
                match: prevMatch,
                bodyFont: bodyFont,
                hasFontSignal: hasFontSignal,
                titleHeadsLine: false,
                precededByHeadingLabel: false
            )
            guard prevLooksLikeHeading else { break }
            if let tn = titleNum, let ln = leadingSectionNumber(prev.text), ln != tn { break }
            let canPrefixWrappedHeading = prev.text.count <= 40 && prev.text.split(separator: " ").count <= 4
            guard prevMatch.matches || canPrefixWrappedHeading else { break }
            start = cursor - 1
            cursor -= 1
        }
        return start
    }

    private static func candidateInheritsConflictingSectionNumber(
        for pos: Int,
        titleNum: String,
        title: String,
        allLines: [PDFTextLine],
        bodyFont: Double,
        bodyStartIndex: Int,
        hasFontSignal: Bool
    ) -> Bool {
        guard allLines.indices.contains(pos) else { return false }

        var cursor = pos
        while cursor > bodyStartIndex {
            let prev = allLines[cursor - 1]
            let cur = allLines[cursor]
            guard prev.pageIndex == cur.pageIndex else { break }
            guard linesAreAdjacent(prev, cur) else { break }
            guard !isContentsLeaderLine(prev.text) else { break }

            let prevMatch = matchQuality(title: title, text: prev.text)
            let prevLooksLikeHeading = headingCandidateLooksValid(
                prev,
                match: prevMatch,
                bodyFont: bodyFont,
                hasFontSignal: hasFontSignal,
                titleHeadsLine: false,
                precededByHeadingLabel: false
            )
            guard prevLooksLikeHeading else { break }

            if let neighborNum = leadingSectionNumber(prev.text) {
                return neighborNum != titleNum
            }

            cursor -= 1
        }

        return false
    }

    private static func linesAreAdjacent(_ a: PDFTextLine, _ b: PDFTextLine) -> Bool {
        let upper = a.yTop >= b.yTop ? a : b
        let lower = upper == a ? b : a
        let gap = upper.yBottom - lower.yTop
        return gap <= 32 && gap >= -6
    }

    private static func previousLineIsHeadingLabel(before index: Int, in allLines: [PDFTextLine]) -> Bool {
        guard index > 0, allLines.indices.contains(index) else { return false }
        let previous = allLines[index - 1]
        let current = allLines[index]
        guard previous.pageIndex == current.pageIndex else { return false }
        guard linesAreAdjacent(previous, current) else { return false }
        return isHeadingLabelLine(previous.text) || isNumericHeadingLabelLine(previous.text)
    }

    /// Extract a leading ARABIC section number from a title / heading line, if present:
    /// "7." → "7", "9.3." → "9.3", "3.2.1 Foo" → "3.2.1", "Chapter 7 …" → "7",
    /// "Part 3 …" → "3". Roman numerals are intentionally NOT matched (OCR-garble risk
    /// on scanned books; those resolve by word-match, which already works). Used to stop
    /// a numbered title from matching a DIFFERENTLY-numbered heading line (CBA, OpenStax).
    static func leadingSectionNumber(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^(?i:chapter|part|section|appendix|article|book)\s+(\d{1,3})\b"#,
                           options: .regularExpression) {
            let m = t[r]
            if let n = m.range(of: #"\d{1,3}"#, options: .regularExpression) { return String(m[n]) }
        }
        if let r = t.range(of: #"^\d{1,3}(?:\.\d{1,3}){0,3}"#, options: .regularExpression) {
            return String(t[r])
        }
        return nil
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased()
         .components(separatedBy: CharacterSet.alphanumerics.inverted)
         .filter { $0.count >= 2 }      // drop 1-char noise / lone chapter numbers
    }

    private static func matchWords(_ s: String) -> [String] {
        let base = words(s)
        let filtered = base.filter { !stopWords.contains($0) }
        // Keep the matcher resilient for genuinely short titles by only
        // dropping stop words when enough informative words remain.
        return filtered.count >= 3 ? filtered : base
    }

    private static func titleHeadsLine(title: String, text: String) -> Bool {
        titleWordVariants(for: title).contains { tokens in
            titlePrefixTokensMatch(tokens, text: text)
        }
    }

    private static func titleWordVariants(for title: String) -> [[String]] {
        var variants: [[String]] = []

        let full = matchWords(title)
        if !full.isEmpty { variants.append(full) }

        if let stripped = stripHeadingLabelPrefix(from: title) {
            let tail = matchWords(stripped)
            if tail.count >= 2 && !variants.contains(tail) {
                variants.append(tail)
            }
        }

        return variants
    }

    private static func stripHeadingLabelPrefix(from title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(
            of: #"^(chapter|part|section|appendix|article|book)\s+[ivxlcdm\d]{1,8}\s*[:.]?\s*"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let remainder = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? nil : remainder
    }

    private static func titlePrefixTokensMatch(_ titleTokens: [String], text: String) -> Bool {
        let textTokens = matchWords(text)
        guard !titleTokens.isEmpty, !textTokens.isEmpty else { return false }
        return orderedPrefixMatch(prefix: titleTokens, full: textTokens)
            || (textTokens.count >= 2 && orderedPrefixMatch(prefix: textTokens, full: titleTokens))
    }

    private static func orderedPrefixMatch(prefix: [String], full: [String]) -> Bool {
        guard full.count >= prefix.count else { return false }
        for (lhs, rhs) in zip(prefix, full) {
            if normalizedHeadingToken(lhs) != normalizedHeadingToken(rhs) {
                return false
            }
        }
        return true
    }

    private static func normalizedHeadingToken(_ token: String) -> String {
        token.localizedLowercase
            .replacingOccurrences(of: "l", with: "1")
            .replacingOccurrences(of: "i", with: "1")
    }

    private static func headingTitleClusterRanges(
        around index: Int,
        allLines: [PDFTextLine],
        bodyFont: Double,
        bodyStartIndex: Int,
        hasFontSignal: Bool
    ) -> [[Int]] {
        guard allLines.indices.contains(index) else { return [] }
        var start = index
        var end = index

        while let previous = previousHeadingTitleFragmentIndex(
            before: start,
            allLines: allLines,
            bodyFont: bodyFont,
            bodyStartIndex: bodyStartIndex,
            hasFontSignal: hasFontSignal
        ) {
            start = previous
        }

        while let next = nextHeadingTitleFragmentIndex(
            after: end,
            allLines: allLines,
            bodyFont: bodyFont,
            hasFontSignal: hasFontSignal
        ) {
            end = next
        }

        let indices = Array(start...end)
        guard indices.count > 1 else { return [[index]] }

        var ranges: [[Int]] = [[index]]
        for lower in 0..<indices.count {
            for upper in lower..<indices.count {
                let range = Array(indices[lower...upper])
                guard range.contains(index) else { continue }
                guard range.count <= 6 else { continue }
                let clusterText = range.map { allLines[$0].text }.joined(separator: " ")
                guard looksLikeHeadingClusterText(clusterText) else { continue }
                ranges.append(range)
            }
        }
        return ranges
    }

    private static func previousHeadingTitleFragmentIndex(
        before index: Int,
        allLines: [PDFTextLine],
        bodyFont: Double,
        bodyStartIndex: Int,
        hasFontSignal: Bool
    ) -> Int? {
        guard index > bodyStartIndex else { return nil }
        let previous = allLines[index - 1]
        let current = allLines[index]
        guard previous.pageIndex == current.pageIndex else { return nil }
        guard linesAreAdjacent(previous, current) else { return nil }
        guard headingTitleFragmentLooksPlausible(
            previous,
            bodyFont: bodyFont,
            hasFontSignal: hasFontSignal,
            allowGapAbove: false
        ) else { return nil }
        return index - 1
    }

    private static func nextHeadingTitleFragmentIndex(
        after index: Int,
        allLines: [PDFTextLine],
        bodyFont: Double,
        hasFontSignal: Bool
    ) -> Int? {
        guard index + 1 < allLines.count else { return nil }
        let current = allLines[index]
        let next = allLines[index + 1]
        guard next.pageIndex == current.pageIndex else { return nil }
        guard linesAreAdjacent(current, next) else { return nil }
        guard headingTitleFragmentLooksPlausible(
            next,
            bodyFont: bodyFont,
            hasFontSignal: hasFontSignal,
            allowGapAbove: false
        ) else { return nil }
        return index + 1
    }

    private static func headingTitleFragmentLooksPlausible(
        _ line: PDFTextLine,
        bodyFont: Double,
        hasFontSignal: Bool,
        allowGapAbove: Bool
    ) -> Bool {
        guard !isContentsLeaderLine(line.text) else { return false }
        let wordCount = line.text.split(separator: " ").count
        guard line.text.count <= 120, wordCount <= 12 else { return false }
        if isHeadingLabelLine(line.text) || isNumericHeadingLabelLine(line.text) { return true }
        if hasFontSignal && standsOut(line, bodyFont: bodyFont) { return true }
        if allowGapAbove && line.gapAbove >= 16 { return true }
        return looksLikeHeadingClusterFragment(line.text) && (!hasFontSignal || line.gapAbove <= 10)
    }

    private static func looksLikeHeadingClusterFragment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let words = headingClusterWords(trimmed)
        guard !words.isEmpty, words.count <= 12, trimmed.count <= 120 else { return false }
        if isHeadingLabelLine(trimmed) || isNumericHeadingLabelLine(trimmed) { return true }
        guard let firstLetter = trimmed.first(where: { $0.isLetter }), firstLetter.isUppercase else { return false }
        guard !trimmed.hasSuffix("."), !trimmed.hasSuffix("!"), !trimmed.hasSuffix("?"), !trimmed.hasSuffix(";"), !trimmed.hasSuffix(":") else {
            return false
        }
        return true
    }

    private static func looksLikeHeadingClusterText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 240 else { return false }
        let words = headingClusterWords(trimmed)
        guard !words.isEmpty, words.count <= 28 else { return false }
        if let last = trimmed.last, ".!?;".contains(last) {
            return false
        }
        return true
    }

    private static func headingClusterWords(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }
}

// ========== BLOCK 02: KEY DERIVER - END ==========
