import SwiftUI

// ========== BLOCK 01: ASK POSEY ONBOARDING - START ==========

/// The brief onboarding shown when a reader taps the "Ask Posey" invitation
/// in preferences while the feature is still locked. It explains what Ask
/// Posey is, that it's free and fully private/offline, and that it needs a
/// one-time on-device model download — then flows into the Model Library
/// where the embedder + a language model are downloaded.
///
/// 2026-05-31 — Ask Posey is a post-download unlock. This screen is the
/// discovery step; it repeats on each entry until Nomic + ≥1 MLX model are
/// present (`AskPoseyAvailability.isUnlocked`), after which the preferences
/// section switches to the live settings and this is never shown again.
///
/// Deliberately quiet and glyph-first, matching the reader's restrained tone:
/// the document is the point; this gets out of the way.
struct AskPoseyOnboardingView: View {

    /// Proceed to the Model Library (the download surface).
    let onContinue: () -> Void
    /// Dismiss without downloading (the reader can come back any time).
    let onNotNow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
                .padding(.bottom, 18)

            Text("Ask Posey")
                .font(.title.weight(.semibold))
            Text("A private reading companion")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 20) {
                onboardingPoint(
                    icon: "text.book.closed",
                    title: "Ask about what you're reading",
                    body: "Questions about characters, ideas, what happened, or what a passage means — answered from the book itself, not the open internet."
                )
                onboardingPoint(
                    icon: "lock.shield",
                    title: "Completely private, fully offline",
                    body: "Everything runs on your device. Nothing you read or ask ever leaves it. No account, no connection required."
                )
                onboardingPoint(
                    icon: "gift",
                    title: "Free — a one-time setup",
                    body: "Ask Posey costs nothing. It just needs a one-time download of the on-device models that power it: an embedder and a language model you choose."
                )
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 24)

            VStack(spacing: 12) {
                Button(action: onContinue) {
                    Text("Choose Your Models")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("askPosey.onboarding.continue")

                Button(action: onNotNow) {
                    Text("Not Now")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("askPosey.onboarding.notNow")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func onboardingPoint(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
    }
}
// ========== BLOCK 01: ASK POSEY ONBOARDING - END ==========
