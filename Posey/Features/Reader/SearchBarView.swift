import SwiftUI

// ========== BLOCK 01: SEARCH BAR VIEW - START ==========

/// Inline find bar that sits at the top of the reader when search is active.
/// Driven entirely by bindings and callbacks — no internal search logic.
struct SearchBarView: View {
    @Binding var query: String
    let matchCount: Int
    /// 0-based position within matches, nil if no matches or no query.
    let currentMatchPosition: Int?
    /// True while a meaning-search is running (shows a spinner in place of
    /// the "Search by meaning" button).
    let isSemanticSearching: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    /// Tapped from the zero-literal-results state to run Tier-3 meaning search.
    let onSemanticSearch: () -> Void
    let onDismiss: () -> Void

    @FocusState private var isFieldFocused: Bool

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var matchLabel: String {
        guard hasQuery else { return "" }
        let ordinal = (currentMatchPosition ?? 0) + 1
        return "\(ordinal) of \(matchCount)"
    }

    /// True when the literal pass found nothing for a real query — the
    /// only state that shows the second-row meaning-search affordance.
    private var showMeaningRow: Bool { hasQuery && matchCount == 0 }

    var body: some View {
        // Two rows. Row 1 keeps the text field full-width and always
        // typeable; the count + next/prev only appear when there are
        // literal hits. The zero-result "search by meaning" affordance
        // gets its OWN row (row 2) so it never crushes the field or pushes
        // "Done" onto a second line (the 2026-06-20 crush bug).
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("Find in document", text: $query)
                    .focused($isFieldFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { onNext() }

                if !query.isEmpty {
                    if matchCount > 0 {
                        Text(matchLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()

                        Button(action: onPrevious) {
                            Image(systemName: "chevron.up")
                                .font(.footnote.weight(.semibold))
                                .frame(width: 36, height: 36)
                        }
                        .remoteRegister("search.previous", action: onPrevious)
                        .accessibilityLabel("Previous match")

                        Button(action: onNext) {
                            Image(systemName: "chevron.down")
                                .font(.footnote.weight(.semibold))
                                .frame(width: 36, height: 36)
                        }
                        .remoteRegister("search.next", action: onNext)
                        .accessibilityLabel("Next match")
                    }

                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                    }
                    .remoteRegister("search.clearQuery") { query = "" }
                    .accessibilityLabel("Clear search")
                }

                Button("Done") { onDismiss() }
                    .font(.footnote)
                    .fixedSize()
                    .remoteRegister("search.done", action: onDismiss)
            }

            if showMeaningRow {
                HStack(spacing: 8) {
                    Text("No exact matches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if isSemanticSearching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button(action: onSemanticSearch) {
                            Text("Search by meaning")
                                .font(.caption.weight(.semibold))
                        }
                        .remoteRegister("search.byMeaning", action: onSemanticSearch)
                        .accessibilityLabel("Search by meaning")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .tint(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .onAppear { isFieldFocused = true }
    }
}

// ========== BLOCK 01: SEARCH BAR VIEW - END ==========
