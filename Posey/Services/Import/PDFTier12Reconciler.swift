import Foundation
import PDFKit
import Vision

// ========== BLOCK 01: TIER 2 VISION EXTRACTOR - START ==========

/// Phase 2 of the Tier 1/2 PDF extraction architecture.
///
/// Runs Apple Vision OCR on a rendered PDF page when
/// `PDFPageConfidenceDetector` flagged the page as low-confidence
/// for PDFKit. **Only invoked on flagged pages** — the per-page cost
/// (~1 second) is unacceptable across full documents.
///
/// Render parameters chosen to match Vision's documented OCR sweet
/// spot (≥ 300 DPI). PDF default is 72 DPI; 4× → ~288 DPI which is
/// close enough in practice and keeps the rendered bitmap small
/// enough to fit comfortably on iPhone memory budget (US Letter at
/// 4× = 2448 × 3168 px ≈ 30 MB in DeviceGray).
///
/// Confidence floor mirrors the existing scanned-PDF OCR path
/// (`PDFDocumentImporter.ocrText`): pages below 0.75 average Vision
/// confidence are treated as garbled and the reconciler keeps Tier 1.
struct PDFTier2VisionExtractor {

    /// Average Vision confidence required to accept the output.
    static let minAvgConfidence: Float = 0.75

    /// Render scale. 4× of 72 DPI = 288 DPI — within Vision's
    /// recommended OCR range. Higher (300+) wastes memory for
    /// negligible accuracy gain on most documents.
    static let renderScale: CGFloat = 4.0

    /// Run Vision OCR on the page. Returns the recognized text
    /// without any normalization (the importer normalizes on the
    /// way out, same as Tier 1). Empty string on render failure,
    /// Vision failure, no observations, or sub-confidence output.
    ///
    /// 2026-05-22 Phase 2.2 quick-win — wrapped in `autoreleasepool`
    /// so Cocoa autoreleased objects (Vision observations + the
    /// rendered CGImage retained by the request) drain after each
    /// per-page call. Without this wrap, 78 sequential Vision calls
    /// during a Cryptography for Dummies import on iPhone 16 Plus
    /// blew past the jetsam memory ceiling and the app was killed
    /// mid-import. This is interim — Phase 2.2 moves Tier 2 to a
    /// background enhancement pass after persistence.
    static func extract(_ page: PDFPage) -> String {
        autoreleasepool {
            guard let image = render(page) else { return "" }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil else { return "" }

            let observations = request.results ?? []
            let candidates = observations.compactMap { $0.topCandidates(1).first }
            guard !candidates.isEmpty else { return "" }

            let avg = candidates.map(\.confidence).reduce(0, +) / Float(candidates.count)
            guard avg >= minAvgConfidence else { return "" }

            return candidates.map(\.string).joined(separator: " ")
        }
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = max(1, Int(bounds.width * renderScale))
        let height = max(1, Int(bounds.height * renderScale))

        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        ctx.saveGState()
        ctx.scaleBy(x: renderScale, y: renderScale)
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        return ctx.makeImage()
    }
}

// ========== BLOCK 01: TIER 2 VISION EXTRACTOR - END ==========

// ========== BLOCK 02: TIER 1/2 RECONCILER - START ==========

/// Decides which extractor's output wins on a flagged page.
///
/// Policy in Phase 2 is intentionally simple — wholesale-replacement
/// or wholesale-keep, no character-level splicing yet. The LCS hybrid
/// (take Tier 1 characters, take Tier 2 word boundaries) is deferred
/// per Mark's approval; see DECISIONS.md 2026-05-22 late-evening.
///
/// Per-mode policy:
///
///   - `.full` — image-only / near-empty page. Tier 2 wins when
///     Tier 1 has < 50 chars AND Tier 2 has ≥ 500 chars. (The page
///     went from "no text" to "real text"; the swap is obviously
///     correct.) Otherwise Tier 1 stays.
///
///   - `.fusionRepair` — text present but word boundaries fused.
///     Tier 2 wins when its whitespace-token count is ≥ 1.25× Tier
///     1's. (Vision is reading visual letterspacing PDFKit's text
///     stream can't see, so it splits "ANETERNAL GOLDEN BRAID" into
///     "AN ETERNAL GOLDEN BRAID" — token count goes from 3 to 4.)
///     Otherwise Tier 1 stays — the TOC false-positive case where
///     Vision and PDFKit produce similar token counts correctly
///     keeps Tier 1.
///
///   - `.figureRegion` — not yet emitted by the detector. Conservative
///     keep-Tier-1 until Phase 3.
///
///   - `.none` / empty Tier 2 — keep Tier 1.
///
/// All thresholds are named constants so calibration can move them
/// without code-search archeology.
struct PDFTier12Reconciler {

    // MARK: Tunables

    /// `.full` mode: Tier 1 must be below this character count for
    /// the wholesale swap to be considered. The detector already
    /// flags pages with charCount < 50; this constraint is mostly
    /// defensive in case the flag-criteria and the reconcile-criteria
    /// ever drift.
    static let fullModeTier1MaxChars: Int = 50

    /// `.full` mode: Tier 2 must produce at least this many chars
    /// to be considered. Below this, Vision didn't actually find
    /// readable text — better to leave the page as a visual stop
    /// (which the importer's existing pipeline handles).
    static let fullModeTier2MinChars: Int = 500

    /// `.fusionRepair`: Tier 2 wins when its token count is at least
    /// this multiple of Tier 1's. 1.25× is generous on purpose —
    /// fusion repair on covers typically goes from 3 tokens to 4 or
    /// 5 (1.33–1.66×). TOC false-positives produce similar token
    /// counts in both extractors (~1.0×) so they correctly stay on
    /// Tier 1.
    static let fusionRepairTokenRatio: Double = 1.25

    /// 2026-05-22 Phase 2.1 — char-loss safety guard. Reject any
    /// proposed swap (in any mode) where Tier 2's output has at
    /// least this fraction fewer characters than Tier 1. Catches
    /// the NIST p3 TOC regression case: Vision produced a higher
    /// token count by splitting differently but dropped dot-leader
    /// + page-number content, ending up at 50% of Tier 1's char
    /// count. The token gate alone allowed the swap; this guard
    /// rejects it.
    ///
    /// Applied to ALL modes including `.full` — defends against
    /// pathological Vision outputs where rescue mode runs but the
    /// output is structurally incomplete.
    static let maxTier2CharLossRatio: Double = 0.30

    // MARK: Result type

    enum Decision: String, Sendable {
        case visionWon = "vision_won"
        case tier1Kept = "tier1_kept"
        case tier2Empty = "tier2_empty"
    }

    struct Result: Sendable {
        let text: String
        let decision: Decision
        let tier2Chars: Int
    }

    // MARK: Public

    /// Merge Tier 1 + Tier 2 outputs for a flagged page. The mode
    /// is the flag's recommended Tier 2 mode (`PDFPageFlags.Tier2Mode`).
    static func merge(
        tier1: String,
        tier2: String,
        mode: PDFPageFlags.Tier2Mode
    ) -> Result {
        let tier2Chars = tier2.count

        if tier2.isEmpty {
            return Result(text: tier1, decision: .tier2Empty, tier2Chars: 0)
        }

        // 2026-05-22 Phase 2.1 — universal char-loss guard. If a
        // swap would discard > maxTier2CharLossRatio of Tier 1's
        // characters, refuse regardless of mode or token ratio.
        // The `.full` rescue case (Tier 1 < 50 chars) is exempt
        // because the loss math doesn't mean anything when the
        // baseline is tiny — we're not "losing" content, we're
        // adding it.
        if tier1.count >= PDFTier12Reconciler.fullModeTier1MaxChars {
            let minAllowedTier2Chars = Int(
                Double(tier1.count) * (1.0 - maxTier2CharLossRatio)
            )
            if tier2.count < minAllowedTier2Chars {
                return Result(text: tier1, decision: .tier1Kept, tier2Chars: tier2.count)
            }
        }

        switch mode {
        case .none:
            return Result(text: tier1, decision: .tier1Kept, tier2Chars: tier2Chars)

        case .full:
            if tier1.count < fullModeTier1MaxChars && tier2Chars >= fullModeTier2MinChars {
                return Result(text: tier2, decision: .visionWon, tier2Chars: tier2Chars)
            }
            return Result(text: tier1, decision: .tier1Kept, tier2Chars: tier2Chars)

        case .fusionRepair:
            let t1Tokens = tier1.split(whereSeparator: { $0.isWhitespace }).count
            let t2Tokens = tier2.split(whereSeparator: { $0.isWhitespace }).count
            if t1Tokens > 0,
               Double(t2Tokens) >= Double(t1Tokens) * fusionRepairTokenRatio {
                return Result(text: tier2, decision: .visionWon, tier2Chars: tier2Chars)
            }
            return Result(text: tier1, decision: .tier1Kept, tier2Chars: tier2Chars)

        case .figureRegion:
            // Not emitted by the Phase 1 detector; reserved for
            // Phase 3. Keep Tier 1 until the policy is designed.
            return Result(text: tier1, decision: .tier1Kept, tier2Chars: tier2Chars)
        }
    }
}

// ========== BLOCK 02: TIER 1/2 RECONCILER - END ==========
