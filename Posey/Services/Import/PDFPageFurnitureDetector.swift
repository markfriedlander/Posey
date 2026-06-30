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
///   • A signature recurring in a margin band on ≥ `minFraction` of pages AND on
///     ≥ `minPages` pages is furniture → those band lines are dropped.
///
/// SAFETY — this project's worst scar is eating real content (Dracula ch14–27).
/// Every guard favors under-stripping over over-stripping:
///   • short docs (< `minDocPages`) are left entirely untouched — recurrence is
///     unreliable there;
///   • only margin-band lines are ever removed, never body lines;
///   • removal requires IDENTICAL normalized text recurring across many pages — a
///     real body line is never the identical first/last line on a third of pages;
///   • per-CHAPTER running headers (the title changes each chapter) never reach the
///     document-wide fraction, so they survive — only document-CONSTANT furniture
///     (one signature across the whole book) is removed.
///
/// Note: Crypto's ChmMagic banner is already stripped per-line in
/// `PDFLineExtractor` (brand stripper) before these arrays exist, so this detector
/// never sees it — the two layers compose (brand net + general recurrence net).
///
/// ACCEPTED RESIDUAL (Mark, 2026-06-30): low-frequency furniture that the source
/// PDF extracts INCONSISTENTLY is deliberately left. E.g. the Antifa handbook's
/// "MARK BRAY" author footer is isolated as its own line on only ~13 of 286 pages
/// (iOS merges it into body text on the rest), well under the 30% threshold. We do
/// NOT lower the threshold to grab it — that would also remove this book's real
/// recurring structure ("NOTES" section headers, "***" scene breaks). An LLM
/// header/footer judge was considered to catch this long tail and rejected as not
/// worth the hallucination / eat-real-headings risk for a cosmetic, unnoticed
/// residual. Under-strip ≫ over-strip remains the rule.
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
                       minFraction: Double = 0.30,
                       minPages: Int = 5,
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

        // A key is furniture iff it clears BOTH the fraction and the absolute floor.
        let need = max(minPages, Int((Double(pageCount) * minFraction).rounded(.up)))
        var furniture = Set<String>()
        var removed: [Removal] = []
        for (key, pages) in pagesForSignature where pages.count >= need {
            furniture.insert(key)
            removed.append(Removal(signature: key, pages: pages.count,
                                   sample: sampleForSignature[key] ?? key))
        }
        guard !furniture.isEmpty else { return Result(cleaned: linesByPage, removed: []) }

        // Drop furniture lines — ONLY in a margin band. KEEP THE FIRST occurrence
        // when removal is driven by a pure WORD-PHRASE signature (Mark, 2026-06-30):
        // a running header that IS the document's real title must keep its one legit
        // first appearance. Numeric/structural furniture (a "#"-bearing signature, or
        // a fixed numeric-anchor stamp) has no legit single instance → remove ALL.
        // Walking pages then lines in order visits reading order, so `keptFirst`
        // keeps the earliest title instance.
        var cleaned: [[PDFTextLine]] = []
        cleaned.reserveCapacity(linesByPage.count)
        var keptFirst = Set<String>()
        for page in linesByPage {
            let band = bandIndices(page.count)
            var out: [PDFTextLine] = []
            out.reserveCapacity(page.count)
            for (i, line) in page.enumerated() {
                if band.contains(i), wordCount(line.text) <= maxHeaderWords {
                    let sig = signature(line.text)
                    let anchor = numericAnchor(line.text)
                    let byWord = furniture.contains(sig)
                    let byAnchor = anchor.map { furniture.contains($0) } ?? false
                    if byWord || byAnchor {
                        // keep-first ONLY for a pure word-phrase title: matched by a
                        // word signature, no "#", not a numeric-anchor stamp.
                        if byWord, !byAnchor, !sig.contains("#"), keptFirst.insert(sig).inserted {
                            out.append(line)   // legit first title instance survives
                        }
                        continue               // everything else removed
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
}

// ========== BLOCK 01: PDF PAGE FURNITURE DETECTOR - END ==========
