// ThinkingIndicatorBubble.swift
//
// The empty-bubble "Posey is thinking" affordance, rendered between
// the user pressing send and the first AFM token arriving. Replaces
// the older three-dots-plus-static-text indicator. Cycles randomly
// through ~30 short phrases written in Posey's voice — warm, slightly
// wry, librarian-with-read-everything. Per Mark's brief: nothing
// robotic, nothing sycophantic, nothing that reads as a loading
// spinner with words.
//
// Phrases are deliberately first-person and active ("Hmm, let me find
// that…", "Pulling that thread…") so the user feels addressed by a
// reader-companion rather than informed by a system. They imply real
// work happening — checking the document, locating the source — even
// when the AFM call is taking a while.

import SwiftUI

struct ThinkingIndicatorBubble: View {

    /// Index of the currently-shown phrase. Initial value is random
    /// so the user doesn't see the same opener every time they ask
    /// a question.
    @State private var currentIndex: Int = Int.random(in: 0..<Self.phrases.count)

    /// Rotation interval. Long enough that the user can read each
    /// phrase before it changes (~2.5s); short enough that on a
    /// 6-second AFM wait they see two or three different phrases.
    private static let rotationSeconds: Double = 2.5

    /// 30 phrases. Anti-repeat enforced by the rotation closure.
    /// Tone: warm, slightly wry, smart librarian who has read
    /// everything and is now digging through the stacks. Active
    /// verbs ("Let me find", "Tracking down", "Pulling"). Casual
    /// punctuation (em dash, ellipsis). First-person where it lands.
    private static let phrases: [String] = [
        "Hmm, let me find that…",
        "Digging through the pages…",
        "One moment, I'm tracking this down…",
        "Let me see what the document has to say…",
        "Pulling the relevant passages…",
        "Checking the stacks…",
        "I think I remember where this lives…",
        "Let me cross-reference this…",
        "Sifting through to find the right bit…",
        "Tracking down the source…",
        "Looking for where the author covers this…",
        "Rifling through the chapters…",
        "Let me see what's actually on the page…",
        "Pulling that thread…",
        "Finding where this is addressed…",
        "Looking this up properly…",
        "Let me read what it actually says…",
        "Hunting for the specific bit…",
        "Going to the source on this one…",
        "Combing through for an answer…",
        "Let me consult the text…",
        "Okay, where did the author put this…",
        "One moment — I want to get this right…",
        "Let me make sure before I answer…",
        "Finding chapter and verse…",
        "Just a moment — checking the passages…",
        "Let me see how the author handles this…",
        "Tracing this back to the document…",
        "Looking for the relevant lines…",
        "Checking what's said on this exact point…"
    ]

    var body: some View {
        HStack {
            Text(Self.phrases[currentIndex])
                .font(.footnote)
                .foregroundStyle(.secondary)
                .id(currentIndex) // forces a fresh transition on each change
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .task {
            // Rotate while this view is on screen. Cancels naturally
            // when the bubble is replaced by the streaming response
            // bubble (typingIndicator stops rendering).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.rotationSeconds))
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    var next = Int.random(in: 0..<Self.phrases.count)
                    // Anti-repeat: skip to the next index if the
                    // random pick collided with the current phrase.
                    if next == currentIndex {
                        next = (next + 1) % Self.phrases.count
                    }
                    currentIndex = next
                }
            }
        }
    }
}

#if DEBUG
#Preview("Thinking indicator") {
    VStack {
        Spacer()
        ThinkingIndicatorBubble()
            .padding()
        Spacer()
    }
    .background(Color(.systemGroupedBackground))
}
#endif
