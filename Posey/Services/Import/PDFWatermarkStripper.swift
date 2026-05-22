import Foundation

// ========== BLOCK 01: PDF WATERMARK STRIPPER - START ==========

/// Strips known converter / evaluation watermarks from PDF-extracted text.
///
/// Many PDFs distributed online were converted from another format (CHM,
/// HTML, EPUB) using a desktop converter that injects a registration
/// notice on every page. PDFKit reads that notice as ordinary text, so
/// Posey would otherwise (a) read it aloud, (b) embed it in the RAG
/// index, and (c) display it as the document's first sentence.
///
/// Patterns are intentionally narrow — each must:
///   1. Carry a distinctive brand name or unambiguous phrase
///      ("ChmMagic", "Aspose.PDF", "Calibre", "Evaluation Only" with a
///      URL).
///   2. End on a sentence terminator or URL boundary so the stripper
///      never eats prose past the notice.
///
/// We deliberately do NOT use catch-all "demo" / "trial" wording —
/// false positives there would silently delete real prose. The list
/// grows on observed real-world examples (see DECISIONS.md 2026-05-22
/// "PDF watermark stripping").
///
/// Added 2026-05-22 after Cryptography for Dummies surfaced a ChmMagic
/// banner repeated on every page of plainText.
struct PDFWatermarkStripper {

    /// One watermark pattern. `regex` runs against the joined text with
    /// `dotMatchesLineSeparators` so multi-line notices match.
    struct Pattern {
        let id: String
        let regex: NSRegularExpression
    }

    /// Curated pattern list. Order doesn't matter — every pattern is
    /// applied and overlapping matches resolve in source order.
    static let patterns: [Pattern] = build()

    private static func build() -> [Pattern] {
        let specs: [(id: String, source: String)] = [
            // CHM-to-PDF converter (Cryptography for Dummies).
            // "This document was created by an unregistered ChmMagic,
            //  please go to http://www.bisenter.com to register it.
            //  Thanks."
            //
            // The watermark recurs on every page, and PDFKit's text
            // extraction frequently TRUNCATES it at the page boundary.
            // We saw three variants in Cryptography for Dummies:
            //   1. Full: "…register it. Thanks."
            //   2. No-period: "…register it. Thanks Do You…"
            //                 (the trailing "Thanks." dot eaten by
            //                  the page break)
            //   3. Truncated: "…to registe[r] Chapter 16:…"
            //                 (the rest of "register" + Thanks gone)
            //
            // The pattern anchors on the bisenter.com URL (the most
            // unique fingerprint), then accepts any of the three tail
            // variants. `\w*` after "registe" handles "register" and
            // "registe[anything-truncated]" alike.
            ("chmmagic",
             #"This document was created by an unregistered ChmMagic.{0,80}?bisenter\.com\s+to\s+(?:register\s+it\s*\.\s*Thanks\s*\.?|registe\w*\.?)\s*"#),

            // Aspose.PDF / Aspose.Words evaluation banner.
            // "Evaluation Only. Created with Aspose.PDF. Copyright YYYY Aspose Pty Ltd."
            ("aspose",
             #"Evaluation Only\.\s*Created with Aspose\.[A-Za-z]+\.[^.]*\."#),

            // Calibre converter footer / banner. Calibre writes a
            // discoverable signature when configured to brand output.
            ("calibre",
             #"(?:Generated|Created)\s+(?:by|with)\s+[Cc]alibre[^.\n]{0,80}\."#),

            // Generic "Evaluation Only" notice that pairs a URL with
            // a "register" or "trial" word — narrow enough that it
            // won't hit ordinary prose.
            ("generic_evaluation",
             #"Evaluation Only[.,]?\s+(?:Please\s+)?(?:register|visit|trial)[^.]*?https?://\S+[^.\s]*\.?"#)
        ]

        return specs.compactMap { spec in
            guard let regex = try? NSRegularExpression(
                pattern: spec.source,
                options: [.dotMatchesLineSeparators, .caseInsensitive]
            ) else {
                return nil
            }
            return Pattern(id: spec.id, regex: regex)
        }
    }

    /// Apply every pattern to `text`, replacing each match with a
    /// single space and then collapsing 2+ ASCII spaces back to one.
    /// Newlines / paragraph structure are preserved.
    static func strip(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var working = text
        for pattern in patterns {
            let range = NSRange(working.startIndex..., in: working)
            working = pattern.regex.stringByReplacingMatches(
                in: working,
                range: range,
                withTemplate: " "
            )
        }
        // Collapse doubled ASCII spaces that the replacements left
        // behind (don't touch newlines — paragraph structure matters
        // to downstream passes).
        if let wsRegex = try? NSRegularExpression(pattern: #" {2,}"#) {
            let range = NSRange(working.startIndex..., in: working)
            working = wsRegex.stringByReplacingMatches(
                in: working,
                range: range,
                withTemplate: " "
            )
        }
        // Trim a leading whitespace artifact that the strip can leave
        // when a watermark was the very first text on the page.
        return working.trimmingCharacters(in: .whitespaces)
    }
}

// ========== BLOCK 01: PDF WATERMARK STRIPPER - END ==========
