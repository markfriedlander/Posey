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

    /// IDs for ScrollViewReader targets. The anchor row no longer lives
    /// inside the ScrollView (it's pinned above it now), but we still
    /// scroll to the latest user message after send so the user sees
    /// their question + Posey's answer streaming below.
    private static let priorHistoryDividerID = "askPosey.priorHistoryDivider"
    private static let typingIndicatorID = "askPosey.typingIndicator"

    /// Scroll the most-recently-sent user message to the top of the
    /// visible scroll area so the question stays anchored at the top
    /// and the streaming response appears below it. Falls back to the
    /// typing indicator (or last assistant message) when no user
    /// message is in this session.
    private func scrollToLatestUserMessage(proxy: ScrollViewProxy) {
        let session = viewModel.messages.suffix(from: viewModel.historyBoundary)
        guard let target = session.last(where: { $0.role == .user }) ?? session.last else {
            return
        }
        Task { @MainActor in
            // Brief delay so the LazyVStack realises the new row
            // before scrollTo runs — otherwise the proxy can't find
            // the id.
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeInOut(duration: 0.18)) {
                proxy.scrollTo(target.id, anchor: .top)
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                indexingNotice

                // Anchor / doc-scope row pinned ABOVE the ScrollView so
                // it's always visible — the user always knows what
                // passage or document they're asking about. Earlier
                // attempts placed this inside the LazyVStack and used
                // `.defaultScrollAnchor(.bottom)` + `proxy.scrollTo`
                // to keep it on screen, but the two fought each other:
                // once a message streamed in, the bottom anchor won
                // and the anchor row scrolled off above. Pinning it
                // outside is simpler and bulletproof.
                if let anchor = viewModel.anchor,
                   !anchor.trimmedDisplayText.isEmpty {
                    anchorRow(anchor)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                } else {
                    documentScopeRow
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            // Prior conversation history loaded from
                            // ask_posey_conversations at sheet open.
                            if viewModel.historyBoundary > 0 {
                                ForEach(
                                    Array(viewModel.messages.prefix(viewModel.historyBoundary))
                                ) { message in
                                    AskPoseyMessageBubble(message: message)
                                }
                                priorHistoryDivider
                                    .id(Self.priorHistoryDividerID)
                            }

                            // This session's messages — appear as the
                            // user sends.
                            if viewModel.messages.count > viewModel.historyBoundary {
                                ForEach(
                                    Array(viewModel.messages.suffix(from: viewModel.historyBoundary).enumerated()),
                                    id: \.element.id
                                ) { _, message in
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
                                    }
                                    .id(message.id)
                                }
                            }

                            if viewModel.isResponding,
                               !viewModel.messages.contains(where: { $0.isStreaming }) {
                                typingIndicator
                                    .id(Self.typingIndicatorID)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                    .onChange(of: viewModel.messages.count) { _, _ in
                        // After every send, the most recent user
                        // message should land at the TOP of the visible
                        // scroll area so the user sees their question
                        // and Posey's answer streaming in below.
                        // Without this hook, the conversation would
                        // accumulate at the bottom-ish and require the
                        // user to scroll back to find what they asked.
                        scrollToLatestUserMessage(proxy: proxy)
                    }
                }

                Divider().opacity(0.4)

                composer
            }
            .navigationTitle(navigationTitleText)
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

    /// Title shown in the sheet's nav bar. Falls back to "Ask Posey"
    /// when no document title was provided (older callers, previews).
    /// When a title IS available, we surface it directly so the sheet
    /// always shows the user what document they're asking about —
    /// crucial for document-scope invocations where there's no
    /// anchor passage to provide that link.
    var navigationTitleText: String {
        if let title = viewModel.documentTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return "Ask Posey"
    }

    /// Doc-scope context row — substitutes for the anchor row when
    /// the user invoked Ask Posey on the whole document (no anchor
    /// passage). Communicates "you're asking about this document as
    /// a whole" so the sheet has a clear top-of-conversation cue.
    /// Same visual style as `anchorRow` (thin material rounded
    /// rectangle with a leading icon) so the layout reads
    /// consistently regardless of scope.
    var documentScopeRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.text")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text("ASKING ABOUT")
                    .font(.caption2.smallCaps())
                    .foregroundStyle(.secondary)
                Text(navigationTitleText)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text("the whole document")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Asking about the whole document, \(navigationTitleText)")
        .accessibilityIdentifier("askPosey.documentScopeRow")
    }

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
                "Ask Posey…",
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
