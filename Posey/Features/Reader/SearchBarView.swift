import SwiftUI

// ========== BLOCK 01: SEARCH BAR VIEW - START ==========

/// Inline find bar that sits at the top of the reader when search is active.
/// Driven entirely by bindings and callbacks — no internal search logic.
struct SearchBarView: View {
    @Binding var query: String
    let matchCount: Int
    /// 0-based position within matches, nil if no matches or no query.
    let currentMatchPosition: Int?
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onDismiss: () -> Void

    @FocusState private var isFieldFocused: Bool

    private var matchLabel: String {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        guard matchCount > 0 else { return "No matches" }
        let ordinal = (currentMatchPosition ?? 0) + 1
        return "\(ordinal) of \(matchCount)"
    }

    var body: some View {
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
                Text(matchLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()

                Button(action: onPrevious) {
                    Image(systemName: "chevron.up")
                        .font(.footnote.weight(.semibold))
                }
                .disabled(matchCount == 0)
                .accessibilityIdentifier("search.previous")

                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                }
                .disabled(matchCount == 0)
                .accessibilityIdentifier("search.next")

                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("search.clearQuery")
            }

            Button("Done") { onDismiss() }
                .font(.footnote)
                .accessibilityIdentifier("search.done")
        }
        .tint(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .onAppear { isFieldFocused = true }
    }
}

// ========== BLOCK 01: SEARCH BAR VIEW - END ==========
