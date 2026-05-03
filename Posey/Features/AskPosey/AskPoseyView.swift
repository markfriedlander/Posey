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

    /// ID for the typing-indicator row when no streaming bubble is in
    /// flight yet. Used as a fallback scroll target if the
    /// most-recent-user-message lookup fails.
    private static let typingIndicatorID = "askPosey.typingIndicator"

    /// Scroll the most-recently-sent user message to the top of the
    /// visible scroll area so the question stays anchored at the top
    /// and the streaming response appears below it.
    private func scrollToLatestUserMessage(proxy: ScrollViewProxy) {
        guard let target = viewModel.messages.last(where: { $0.role == .user }) else {
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

    /// Scroll to the anchor marker the view model wants us to land on.
    /// Default behavior = the most recent anchor (the one we just
    /// appended for this invocation). Notes-tap-conversation overrides
    /// via `initialScrollAnchorStorageID` so the sheet opens scrolled
    /// to a previous anchor in the thread.
    ///
    /// **Three-stage scroll** to defeat lazy-realization races: the
    /// ScrollView lazy-realizes rows as it lays out; on the first
    /// scrollTo for a target far below the natural top, the proxy
    /// can't find the row's frame because it isn't yet realized.
    /// We scroll immediately (forces the lazy stack to realize the
    /// surrounding rows), then again after 200ms (catches the case
    /// where the first pass only partially advanced realization),
    /// then a final animated scroll at 450ms so the user sees a
    /// smooth land. Mirrors the ReaderView initial-scroll pattern
    /// (60ms + 180ms) which was added for the same reason.
    private func scrollToInitialAnchor(proxy: ScrollViewProxy) {
        let storageID = viewModel.initialScrollAnchorStorageID
        // Scope the search by `storageID == storageID` predicate when
        // we have one — `messages.first(where:)` instead of `last(where:)`
        // because the storage id is unique and `.first` short-circuits.
        let target: AskPoseyMessage?
        if let storageID {
            target = viewModel.messages.first { msg in
                msg.role == .anchor && msg.storageID == storageID
            }
        } else {
            target = viewModel.messages.last { $0.role == .anchor }
        }
        guard let target else { return }
        Task { @MainActor in
            // Pass 1 — no animation, immediate. Forces the lazy stack
            // to realize the target's enclosing region.
            proxy.scrollTo(target.id, anchor: .top)
            try? await Task.sleep(for: .milliseconds(200))
            // Pass 2 — still no animation. Catches the case where
            // pass 1 only partially advanced realization (long
            // threads with many anchors).
            proxy.scrollTo(target.id, anchor: .top)
            try? await Task.sleep(for: .milliseconds(250))
            // Pass 3 — smooth animated land for the user-visible
            // settle.
            withAnimation(.easeInOut(duration: 0.18)) {
                proxy.scrollTo(target.id, anchor: .top)
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                indexingNotice

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.messages) { message in
                                threadRow(for: message)
                                    .id(message.id)
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
                    .onChange(of: viewModel.messages.count) { oldValue, newValue in
                        // After every user send, the most recent user
                        // message should land at the TOP of the visible
                        // scroll area so the user sees their question
                        // and Posey's answer streaming in below. Skip
                        // the initial population pulse from
                        // loadHistory() (oldValue == 0).
                        if oldValue > 0,
                           viewModel.messages.last?.role == .user {
                            scrollToLatestUserMessage(proxy: proxy)
                        }
                    }
                    .onChange(of: viewModel.isLoadingHistory) { _, newValue in
                        // Land on the target anchor once history has
                        // loaded and the marker for this invocation
                        // (or the navigation target) is in `messages`.
                        if !newValue {
                            scrollToInitialAnchor(proxy: proxy)
                        }
                    }
                    .onAppear {
                        // Backstop for the case where loadHistory
                        // already finished by the time the
                        // ScrollViewReader is mounted (cached / fast
                        // path) — `.onChange(of: isLoadingHistory)`
                        // would never fire.
                        if !viewModel.isLoadingHistory {
                            scrollToInitialAnchor(proxy: proxy)
                        }
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
                    .remoteRegister("askPosey.done") {
                        viewModel.cancelInFlight()
                        dismiss()
                    }
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .remoteDismissPresentedSheet)
            ) { _ in
                viewModel.cancelInFlight()
                dismiss()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .remoteTapAskPoseyAnchor)
            ) { note in
                guard let storageID = note.userInfo?["storageID"] as? String,
                      let target = viewModel.messages.first(where: { $0.storageID == storageID }),
                      let offset = target.anchorOffset else { return }
                viewModel.cancelInFlight()
                onJumpToChunk?(offset)
                dismiss()
            }
            .onAppear {
                RemoteControlState.shared.presentedSheet = "askPosey"
            }
            .onDisappear {
                if RemoteControlState.shared.presentedSheet == "askPosey" {
                    RemoteControlState.shared.presentedSheet = nil
                }
            }
            // No user-facing error alert. AFM failures already surface
            // as a friendly fallback bubble in the conversation thread
            // (see AskPoseyChatViewModel.handleSendError) — that's the
            // only UX the user should see. Earlier behavior popped a
            // raw "Error Domain=FoundationModels…" string in front of
            // the user; that alert path is gone. The `lastError`
            // property is still set on the view model so the local-API
            // tuning loop can surface error details via `/ask`, but
            // it's never rendered as alert chrome.
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
        // Inline-citation tap dispatcher (Task 2 #25). Each `[N]`
        // marker in an assistant response is rendered as a markdown
        // link `[ⁿ](posey-cite://N)`; tapping it invokes this
        // OpenURLAction with that URL. We resolve N back to the
        // matching chunk on the latest assistant message that has at
        // least N chunks, dispatch via `onJumpToChunk`, dismiss. Any
        // non-citation URL (regular http(s) link) returns
        // `.systemAction` so SwiftUI hands it to the system handler.
        .environment(\.openURL, OpenURLAction { url in
            guard let n = AskPoseyCitationRenderer.chunkNumber(from: url) else {
                return .systemAction
            }
            // Find the assistant message that has at least N chunks.
            // Scan newest-first so a follow-up answer's citations
            // resolve against ITS chunks, not an older reply's.
            for message in viewModel.messages.reversed()
            where message.role == .assistant && n >= 1 && n <= message.chunksInjected.count {
                let chunk = message.chunksInjected[n - 1]
                if let onJumpToChunk {
                    viewModel.cancelInFlight()
                    onJumpToChunk(chunk.startOffset)
                    dismiss()
                }
                return .handled
            }
            return .discarded
        })
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

}
// ========== BLOCK 01: ROOT VIEW - END ==========


// ========== BLOCK 01B: ANCHOR ROW REMOTE REGISTRATION - START ==========
/// Registers each anchor row with `RemoteTargetRegistry` under a
/// per-row id (`askPosey.anchor.<storageID>` /
/// `askPosey.documentScopeRow.<storageID>`) so a TAP API call can
/// drive a specific anchor's tap action regardless of position in
/// the thread. Also keeps the `accessibilityIdentifier` on the
/// shared base id (`askPosey.anchor` / `askPosey.documentScopeRow`)
/// so existing UI tests / VoiceOver labels continue to work.
private struct AskPoseyAnchorRowRemoteRegister: ViewModifier {
    let message: AskPoseyMessage
    let isDocumentScope: Bool
    let onJumpToChunk: ((Int) -> Void)?
    let dismiss: DismissAction
    let cancelInFlight: () -> Void

    func body(content: Content) -> some View {
        let baseID = isDocumentScope ? "askPosey.documentScopeRow" : "askPosey.anchor"
        let storageID = message.storageID ?? message.id.uuidString
        let scopedID = "\(baseID).\(storageID)"
        return content
            .accessibilityIdentifier(baseID)
            .onAppear {
                let action: () -> Void = {
                    guard let offset = message.anchorOffset, let onJumpToChunk else { return }
                    cancelInFlight()
                    onJumpToChunk(offset)
                    dismiss()
                }
                RemoteTargetRegistry.shared.register(scopedID, action: action)
                RemoteTargetRegistry.shared.register(baseID, action: action)
            }
            .onDisappear {
                RemoteTargetRegistry.shared.unregister(scopedID)
                // Only unregister the shared base id if THIS row is
                // the one that registered it most recently. We can't
                // tell from here, so leave it; the next row to appear
                // will overwrite. Acceptable: the shared id always
                // points at SOME currently-visible anchor.
            }
    }
}
// ========== BLOCK 01B: ANCHOR ROW REMOTE REGISTRATION - END ==========


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

    /// Single-row dispatcher: anchor markers render as inline callout
    /// rows; user / assistant messages render as bubbles plus optional
    /// sources strip / navigation cards. Lives inside the LazyVStack
    /// so the whole thread (anchors + Q&A + Q&A + new anchor + Q&A)
    /// reads chronologically top-to-bottom.
    @ViewBuilder
    func threadRow(for message: AskPoseyMessage) -> some View {
        switch message.role {
        case .anchor:
            anchorMarkerRow(message)
        case .user, .assistant:
            VStack(alignment: .leading, spacing: 4) {
                AskPoseyMessageBubble(message: message)
                // Navigation cards (.search intent results) are still
                // rendered as a separate strip — they're a structurally
                // different surface from text + inline citations. The
                // old "SOURCES N · 87%" pill strip is gone; sources
                // are now inline `[ⁿ]` superscripts inside the bubble
                // text (Task 2 #25).
                if message.role == .assistant,
                   !message.navigationCards.isEmpty {
                    navigationCardList(for: message)
                }
            }
        }
    }

    /// Inline anchor marker — full passage text for passage scope,
    /// `ASKING ABOUT / <doc title> / the whole document` for document
    /// scope. Both render with the same thin-material card style and
    /// are tappable: a tap dismisses the sheet and jumps the reader
    /// to the captured offset (every anchor has one — passage scope
    /// from the active sentence at invocation, document scope from
    /// the same).
    func anchorMarkerRow(_ message: AskPoseyMessage) -> some View {
        let isDocumentScope = (message.anchorScope == "document")
        let iconName = isDocumentScope ? "doc.text" : "quote.opening"
        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = "ASKING ABOUT"
        return Button {
            // Capture the offset locally to avoid escaping
            // self into the closure.
            guard let offset = message.anchorOffset, let onJumpToChunk else {
                return
            }
            viewModel.cancelInFlight()
            onJumpToChunk(offset)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: iconName)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(.caption2.smallCaps())
                        .foregroundStyle(.secondary)
                    if isDocumentScope {
                        Text(trimmedContent)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                        Text("the whole document")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    } else {
                        Text(trimmedContent)
                            .font(.callout)
                            .italic()
                            .foregroundStyle(.primary.opacity(0.85))
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(onJumpToChunk == nil || message.anchorOffset == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isDocumentScope
                ? "Asking about the whole document, \(trimmedContent). Tap to jump back."
                : "Anchor passage: \(trimmedContent). Tap to jump."
        )
        .modifier(AskPoseyAnchorRowRemoteRegister(
            message: message,
            isDocumentScope: isDocumentScope,
            onJumpToChunk: onJumpToChunk,
            dismiss: dismiss,
            cancelInFlight: { viewModel.cancelInFlight() }
        ))
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
            case .anchor:
                // Anchor markers render via AskPoseyView.anchorMarkerRow
                // (not as bubbles). This case is unreachable in practice
                // because threadRow dispatches anchors away from the
                // bubble view, but the switch must be exhaustive.
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var bubble: some View {
        // Renders the message body via SwiftUI's markdown
        // initializer so AFM responses like **bold** / *italic* /
        // `code` show as formatted text instead of literal markdown.
        // Inline citation links of the shape `[¹](posey-cite://1)`
        // are tappable — handled by the
        // `.environment(\\.openURL, ...)` action installed at the
        // sheet root, which dispatches `posey-cite://N` URLs to the
        // matching chunk's offset via `onJumpToChunk`.
        Text(.init(renderedMarkdown))
            .font(.body)
            .foregroundStyle(.primary)
            .tint(.accentColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .textSelection(.enabled)
    }

    /// Rewrites the raw assistant text so each `[N]` marker that
    /// resolves to a known chunk becomes a markdown link with a
    /// unicode-superscript label and a `posey-cite://N` URL. The
    /// AskPoseyView root installs an `OpenURLAction` that intercepts
    /// `posey-cite://` URLs and dispatches them to `onJumpToChunk`.
    /// Markers without a matching chunk (e.g. AFM hallucinated
    /// `[12]` when only 4 chunks were injected) fall through
    /// unchanged so they're visible but inert.
    /// When AFM didn't emit any markers (it's inconsistent about
    /// following the citation instruction even with the rule
    /// repeated three times in the prompt), the renderer falls
    /// back to auto-attributing each sentence to its best-match
    /// chunk by unique-keyword overlap.
    private var renderedMarkdown: String {
        guard message.role == .assistant,
              !message.chunksInjected.isEmpty else { return message.content }
        return AskPoseyCitationRenderer.render(
            text: message.content,
            chunks: message.chunksInjected
        )
    }

    private var accessibilityLabel: String {
        switch message.role {
        case .user: return "You said: \(message.content)"
        case .assistant: return "Posey said: \(message.content)"
        case .anchor: return ""
        }
    }
}

/// Maps `[N]` inline citation markers in an assistant response to
/// SwiftUI markdown links pointing at `posey-cite://N`, with the
/// link's display text rendered as unicode-superscript digits so
/// they read like Perplexity-style superscript citations.
enum AskPoseyCitationRenderer {
    static let citationURLScheme = "posey-cite"

    /// Convert `[N]` markers in the answer text to tappable
    /// superscript markdown links. The text reaching this renderer
    /// has already been through embedding-based attribution
    /// upstream (AskPoseyChatViewModel.finalizeAssistantTurn) — the
    /// renderer's only job is the marker→link transform.
    static func render(text: String, chunks: [RetrievedChunk]) -> String {
        convertMarkersToLinks(text, chunkCount: chunks.count)
    }

    /// Test seam matching the original signature.
    static func render(text: String, chunkCount: Int) -> String {
        convertMarkersToLinks(text, chunkCount: chunkCount)
    }

    private static func convertMarkersToLinks(_ text: String, chunkCount: Int) -> String {
        guard chunkCount > 0 else { return text }
        let pattern = #"\[(\d{1,2})\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsRange = NSRange(text.startIndex..., in: text)
        var result = ""
        var lastEnd = text.startIndex
        regex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
            guard let match,
                  let fullRange = Range(match.range, in: text),
                  let numRange = Range(match.range(at: 1), in: text),
                  let n = Int(text[numRange]),
                  n >= 1, n <= chunkCount else { return }
            result += text[lastEnd..<fullRange.lowerBound]
            result += "[\(superscript(for: n))](\(citationURLScheme)://\(n))"
            lastEnd = fullRange.upperBound
        }
        result += text[lastEnd..<text.endIndex]
        return result
    }

    /// Resolve the chunk number out of a `posey-cite://N` URL.
    /// Returns nil for any other URL shape so the global URL handler
    /// can defer to the system for non-citation links.
    static func chunkNumber(from url: URL) -> Int? {
        guard url.scheme == citationURLScheme,
              let host = url.host,
              let n = Int(host) else { return nil }
        return n
    }

    private static let superscriptDigits: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"
    ]

    private static func superscript(for n: Int) -> String {
        String(String(n).map { superscriptDigits[$0] ?? $0 })
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
