import Foundation

// ===== BLOCK 01: EDITORIAL FRONT-MATTER DETECTOR - START =====

/// Identifies EDITORIAL prose — a publisher's or critic's introduction/preface
/// that discusses the book and its author — as distinct from the AUTHOR'S OWN
/// work (which includes authorial prefaces, in-story letters, etymologies, and
/// journals, and must be KEPT). Used to exclude editorial front matter from the
/// Ask Posey RAG/RAPTOR pool so it can't be summarized + served as if it were
/// the work (e.g. Saintsbury's preface in Gutenberg's Pride & Prejudice, which
/// discusses Mansfield Park / Emma / Austen's biography — caught contaminating
/// P&P's RAPTOR tree, 2026-06-27).
///
/// ### Why a heuristic, not an LLM
/// A 2026-06-27 model sweep (same prompt, real passages) showed EVERY on-device
/// engine — Gemma 5/6, Qwen/Llama 4/6, Dolphin 2/6, AND AFM 4/6 — calls an
/// eloquent editorial preface "the work." None can draw this line. The robust,
/// MEASURED signal is structural: editorial prose names THE BOOK'S OWN AUTHOR in
/// the third person and uses biographical/critical vocabulary; the author's own
/// work never names its author. Measured on real front matter:
///   author-surname mentions   P&P(Saintsbury) 27  vs  Moby 0  vs  Dracula 0
///   bio/critical words        P&P 17              vs  Moby 0  vs  Dracula 0
/// (Moby's Etymology/Extracts, Frankenstein's Letters, Dracula's journal are
/// authorial — score ~0 — and correctly KEPT.)
///
/// ### Design choices
/// - Returns UNIT IDS, not offsets — callers exclude by identity, so there is
///   no coordinate-space arithmetic (the offset-space mismatch that briefly
///   over-trimmed Alice when applying a reader-space content-end to the
///   prose-only chunk pool).
/// - Scoped to the book's OWN author (from `metadata_authors`), so a work that
///   QUOTES other authors (Moby's "Extracts") is not tripped.
/// - Position-agnostic: catches an editorial block whether it sits as a front
///   preface or a back "About the Author."
/// - The "publication-year" signal was REJECTED by measurement — Moby's Extracts
///   cite dated sources (years = 9, higher than P&P) and would false-positive.
///
/// ### Known edges (handled by the manual per-section override, not here)
/// A surname that is also a common word (case-sensitive matching guards the
/// proper-noun form, e.g. "Stoker" ≠ "stoker"); an autobiography written in the
/// third person; a literary-criticism book whose subject IS its own author.
enum EditorialFrontMatterDetector {

    /// Biographical / critical vocabulary marking prose ABOUT a work rather than
    /// the work itself. Spaces guard against matching inside other words.
    private static let bioCriticalTerms: [String] = [
        "her death", "his death", " born ", " the novel", " the author",
        "criticism", "critic", "masterpiece", "readers", " wrote ",
        "published", "writings"
    ]

    /// A run continues across up to this many non-editorial prose units —
    /// bridges preface paragraphs that don't happen to name the author.
    private static let bridgeGap = 3
    /// A run qualifies as editorial only at/above these totals. P&P's preface
    /// scored 27/17; an isolated stray mention (a title page's "by Jane Austen")
    /// stays well below 5 and is left alone.
    private static let minAuthorHits = 5
    private static let minBioHits = 1

    /// IDs of prose units that fall inside a qualifying editorial block.
    /// Empty when there is no author metadata or no editorial block.
    static func editorialUnitIDs(units: [ContentUnit],
                                 authorSurnames rawNames: [String]) -> Set<UUID> {
        let surnames = rawNames
            .compactMap { $0.split(whereSeparator: { !$0.isLetter }).last.map(String.init) }
            .filter { $0.count >= 3 }   // skip initials / too-short tokens
        guard !surnames.isEmpty else { return [] }

        let prose = units.filter { $0.kind.carriesProseText }
        guard !prose.isEmpty else { return [] }

        var excluded: Set<UUID> = []
        var i = 0
        while i < prose.count {
            let (a0, b0) = score(prose[i].text, surnames: surnames)
            if a0 == 0 && b0 == 0 { i += 1; continue }
            // Extend a contiguous run, bridging short non-editorial gaps.
            var j = i, last = i, totalA = 0, totalB = 0, gap = 0
            while j < prose.count {
                let (a, b) = score(prose[j].text, surnames: surnames)
                if a > 0 || b > 0 { last = j; totalA += a; totalB += b; gap = 0 }
                else { gap += 1; if gap > bridgeGap { break } }
                j += 1
            }
            if totalA >= minAuthorHits && totalB >= minBioHits {
                for k in i...last { excluded.insert(prose[k].id) }
            }
            i = last + 1
        }
        return excluded
    }

    /// (author-surname mentions, bio/critical hits) for one unit's text.
    private static func score(_ text: String, surnames: [String]) -> (Int, Int) {
        // Author surname: case-sensitive whole-word (the proper noun), so the
        // common noun "stoker" never matches the author "Stoker".
        var a = 0
        for w in text.split(whereSeparator: { !$0.isLetter })
        where surnames.contains(String(w)) { a += 1 }
        // Bio/critical: case-insensitive substring (terms are space-guarded).
        let low = text.lowercased()
        var b = 0
        for term in bioCriticalTerms {
            var search = low.startIndex..<low.endIndex
            while let r = low.range(of: term, range: search) {
                b += 1
                search = r.upperBound..<low.endIndex
            }
        }
        return (a, b)
    }
}

// ===== BLOCK 01: EDITORIAL FRONT-MATTER DETECTOR - END =====
