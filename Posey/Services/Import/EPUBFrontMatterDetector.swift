import Foundation

// ========== BLOCK 01: SIGNAL TYPES - START ==========
/// Detects auto-generator front-matter at the start of an EPUB's spine.
///
/// Many tools that auto-build EPUBs from scanned source material prepend
/// boilerplate spine items the reader does not want to hear or scroll
/// through. The most common offender is the Internet Archive's
/// `hocr-to-epub` pipeline, which always starts the spine with a
/// `notice.html` containing the long "This book was produced in EPUB
/// format by the Internet Archive…" disclaimer. Mark's import of
/// "Illuminatus TRILOGY EBOOK.epub" surfaced this — the reader opened
/// directly onto the disclaimer and TTS would read it aloud sentence by
/// sentence.
///
/// We solve it the same way we solve PDF Tables of Contents: the
/// importer records a `playbackSkipUntilOffset` on the document, and
/// the reader/view-model already filters segments and display blocks
/// past that offset. Same plumbing, different detector.
///
/// **Heuristic, not a parser.** This detector is deliberately
/// conservative: it only trips when one of the spine item's HTML
/// signatures matches a known auto-generator marker. False negatives
/// (a spine item we should have skipped but didn't) leave the user
/// with extra text up front, which is annoying but recoverable. False
/// positives (skipping legitimate content) are far worse, so the bar
/// for marking a spine item as front matter is "this looks
/// unambiguously like a known auto-generator stub."
struct EPUBFrontMatterDetector {

    /// Input describing one spine item the detector should consider.
    /// Only the `html` and `href` are inspected; `plainTextStartOffset`
    /// is just bookkeeping the caller hands back so the detector can
    /// compute a final skip offset without re-walking the spine.
    struct SpineCandidate {
        let href: String
        let plainTextStartOffset: Int
        let html: String
    }

    /// Result of running the detector. `skipUntilOffset` is the
    /// `playbackSkipUntilOffset` the document should be persisted with
    /// (0 if no front matter detected). `frontMatterHrefs` lists the
    /// bare hrefs the detector identified as front matter so the
    /// caller can filter them out of any synthesised TOC — otherwise
    /// the TOC sheet would still surface entries like "Notice" that
    /// the reader can never reach.
    struct Result {
        let skipUntilOffset: Int
        let frontMatterHrefs: Set<String>
    }

    /// Walk `spineItems` from the start. Any contiguous run of
    /// front-matter items at the head of the spine is collected; the
    /// detector stops at the first non-matching item and returns the
    /// offset of that item as `skipUntilOffset`. Any matches LATER in
    /// the spine are ignored — front matter is, by definition, at the
    /// front.
    static func detect(spineItems: [SpineCandidate]) -> Result {
        var skipUntilOffset = 0
        var hrefs: Set<String> = []

        for (index, candidate) in spineItems.enumerated() {
            guard isFrontMatter(html: candidate.html) else { break }
            hrefs.insert(bareHref(candidate.href))
            // The skip offset advances to the START of the next spine
            // item — i.e., where the front matter ends and real content
            // begins. If this is the last spine item (rare: a doc that
            // is only front matter) we leave skipUntilOffset at the
            // last known body start, which means "skip nothing" — better
            // to read aloud than to silence the document entirely.
            if index + 1 < spineItems.count {
                skipUntilOffset = spineItems[index + 1].plainTextStartOffset
            }
        }

        return Result(skipUntilOffset: skipUntilOffset, frontMatterHrefs: hrefs)
    }

    // MARK: - Heuristics

    /// True when `html` looks like an auto-generator stub. Any single
    /// match across the heuristics is enough — the cost of one match
    /// being slightly off is small (we skip a paragraph the user could
    /// have read) but the markers below are deliberately specific to
    /// recognised pipelines, so spurious matches in real content are
    /// extremely unlikely.
    private static func isFrontMatter(html: String) -> Bool {
        let lower = html.lowercased()

        // Internet Archive disclaimer — by far the most common case
        // we've seen. The full disclaimer paragraph contains the
        // exact phrase below. We match on a substring rather than the
        // full sentence so a small wording change in a future IA
        // update doesn't silently disable the heuristic.
        if lower.contains("produced in epub format by the internet archive") {
            return true
        }

        // hocr-to-epub generator marker — IA's pipeline embeds this in
        // the notice file (and only there).
        if lower.contains("created with hocr-to-epub") {
            return true
        }

        // Title element of the canonical IA notice. Bracketed match so
        // a content paragraph that happens to contain the word "notice"
        // is not flagged.
        if lower.contains("<title>notice</title>") {
            return true
        }

        return false
    }

    /// Normalize a spine item's href so the caller's TOC filter and
    /// the importer's `pathToPlainOffset` keys agree. Strips any
    /// fragment and reduces to the file's last path component.
    private static func bareHref(_ href: String) -> String {
        let withoutFragment = href.components(separatedBy: "#").first ?? href
        return (withoutFragment as NSString).lastPathComponent
    }
}
// ========== BLOCK 01: SIGNAL TYPES - END ==========
