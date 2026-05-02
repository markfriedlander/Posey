import SwiftUI

// ========== BLOCK 01: ROOT VIEW - START ==========
/// The Ask Posey modal sheet. Half-sheet by default with `.medium`
/// and `.large` detents — the document remains visible behind the
/// sheet so the reader always knows where they are in the document.
///
/// Per `ask_posey_implementation_plan.md` §12.4 the half-sheet vs
/// full-modal decision is a design risk to validate on device with
/// real documents. This view is structured so the only thing that
/// would need to change is the `presentationDetents` set and the
/// background visibility — the contents reflow naturally to either
/// shape.
///
/// Layout, top to bottom:
/// 1. Header strip — privacy lock icon, title, dismiss button.
/// 2. Anchor passage (when present) in a quoted style.
/// 3. Threaded chat history — scrollable, oldest at top.
/// 4. Composer (TextField + Send button) anchored at the bottom.
///
/// Keyboard handling: SwiftUI's keyboard avoidance pushes the
/// composer above the keyboard automatically. The chat scroll view
/// uses `defaultScrollAnchor(.bottom)` so newly added messages stay
/// visible without manual `scrollTo` plumbing.
struct AskPoseyView: View {

    @ObservedObject var viewModel: AskPoseyChatViewModel
    /// Mirrors the embedding-index notifications so we can show a
    /// sheet-internal "Indexing this document…" notice when the user
    /// opens Ask Posey on a doc that's still building its embedding
    /// index. Spec: `ask_posey_spec.md` "indexing-indicator" surface.
    /// M7: in-sheet UX for the M2 work.
    @StateObject private var indexingTracker = IndexingTracker()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var composerFocused: Bool
    /// Per-sheet view-state tracking for the M7 auto-save-to-notes
    /// button. Lives in the view (not the view model) because it's
    /// purely UI feedback — once the sheet dismisses, the persisted
    /// note is the source of truth and the in-memory flag is gone.
    @State private var savedAssistantMessageIDs: Set<UUID> = []

    /// Closure invoked when the user taps a Sources-strip pill below
    /// an assistant bubble. Owned by the host (ReaderView) which
    /// dismisses the sheet and calls `ReaderViewModel.jumpToOffset`.
    /// Optional — when nil, the pills render for awareness but don't
    /// trigger navigation. M7 source attribution surface.
    let onJumpToChunk: ((Int) -> Void)?

    init(
        viewModel: AskPoseyChatViewModel,
        onJumpToChunk: ((Int) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onJumpToChunk = onJumpToChunk
    }

    /// Stable id for the anchor row so ScrollViewReader can scroll to
    /// it on initial appear. Anchor row sits at the boundary between
    /// prior-session history (above) and this-session additions
    /// (below) — same iMessage layout pattern Mark called for.
    private static let anchorRowID = "askPosey.anchorRowID"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                indexingNotice
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            // Prior conversation history loaded from
                            // ask_posey_conversations at sheet open.
                            // Renders above the anchor so the user
                            // can scroll up to find what was discussed
                            // before. Per Mark (2026-05-01):
                            // "invisible unless you look for it,
                            // always there if you want it."
                            if viewModel.historyBoundary > 0 {
                                ForEach(
                                    Array(viewModel.messages.prefix(viewModel.historyBoundary))
                                ) { message in
                                    AskPoseyMessageBubble(message: message)
                                }
                                priorHistoryDivider
                            }

                            // Anchor row: the passage the user
                            // invoked Ask Posey from. Sits at the
                            // boundary so scroll-to-this on initial
                            // appear lands the user looking at the
                            // anchor with prior history above
                            // (off-screen, scroll up to see).
                            if let anchor = viewModel.anchor,
                               !anchor.trimmedDisplayText.isEmpty {
                                anchorRow(anchor)
                                    .id(Self.anchorRowID)
                            }

                            // This session's messages — appear below
                            // the anchor as the user sends.
                            if viewModel.messages.count > viewModel.historyBoundary {
                                ForEach(
                                    Array(viewModel.messages.suffix(from: viewModel.historyBoundary))
                                ) { message in
                                    VStack(alignment: .leading, spacing: 4) {
                                        AskPoseyMessageBubble(message: message)
                                        if message.role == .assistant,
                                           !message.navigationCards.isEmpty {
                                            navigationCardList(for: message)
                                        } else if message.role == .assistant,
                                                  !message.chunksInjected.isEmpty {
                                            // Sources strip only when not in
                                            // navigation-card mode — cards
                                            // are themselves the source link.
                                            sourcesStrip(for: message.chunksInjected)
                                        }
                                        if message.role == .assistant,
                                           !message.isStreaming,
                                           !message.content.isEmpty {
                                            saveToNotesButton(for: message)
                                        }
                                    }
                                }
                            }

                            if viewModel.isResponding,
                               !viewModel.messages.contains(where: { $0.isStreaming }) {
                                typingIndicator
                                    .transition(.opacity)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(maxHeight: .infinity)
                    .onAppear {
                        // Programmatically scroll to the anchor row
                        // on initial appear so the user lands looking
                        // at the passage that opened Ask Posey, with
                        // prior history above the fold (invisible
                        // unless they scroll up). Brief delay because
                        // SwiftUI's layout pass must finish before
                        // the proxy can find the row id. The delay
                        // also lets `historyBoundary` settle if the
                        // history-load Task is still in flight.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(180))
                            if viewModel.anchor != nil {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    proxy.scrollTo(Self.anchorRowID, anchor: .top)
                                }
                            }
                        }
                    }
                }

                Divider().opacity(0.4)

                composer
            }
            .navigationTitle("Ask Posey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        viewModel.cancelInFlight()
                        dismiss()
                    }
                    .accessibilityIdentifier("askPosey.done")
                }
            }
            .alert(
                "Ask Posey",
                isPresented: errorBinding,
                presenting: viewModel.lastError
            ) { _ in
                Button("OK", role: .cancel) {
                    viewModel.lastError = nil
                }
            } message: { error in
                Text(error.errorDescription ?? "An error occurred.")
            }
        }
        // Detent strategy: on iPhone (compact horizontal size class)
        // the .medium detent leaves no visible document behind the
        // sheet, so we go straight to .large — the document
        // momentarily slides offscreen but Ask Posey is the focused
        // task at that point. On iPad / Mac (regular size class)
        // there's enough horizontal real estate that .medium leaves
        // useful document context visible behind the sheet, so both
        // detents are offered.
        .presentationDetents(detentsForCurrentDevice)
        .presentationContentInteraction(.scrolls)
        .interactiveDismissDisabled(viewModel.isResponding)
        .onAppear {
            // Auto-focus the composer when the sheet appears so the
            // user can start typing immediately. Slight delay because
            // SwiftUI race: focus assignment before the sheet has
            // finished its present animation can be silently dropped.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                composerFocused = true
            }
        }
    }

    /// Two-way binding for the alert presentation gate. SwiftUI's
    /// `alert(isPresented:)` needs a Bool binding; the view model
    /// exposes `lastError: AskPoseyServiceError?`. Bridge the two so
    /// dismissing the alert clears the underlying error.
    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.lastError != nil },
            set: { newValue in
                if !newValue { viewModel.lastError = nil }
            }
        )
    }
}
// ========== BLOCK 01: ROOT VIEW - END ==========


// ========== BLOCK 02: ANCHOR + PRIVACY + COMPOSER - START ==========
private extension AskPoseyView {

    /// Anchor passage rendered as the first row in the chat list.
    /// Lives inside the LazyVStack so it scrolls with the
    /// conversation rather than pinning permanently to the top of
    /// the sheet — when a long Q&A pushes it off, the user can
    /// scroll back to it like any other message.
    func anchorRow(_ anchor: AskPoseyAnchor) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "quote.opening")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text("ANCHOR")
                    .font(.caption2.smallCaps())
                    .foregroundStyle(.secondary)
                Text(anchor.trimmedDisplayText)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Anchor passage: \(anchor.trimmedDisplayText)")
        .accessibilityIdentifier("askPosey.anchor")
    }

    /// Detent strategy keyed off horizontal size class. iPhone in
    /// portrait or landscape (compact) → `.large` only; the sheet
    /// fully covers the document because `.medium` left no visible
    /// document on a 16 Plus and the sheet IS the focused task at
    /// that point. iPad / Mac / split-view-with-room (regular) →
    /// `.medium` + `.large`; real estate is large enough that
    /// `.medium` keeps document context visible behind the sheet.
    var detentsForCurrentDevice: Set<PresentationDetent> {
        if horizontalSizeClass == .compact {
            return [.large]
        } else {
            return [.medium, .large]
        }
    }

    /// "Posey is thinking…" placeholder while a response is in
    /// flight. Three-dot animation keeps the UI signaling that
    /// something is happening without committing to a specific
    /// per-token rendering — M5 streaming will replace this with
    /// the live response bubble itself.
    var typingIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .frame(width: 6, height: 6)
                    .opacity(0.55)
                    .scaleEffect(1.0)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(i) * 0.18),
                        value: viewModel.isResponding
                    )
            }
            Text("Posey is thinking…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("Posey is thinking")
    }

    var composer: some View {
        HStack(spacing: 10) {
            TextField(
                "Ask about this passage…",
                text: $viewModel.inputText,
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .focused($composerFocused)
            .submitLabel(.send)
            .onSubmit { submit() }
            .accessibilityIdentifier("askPosey.composer")

            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSend)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("askPosey.send")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    /// M7 in-sheet indexing indicator. Visible when the document's
    /// embedding index is still being built — Ask Posey can run
    /// without it (anchor + STM still work) but RAG-grounded answers
    /// are weaker until indexing completes. The notice tells the
    /// user that's why; spec'd in `ask_posey_spec.md`
    /// "indexing-indicator" subsection of "The Ask Posey Sheet UI".
    @ViewBuilder
    var indexingNotice: some View {
        let docID = viewModel.documentID
        if indexingTracker.isIndexing(docID) {
            let progress = indexingTracker.indexingProgress[docID]
            HStack(spacing: 10) {
                if let progress, progress.total > 0 {
                    let fraction = min(1.0, Double(progress.processed) / Double(progress.total))
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text("Indexing this document… \(progress.processed) of \(progress.total) sections")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text("Indexing this document for Ask Posey…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("askPosey.indexingNotice")
        }
    }

    /// M7 auto-save to notes — small "Save to Notes" button below
    /// each finalised assistant bubble. Tapping persists the Q + A
    /// pair as a Note on the document, anchored to the conversation's
    /// anchor offset (or first cited chunk for document-scoped). The
    /// per-message saved-state lives in `savedAssistantMessageIDs` so
    /// the button can flip to a "Saved" state after success without
    /// the view model needing to track it.
    func saveToNotesButton(for message: AskPoseyMessage) -> some View {
        let isSaved = savedAssistantMessageIDs.contains(message.id)
        return HStack {
            Spacer().frame(maxWidth: .infinity, alignment: .leading)
            Button {
                guard !isSaved else { return }
                if viewModel.saveAssistantTurnToNotes(message) {
                    savedAssistantMessageIDs.insert(message.id)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isSaved ? "checkmark.circle.fill" : "square.and.pencil")
                        .imageScale(.small)
                    Text(isSaved ? "Saved" : "Save to Notes")
                        .font(.caption2)
                }
                .foregroundStyle(isSaved ? Color.secondary : Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .disabled(isSaved)
            .accessibilityLabel(isSaved ? "Saved to notes" : "Save this answer to notes")
            .accessibilityIdentifier("askPosey.saveToNotes")
        }
        .padding(.trailing, 8)
    }

    /// M7 navigation cards — vertical list of tappable destinations
    /// that replace prose for `.search` intent responses. Each card
    /// shows the title + reason; tapping cancels any in-flight stream,
    /// dismisses the sheet, and jumps the reader to the card's offset
    /// via the same `onJumpToChunk` closure source-attribution pills
    /// use.
    func navigationCardList(for message: AskPoseyMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.navigationCards) { card in
                Button {
                    guard let onJumpToChunk else { return }
                    viewModel.cancelInFlight()
                    onJumpToChunk(card.plainTextOffset)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "arrow.right.circle.fill")
                                .imageScale(.medium)
                                .foregroundStyle(.tint)
                            Text(card.title)
                                .font(.callout.weight(.semibold))
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 4)
                        }
                        Text(card.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .padding(.leading, 24)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Jump to \(card.title). \(card.reason)")
                .accessibilityIdentifier("askPosey.navCard")
                .disabled(onJumpToChunk == nil)
            }
        }
    }

    /// M7 source attribution: a horizontal scroll of pill buttons
    /// listing the document chunks injected into the prompt that
    /// produced this assistant response. Tapping a pill dismisses the
    /// sheet and jumps the reader to the chunk's offset (when
    /// `onJumpToChunk` is wired). Spec'd in
    /// `ask_posey_spec.md` "Source Attribution".
    func sourcesStrip(for chunks: [RetrievedChunk]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("SOURCES")
                    .font(.caption2.smallCaps())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 2)
                ForEach(Array(chunks.enumerated()), id: \.offset) { index, chunk in
                    Button {
                        guard let onJumpToChunk else { return }
                        // Cancel any in-flight stream + dismiss the
                        // sheet first so the user lands on the reader
                        // with the jump already applied.
                        viewModel.cancelInFlight()
                        onJumpToChunk(chunk.startOffset)
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(index + 1)")
                                .font(.caption2.weight(.semibold))
                            Text(String(format: "%.0f%%", chunk.relevance * 100))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Source \(index + 1) at offset \(chunk.startOffset), relevance \(String(format: "%.0f", chunk.relevance * 100)) percent. Tap to jump.")
                    .disabled(onJumpToChunk == nil)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 14)
        }
        .accessibilityElement(children: .contain)
    }

    /// Visual divider between prior-session history and the anchor
    /// row. Communicates "there's older stuff above this line, but
    /// the conversation about THIS passage starts here." Inspired by
    /// iMessage's date dividers — small, subtle, never gets in the
    /// user's way.
    var priorHistoryDivider: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
            Text("Earlier conversation")
                .font(.caption2.smallCaps())
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }

    /// Submit the composer's content. Routes to the live `send()`
    /// path when AFM is available on this platform; falls back to
    /// the M4 `sendEchoStub` for previews/tests/older OS targets.
    func submit() {
        guard viewModel.canSend else { return }
        Task { @MainActor in
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                await viewModel.send()
                return
            }
            #endif
            await viewModel.sendEchoStub()
        }
    }
}
// ========== BLOCK 02: ANCHOR + PRIVACY + COMPOSER - END ==========


// ========== BLOCK 03: MESSAGE BUBBLE - START ==========
struct AskPoseyMessageBubble: View {
    let message: AskPoseyMessage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            switch message.role {
            case .user:
                Spacer(minLength: 32)
                bubble
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            case .assistant:
                bubble
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 32)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var bubble: some View {
        Text(message.content)
            .font(.body)
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .textSelection(.enabled)
    }

    private var accessibilityLabel: String {
        let speaker = message.role == .user ? "You said" : "Posey said"
        return "\(speaker): \(message.content)"
    }
}
// ========== BLOCK 03: MESSAGE BUBBLE - END ==========


// ========== BLOCK 04: PREVIEWS - START ==========
#if DEBUG
#Preview("Ask Posey — empty + anchor") {
    Color.gray
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            AskPoseyView(
                viewModel: AskPoseyChatViewModel(
                    documentID: UUID(),
                    documentPlainText: "",
                    anchor: AskPoseyAnchor(
                        text: "It was the year when they finally immanentized the Eschaton.",
                        plainTextOffset: 0
                    )
                )
            )
        }
}

#Preview("Ask Posey — populated transcript") {
    PopulatedAskPoseyPreview()
}

/// SwiftUI's `#Preview` body is a `@ViewBuilder` and doesn't permit
/// statements (`let`, `return`) — wrap the seeded state in a tiny
/// View whose `body` builds the canvas. Keeps the preview literally
/// declarative and lets us seed messages without fighting the
/// builder.
private struct PopulatedAskPoseyPreview: View {
    @StateObject private var viewModel: AskPoseyChatViewModel = {
        let vm = AskPoseyChatViewModel(
            documentID: UUID(),
            documentPlainText: "",
            anchor: AskPoseyAnchor(
                text: "The history of the world is the history of the warfare between secret societies.",
                plainTextOffset: 1234
            )
        )
        // `messages` is private(set) — preview needs the layout
        // signal so we cheat via a tiny seeding hook below.
        vm.previewSeedTranscript([
            AskPoseyMessage(role: .user, content: "What does this passage mean?"),
            AskPoseyMessage(
                role: .assistant,
                content: "[stub] M4 sheet shell. M5 will wire real Apple Foundation Models output here. Right now you're seeing the layout for assistant bubbles with a multi-line answer to confirm wrapping looks correct on the device."
            )
        ])
        return vm
    }()

    var body: some View {
        Color.gray.ignoresSafeArea().sheet(isPresented: .constant(true)) {
            AskPoseyView(viewModel: viewModel)
        }
    }
}
#endif
// ========== BLOCK 04: PREVIEWS - END ==========
