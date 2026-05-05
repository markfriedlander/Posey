// ========== BLOCK 01: ASK POSEY FIRST-USE SHEET - START ==========
//
// 2026-05-04 — One-time notification shown the first time the user
// opens Ask Posey on any document. Sets expectations honestly about
// the scoped 1.0 promise: passage-anchored reading help (explain,
// define, find related), not document-wide discussion. Non-fiction
// reading material works best.
//
// Re-scoped 2026-05-04 (evening) per Mark + Claude (claude.ai)
// agreement: smaller, real promise that the current AFM model can
// actually keep. The dream version (whole-doc synthesis, conceptual
// argument discussion) is deferred until the next AFM revision (WWDC
// June 8, 2026 — Gemini-backed Foundation Models expected).
//
// Voice: warm and direct — Posey knowing what she's for, not an
// apology and not an oversell.

import SwiftUI

struct AskPoseyFirstUseSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("How I can help")
                    .font(.title2.bold())
            }
            .padding(.top, 8)

            Text("I help with passages you're reading — explaining what something means, defining a term in context, finding related parts of the document, or quoting what the doc actually says.")
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Double-tap a sentence in the reader to highlight it, then tap me. I'll open already focused on that passage — quick actions for explaining it, defining a term, or finding related parts of the document.")
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("I'm not trying to be a discussion partner about the whole book — big-picture synthesis isn't my strength yet. Non-fiction reading material works best.")
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
