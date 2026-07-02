import Foundation

// ========== BLOCK 01: PDF PAGE FURNITURE DETECTOR - START ==========

/// Removes recurring PAGE FURNITURE — running headers, footers, page-number
/// stamps, declassification/converter banners — from a PDF's per-page line
/// arrays BEFORE content units are built.
///
/// Why this exists (Mark, 2026-06-30): the brand-anchored `PDFWatermarkStripper`
/// only knows four literal strings (ChmMagic / Aspose / Calibre / generic-eval).
/// That is a *ChmMagic stripper*, not a watermark stripper. Real documents carry
/// document-SPECIFIC furniture we can't hardcode: "ANTIFA" atop every page of the
/// Antifa handbook, "DOCID: 3803783" stamped through a declassified file, the book
/// title on every page, bare page numbers. All of it pollutes the reading
/// experience AND the RAG index, and fails the User hat.
///
/// METHOD — position + recurrence (the standard, robust approach), using the
/// geometry `PDFLineExtractor` already carries:
///   • Only ever consider the TOP band (first `bandSize` lines, reading order)
///     and BOTTOM band (last `bandSize` lines) of each page — NEVER body lines.
///   • Normalize a candidate line to a SIGNATURE: lowercase, digit-runs → "#"
///     (so "Page 12" / "Page 13" and bare "12" / "13" collapse to one signature),
///     every non-alphanumeric folded to a single space.
///   • A signature recurring in a margin band on ≥ `runnerMinPages` pages (an
///     ABSOLUTE floor, not a fraction of the book) is furniture → those band lines
///     are dropped.
///
/// WHY AN ABSOLUTE FLOOR (CC#19, 2026-07-02, Mark-approved): the old rule needed
/// a signature on ≥30% of the WHOLE book. A per-CHAPTER running header ("Strange
/// Loops…" atop every page of one GEB chapter, "Introduction"/"NOTES"/"APPENDIX A"
/// atop each section of Antifa) only appears within its own section, so it never
/// reaches a document-wide fraction and survived — littering the reader and the RAG
/// index. But a real body line is NEVER the identical ≤`maxHeaderWords`-word first/
/// last line on 6+ pages. So the recurrence COUNT itself is the signal; the fraction
/// was overly conservative on long books. Page numbers ride the same net: bare "12"/
/// "13" collapse to the "#" signature, which recurs far past the floor.
///
/// SAFETY — this project's worst scar is eating real content (Dracula ch14–27).
/// Every guard favors under-stripping over over-stripping:
///   • short docs (< `minDocPages`) are left entirely untouched — recurrence is
///     unreliable there;
///   • only margin-band lines (first/last `bandSize`) are ever removed, never body;
///   • removal requires IDENTICAL normalized text recurring across ≥ `runnerMinPages`
///     pages — a real body sentence never repeats verbatim as a margin line that often;
///   • KEEP-FIRST: a pure word-phrase title keeps its earliest occurrence, so a
///     section/book title that exists ONLY as a running header is never lost entirely
///     — only its repeats are stripped. (Cost: one header copy per signature survives.)
///
/// Note: Crypto's ChmMagic banner is already stripped per-line in
/// `PDFLineExtractor` (brand stripper) before these arrays exist, so this detector
/// never sees it — the two layers compose (brand net + general recurrence net).
///
/// RESIDUAL (CC#19, 2026-07-02): with the absolute floor, the Antifa "MARK BRAY"
/// footer (~13 pages) and the per-section headers ("NOTES" ×17, "INTRODUCTION" ×7,
/// "APPENDIX A" ×5) now qualify and are stripped — KEEP-FIRST leaves ONE copy of
/// each word-phrase title (safe: never lose a title entirely). "***" scene breaks
/// are non-alphanumeric → empty signature → never tallied, so untouched. The only
/// remaining residual is that single kept copy per running-header signature, which
/// can still block a cross-page hyphen rejoin on the page it lands (honest, minor).
/// Under-strip ≫ over-strip remains the rule; the letter-count no-body-lost check
/// (ImporterGateTests) guards every change.
enum PDFPageFurnitureDetector {

    /// One furniture signature that was removed, with how many pages carried it
    /// and a human-readable sample (for logging / antenna visibility / tests).
    struct Removal: Equatable {
        let signature: String
        let pages: Int
        let sample: String
    }

    struct Result {
        let cleaned: [[PDFTextLine]]
        let removed: [Removal]
    }

    static func detect(in linesByPage: [[PDFTextLine]],
                       bandSize: Int = 2,
                       runnerMinPages: Int = 6,
                       minDocPages: Int = 6,
                       maxHeaderWords: Int = 8) -> Result {
        let pageCount = linesByPage.count
        guard pageCount >= minDocPages else { return Result(cleaned: linesByPage, removed: []) }

        // Margin-band positions for a page of `count` lines: the first `bandSize`
        // (top) and last `bandSize` (bottom) in reading order.
        func bandIndices(_ count: Int) -> Set<Int> {
            var s = Set<Int>()
            for i in 0..<min(bandSize, count) { s.insert(i) }
            for i in max(0, count - bandSize)..<count { s.insert(i) }
            return s
        }

        // Tally: signature → set of pages where it appears in a margin band.
        var pagesForSignature: [String: Set<Int>] = [:]
        var sampleForSignature: [String: String] = [:]
        for (p, page) in linesByPage.enumerated() {
            let band = bandIndices(page.count)
            var seenOnThisPage = Set<String>()
            for i in band {
                let line = page[i]
                // Furniture candidacy is by WORD COUNT, not character count: a
                // running header / stamp / URL is FEW WORDS (a long archive URL is
                // one giant "word"); a body sentence is MANY words. The old 80-char
                // cap wrongly excluded long URL furniture — the Wayback-Machine
                // header that iOS extracts (89–114 chars, ≤5 words) survived on the
                // PHONE while macOS extraction never produced it. The phone is the
                // truth (Mark, 2026-06-30); word-count candidacy works on both the
                // iOS and the macOS-iPad PDF engines.
                guard wordCount(line.text) <= maxHeaderWords else { continue }
                // Two furniture KEYS per line: (1) the digit-collapsed text
                // signature — running headers, "Page N of M", bare page numbers;
                // (2) a fixed NUMERIC ANCHOR — the longest ≥4-digit run, if any. A
                // stamp ID ("DOCID: 3803783") or an archive URL ("…/web/20010522…/")
                // keeps the SAME number on every page even when OCR mangles the
                // letters, so the anchor unifies all variants; page numbers VARY
                // (and are 1–3 digits), so the anchor never collapses them together.
                var keys: [String] = []
                let sig = signature(line.text)
                if !sig.isEmpty {
                    keys.append(sig)
                    if sampleForSignature[sig] == nil { sampleForSignature[sig] = line.text }
                }
                if let anchor = numericAnchor(line.text) {
                    keys.append(anchor)
                    if sampleForSignature[anchor] == nil { sampleForSignature[anchor] = line.text }
                }
                for key in keys where seenOnThisPage.insert(key).inserted {
                    pagesForSignature[key, default: []].insert(p)
                }
            }
        }

        // A key is furniture iff it recurs on ≥ the absolute floor of pages. No
        // fraction: a per-section running header only spans its own section but is
        // still furniture (see WHY AN ABSOLUTE FLOOR above).
        let need = runnerMinPages
        var furniture = Set<String>()
        var removed: [Removal] = []
        for (key, pages) in pagesForSignature where pages.count >= need {
            furniture.insert(key)
            removed.append(Removal(signature: key, pages: pages.count,
                                   sample: sampleForSignature[key] ?? key))
        }
        // NB: do NOT early-return when `furniture` is empty — lone page numbers (below)
        // are removed unconditionally, independent of the recurrence set.

        // Drop furniture lines — ONLY in a margin band. Two mechanisms:
        //   (a) LONE PAGE NUMBERS — a band line that is nothing but a page number
        //       (pure digits, or a strict Roman numeral like "xix") is ALWAYS furniture,
        //       no recurrence needed, remove ALL. Critical: a Roman page number varies
        //       per page ("xiv","xv"…) so it never recurs into the signature set, yet if
        //       left it corrupts a cross-page hyphen rejoin ("move-" + "xix" → "movexix"
        //       once the interposed running header is stripped — caught on device
        //       2026-07-02).
        //   (b) RECURRENCE furniture — signatures over the absolute floor. KEEP THE FIRST
        //       occurrence of a pure WORD-PHRASE title (never lose a title entirely);
        //       numeric/"#"/anchor-stamp furniture has no legit single instance → remove
        //       ALL. Walking pages then lines visits reading order, so `keptFirst` keeps
        //       the earliest title instance.
        var cleaned: [[PDFTextLine]] = []
        cleaned.reserveCapacity(linesByPage.count)
        var keptFirst = Set<String>()
        for page in linesByPage {
            let band = bandIndices(page.count)
            var out: [PDFTextLine] = []
            out.reserveCapacity(page.count)
            for (i, line) in page.enumerated() {
                if band.contains(i) {
                    if isLonePageNumber(line.text) { continue }   // (a) always furniture
                    if wordCount(line.text) <= maxHeaderWords {
                        let sig = signature(line.text)
                        let anchor = numericAnchor(line.text)
                        let byWord = furniture.contains(sig)
                        let byAnchor = anchor.map { furniture.contains($0) } ?? false
                        if byWord || byAnchor {
                            if byWord, !byAnchor, !sig.contains("#"), keptFirst.insert(sig).inserted {
                                out.append(line)   // (b) legit first title instance survives
                            }
                            continue               // everything else removed
                        }
                    }
                }
                out.append(line)
            }
            cleaned.append(out)
        }
        return Result(cleaned: cleaned, removed: removed.sorted { $0.pages > $1.pages })
    }

    /// Normalized recurrence signature: lowercase; each run of digits collapses to
    /// a single "#"; every non-alphanumeric character folds to one space; trimmed.
    /// So "Page 12" and "Page 13" → "page #"; bare "12" / "13" → "#"; "DOCID:
    /// 3803783" → "docid #".
    static func signature(_ text: String) -> String {
        var out = ""
        var lastWasSpace = false
        var inDigitRun = false
        for ch in text.lowercased() {
            if ch.isNumber {
                if !inDigitRun { out.append("#"); inDigitRun = true; lastWasSpace = false }
                continue
            }
            inDigitRun = false
            if ch.isLetter {
                out.append(ch); lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" "); lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// A line's fixed numeric fingerprint: its longest run of ≥4 digits, as
    /// "num:<digits>", else nil. ≥4 digits excludes page numbers (1–3 digits) and,
    /// because the key carries the ACTUAL number, two different page numbers never
    /// collapse — only a CONSTANT id/year/edition recurring across pages becomes
    /// furniture. So "DOCID: 3803783" (every spelling) → "num:3803783"; "Page 12" →
    /// nil; a 4-digit page number → its own unique key (never recurs) → ignored.
    static func numericAnchor(_ text: String) -> String? {
        var best = "", current = ""
        for ch in text {
            if ch.isNumber {
                current.append(ch)
                if current.count > best.count { best = current }
            } else {
                current = ""
            }
        }
        return best.count >= 4 ? "num:\(best)" : nil
    }

    /// Whitespace-separated word count (rough — collapses runs).
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }

    /// A band line that is NOTHING but a page number — pure digits ("246"), or a
    /// strict Roman numeral 3–7 chars ("xix", "mcmlxxxiv"). Always furniture. Roman
    /// numerals need explicit handling because they vary per page and so never recur
    /// into the signature set. The STRICT pattern (proper Roman ordering, anchored)
    /// rejects real words that only use those letters — "civil", "mill", "did". We
    /// require length ≥3: 1-char ("i","v","x") and 2-char ("vi","xi","mi","li","di")
    /// Roman numerals overlap too many real words / initials / list markers to strip
    /// safely; 3+ char Roman words are vanishingly rare as a lone margin line, so the
    /// under-strip ≫ over-strip rule holds. (Front-matter pages i–xx below 3 chars are
    /// left — harmless.)
    static func isLonePageNumber(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        if t.allSatisfy({ $0.isNumber }) { return true }
        guard t.count >= 3, t.count <= 7 else { return false }
        let roman = "^m{0,3}(cm|cd|d?c{0,3})(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})$"
        guard let re = try? NSRegularExpression(pattern: roman, options: [.caseInsensitive]) else {
            return false
        }
        return re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }
}

// ========== BLOCK 01: PDF PAGE FURNITURE DETECTOR - END ==========
