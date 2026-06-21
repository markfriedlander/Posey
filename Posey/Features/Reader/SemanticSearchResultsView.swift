import SwiftUI

// ========== BLOCK 01: SEMANTIC SEARCH RESULT MODEL - START ==========

/// One "related passage" produced by meaning-based search — the Tier-3
/// semantic fallback that appears only when literal find returns zero
/// matches (see `ReaderViewModel.runSemanticSearch`). Each result maps a
/// retrieved leaf chunk back to a concrete reader position (`segmentIndex`
/// / `unitID`) so a tap can scroll there and pulse the sentence, exactly
/// like a literal match. Ranked, not document-ordered — there is no
/// "1 of N" navigation here; the reader picks from the list.
struct SemanticSearchResult: Identifiable, Equatable, Sendable {
    /// The retrieved chunk's id — stable, used as the list identity.
    let id: UUID
    /// Display snippet (the chunk's text, trimmed for the row).
    let snippet: String
    /// The unit this passage starts in — the scroll/pulse target.
    let unitID: UUID
    /// Resolved reader segment index for the jump. Always valid: results
    /// whose unit can't be resolved to an on-screen sentence are dropped
    /// before the list is published.
    let segmentIndex: Int
}

// ========== BLOCK 01: SEMANTIC SEARCH RESULT MODEL - END ==========


// ========== BLOCK 02: SEMANTIC SEARCH RESULTS VIEW - START ==========

/// The "Related passages" panel. Sits directly beneath the search bar when
/// a meaning-search has run. Deliberately a ranked LIST the reader chooses
/// from — not folded into the literal next/prev chevron sequence, because
/// ranked semantic hits have no document order and blending the two would
/// break the find-box mental model (the design call made with Mark).
struct SemanticSearchResultsView: View {
    let isSearching: Bool
    let results: [SemanticSearchResult]
    let onSelect: (SemanticSearchResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Related passages")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isSearching {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)

            if isSearching {
                // Header spinner is enough; keep the panel quiet while it runs.
                Color.clear.frame(height: 0)
            } else if results.isEmpty {
                Text("No related passages found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            Button {
                                onSelect(result)
                            } label: {
                                Text(result.snippet)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 16)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            // Index-based id: stable + tappable for automation
                            // and assistive tech (UUIDs are neither). Registered
                            // with the remote registry — the codebase's reliable
                            // tap path for SwiftUI controls (raw a11y ids inside
                            // a ScrollView don't surface to the tap traversal).
                            .accessibilityIdentifier("search.semantic.result.\(index)")
                            .remoteRegister("search.semantic.result.\(index)") { onSelect(result) }

                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }
}

// ========== BLOCK 02: SEMANTIC SEARCH RESULTS VIEW - END ==========
