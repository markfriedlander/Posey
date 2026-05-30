import Foundation
import NaturalLanguage

// ========== BLOCK 01: SUMMARY ENTITY GROUNDING - START ==========

/// A second, complementary verification gate for generated summaries.
///
/// **Why it exists (measured 2026-05-30).** The embedding-cosine verifier
/// (`AskPoseySummaryVerifier`) catches *topical* drift — a summary about a
/// different subject than its source. It does NOT catch a confident,
/// *on-topic* fabrication. AFM summarized the Moby-Dick passage "Who ain't a
/// slave? Tell me that." as *"The passage is from the book 'Beloved', by Toni
/// Morrison… an unnamed woman who has been enslaved."* — topically about
/// slavery, so its cosine to the (slavery) source was high and it PASSED. A
/// wrong-but-on-topic summary in the retrieval pool yields a confidently
/// wrong answer with the same fluency as a correct one. Verification is
/// load-bearing, so we add a gate aimed precisely at the fabrication this
/// missed: invented **named entities**.
///
/// **What it does.** Extracts the people / places / organizations named in
/// the summary (Apple's `NLTagger` named-entity recognition) and checks each
/// against the source text. A summary that names a person, place, or
/// organization whose content tokens appear NOWHERE in its source is
/// fabricating — "Toni Morrison" never occurs in a Moby-Dick chapter. Such a
/// summary is rejected wholesale: a summary willing to invent a name is not
/// trustworthy enough to keep, and raw RAG still covers the passage.
///
/// Conservative by design (rejects only when NO token of an entity traces to
/// the source) to minimize false rejections of legitimate name variants,
/// while still catching wholesale fabrications like the one above.
public struct SummaryEntityGrounding {

    public struct Result: Sendable {
        /// True when every named entity in the summary traces to the source.
        public let grounded: Bool
        /// Entities present in the summary but absent from the source.
        public let fabricatedEntities: [String]
    }

    /// Minimum content-token length to consider (skips "a", "of", initials).
    public static let minTokenLength = 3

    public static func check(summary: String, source: String) -> Result {
        let sourceLower = source.lowercased()
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = summary
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        let nameTags: Set<NLTag> = [.personalName, .placeName, .organizationName]

        var fabricated: [String] = []
        var seen = Set<String>()
        tagger.enumerateTags(in: summary.startIndex..<summary.endIndex,
                             unit: .word, scheme: .nameType, options: options) { tag, range in
            guard let tag, nameTags.contains(tag) else { return true }
            let entity = String(summary[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = entity.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { return true }
            seen.insert(key)

            // Content tokens of the entity (letters only, length-filtered).
            let tokens = key
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
                .filter { $0.count >= minTokenLength }
            guard !tokens.isEmpty else { return true }

            // Fabricated iff NONE of its tokens appear anywhere in the source.
            // (Conservative: any single grounded token clears the entity.)
            let anyGrounded = tokens.contains { sourceLower.contains($0) }
            if !anyGrounded { fabricated.append(entity) }
            return true
        }
        return Result(grounded: fabricated.isEmpty, fabricatedEntities: fabricated)
    }
}
// ========== BLOCK 01: SUMMARY ENTITY GROUNDING - END ==========
