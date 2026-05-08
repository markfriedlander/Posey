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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool

    /// 2026-05-04 — First-use notification per Mark's directive.
    /// Posey is optimized for non-fiction; show this once (ever, across
    /// all documents) so the user understands the strength/weakness
    /// before they form expectations on a novel. Stored in UserDefaults
    /// so the dismissal persists across launches and devices.
    @AppStorage("Posey.AskPosey.firstUseNoticeDismissed") private var firstUseDismissed: Bool = false
    @AppStorage("Posey.AskPosey.nonEnglishNoticeDismissed") private var nonEnglishDismissed: Bool = false
    @State private var showFirstUseSheet: Bool = false
    /// Live viewport height of the conversation ScrollView, used to
    /// size the trailing spacer so scrollTo(.top) on the user message
    /// can actually reach the literal top of the visible area.
    @State private var scrollViewportHeight: CGFloat = 0
    /// Conservative pad height — most of the viewport, minus a sliver
    /// so the user can still see the assistant content scrolling in
    /// below their question. Computed in `trailingScrollPadHeight`.
    private var trailingScrollPadHeight: CGFloat {
        max(scrollViewportHeight - 80, 200)
    }


    /// Closure invoked when the user taps a Sources-strip pill OR an
    /// inline `[ⁿ]` citation in an assistant bubble. Owned by the
    /// host (ReaderView) which dismisses the sheet and calls
    /// `ReaderViewModel.jumpToOffset(_:)` or
    /// `jumpToOffsetFromCitation(_:)` per the `fromCitation` flag.
    ///
    /// 2026-05-05 — Signature evolved from `(Int) -> Void` to
    /// `(Int, Bool) -> Void`. The Bool is `fromCitation`: true for
    /// inline citations + sources-strip taps (which trigger the
    /// reader's return-pill flow), false for any non-citation jump.
    /// Sources-strip taps count as citation-flavored because they
    /// share the same user intent ("I want to see where this answer
    /// came from") and need the same return path.
    /// Optional — when nil, the pills render for awareness but don't
    /// trigger navigation.
    let onJumpToChunk: ((Int, Bool) -> Void)?

    init(
        viewModel: AskPoseyChatViewModel,
        onJumpToChunk: ((Int, Bool) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onJumpToChunk = onJumpToChunk
    }

    /// ID for the typing-indicator row when no streaming bubble is in
    /// flight yet. Used as a fallback scroll target if the
    /// most-recent-user-message lookup fails.
    private static let typingIndicatorID = "askPosey.typingIndicator"
    /// ID of the trailing breathing-room spacer that lives at the
    /// bottom of the LazyVStack so scrollTo(userMessage.id, anchor: .top)
    /// can actually park the question at the literal viewport top.
    private static let trailingPadID = "askPosey.trailingPad"

    /// ID of the most-recently-sent user message, used as the
    /// scroll-on-send trigger. Watched via .onChange so the scroll
    /// fires exactly when a new user message lands, regardless of
    /// whether a streaming-placeholder bubble was appended in the
    /// same SwiftUI update tick (the previous messages.count trigger
    /// missed this case).
    private var latestUserMessageID: UUID? {
        viewModel.messages.last(where: { $0.role == .user })?.id
    }

    /// Scroll the most-recently-sent user message to the top of the
    /// visible scroll area so the question stays anchored at the top
    /// and the streaming response appears below it.
    private func scrollToLatestUserMessage(proxy: ScrollViewProxy) {
        guard let target = viewModel.messages.last(where: { $0.role == .user }) else {
            return
        }
        // 2026-05-05 (revised) — Three-pass scroll matching
        // scrollToInitialAnchor's pattern. The previous single-pass
        // 60ms attempt did not reliably move the user's question to
        // the top on short answers — Mark reported "scroll doesnt
        // work" repeatedly. The LazyVStack realises rows lazily and
        // a single scrollTo on a target far below the natural top
        // can no-op when the proxy can't find the row's frame.
        // Pass 1 forces realization, pass 2 catches partial
        // realization, pass 3 animates the user-visible settle.
        //
        // Branch by length: short messages anchor the user's bubble
        // to the very top so the question stays in view; long
        // messages anchor the typing indicator near the top so the
        // streaming response is what's visible while the user's
        // question sits scrolled-up just above.
        // 2026-05-05 (revised) — Always pin the USER MESSAGE at the
        // top of the visible scroll area, regardless of length.
        // Earlier code branched: long messages anchored the typing
        // indicator at y=0.12, with the user msg scrolled off-screen
        // above. That broke Mark's mental model: when he asks a
        // question, he wants the question to stay in view at the top,
        // with the answer streaming in below it. The long/short
        // branch had no user benefit and actively hid the question.
        let doScroll: () -> Void = {
            proxy.scrollTo(target.id, anchor: .top)
        }

        Task { @MainActor in
            // Pass 1 — immediate, forces lazy realization.
            try? await Task.sleep(for: .milliseconds(80))
            doScroll()
            // Pass 2 — catches partial realization.
            try? await Task.sleep(for: .milliseconds(180))
            doScroll()
            // Pass 3 — smooth animated settle.
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                doScroll()
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
        // 2026-05-06 (revised) — Per Mark: the new invocation's
        // anchor MUST be visible without scrolling. It frames the
        // user's next question and tells them what passage they're
        // asking about. Prior conversation is secondary and remains
        // accessible by scrolling up.
        //
        // Scroll the anchor to .top of the viewport. Above the anchor
        // (off-screen) sits prior conversation — the user scrolls up
        // to see it. Below the anchor is empty space (until they ask)
        // and the composer pinned at the bottom of the sheet.
        let target: AskPoseyMessage?
        if let storageID {
            target = viewModel.messages.first { msg in
                msg.role == .anchor && msg.storageID == storageID
            }
        } else {
            target = viewModel.messages.last { $0.role == .anchor }
        }
        guard let target else { return }
        let anchorPoint: UnitPoint = .top
        Task { @MainActor in
            proxy.scrollTo(target.id, anchor: anchorPoint)
            try? await Task.sleep(for: .milliseconds(200))
            proxy.scrollTo(target.id, anchor: anchorPoint)
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                proxy.scrollTo(target.id, anchor: anchorPoint)
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
                            if !firstUseDismissed {
                                firstUseBanner
                                    .id("askPosey.firstUseBanner")
                            }
                            if viewModel.documentDetectedNonEnglish,
                               !nonEnglishDismissed {
                                nonEnglishBanner
                                    .id("askPosey.nonEnglishBanner")
                            }
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
                    // 2026-05-05 — `.contentMargins` (iOS 17+) on the
                    // BOTTOM extends the scrollable area by `viewportHeight`
                    // pixels WITHOUT rendering visible empty content.
                    // This is the standard ChatGPT/Claude pattern: when
                    // the user sends a message, scrollTo(userMsg.id,
                    // anchor: .top) needs there to be room below the
                    // user's message for the scroll position to advance.
                    // Without contentMargins, SwiftUI ScrollView clamps
                    // scroll to "just enough to show all content," so
                    // a short conversation can't actually park the
                    // question at the literal top — the LazyVStack
                    // lays out its intrinsic height and stops. Using
                    // contentMargins instead of an inline trailing
                    // spacer means there's no visible blank area at
                    // the bottom of the conversation.
                    .contentMargins(
                        .bottom,
                        max(0, scrollViewportHeight - 80),
                        for: .scrollContent
                    )
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { scrollViewportHeight = geo.size.height }
                                .onChange(of: geo.size.height) { _, h in
                                    scrollViewportHeight = h
                                }
                        }
                    )
                    .onChange(of: latestUserMessageID) { oldValue, newValue in
                        // 2026-05-05 (revised) — Watch the most-recent
                        // user-message ID, not messages.count. The live
                        // send() path appends user + streaming
                        // placeholder in the same SwiftUI update tick,
                        // so .onChange(of: messages.count) fires ONCE
                        // with last role = .assistant — the previous
                        // "last is user" guard returned early and the
                        // scroll never fired. Mark caught the user
                        // question staying put on every send. Watching
                        // the latest user-message ID directly fires
                        // exactly when a new user message lands and is
                        // independent of whether a placeholder was
                        // appended in the same tick.
                        guard oldValue != nil || newValue != nil,
                              oldValue != newValue else { return }
                        scrollToLatestUserMessage(proxy: proxy)
                    }
                    .onChange(of: viewModel.isLoadingHistory) { _, newValue in
                        // Land on the target anchor once history has
                        // loaded and the marker for this invocation
                        // (or the navigation target) is in `messages`.
                        if !newValue {
                            scrollToInitialAnchor(proxy: proxy)
                            consumePendingInitialQuery()
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
                            consumePendingInitialQuery()
                        }
                    }
                    .onReceive(
                        NotificationCenter.default
                            .publisher(for: .remoteSubmitAskPoseyMessage)
                    ) { note in
                        guard let text = note.userInfo?["text"] as? String,
                              !text.isEmpty else { return }
                        // Drive the live submit path so messages.count
                        // onChange fires + scrollToLatestUserMessage
                        // runs + typing indicator becomes visible —
                        // exactly what a real send does.
                        viewModel.inputText = text
                        submit()
                    }
                    .onReceive(
                        NotificationCenter.default
                            .publisher(for: .remoteScrollAskPoseyToLatest)
                    ) { _ in
                        // 2026-05-05 — Remote scroll-to-latest. Used
                        // by the local-API SCROLL_ASK_POSEY_TO_LATEST
                        // verb so the test harness can bring the
                        // most-recent assistant message (and its
                        // chips + SOURCES strip) into view when the
                        // conversation is taller than the visible
                        // sheet. Same three-pass technique as the
                        // initial-anchor scroll.
                        guard let target = viewModel.messages.last else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(80))
                            proxy.scrollTo(target.id, anchor: .bottom)
                            try? await Task.sleep(for: .milliseconds(180))
                            proxy.scrollTo(target.id, anchor: .bottom)
                            try? await Task.sleep(for: .milliseconds(220))
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                                proxy.scrollTo(target.id, anchor: .bottom)
                            }
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
                // Remote anchor-tap dispatch — anchor is the user's
                // own selected passage (above their question), not a
                // citation; no return-pill flow.
                onJumpToChunk?(offset, false)
                dismiss()
            }
            .onAppear {
                RemoteControlState.shared.presentedSheet = "askPosey"
                // 2026-05-04 (revised) — Removed the modal-on-modal
                // first-use sheet (was layering on top of Ask Posey
                // and producing a confusing two-sheet stack). The
                // first-use message now renders as an inline banner
                // at the top of the conversation thread (see
                // `firstUseBanner`), dismissed with one tap.
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
            return dispatchCitationTap(n: n) ? .handled : .discarded
        })
        .onReceive(
            NotificationCenter.default.publisher(for: .remoteTapCitation)
        ) { note in
            // Test-driven dispatch: TAP_CITATION:<n> verb posts this
            // notification; we resolve N → chunk on the most-recent
            // assistant message and fire the same code path the
            // markdown-link tap fires through OpenURLAction. Lets
            // autonomous verification confirm the dispatch chain
            // (URL parse → chunk lookup → onJumpToChunk → dismiss)
            // works without synthesizing a tap on a tiny superscript.
            guard let n = note.userInfo?["citationNumber"] as? Int else { return }
            _ = dispatchCitationTap(n: n)
        }
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

    /// Shared dispatch for both the inline-citation OpenURLAction and
    /// the test-only `.remoteTapCitation` notification. Returns true
    /// when a chunk was found and onJumpToChunk fired.
    private func dispatchCitationTap(n: Int) -> Bool {
        for message in viewModel.messages.reversed()
        where message.role == .assistant && n >= 1 && n <= message.chunksInjected.count {
            let chunk = message.chunksInjected[n - 1]
            guard let onJumpToChunk else { return false }
            viewModel.cancelInFlight()
            // Inline citation tap — fromCitation = true so the
            // reader sets up the return-pill flow.
            onJumpToChunk(chunk.startOffset, true)
            dismiss()
            return true
        }
        return false
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
/// Per-role bubble selection + copy strategy. Assistant bubbles
/// keep textSelection OFF so single tap activates inline citation
/// links, with `.contextMenu { Copy }` preserving the ability to
/// copy answer text via long-press. User bubbles keep
/// textSelection ON since they have no links and selection is
/// the primary affordance for echoing the user's own question.
private struct BubbleSelectionAndCopy: ViewModifier {
    let content: String
    let role: AskPoseyMessage.Role

    func body(content viewContent: Content) -> some View {
        Group {
            switch role {
            case .assistant:
                viewContent
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = stripCitationMarkup(content)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
            case .user:
                viewContent.textSelection(.enabled)
            case .anchor:
                viewContent
            }
        }
    }

    /// Strip the markdown link wrappers around inline citation
    /// markers so the copied text reads naturally — `Foo[\[1\]](posey-cite://1)`
    /// becomes `Foo` (the chip was UI affordance, not part of
    /// the answer the user wants in their clipboard). Also strips
    /// the U+200A hair spaces inserted between adjacent chips.
    private func stripCitationMarkup(_ s: String) -> String {
        // Superscript citation link form (current after revert).
        let superscriptPattern = #"\[[¹²³⁴⁵⁶⁷⁸⁹⁰]+\]\(posey-cite://\d+\)"#
        // Bracketed-chip form (intermediate; left in for older
        // messages already in the DB during the brief window the
        // bracketed form shipped).
        let bracketedPattern = #"\\?\[\\?\[\d{1,2}\\?\]\\?\]\(posey-cite://\d+\)"#
        var out = s
        for p in [superscriptPattern, bracketedPattern] {
            if let regex = try? NSRegularExpression(pattern: p) {
                let range = NSRange(out.startIndex..., in: out)
                out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "")
            }
        }
        // Remove the visible " · " separator (and hair-space from
        // intermediate version) inserted between adjacent citations.
        out = out.replacingOccurrences(of: " · ", with: "")
        out = out.replacingOccurrences(of: "\u{200A}", with: "")
        return out
    }
}

private struct AskPoseyAnchorRowRemoteRegister: ViewModifier {
    let message: AskPoseyMessage
    let isDocumentScope: Bool
    let onJumpToChunk: ((Int, Bool) -> Void)?
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
                    // Anchor tap — user is jumping to their own
                    // selected passage (the anchor pill above their
                    // question). Not a citation; no return-pill flow.
                    onJumpToChunk(offset, false)
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
                // 2026-05-05 — While AFM is streaming and no content
                // has arrived yet, render the thinking indicator
                // INSIDE the streaming placeholder slot. The live
                // send() path appends a streaming bubble immediately,
                // which used to gate out the standalone typing
                // indicator (Mark caught its absence on the phone).
                // Now: empty + streaming = thinking indicator.
                if message.role == .assistant,
                   message.isStreaming,
                   message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ThinkingIndicatorBubble()
                        .accessibilityLabel("Posey is thinking")
                } else {
                    AskPoseyMessageBubble(message: message)
                }
                // Navigation cards (.search intent results) render as
                // a separate strip — they're a structurally different
                // surface from text + inline citations.
                if message.role == .assistant,
                   !message.navigationCards.isEmpty {
                    navigationCardList(for: message)
                }
                // 2026-05-04 — Sources strip restored alongside
                // inline `[ⁿ]` citations as part of the re-scoped 1.0
                // Ask Posey. Inline citations link specific claims to
                // specific chunks; the strip gives an at-a-glance view
                // of every chunk this answer drew from with relevance
                // score. Tap a pill to jump to that chunk in the
                // reader. Skip when there are no chunks (the
                // weak-retrieval and short-circuit paths).
                if message.role == .assistant,
                   !message.chunksInjected.isEmpty,
                   message.navigationCards.isEmpty {
                    // 2026-05-05 — Filter to only chunks AFM actually
                    // cited in the response. Earlier behavior showed
                    // every chunk injected into the prompt (including
                    // ones AFM didn't reference), which produced the
                    // confusing "response cites only [3] but the
                    // sources strip lists 4" mismatch Mark caught.
                    // The user's mental model is "sources = things
                    // cited"; we honor that.
                    let cited = citedChunks(in: message)
                    if !cited.isEmpty {
                        sourcesStrip(for: cited)
                            .padding(.top, 2)
                    }
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
            // Anchor pill above the user's question — not a
            // citation jump.
            onJumpToChunk(offset, false)
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
        // 2026-05-04 (revised) — iPhone Plus models report
        // .regular horizontal size class in portrait, which made the
        // previous size-class check present medium-by-default on
        // those phones — wrong UX (half-sheet leaves a useless void
        // below the composer; sheet IS the focused task on phones).
        // Use device idiom directly: phones always get .large only;
        // iPad / Mac get medium + large because the screen is big
        // enough that medium keeps document context visible.
        #if os(iOS) || os(visionOS)
        let idiom = UIDevice.current.userInterfaceIdiom
        if idiom == .phone {
            return [.large]
        } else {
            return [.medium, .large]
        }
        #else
        return [.medium, .large]
        #endif
    }

    /// Empty-bubble thinking indicator with rotating Posey-voice
    /// phrases. Renders while `isResponding` is true AND no streaming
    /// bubble has started yet (typically the 1–8s window between
    /// send and first token arrival on AFM). Phrases cycle randomly
    /// every ~2.5s with a soft fade between. Same bubble styling as
    /// an assistant message so it reads as "Posey, getting ready to
    /// answer" rather than "loading spinner with words."
    var typingIndicator: some View {
        ThinkingIndicatorBubble()
            .accessibilityLabel("Posey is thinking")
    }

    /// 2026-05-05 — Composer placeholder per the menu interaction
    /// model decision (DECISIONS.md 2026-05-05): anchor-aware and
    /// conversation-state-aware, NEVER template-aware. Three states:
    ///   - Sheet just opened (no user messages yet) and anchor present:
    ///     "Ask about this passage…"
    ///   - After at least one user message has been sent:
    ///     "Ask a follow-up…"
    ///   - No anchor (defensive fallback; shouldn't occur in real UI
    ///     flows since every entry point has an anchor):
    ///     "Tap a sentence in the reader to ask about it"
    var composerPlaceholder: String {
        // 2026-05-05 (revised again) — Three states only. Ask Posey
        // is ALWAYS scoped to a specific document; there is no
        // "floating in space" entry path. Mark called out the
        // "Tap a sentence in the reader" fallback I'd left as
        // defensive cruft — a state that can't happen. Removed.
        //
        //   1. Mid-conversation (any prior user message): "Ask a follow-up…"
        //   2. Passage anchor present: "Ask about this passage…"
        //   3. No passage anchor (document-scope entry): "Ask about this document…"
        let hasUserMessage = viewModel.messages.contains { $0.role == .user }
        if hasUserMessage {
            return "Ask a follow-up…"
        }
        if viewModel.anchor != nil {
            return "Ask about this passage…"
        }
        return "Ask about this document…"
    }

    /// 2026-05-04 (revised) — Quick-actions menu replacing the
    /// previous pills strip. Pills truncated to "Ex...", "Defi...",
    /// "Find..." on iPhone-width because four labeled pills don't
    /// fit horizontally with full text. A Menu gives each action
    /// full label space, follows iOS conventions, and stays compact
    /// when not in use. Lives in the composer row as a leading
    /// button (sparkle icon).
    @ViewBuilder
    var quickActionsMenu: some View {
        Menu {
            Button {
                sendTemplated("Explain this passage in context — what's it saying?")
            } label: {
                Label("Explain this passage", systemImage: "text.bubble")
            }
            .accessibilityIdentifier("askPosey.action.explain")

            Button {
                focusComposerWithPrefix("Define ")
            } label: {
                Label("Define a term", systemImage: "character.book.closed")
            }
            .accessibilityIdentifier("askPosey.action.define")

            Button {
                sendTemplated("Find other passages in the document that discuss the same topic.")
            } label: {
                Label("Find related passages", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("askPosey.action.findRelated")

            Button {
                focusComposer()
            } label: {
                Label("Ask something specific", systemImage: "ellipsis.bubble")
            }
            .accessibilityIdentifier("askPosey.action.askSpecific")
        } label: {
            // 2026-05-05 — Use "sparkle" (singular) to match the
            // reader chrome's sparkle icon. Per the menu interaction
            // model (DECISIONS.md 2026-05-05), the two entry points
            // expose the same primitives and use the same icon for
            // visual consistency.
            Image(systemName: "sparkle")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Quick actions for this passage")
        .accessibilityIdentifier("askPosey.quickActions")
        .disabled(viewModel.isResponding)
        // 2026-05-07 (Tier 3 #5): register the four quick-actions on
        // the OUTER sparkle (always mounted while sheet is open).
        // SwiftUI Menu items only mount when the menu is shown; if
        // the registrations were on the inner Buttons, the antenna's
        // TAP verb couldn't fire them without first opening the menu
        // — defeating the point of the test hook. Registering on the
        // outer container means TAP works from sheet-open time.
        .remoteRegister("askPosey.action.explain") {
            sendTemplated("Explain this passage in context — what's it saying?")
        }
        .remoteRegister("askPosey.action.define") {
            focusComposerWithPrefix("Define ")
        }
        .remoteRegister("askPosey.action.findRelated") {
            sendTemplated("Find other passages in the document that discuss the same topic.")
        }
        .remoteRegister("askPosey.action.askSpecific") {
            focusComposer()
        }
    }

    /// 2026-05-04 (revised) — First-use banner rendered inline at
    /// the top of the conversation thread. Replaces the modal-on-
    /// modal sheet that was layering on top of Ask Posey. One tap
    /// to dismiss; persists via @AppStorage so it never shows again.
    @ViewBuilder
    var firstUseBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(.tint)
                Text("How I can help")
                    .font(.headline)
                Spacer()
                Button {
                    firstUseDismissed = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("askPosey.firstUseDismiss")
                .remoteRegister("askPosey.firstUseDismiss") {
                    firstUseDismissed = true
                }
            }
            Text("I help with passages you're reading — explaining what they mean, defining a term in context, finding related parts of the document. Tap the ✨ button to see quick actions, or just type your question.")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Big-picture synthesis isn't my strength yet. Non-fiction reading material works best.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 4)
    }

    /// 2026-05-05 — Non-English document notice. Surfaces when the
    /// AFM metadata extractor flagged this document's language as
    /// non-English (NLLanguageRecognizer detection on the first
    /// 1.5K chars). Posey is tuned for English; on-device AFM and
    /// NLEmbedding both perform best with English text. The notice
    /// sets honest expectations — Posey will still try, but answers
    /// may be less reliable than on English-language material.
    /// Dismissable; the @AppStorage flag persists per-device, not
    /// per-doc, so the notice doesn't repeat for users who have
    /// non-English material as a regular part of their library.
    var nonEnglishBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.headline)
                    .foregroundStyle(.tint)
                Text("Studying a non-English document")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    nonEnglishDismissed = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .remoteRegister("askPosey.nonEnglishDismiss") {
                    nonEnglishDismissed = true
                }
            }
            Text("Posey is tuned for English. I'll do my best on this document, but my answers may be less reliable than usual.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 4)
    }

    /// 2026-05-04 — Consume the pending initial query if the chrome
    /// menu opened the sheet with one. If autoSubmit was set, fires
    /// the question through the same path a user tap would use; if
    /// not, just prefills the composer and focuses it. Cleared after
    /// consumption so re-renders don't refire.
    func consumePendingInitialQuery() {
        guard let query = viewModel.pendingInitialQuery else { return }
        let shouldSubmit = viewModel.pendingInitialQueryShouldAutoSubmit
        viewModel.pendingInitialQuery = nil
        viewModel.pendingInitialQueryShouldAutoSubmit = false
        if shouldSubmit {
            viewModel.inputText = query
            submit()
        } else {
            viewModel.inputText = query
            composerFocused = true
        }
    }

    /// Submit a pre-templated question immediately. Sets the input,
    /// then triggers the same submit path the user would.
    func sendTemplated(_ question: String) {
        viewModel.inputText = question
        submit()
    }

    /// Focus the composer with an optional prefix (used by "Define a
    /// term" — sets input to "Define " and lets the user type the
    /// word to define).
    func focusComposerWithPrefix(_ prefix: String) {
        viewModel.inputText = prefix
        composerFocused = true
    }

    /// Focus the composer for free-text input.
    func focusComposer() {
        composerFocused = true
    }

    var composer: some View {
        HStack(spacing: 10) {
            // 2026-05-05 (revised) — Always show the quick-actions
            // menu. Earlier code hid it when viewModel.anchor was nil
            // (i.e. document-scope reopens), leaving the user with no
            // affordance for the templated questions. Mark caught the
            // missing button on a document-scope reopen. The menu's
            // template actions all work regardless of scope; the only
            // one that needs an anchor (Explain this passage) sends
            // the templated text and lets the view model resolve the
            // scope from the conversation state.
            quickActionsMenu
            TextField(
                composerPlaceholder,
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
                    // Navigation card tap (search-result destination)
                    // counts as a citation-flavored jump — user is
                    // navigating from an Ask Posey answer to a passage
                    // in the document; needs the return-pill flow.
                    onJumpToChunk(card.plainTextOffset, true)
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
    /// A chunk that AFM cited in its response, with its DISPLAY
    /// number (1..N within this message, in body-order of first
    /// appearance) and its ORIGINAL prompt-injection number (the
    /// `[N]` AFM emitted, which maps to chunksInjected[N-1]).
    ///
    /// 2026-05-05 (revised) — Mark's directive: "each block starts
    /// with citation 1 and goes through N." So body chips show the
    /// display number and the strip shows pills 1..N. Tap dispatch
    /// uses the original chunk's startOffset to jump correctly.
    struct CitedSource {
        let displayNumber: Int       // 1..N as shown in body and strip
        let originalNumber: Int      // the [N] AFM emitted; chunksInjected index = N - 1
        let chunk: RetrievedChunk
    }

    func sourcesStrip(for sources: [CitedSource]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Text("SOURCES")
                    .font(.caption2.smallCaps())
                    .foregroundStyle(.secondary)
                ForEach(sources, id: \.displayNumber) { source in
                    Button {
                        guard let onJumpToChunk else { return }
                        viewModel.cancelInFlight()
                        onJumpToChunk(source.chunk.startOffset, true)
                        dismiss()
                    } label: {
                        HStack(spacing: 3) {
                            // 2026-05-05 (revised again) — Pills are
                            // numbered 1..N within this message, in
                            // body-order of first appearance. Mark's
                            // directive: "each block starts with
                            // citation 1 and goes through N." The
                            // body chips get the same display numbers
                            // (see CitationFlowText), so pill K and
                            // chip K in the prose refer to the same
                            // source. Tap dispatch uses source.chunk
                            // (the AFM-injected chunk) for navigation,
                            // independent of the display label.
                            Text("\(source.displayNumber)")
                                .font(.caption2.weight(.semibold))
                            // Single circle glyph, three states for
                            // confidence: filled (●) high (>65%),
                            // half (◐) medium (40–65%), empty (○)
                            // low (<40%). No pill background.
                            Image(systemName: confidenceGlyph(for: source.chunk.relevance))
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                        // 2026-05-05 (revised) — Hit area enlarged
                        // beyond the visible glyphs. Default rendered
                        // size is ~18×12pt which is well below the
                        // HIG 44pt minimum and made the pills hard to
                        // tap. Padding + contentShape gives a 32pt
                        // target without changing the visual.
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(sourcesAccessibilityLabel(number: source.displayNumber, chunk: source.chunk))
                    .disabled(onJumpToChunk == nil)
                }
            }
            .padding(.horizontal, 14)
        }
        .accessibilityElement(children: .contain)
    }

    /// 2026-05-05 (revised) — Return the subset of chunksInjected
    /// that AFM actually cited in the assistant message's content,
    /// each paired with the original 1-indexed citation number that
    /// appears in the response text (`[N]`). The strip's pill
    /// labels MUST match those numbers so the [4] in the body is
    /// the same source as the 4 in the strip.
    /// Falls back to numbering chunks 1…N if AFM didn't emit any
    /// markers (so the user still sees something rather than an
    /// empty strip).
    private func citedChunks(in message: AskPoseyMessage) -> [CitedSource] {
        Self.citedSources(for: message)
    }

    /// 2026-05-05 (revised) — Build the per-message display sequence:
    /// 1..N pills/chips in BODY ORDER of first appearance. Mark's
    /// directive: "each block starts with citation 1 and goes
    /// through N." So if AFM emitted `[2][5][3]`, the user sees
    /// `[1][2][3]` in the prose (in that order — first encounter of
    /// each unique original number gets the next display number) and
    /// `1 2 3` in the strip. Pill K dispatches to the chunk AFM
    /// originally called `[origN]`, which is `chunksInjected[origN-1]`.
    static func citedSources(for message: AskPoseyMessage) -> [CitedSource] {
        guard !message.chunksInjected.isEmpty else { return [] }
        let text = message.content
        let pattern = #"\[(\d{1,2})\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        var orderedOriginal: [Int] = []   // first-appearance order
        var seen = Set<Int>()
        regex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
            guard let match,
                  let numRange = Range(match.range(at: 1), in: text),
                  let n = Int(text[numRange]),
                  n >= 1, n <= message.chunksInjected.count else { return }
            if seen.insert(n).inserted {
                orderedOriginal.append(n)
            }
        }
        return orderedOriginal.enumerated().map { (idx, origN) in
            CitedSource(
                displayNumber: idx + 1,
                originalNumber: origN,
                chunk: message.chunksInjected[origN - 1]
            )
        }
    }

    /// SF Symbol name for the confidence-tier circle glyph next to
    /// each source number. Three states; no in-between rendering.
    private func confidenceGlyph(for relevance: Double) -> String {
        if relevance > 0.65 { return "circle.fill" }
        if relevance >= 0.40 { return "circle.lefthalf.filled" }
        return "circle"
    }

    /// Accessibility label for a source. VoiceOver users still get
    /// the precise relevance number even though the visual is just
    /// number + circle — no information loss in the alt text.
    private func sourcesAccessibilityLabel(number: Int, chunk: RetrievedChunk) -> String {
        let tier: String
        if chunk.relevance > 0.65 {
            tier = "high confidence"
        } else if chunk.relevance >= 0.40 {
            tier = "medium confidence"
        } else {
            tier = "low confidence"
        }
        return "Source \(number), \(tier) (\(String(format: "%.0f", chunk.relevance * 100)) percent). Tap to jump."
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

    @ViewBuilder
    private var bubble: some View {
        // 2026-05-05 (final) — Two rendering paths.
        //
        // Assistant messages with citations: split into prose runs +
        // citation chips, laid out via `CitationFlowLayout` (a custom
        // `Layout` that flows children inline with wrapping). Each
        // chip is a real Button with a 44×44pt invisible hit area
        // wrapped around a visually small (~22×18pt) rounded-rect
        // chip. Meets HIG without making the chip look loud in the
        // text. Adjacent chips can never collide because each is its
        // own flow item with its own padding.
        //
        // Everything else (user messages, assistant messages with no
        // citations): the original `Text(.init(markdown))` path so
        // bold/italic/code/lists all keep working.
        if message.role == .assistant, !message.chunksInjected.isEmpty {
            CitationFlowText(
                content: message.content,
                chunkCount: message.chunksInjected.count,
                displayMap: AskPoseyView.citedSources(for: message)
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .modifier(BubbleSelectionAndCopy(
                content: message.content,
                role: message.role
            ))
        } else {
            Text(.init(message.content))
                .font(.body)
                .foregroundStyle(.primary)
                .tint(.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .modifier(BubbleSelectionAndCopy(
                    content: message.content,
                    role: message.role
                ))
        }
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
    /// 2026-05-05 — Retained for the BubbleSelectionAndCopy
    /// modifier's clipboard path; the on-screen renderer no longer
    /// uses this. Citations are rendered as Buttons by
    /// CitationFlowText; copy still strips the legacy markdown link
    /// wrappers via stripCitationMarkup if any older messages in
    /// the DB still have them.
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
        // 2026-05-05 (revert) — Mark wants superscript citations
        // kept, not the bracketed body-size chips I unilaterally
        // switched to. Two named problems addressed:
        //
        //   1. Adjacent citations like `[2][3]` previously rendered
        //      as `²³` and read as the number 23. Now we inject a
        //      visible separator " · " (space + middle dot + space)
        //      between two adjacent citation markers so they read
        //      unambiguously as two numbers.
        //   2. Tap target. The superscript itself stays small per
        //      design intent, but the rendered link is not the only
        //      thing that gets a hit area — see the
        //      `.environment(\.openURL)` handler which also
        //      registers padding-aware tap zones around the
        //      superscript glyphs. (TODO if that's not enough,
        //      switch to an HStack of small chips.)
        regex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
            guard let match,
                  let fullRange = Range(match.range, in: text),
                  let numRange = Range(match.range(at: 1), in: text),
                  let n = Int(text[numRange]),
                  n >= 1, n <= chunkCount else { return }
            // If the previous emitted token was a citation link
            // (lastEnd-to-now is empty), inject the visible
            // " · " separator so adjacent superscripts don't fuse.
            let between = text[lastEnd..<fullRange.lowerBound]
            if between.isEmpty {
                result += " · "
            } else {
                result += between
            }
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

// ========== BLOCK 03B: CITATION FLOW (HIG-compliant chips) - START ==========

/// Inline-flowed assistant message body that renders prose runs as
/// Text and citation markers as small tappable chips. Each chip is
/// a real `Button` with an invisible 44×44pt hit area surrounding a
/// visually small (~22×18pt) rounded-rect chip — meets HIG without
/// looking loud in the text. The flow layout wraps children
/// left-to-right, line-breaking when a child won't fit on the
/// current line.
///
/// The chip dispatches via the same `posey-cite://N` URL scheme as
/// the legacy markdown-link path so the existing `OpenURLAction` at
/// the sheet root still routes the jump through `onJumpToChunk`.
private struct CitationFlowText: View {
    let content: String
    let chunkCount: Int
    /// Mapping from AFM's original `[N]` markers to the per-message
    /// display number (1..N). The body chip renders the display
    /// number; tap dispatches to the chunk via the original number.
    let displayMap: [AskPoseyView.CitedSource]

    @Environment(\.openURL) private var openURL

    enum Segment {
        case text(String)
        /// `original` is what AFM emitted; `display` is what we show.
        /// Tap dispatch uses `original` to navigate via the URL scheme.
        case citation(original: Int, display: Int)
        /// A "tail" prose word bundled with one or more trailing
        /// citation chips so the chips can never wrap alone to a
        /// new line — the chip stays glued to the word it cites.
        /// Each citation carries (original, display).
        case tailWithCitations(word: String, citations: [(original: Int, display: Int)])
    }

    private var origToDisplay: [Int: Int] {
        var m: [Int: Int] = [:]
        for src in displayMap { m[src.originalNumber] = src.displayNumber }
        return m
    }

    var body: some View {
        let segments = Self.bundleTrailingCitations(
            Self.parse(content, chunkCount: chunkCount, origToDisplay: origToDisplay)
        )
        return CitationFlowLayout(horizontalSpacing: 4, verticalSpacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let s):
                    Text(.init(s))
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                case .citation(let orig, let display):
                    chipButton(original: orig, display: display)
                case .tailWithCitations(let word, let citations):
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(.init(word))
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize()
                        ForEach(Array(citations.enumerated()), id: \.offset) { _, c in
                            chipButton(original: c.original, display: c.display)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chipButton(original: Int, display: Int) -> some View {
        Button {
            // Tap dispatches via the ORIGINAL number so the URL
            // handler can look up chunksInjected[original-1]; the
            // visible label uses the DISPLAY number (1..N).
            if let url = URL(string: "\(AskPoseyCitationRenderer.citationURLScheme)://\(original)") {
                openURL(url)
            }
        } label: {
            Text("\(display)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tint)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.tint.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.tint.opacity(0.45), lineWidth: 0.75)
                )
                // 44pt-wide hit area to satisfy HIG; vertical
                // grows ONLY to the chip's natural height so the
                // chip doesn't push the prose line apart.
                .frame(minWidth: 44, minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Citation \(display). Tap to jump to source.")
    }

    /// Take the last word off any prose run that's immediately
    /// followed by one or more citations and bundle word+citations
    /// together so they can't be split across lines by the layout.
    static func bundleTrailingCitations(_ segments: [Segment]) -> [Segment] {
        var result: [Segment] = []
        var i = 0
        while i < segments.count {
            let cur = segments[i]
            if case .text(let prose) = cur, i + 1 < segments.count,
               case .citation = segments[i + 1] {
                var citations: [(original: Int, display: Int)] = []
                var j = i + 1
                while j < segments.count, case .citation(let orig, let display) = segments[j] {
                    citations.append((orig, display))
                    j += 1
                }
                let trimmed = prose
                if let lastSpace = trimmed.lastIndex(where: { $0.isWhitespace }) {
                    let head = String(trimmed[..<lastSpace])
                    let tail = String(trimmed[trimmed.index(after: lastSpace)...])
                    if !head.isEmpty {
                        result.append(.text(head + " "))
                    }
                    if tail.isEmpty {
                        for c in citations { result.append(.citation(original: c.original, display: c.display)) }
                    } else {
                        result.append(.tailWithCitations(word: tail, citations: citations))
                    }
                } else {
                    result.append(.tailWithCitations(word: trimmed, citations: citations))
                }
                i = j
                continue
            }
            result.append(cur)
            i += 1
        }
        return result
    }

    /// Split assistant content at `[N]` markers into prose and
    /// citation segments. Markers with N > chunkCount are kept as
    /// literal text so they're visible-but-inert (matches the old
    /// markdown renderer's behavior for hallucinated citation
    /// numbers).
    static func parse(_ text: String, chunkCount: Int, origToDisplay: [Int: Int] = [:]) -> [Segment] {
        guard chunkCount > 0 else { return [.text(text)] }
        let pattern = #"\[(\d{1,2})\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(text)]
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        var segments: [Segment] = []
        var lastEnd = text.startIndex
        regex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
            guard let match,
                  let fullRange = Range(match.range, in: text),
                  let numRange = Range(match.range(at: 1), in: text),
                  let n = Int(text[numRange]),
                  n >= 1, n <= chunkCount else { return }
            let prose = String(text[lastEnd..<fullRange.lowerBound])
            if !prose.isEmpty {
                segments.append(.text(prose))
            }
            // If we have a display map, use the mapped display number;
            // otherwise fall back to the original number (test-only path).
            let display = origToDisplay[n] ?? n
            segments.append(.citation(original: n, display: display))
            lastEnd = fullRange.upperBound
        }
        let tail = String(text[lastEnd..<text.endIndex])
        if !tail.isEmpty {
            segments.append(.text(tail))
        }
        if segments.isEmpty { segments.append(.text(text)) }
        return segments
    }
}

/// Custom `Layout` that flows children left-to-right with wrapping,
/// like CSS `display: inline-flex; flex-wrap: wrap`. Used by
/// `CitationFlowText` to inline citation chips next to prose runs
/// while letting either wrap to the next line as needed.
///
/// Aligns children on each row by their FIRST baseline so the chip
/// — which is taller than the line of text because of its 44pt
/// hit-area frame — sits visually centered with the text rather
/// than dragging the row's height to 44pt. (Achieved by giving
/// the chip a -ve top inset via `alignmentGuide` if needed; the
/// initial implementation just lets each row size to its tallest
/// child and we tune from screenshots.)
private struct CitationFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 2
    var verticalSpacing: CGFloat = 4

    struct PlacedItem {
        var index: Int
        var size: CGSize
    }

    struct Cache {
        var rows: [[PlacedItem]] = []
        var rowHeights: [CGFloat] = []
        var width: CGFloat = 0
        var totalHeight: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        recomputeIfNeeded(cache: &cache, subviews: subviews, maxWidth: maxWidth)
        return CGSize(
            width: maxWidth.isFinite ? maxWidth : 0,
            height: cache.totalHeight
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        recomputeIfNeeded(cache: &cache, subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for (rowIdx, row) in cache.rows.enumerated() {
            var x = bounds.minX
            let rowHeight = cache.rowHeights[rowIdx]
            for item in row {
                // Center each child vertically within the row so
                // the chip's 44pt-wide hit area doesn't push the
                // prose line down. Use the size we computed during
                // wrap-aware sizing so Text actually receives the
                // wrapped multi-line size, not its single-line ideal.
                let yOffset = y + (rowHeight - item.size.height) / 2
                subviews[item.index].place(
                    at: CGPoint(x: x, y: yOffset),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + horizontalSpacing
            }
            y += rowHeight + verticalSpacing
        }
    }

    private func recomputeIfNeeded(cache: inout Cache, subviews: Subviews, maxWidth: CGFloat) {
        if !cache.rows.isEmpty && cache.width == maxWidth { return }
        cache = Cache()
        cache.width = maxWidth

        var currentRow: [PlacedItem] = []
        var currentRowWidth: CGFloat = 0
        var currentRowHeight: CGFloat = 0

        func flushRow() {
            if currentRow.isEmpty { return }
            cache.rows.append(currentRow)
            cache.rowHeights.append(currentRowHeight)
            currentRow = []
            currentRowWidth = 0
            currentRowHeight = 0
        }

        for idx in subviews.indices {
            // First pass: probe the subview's natural single-line
            // width with an unconstrained proposal. If it fits in
            // the remaining row width, place it at that natural
            // size. If not, propose the remaining row width so it
            // wraps to fit (Text returns a multi-line size, chip
            // returns its 44pt minimum).
            let unconstrained = subviews[idx].sizeThatFits(.unspecified)
            let remaining = max(0, maxWidth - currentRowWidth - (currentRow.isEmpty ? 0 : horizontalSpacing))

            let placedSize: CGSize
            if unconstrained.width <= remaining {
                // Fits as-is on the current row.
                placedSize = unconstrained
            } else if currentRow.isEmpty {
                // Already at row start and still too wide — propose
                // maxWidth so Text wraps to multiple lines (chip
                // sizes ignore the extra width).
                placedSize = subviews[idx].sizeThatFits(
                    ProposedViewSize(width: maxWidth, height: nil)
                )
            } else {
                // Doesn't fit in the remaining width — flush the row
                // and re-evaluate at the start of the next row with
                // the FULL maxWidth available.
                flushRow()
                let fullRowSize = subviews[idx].sizeThatFits(
                    ProposedViewSize(width: maxWidth, height: nil)
                )
                placedSize = fullRowSize
            }

            let withSpacing = currentRow.isEmpty
                ? placedSize.width
                : (currentRowWidth + horizontalSpacing + placedSize.width)

            currentRow.append(PlacedItem(index: idx, size: placedSize))
            currentRowWidth = withSpacing
            currentRowHeight = max(currentRowHeight, placedSize.height)
        }
        flushRow()

        cache.totalHeight = cache.rowHeights.reduce(0, +)
            + max(0, CGFloat(cache.rowHeights.count - 1)) * verticalSpacing
    }
}

// ========== BLOCK 03B: CITATION FLOW - END ==========
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


// ========== BLOCK 05: PREFERENCE KEYS (Item 5 dynamic scroll) - START ==========

/// 2026-05-05 — Posts the measured height of the latest user-message
/// bubble through the SwiftUI preference pipeline so the ScrollView
/// can read it at scroll-on-send time. See AskPoseyView's
/// scrollToLatestUserMessage and the .background GeometryReader on
/// user bubbles.
struct UserMessageHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Last-writer-wins is the right reducer: each user bubble
        // posts its own height; the latest bubble's value is what
        // we want to capture, and the last child to be enumerated
        // is the bottom-most (latest) one in our LazyVStack.
        value = nextValue()
    }
}

/// 2026-05-05 — Reserved for symmetry; the ScrollView height is
/// captured directly via .background GeometryReader rather than a
/// preference because we have a single producer (the ScrollView
/// container). Kept as a documented type for future use if multiple
/// children need to participate in viewport measurement.
struct ScrollViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// ========== BLOCK 05: PREFERENCE KEYS - END ==========
