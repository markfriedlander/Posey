import Foundation
import PDFKit

// ========== BLOCK 01: PAGE FLAGS MODEL - START ==========

/// One per page. Sendable + Codable so it can ride through the import
/// actor crossing on `ParsedPDFDocument` and persist as JSON sidecars
/// for the calibration phase. See `PageFlagsStore`.
///
/// **Phase 1 (this commit): logging + persistence only.** The importer
/// computes flags during its per-page loop and persists them; nothing
/// branches on `needsTier2` yet. Tier 2 wiring is Phase 2, gated on
/// Mark+Claude reviewing the calibration output from this phase.
struct PDFPageFlags: Codable, Sendable, Equatable {
    /// 0-based, matches `PDFDocument.page(at:)`.
    let pageIndex: Int

    /// True when any detector heuristic triggered. Mirrors the
    /// existence of at least one entry in `reasons` and a non-`.none`
    /// `tier2Mode`. Carried explicitly for fast filtering downstream.
    let needsTier2: Bool

    /// Which Tier 2 mode the detector recommends. Calibration logging
    /// only; no extractor runs based on this yet.
    let tier2Mode: Tier2Mode

    /// Human-readable strings explaining which heuristics fired and
    /// with what concrete numbers. The most useful field for
    /// calibration — these strings are what we eyeball across the
    /// corpus to decide where thresholds should land.
    let reasons: [String]

    /// Raw per-page signals, captured for offline calibration. Tuning
    /// thresholds from logs alone is guesswork; tuning from the
    /// underlying distribution is sound.
    let signals: Signals

    enum Tier2Mode: String, Codable, Sendable {
        case none
        case full           // image-only or near-empty pages
        case fusionRepair   // text present but word boundaries fused
        case figureRegion   // mixed text + large image (Phase 2; not emitted yet)
    }

    struct Signals: Codable, Sendable, Equatable {
        let charCount: Int
        let pageAreaPt2: Double
        /// Characters per 1000 pt² of mediaBox area. Body pages
        /// typically score 5–20. Cover/title/figure pages score
        /// 0–1. Pure image pages score 0.
        let charDensity: Double
        /// Count of whitespace-separated tokens that are length
        /// ≥ `longCapsTokenMinLength` AND fully uppercase. Cover-
        /// page fusion signature: "ANETERNAL", "GOLDENBRAID",
        /// "DOUGLAS HOFSTADTER". Body prose almost never produces
        /// these.
        let longCapsTokenCount: Int
        /// Mean token length across all whitespace-separated
        /// tokens on the page. Body prose: 4–6. Fused covers: 12+.
        let avgWordLength: Double
    }
}

// ========== BLOCK 01: PAGE FLAGS MODEL - END ==========

// ========== BLOCK 02: PDF PAGE CONFIDENCE DETECTOR - START ==========

/// Confidence-based page-level detector. Decides which pages the
/// upcoming Tier 2 Vision-OCR path should run on.
///
/// Phase 1 deliverable — implements the detector, logs + persists
/// its decisions, but **does not branch behavior in the importer**.
/// The calibration goal is to look at the flags across the full 35-
/// PDF audit corpus, eyeball false positives and false negatives,
/// then tighten before Phase 2 wires Tier 2 in.
///
/// Approach (cheap signals, no rendering, no Vision):
///
///   1. **Empty / near-empty** — full-size mediaBox area with
///      < 50 chars of text → likely image-only page that needs OCR.
///   2. **Sparse text density** — chars per 1000 pt² < 0.5 on a
///      full-size page → likely scanned region or figure-heavy page.
///   3. **All-caps long-token fusion** — ≥ 2 whitespace-separated
///      uppercase tokens of length ≥ 12 → cover-page word-fusion
///      signature ("ANETERNAL GOLDEN BRAID", "DOUGLAS HOFSTADTER").
///   4. **High mean word length** — average word length > 10 on a
///      page with at least 80 chars → decorative typography or
///      letterspaced rendering where PDFKit can't separate words.
///
/// Thresholds are intentionally generous on the first pass — better
/// to over-flag during calibration and tighten than to under-flag and
/// miss the cases we're trying to catch. Frozen thresholds will live
/// as named constants here; nothing magic-numbers downstream.
///
/// Cost target: < 5 ms per page on iPhone 16 Plus. The Tier 2 win
/// evaporates if the detector itself is slow on every page.
struct PDFPageConfidenceDetector {

    // MARK: Tunables (generous-side starting points — calibrate)

    /// Pages with fewer characters than this on a full-size area are
    /// treated as image-only candidates. Raised in tightening if too
    /// many small-but-real pages flag.
    static let minCharCountForText: Int = 50

    /// Pages smaller than this aren't large enough for the density
    /// math to mean anything. US Letter = 612 × 792 = ~485k pt²;
    /// 50k pt² ≈ 5"x6" so even an unusually small page meets the
    /// threshold.
    static let minPageAreaPt2: Double = 50_000

    /// Body prose pages score 5–20 chars/1000pt². 0.5 is well below
    /// even a sparse-typed page; firing here implies almost no text
    /// for the available area.
    static let minCharDensity: Double = 0.5

    /// All-caps token length threshold for the fusion signature.
    /// 12 chars is longer than every common English word, so an
    /// all-caps token at this length is almost certainly multiple
    /// words fused together (cover-page rendering loses spaces).
    static let longCapsTokenMinLength: Int = 12

    /// One long all-caps token can happen legitimately ("INTRODUCTION"
    /// is 12). Two on the same page is the cover-page signature.
    static let minLongCapsTokensForFusion: Int = 2

    /// Mean word length threshold for decorative-typography fusion.
    /// Body prose: 4–6. Title pages with letterspacing: 12+.
    static let highAvgWordLength: Double = 10.0

    /// Don't measure mean word length on near-empty pages — the
    /// statistic is noise below this character count.
    static let avgWordLengthMinChars: Int = 80

    // MARK: Public

    /// Assess every page in the document. Returns one `PDFPageFlags`
    /// per page in page-index order.
    static func assess(_ document: PDFDocument) -> [PDFPageFlags] {
        var out: [PDFPageFlags] = []
        out.reserveCapacity(document.pageCount)
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else {
                // Preserve index continuity with a benign placeholder
                // so downstream consumers can index by page number.
                out.append(emptyFlags(forPageIndex: i))
                continue
            }
            out.append(assess(page, pageIndex: i))
        }
        return out
    }

    /// Assess a single page. Public for unit-testability.
    static func assess(_ page: PDFPage, pageIndex: Int) -> PDFPageFlags {
        let pageString = page.string ?? ""
        let bounds = page.bounds(for: .mediaBox)
        let area = Double(bounds.width * bounds.height)
        let charCount = pageString.count
        let density = (area > 0) ? Double(charCount) / (area / 1000.0) : 0

        // Tokenize once on Unicode whitespace.
        let tokens: [String] = pageString
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let longCapsTokens = tokens.filter(isLongCapsToken)
        let avgWordLen: Double = {
            guard !tokens.isEmpty else { return 0 }
            let totalChars = tokens.reduce(0) { $0 + $1.count }
            return Double(totalChars) / Double(tokens.count)
        }()

        var reasons: [String] = []
        var mode: PDFPageFlags.Tier2Mode = .none

        // Heuristic 1: image-only / near-empty full-size page.
        if charCount < minCharCountForText && area > minPageAreaPt2 {
            reasons.append("charCount \(charCount) < \(minCharCountForText) on \(formatArea(area)) page")
            if mode == .none { mode = .full }
        }

        // Heuristic 2: sparse density on a full-size page.
        if density < minCharDensity && area > minPageAreaPt2 && charCount >= minCharCountForText {
            reasons.append(
                "charDensity \(formatDensity(density)) < \(formatDensity(minCharDensity)) chars/1000pt²"
            )
            if mode == .none { mode = .full }
        }

        // Heuristic 3: cover-page all-caps fusion signature.
        if longCapsTokens.count >= minLongCapsTokensForFusion {
            let sample = longCapsTokens.prefix(3).joined(separator: " ")
            reasons.append(
                "\(longCapsTokens.count) all-caps tokens ≥ \(longCapsTokenMinLength) chars (e.g. \(sample))"
            )
            if mode == .none { mode = .fusionRepair }
        }

        // Heuristic 4: decorative-typography mean-word-length fusion.
        if charCount >= avgWordLengthMinChars && avgWordLen > highAvgWordLength {
            reasons.append(
                "avgWordLength \(formatLen(avgWordLen)) > \(formatLen(highAvgWordLength)) on page with \(charCount) chars"
            )
            if mode == .none { mode = .fusionRepair }
        }

        return PDFPageFlags(
            pageIndex: pageIndex,
            needsTier2: mode != .none,
            tier2Mode: mode,
            reasons: reasons,
            signals: PDFPageFlags.Signals(
                charCount: charCount,
                pageAreaPt2: area,
                charDensity: density,
                longCapsTokenCount: longCapsTokens.count,
                avgWordLength: avgWordLen
            )
        )
    }

    // MARK: Internal helpers

    /// True iff the token is `≥ longCapsTokenMinLength` characters AND
    /// every letter character in it is uppercase. Non-letter characters
    /// (digits, punctuation) are ignored — "DON'T" still counts as an
    /// all-caps token, as does "VERSION1".
    fileprivate static func isLongCapsToken(_ token: String) -> Bool {
        guard token.count >= longCapsTokenMinLength else { return false }
        var sawLetter = false
        for ch in token {
            if ch.isLetter {
                sawLetter = true
                if !ch.isUppercase { return false }
            }
        }
        return sawLetter
    }

    fileprivate static func emptyFlags(forPageIndex i: Int) -> PDFPageFlags {
        PDFPageFlags(
            pageIndex: i,
            needsTier2: false,
            tier2Mode: .none,
            reasons: [],
            signals: PDFPageFlags.Signals(
                charCount: 0,
                pageAreaPt2: 0,
                charDensity: 0,
                longCapsTokenCount: 0,
                avgWordLength: 0
            )
        )
    }

    fileprivate static func formatArea(_ a: Double) -> String {
        String(format: "%.0fpt²", a)
    }

    fileprivate static func formatDensity(_ d: Double) -> String {
        String(format: "%.2f", d)
    }

    fileprivate static func formatLen(_ l: Double) -> String {
        String(format: "%.1f", l)
    }
}

// ========== BLOCK 02: PDF PAGE CONFIDENCE DETECTOR - END ==========
