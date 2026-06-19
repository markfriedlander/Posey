// SpoilerProtectionPopover.swift
//
// 2026-06-19 (Mark) — the spoiler control's content, shown in the anchored
// popover the shield opens. Replaces the cramped iOS Menu that truncated the
// copy. Layout: "Spoiler protection" title + a clean on/off switch + an
// in-character line that ROTATES (Mark's ask) — same delight mechanism as the
// thinking indicator. The voice is the knowing reading-companion: she's read
// the whole book and either guards what's ahead or speaks freely, in
// character. A fresh line is picked on open and rotates while the popover
// lingers; toggling swaps to the other state's set.

import SwiftUI

struct SpoilerProtectionPopover: View {

    /// Current protection state (source of truth lives on the view model).
    let isOn: Bool
    /// Flip protection (persists via the view model).
    let onToggle: () -> Void

    @State private var index: Int = 0

    /// ON — she's read it all and won't reveal anything past the reader's spot.
    private static let onPhrases: [String] = [
        "I've read the whole thing — but I won't give away anything past where you are.",
        "I know how it ends. I'm not telling — keep going.",
        "I'll stay right beside you and not a step ahead.",
        "Read it cover to cover. What's coming stays between me and the book.",
        "You've earned the right to find it yourself. I won't spoil it.",
        "I'll meet you exactly where you are — nothing from past your bookmark.",
        "I'm holding my tongue about everything you haven't reached yet."
    ]

    /// OFF — open book; she'll answer freely, including what's ahead.
    private static let offPhrases: [String] = [
        "I'll answer freely — including things you haven't reached yet.",
        "No guardrails. Ask me anything, even what's still ahead.",
        "Open book. I'll go past where you are without flinching.",
        "Ask away — I won't hold back what lies ahead.",
        "Everything's fair game now, the road ahead included.",
        "I'll tell you what's coming if you want it. Spoilers and all.",
        "No bookmark holding me back — ask about any of it."
    ]

    private var phrases: [String] { isOn ? Self.onPhrases : Self.offPhrases }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "shield.lefthalf.filled" : "shield.slash")
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text("Spoiler protection")
                    .font(.headline)
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(get: { isOn }, set: { _ in onToggle() }))
                    .labelsHidden()
                    .accessibilityLabel("Spoiler protection")
            }
            Text(phrases[min(index, phrases.count - 1)])
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(index)
                .transition(.opacity)
        }
        .padding(16)
        .frame(width: 300)
        // 2026-06-19 (Mark) — rotate ONLY on open and on state change, not
        // continuously: a fresh in-character line each time you open the
        // popover or flip the switch, then it holds still (no fidgety timer).
        .onAppear { index = Int.random(in: 0..<phrases.count) }
        .onChange(of: isOn) { _, _ in
            index = Int.random(in: 0..<phrases.count)
        }
    }
}
