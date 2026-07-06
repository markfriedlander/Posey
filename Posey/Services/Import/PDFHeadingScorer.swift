import Foundation

// ========== BLOCK 01: STYLE-INFERENCE ENGINE (Piece B) - START ==========

/// PDFHeadingScorer — the **style-inference engine** from `PDF_REBUILD_PLAN.md`
/// (Piece B), finished 2026-07-05 (CC#26, Mark's direction).
///
/// The idea (Mark's, named by GPT): a PDF heading detector must not be a fixed
/// "what is a heading" rule — every book prints its headings differently. So we
/// SEED from a few titles we already know (from the outline or the printed
/// contents), learn *this book's* heading "look" — a `HeadingProfile` (font size
/// vs body, weight, caps, numbering, whitespace, length) — then score EVERY line
/// by *"how much does this resemble the headings I've already seen?"*. Because we
/// score by shape, an OCR-garbled or wrapped heading is still found.
///
/// It emits its OWN heading map. The caller A/B-compares that against the map
/// derived from the file's built-in structure and keeps whichever is stronger
/// (`mapQuality`). That comparison IS the reliability gate — no hand-built
/// "is the outline trustworthy?" heuristic needed (Mark's insight, 2026-07-05).
///
/// FONT IS A FIRST-CLASS SIGNAL here. `PDFTextLine.fontSize/isBold/isAllCaps` are
/// real on the iOS device (they read as blank on macOS), so this engine is
/// verified ON THE PHONE, never bent to run font-blind on the Mac.
struct HeadingProfile {
    /// Most common line font in the document (the body baseline).
    let bodyFont: Double
    /// Median font size of the seed headings (relative prominence = headingFont − bodyFont).
    let headingFont: Double
    /// Fraction of seed headings that are bold / all-caps / open with a section number.
    let boldFraction: Double
    let capsFraction: Double
    let numberedFraction: Double
    /// Median whitespace above a seed heading, and median word count.
    let medianGapAbove: Double
    let medianWordCount: Double
    /// How many real seed headings we learned from (confidence in the profile).
    let seedCount: Int
    /// Whether this document exposes real font signals at all (false → macOS/no-font;
    /// the engine then leans on geometry + numbering + length instead of size/weight).
    let hasFontSignal: Bool
}

enum PDFHeadingScorer {

    // ----- Tunable weights (named knobs, per the modular ethos — not magic numbers). -----
    private static let wFont = 0.30      // font size prominence vs body
    private static let wWeight = 0.15    // bold matches the profile
    private static let wCaps = 0.15      // caps matches the profile
    private static let wGap = 0.15       // whitespace above resembles a heading
    private static let wNumber = 0.15    // opens with a section number when the book's headings do
    private static let wLength = 0.10    // short / standalone like a heading
    private static let minResemblance = 0.45   // below this a line is not heading-shaped
    private static let titleMatchFloor = 0.6   // word-overlap needed to call a line "this title"

    // ========== BLOCK 01: STYLE-INFERENCE ENGINE (Piece B) - END ==========

    // ========== BLOCK 02: PROFILE DERIVATION (seed → learn the book's look) - START ==========

    /// Learn this book's heading look from the seed titles. For each seed title we
    /// find its most heading-shaped appearance (word-overlap match, preferring the
    /// most prominent copy), and aggregate that population into a `HeadingProfile`.
    static func deriveProfile(seedTitles: [String], allLines: [PDFTextLine]) -> HeadingProfile {
        let bodyFont = bodyFontSize(of: allLines)
        let hasFont = allLines.contains { $0.fontSize > 0 }

        var samples: [PDFTextLine] = []
        for title in seedTitles {
            let tokens = Set(words(title))
            guard !tokens.isEmpty else { continue }
            // Among the lines that match this title's words, take the most
            // heading-shaped one (prominence when we have font, else biggest gap).
            let matches = allLines.filter { titleOverlap(tokens, $0.text) >= titleMatchFloor }
            guard let best = matches.max(by: { prominence($0, bodyFont: bodyFont) < prominence($1, bodyFont: bodyFont) }) else { continue }
            samples.append(best)
        }

        guard !samples.isEmpty else {
            return HeadingProfile(bodyFont: bodyFont, headingFont: bodyFont,
                                  boldFraction: 0, capsFraction: 0, numberedFraction: 0,
                                  medianGapAbove: 0, medianWordCount: 3,
                                  seedCount: 0, hasFontSignal: hasFont)
        }

        func median(_ xs: [Double]) -> Double {
            let s = xs.sorted(); let n = s.count
            return n == 0 ? 0 : (n % 2 == 1 ? s[n/2] : (s[n/2 - 1] + s[n/2]) / 2)
        }
        let n = Double(samples.count)
        return HeadingProfile(
            bodyFont: bodyFont,
            headingFont: median(samples.map { $0.fontSize }),
            boldFraction: Double(samples.filter { $0.isBold }.count) / n,
            capsFraction: Double(samples.filter { $0.isAllCaps }.count) / n,
            numberedFraction: Double(samples.filter { opensWithSectionNumber($0.text) }.count) / n,
            medianGapAbove: median(samples.map { $0.gapAbove }),
            medianWordCount: median(samples.map { Double(wordCount($0.text)) }),
            seedCount: samples.count,
            hasFontSignal: hasFont
        )
    }

    // ========== BLOCK 02: PROFILE DERIVATION - END ==========

    // ========== BLOCK 03: RESEMBLANCE SCORING (score every line 0..1) - START ==========

    /// Score how much a line resembles this book's learned headings, 0..1.
    /// Each signal contributes its weight × how well the line matches the profile.
    static func resemblance(_ line: PDFTextLine, profile: HeadingProfile) -> Double {
        var score = 0.0

        if profile.hasFontSignal, profile.headingFont > profile.bodyFont + 0.5 {
            // Font prominence: 1.0 when the line is as big as the profile heading,
            // 0 at body size, clamped. The strongest signal when the book has one.
            let span = max(1.0, profile.headingFont - profile.bodyFont)
            score += wFont * clamp((line.fontSize - profile.bodyFont) / span)
        } else {
            // No font hierarchy (flat academic / no-font): redistribute font weight
            // onto numbering + gap, the signals that still work.
            score += wFont * (opensWithSectionNumber(line.text) ? 0.7 : 0.0)
        }

        // Weight (bold) — reward matching the profile's tendency.
        if profile.boldFraction >= 0.5 { score += wWeight * (line.isBold ? 1.0 : 0.0) }
        else { score += wWeight * (line.isBold == (profile.boldFraction > 0.25) ? 0.5 : 0.0) }

        // Caps.
        if profile.capsFraction >= 0.5 { score += wCaps * (line.isAllCaps ? 1.0 : 0.0) }
        else { score += wCaps * (line.isAllCaps ? 0.3 : 0.5) }

        // Whitespace above — a heading usually has a gap above it.
        let gapTarget = max(profile.medianGapAbove, profile.bodyFont)
        score += wGap * clamp(line.gapAbove / max(1.0, gapTarget))

        // Numbering — reward opening with a section number when the book's headings do.
        if profile.numberedFraction >= 0.4 {
            score += wNumber * (opensWithSectionNumber(line.text) ? 1.0 : 0.0)
        } else {
            score += wNumber * 0.5   // neutral when the book doesn't number its headings
        }

        // Title-shape — a heading is a TITLE (capitalized / all-caps words), NOT a
        // sentence. This separates "2. UNION SECURITY" from "Section 2 the sum of
        // $500, it being agreed…" WITHOUT using length (Mark: real headings get very
        // long, so length is not a valid filter). Prose sentences are mostly
        // lowercase words → low title-shape; headings → high.
        score += wLength * titleShapeScore(line.text)

        return clamp(score)
    }

    /// Is a line heading-shaped enough to be a candidate at all?
    static func looksLikeHeading(_ line: PDFTextLine, profile: HeadingProfile) -> Bool {
        // Never let a contents-page dot-leader line or a long paragraph qualify.
        if isDotLeaderLine(line.text) { return false }
        if line.text.count > 200 { return false }
        return resemblance(line, profile: profile) >= minResemblance
    }

    // ========== BLOCK 03: RESEMBLANCE SCORING - END ==========

    // ========== BLOCK 04: SCORED MAP + A/B QUALITY - START ==========

    /// Build this engine's own heading map: anchor each seed title (IN ORDER) to
    /// the strongest heading-shaped body line that (a) matches the title's words
    /// and (b) comes after the previously anchored title (reading order). A title
    /// with no confident in-order candidate is SKIPPED (never fail silently —
    /// the caller reports the skipped count). Returns (title, line) pairs.
    static func scoredMap(seedTitles: [String], allLines: [PDFTextLine]) -> [(title: String, line: PDFTextLine, score: Double)] {
        let profile = deriveProfile(seedTitles: seedTitles, allLines: allLines)
        var out: [(title: String, line: PDFTextLine, score: Double)] = []
        var floor = 0   // reading-order cursor (index into allLines)

        for title in seedTitles {
            let tokens = Set(words(title))
            guard !tokens.isEmpty else { continue }
            var bestIdx = -1
            var bestScore = 0.0
            for i in floor..<allLines.count {
                let line = allLines[i]
                let overlap = titleOverlap(tokens, line.text)
                guard overlap >= titleMatchFloor else { continue }
                guard looksLikeHeading(line, profile: profile) else { continue }
                // Combined: how much it looks like a heading × how well it matches THIS title.
                let combined = resemblance(line, profile: profile) * 0.6 + overlap * 0.4
                if combined > bestScore { bestScore = combined; bestIdx = i }
            }
            if bestIdx >= 0 {
                out.append((title, allLines[bestIdx], bestScore))
                floor = bestIdx + 1
            }
        }
        return out
    }

    /// Quality of a heading map for A/B comparison (higher = better). Rewards
    /// placing many titles, in strictly increasing reading order, with confident
    /// scores; penalizes duplicates and out-of-order anchors. Used to choose
    /// between the scored map and the built-in map — the reliability gate.
    static func mapQuality(_ map: [(title: String, line: PDFTextLine, score: Double)],
                           allLines: [PDFTextLine]) -> Double {
        guard !map.isEmpty else { return 0 }
        let indexByLine = Dictionary(allLines.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var placed = 0, inOrder = 0, prev = -1
        var scoreSum = 0.0
        var seen = Set<Int>()
        for m in map {
            guard let idx = indexByLine[m.line] else { continue }
            placed += 1
            scoreSum += m.score
            if !seen.insert(idx).inserted { placed -= 1; continue }   // duplicate anchor — no credit
            if idx > prev { inOrder += 1; prev = idx }
        }
        guard placed > 0 else { return 0 }
        let orderRatio = Double(inOrder) / Double(placed)      // 1.0 = perfectly in order
        let avgScore = scoreSum / Double(placed)
        // Coverage (how many titles landed) × order cleanliness × confidence.
        return Double(placed) * orderRatio * (0.5 + 0.5 * avgScore)
    }

    /// FONT-INDEPENDENT health of a resolved built-in map — the cheap check the
    /// gate uses to decide whether the built-in TOC is trustworthy enough to SKIP
    /// the (heavier) seedless engine entirely. Uses ONLY placement + reading order,
    /// never font, so it is valid off-device too:
    ///  - placedRatio: fraction of the printed-TOC titles that anchored to a real
    ///    body line (a genuine TOC finds homes for most of its entries; a garbage
    ///    merged-PDF TOC — CBA — finds few).
    ///  - orderRatio: fraction of those anchors that run in strictly increasing
    ///    reading order (a genuine TOC is monotonic; scrambled matches are not).
    /// A high score on BOTH means the built-in map already describes the body, so
    /// the seedless engine (and its cost / noise) is unnecessary.
    static func builtinHealth(map: [(title: String, line: PDFTextLine)],
                              seedCount: Int,
                              allLines: [PDFTextLine]) -> (placedRatio: Double, orderRatio: Double, placed: Int) {
        guard !map.isEmpty, seedCount > 0 else { return (0, 0, 0) }
        let indexByLine = Dictionary(allLines.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var placed = 0, inOrder = 0, prev = -1
        var seen = Set<Int>()
        for m in map {
            guard let idx = indexByLine[m.line] else { continue }
            if !seen.insert(idx).inserted { continue }   // duplicate anchor — no double credit
            placed += 1
            if idx > prev { inOrder += 1; prev = idx }
        }
        guard placed > 0 else { return (0, 0, 0) }
        return (Double(placed) / Double(seedCount), Double(inOrder) / Double(placed), placed)
    }

    /// SEEDLESS detection — build a heading map from the PAGES themselves, with
    /// NO reliance on the (possibly garbage) built-in title list. This is the map
    /// that recovers structure when the built-in TOC is unusable (CBA): learn the
    /// profile from the population of prominent/numbered lines, then keep every
    /// line that resembles a heading, in reading order. The line's own text
    /// becomes the title. Font-driven → verified on the phone.
    static func detectHeadingsFromPages(allLines: [PDFTextLine]) -> [(line: PDFTextLine, score: Double)] {
        let bodyFont = bodyFontSize(of: allLines)
        let hasFont = allLines.contains { $0.fontSize > 0 }

        // Candidate = stands out from body (bigger / bold / caps) OR opens with a
        // section number; short/standalone; not a dot-leader contents line.
        let candidates = allLines.filter { l in
            if isDotLeaderLine(l.text) { return false }
            let wc = wordCount(l.text)
            // Generous bound only — real section titles get LONG (Mark). This is a
            // sanity cap against whole paragraphs, NOT a heading discriminator.
            guard wc >= 1, wc <= 40, l.text.count <= 250 else { return false }
            // A real heading carries TITLE TEXT, not just a bare marker — drops the
            // standalone subsection markers ("A.", "5.2 J.", "2.B. 3") that are short
            // caps lines but not chapter/section headings.
            guard hasTitleContent(l.text) else { return false }
            let standsOut = (hasFont && l.fontSize > bodyFont + 0.5) || l.isBold || l.isAllCaps
            return standsOut || opensWithSectionNumber(l.text)
        }
        guard !candidates.isEmpty else { return [] }
        ImportTrace.shared.event("      detectHeadingsFromPages: candidates=\(candidates.count) of \(allLines.count) lines; pass1 begin")

        func median(_ xs: [Double]) -> Double {
            let s = xs.sorted(); let n = s.count
            return n == 0 ? 0 : (n % 2 == 1 ? s[n/2] : (s[n/2 - 1] + s[n/2]) / 2)
        }
        let n = Double(candidates.count)
        let profile = HeadingProfile(
            bodyFont: bodyFont,
            headingFont: median(candidates.map { $0.fontSize }),
            boldFraction: Double(candidates.filter { $0.isBold }.count) / n,
            capsFraction: Double(candidates.filter { $0.isAllCaps }.count) / n,
            numberedFraction: Double(candidates.filter { opensWithSectionNumber($0.text) }.count) / n,
            medianGapAbove: median(candidates.map { $0.gapAbove }),
            medianWordCount: median(candidates.map { Double(wordCount($0.text)) }),
            seedCount: candidates.count,
            hasFontSignal: hasFont)

        // PASS 1 — confident headings (strong resemblance). Record each with its
        // document index and (via leadingSectionInt) its top-level section number.
        var chosenIdx = Set<Int>()
        var picks: [(idx: Int, line: PDFTextLine, score: Double)] = []
        for i in allLines.indices {
            let l = allLines[i]
            if isDotLeaderLine(l.text) { continue }
            let wc = wordCount(l.text)
            guard wc >= 1, wc <= 40, l.text.count <= 250, hasTitleContent(l.text) else { continue }
            let standsOut = (hasFont && l.fontSize > bodyFont + 0.5) || l.isBold || l.isAllCaps
            guard standsOut || opensWithSectionNumber(l.text) else { continue }
            let s = resemblance(l, profile: profile)
            if s >= 0.70 { picks.append((i, l, s)); chosenIdx.insert(i) }
        }

        ImportTrace.shared.event("      detectHeadingsFromPages: pass1 done (\(picks.count) picks); pass2 begin")

        // PASS 2 — gap-fill by the KNOWN number sequence (Mark, 2026-07-05). Between
        // two confident numbered anchors whose numbers SKIP (18 → 24), sections
        // 19..23 MUST exist in that span. Search only that span for the missing
        // number leading a heading-ish line — a relaxed bar, because we know exactly
        // what number to expect and where. Recovers headings that just missed pass 1.
        let anchors = picks.compactMap { p -> (idx: Int, num: Int)? in
            leadingSectionInt(p.line.text).map { (p.idx, $0) }
        }.sorted { $0.idx < $1.idx }
        if anchors.count >= 2 {
            for k in 1..<anchors.count {
                let a = anchors[k - 1], b = anchors[k]
                guard b.num > a.num + 1, b.num - a.num <= 30, b.idx > a.idx + 1 else { continue }
                for missing in (a.num + 1)..<b.num {
                    for i in (a.idx + 1)..<b.idx where !chosenIdx.contains(i) {
                        let l = allLines[i]
                        guard leadingSectionInt(l.text) == missing, !isDotLeaderLine(l.text) else { continue }
                        // Case A — the number and title share ONE line ("21. Dressing Rooms").
                        if hasTitleContent(l.text), wordCount(l.text) <= 40 {
                            picks.append((i, l, max(resemblance(l, profile: profile), 0.70)))
                            chosenIdx.insert(i)
                            break
                        }
                        // Case B — SPLIT heading: the section number is alone on its line
                        // ("21.") and its title is the NEXT line ("DRESSING ROOMS AND OTHER
                        // FACILITIES") — a common PDF line-wrap the single-line check above
                        // can't see, and the reason CBA §21–23 were dropped even though the
                        // number sequence guaranteed they exist here. Anchor the TITLE line;
                        // mergeResolvedHeadingLines pulls the bare number back onto it, so the
                        // recovered heading reads "21. DRESSING ROOMS…" in both nav and body.
                        if i + 1 < allLines.count, !chosenIdx.contains(i + 1) {
                            let titleLine = allLines[i + 1]
                            if hasTitleContent(titleLine.text), !isDotLeaderLine(titleLine.text),
                               wordCount(titleLine.text) <= 40, titleShapeScore(titleLine.text) >= 0.6 {
                                picks.append((i + 1, titleLine, 0.70))
                                chosenIdx.insert(i + 1)
                                break
                            }
                        }
                    }
                }
            }
        }

        return picks.sorted { $0.idx < $1.idx }.map { (line: $0.line, score: $0.score) }
    }

    // ========== BLOCK 04: SCORED MAP + A/B QUALITY - END ==========

    // ========== BLOCK 05: SHARED HELPERS - START ==========

    static func bodyFontSize(of lines: [PDFTextLine]) -> Double {
        var counts: [Double: Int] = [:]
        for l in lines where !l.text.trimmingCharacters(in: .whitespaces).isEmpty {
            counts[(l.fontSize * 2).rounded() / 2, default: 0] += 1   // 0.5pt buckets
        }
        return counts.max { $0.value < $1.value }?.key ?? 0
    }

    private static func prominence(_ line: PDFTextLine, bodyFont: Double) -> Double {
        var p = 0.0
        p += (line.fontSize - bodyFont) * 2
        if line.isBold { p += 2 }
        if line.isAllCaps { p += 1.5 }
        if line.gapAbove > bodyFont { p += 1 }
        return p
    }

    static func words(_ s: String) -> [String] {
        s.lowercased()
         .components(separatedBy: CharacterSet.alphanumerics.inverted)
         .filter { $0.count >= 2 }
    }

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " }).count
    }

    /// Fraction of the TITLE's words present in the line (0..1).
    private static func titleOverlap(_ titleTokens: Set<String>, _ text: String) -> Double {
        guard !titleTokens.isEmpty else { return 0 }
        let lineTokens = Set(words(text))
        return Double(titleTokens.intersection(lineTokens).count) / Double(titleTokens.count)
    }

    /// A real heading has TITLE TEXT after any leading marker. Strip a leading
    /// section number / letter / label ("2.", "5.2", "A.", "EXHIBIT C:") and require
    /// a remaining content word (≥4 letters). "3. STRIKES"→"STRIKES" ✓;
    /// "A."→"" ✗; "5.2 J."→"J." ✗; "GENERAL PROVISIONS" ✓.
    /// Fraction of a line's words that start uppercase (Title-case or ALL-CAPS),
    /// ignoring a leading section-number marker. High for a heading title
    /// ("UNION SECURITY" → 1.0), low for a prose sentence ("the sum of $500, it
    /// being agreed…" → ~0.1). The title-vs-sentence discriminator that replaces
    /// length (Mark, 2026-07-05).
    static func titleShapeScore(_ text: String) -> Double {
        let stripped = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(
            of: #"^[0-9IVXLC]+(?:[.\-][0-9A-Za-z]+)*[.:]?\s*"#, with: "", options: .regularExpression)
        let words = stripped.split(separator: " ").filter { $0.contains(where: { $0.isLetter }) }
        guard !words.isEmpty else { return 0 }
        let titled = words.filter { w in
            guard let firstLetter = w.first(where: { $0.isLetter }) else { return false }
            return firstLetter.isUppercase
        }
        return Double(titled.count) / Double(words.count)
    }

    static func hasTitleContent(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(
            of: #"^(?i:(?:chapter|part|section|article|schedule|exhibit)\s+)?[0-9IVXLC]+(?:[.\-][0-9A-Za-z]+)*[.:]?\s*"#,
            with: "", options: .regularExpression)
        return stripped.range(of: #"[A-Za-z]{4,}"#, options: .regularExpression) != nil
    }

    /// The leading TOP-LEVEL section number of a heading line, if any:
    /// "18. Trailers"→18, "5.1 Supplemental…"→5, "Section 24 …"→24. Used by the
    /// gap-fill pass to reason about the known number sequence.
    static func leadingSectionInt(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: #"^(?:(?i:section|schedule|article)\s+)?(\d{1,3})\b"#,
                              options: .regularExpression) else { return nil }
        let head = t[r]
        if let nr = head.range(of: #"\d{1,3}"#, options: .regularExpression) { return Int(head[nr]) }
        return nil
    }

    static func opensWithSectionNumber(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces)
            .range(of: #"^(?:(?i:chapter|part|section|article|schedule)\s+)?\d{1,3}(?:\.\d{1,3}){0,3}\.?\s+\p{L}"#,
                   options: .regularExpression) != nil
    }

    static func isDotLeaderLine(_ text: String) -> Bool {
        text.range(of: #"[.·•…]{3,}\s*\d{1,4}\s*$"#, options: .regularExpression) != nil
    }

    private static func clamp(_ x: Double) -> Double { min(1.0, max(0.0, x)) }

    // ========== BLOCK 05: SHARED HELPERS - END ==========
}
