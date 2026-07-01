import Foundation

// ========== BLOCK 01: PDF TEXT LINE MODEL - START ==========

/// One reconstructed visual line of a PDF page, with the typographic signals the
/// heading-key deriver needs. PDF rebuild (2026-06-29, Mark's framing + a 4-way
/// design consult): there is NO universal "what is a heading" rule across books
/// — GEB uses font *size*, Cryptography uses *bold*, Measure What Matters uses
/// size + ALL-CAPS, the Transformer paper uses a numbered standalone line at body
/// size. The tool reads these per-line signals so a later step can DERIVE each
/// book's own `HeadingProfile` and apply it (a "style-inference engine").
///
/// 2026-06-30 — extracted from `PDFLineExtractor.swift` into its own
/// Foundation-only file (was blocked behind that file's PDFKit + UIKit imports).
/// This lets the pure importer logic (`ContentUnitBuilder.unitsFromPDFLines`,
/// `TextNormalizer`) be compiled + tested in a seconds-fast standalone macOS
/// harness (`tools/pdf-logic-harness/`) fed by CAPTURED iOS line-streams — so a
/// text-logic change no longer costs a full app+MLX+simulator build. `Codable` so
/// the iOS-extracted lines can be dumped to a fixture and reloaded off-device.
/// (Extraction itself — `PDFLineExtractor.lines` — stays iOS-only, PDFKit-native.)
struct PDFTextLine: Equatable, Hashable, Sendable, Codable {
    /// The line's text (clean, reading-order — from PDFKit's own line selection).
    let text: String
    /// The line's representative font size (length-weighted mode of its runs).
    let fontSize: Double
    /// True if a majority (by length) of the line's text is bold.
    let isBold: Bool
    /// True if the line's letters are all uppercase (and it has letters).
    let isAllCaps: Bool
    /// Left edge (min x) of the line in page space — the indent / centering signal.
    let indentX: Double
    /// Horizontal midpoint of the line in page space — used to detect centering.
    let midX: Double
    /// Top of the line in page space (max y). PDF origin is bottom-left, y up →
    /// reading order is DECREASING yTop.
    let yTop: Double
    /// Bottom of the line in page space (min y).
    let yBottom: Double
    /// Vertical whitespace between this line's top and the previous line's bottom.
    /// A large value marks a paragraph or section break.
    let gapAbove: Double
    /// 0-based PDFKit sheet index this line sits on.
    let pageIndex: Int
}

// ========== BLOCK 01: PDF TEXT LINE MODEL - END ==========
