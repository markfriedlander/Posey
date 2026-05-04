// ========== BLOCK 01: ASK POSEY FIRST-USE SHEET - START ==========
//
// 2026-05-04 — Per Mark's directive: a one-time notification shown
// the first time the user opens Ask Posey on any document. Sets
// expectations: Posey is optimized for non-fiction (essays, articles,
// reference material, legal documents, academic papers). Fiction
// support is a future problem.
//
// Voice: warm and direct — Posey knowing her strengths, not an
// apology. Consistent with the existing Ask Posey tone.

import SwiftUI

struct AskPoseyFirstUseSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("A note before we start")
                    .font(.title2.bold())
            }
            .padding(.top, 8)

            Text("I do my best work with non-fiction. Essays, articles, reference material, legal documents, academic papers — that's where I shine.")
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Fiction is trickier for me — novels, narrative writing, anything where the meaning lives between the lines. Give it a try if you're curious, but expect me to stumble more often.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button {
                onDismiss()
            } label: {
                Text("Got it")
                    .font(.body.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("askPosey.firstUseDismiss")
            .remoteRegister("askPosey.firstUseDismiss", action: onDismiss)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .interactiveDismissDisabled(false)
    }
}

#if DEBUG
#Preview {
    AskPoseyFirstUseSheet(onDismiss: {})
}
#endif

// ========== BLOCK 01: ASK POSEY FIRST-USE SHEET - END ==========
