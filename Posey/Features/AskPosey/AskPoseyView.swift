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
        let isLong = target.content.count >= 250
        let anchor: UnitPoint = isLong ? UnitPoint(x: 0.5, y: 0.12) : .top
        // The LazyVStack rows use `.id(message.id)` (UUID value);
        // the typing-indicator uses `.id(typingIndicatorID)` (String).
        // ScrollViewProxy keys by the original Hashable identity, so
        // we have to dispatch by type — passing UUID.uuidString to a
        // UUID-keyed row silently no-ops.
        let doScroll: () -> Void = {
            if isLong {
                proxy.scrollTo(Self.typingIndicatorID, anchor: anchor)
            } else {
                proxy.scrollTo(target.id, anchor: anchor)
            }
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
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
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
        // Bracketed `[\[N\]](posey-cite://N)` form (current).
        let pattern = #"\\?\[\\?\[\d{1,2}\\?\]\\?\]\(posey-cite://\d+\)"#
        // Legacy superscript form (older messages already in DB).
        let legacy = #"\[[¹²³⁴⁵⁶⁷⁸⁹⁰]+\]\(posey-cite://\d+\)"#
        var out = s
        for p in [pattern, legacy] {
            if let regex = try? NSRegularExpression(pattern: p) {
                let range = NSRange(out.startIndex..., in: out)
                out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "")
            }
        }
        // Remove hair-space separators inserted between adjacent chips.
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
                AskPoseyMessageBubble(message: message)
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
        if viewModel.anchor == nil {
            return "Tap a sentence in the reader to ask about it"
        }
        let hasUserMessage = viewModel.messages.contains { $0.role == .user }
        if hasUserMessage {
            return "Ask a follow-up…"
        }
        return "Ask about this passage…"
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
            if viewModel.anchor != nil {
                quickActionsMenu
            }
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
    /// A chunk that AFM cited in its response, paired with the
    /// 1-indexed citation number that appeared in the prompt and
    /// in the rendered response text. The label rendered in the
    /// sources strip MUST match this number so the strip aligns
    /// 1:1 with the inline `[N]` markers in the answer body.
    struct CitedSource {
        let citationNumber: Int   // matches `[N]` in the response text
        let chunk: RetrievedChunk
    }

    func sourcesStrip(for sources: [CitedSource]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Text("SOURCES")
                    .font(.caption2.smallCaps())
                    .foregroundStyle(.secondary)
                ForEach(sources, id: \.citationNumber) { source in
                    Button {
                        guard let onJumpToChunk else { return }
                        // Cancel any in-flight stream + dismiss the
                        // sheet first so the user lands on the reader
                        // with the jump already applied. Sources-strip
                        // tap is a citation-flavored jump (same user
                        // intent as inline `[ⁿ]` citation) — pass
                        // fromCitation = true so the reader sets up
                        // the return-pill flow.
                        viewModel.cancelInFlight()
                        onJumpToChunk(source.chunk.startOffset, true)
                        dismiss()
                    } label: {
                        HStack(spacing: 3) {
                            // 2026-05-05 (revised) — Display the
                            // citation number that appeared in the
                            // response text, NOT the position of
                            // this chunk inside the filtered list.
                            // Earlier behavior renumbered to 1, 2,
                            // 3 from the filtered array, so a
                            // response citing [4][6] showed pills
                            // labeled 1, 2 — Mark caught this. The
                            // user's mental model: "the [4] in the
                            // text is the same source as the 4 in
                            // the strip below."
                            Text("\(source.citationNumber)")
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
                    .accessibilityLabel(sourcesAccessibilityLabel(number: source.citationNumber, chunk: source.chunk))
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
        let text = message.content
        let pattern = #"\[(\d{1,2})\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return message.chunksInjected.enumerated().map {
                CitedSource(citationNumber: $0.offset + 1, chunk: $0.element)
            }
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        var citedNumbers = [Int]()  // ordered, deduped
        var seen = Set<Int>()
        regex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
            guard let match,
                  let numRange = Range(match.range(at: 1), in: text),
                  let n = Int(text[numRange]),
                  n >= 1, n <= message.chunksInjected.count else { return }
            if seen.insert(n).inserted {
                citedNumbers.append(n)
            }
        }
        if citedNumbers.isEmpty { return [] }
        return citedNumbers.map { n in
            CitedSource(citationNumber: n, chunk: message.chunksInjected[n - 1])
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

    private var bubble: some View {
        // Renders the message body via SwiftUI's markdown
        // initializer so AFM responses like **bold** / *italic* /
        // `code` show as formatted text instead of literal markdown.
        // Inline citation links of the shape `[¹](posey-cite://1)`
        // are tappable — handled by the
        // `.environment(\\.openURL, ...)` action installed at the
        // sheet root, which dispatches `posey-cite://N` URLs to the
        // matching chunk's offset via `onJumpToChunk`.
        //
        // **Tap target.** `.textSelection(.enabled)` is intentionally
        // OFF on assistant bubbles for tap-target reasons: with text
        // selection enabled, SwiftUI captures a single tap on a
        // markdown link as the start of a selection range — the link
        // is reachable only via long-press → context menu, which
        // Mark correctly reported as "the citation didn't respond
        // when I tapped it." Without textSelection, single tap
        // activates the link and fires the OpenURLAction directly.
        // A `.contextMenu` with Copy preserves the ability to copy
        // the answer text (long-press → Copy).
        //
        // User bubbles (the user's own question echo) keep
        // textSelection enabled because there are no inline links
        // in user content and copying their own question is the
        // primary affordance.
        Text(.init(renderedMarkdown))
            .font(.body)
            .foregroundStyle(.primary)
            .tint(.accentColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .modifier(BubbleSelectionAndCopy(
                content: renderedMarkdown,
                role: message.role
            ))
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
        // 2026-05-05 (revised) — Render as full-size bracketed
        // links `[N]` instead of unicode superscript `[ⁿ]`. Two
        // problems being fixed at once:
        //
        //   1. Tap target. Superscript `⁴` rendered at .footnote
        //      gave a ~10pt glyph — well below HIG 44pt, and Mark
        //      reported missing taps 2-3 times in a row.
        //   2. Adjacent citations. `⁴⁶` for `[4][6]` reads as the
        //      two-digit number 46. Bracketed `[4]` `[6]` are
        //      visually distinct — the brackets themselves act as
        //      separators.
        //
        // We also insert a hair-thin space (U+200A) BETWEEN two
        // adjacent citation links so the bracketed forms don't
        // collide visually. The space sits outside the link text
        // so it's not part of the tap target.
        regex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
            guard let match,
                  let fullRange = Range(match.range, in: text),
                  let numRange = Range(match.range(at: 1), in: text),
                  let n = Int(text[numRange]),
                  n >= 1, n <= chunkCount else { return }
            // If the previous emitted token was a citation link
            // (the lastEnd-to-now slice is empty or pure
            // whitespace-less), inject a hair space so two
            // adjacent `[N]` chips don't fuse.
            let between = text[lastEnd..<fullRange.lowerBound]
            if between.isEmpty {
                result += "\u{200A}"
            } else {
                result += between
            }
            // Bracketed link: `[\[4\]](posey-cite://4)`. Escape
            // the inner brackets so CommonMark parses them as
            // literal `[` and `]` inside the link text rather than
            // attempting nested-link interpretation.
            result += "[\\[\(n)\\]](\(citationURLScheme)://\(n))"
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

    // 2026-05-05 — Superscript rendering removed; citations are
    // now rendered as bracketed `[N]` links in the body font for
    // tap-target and adjacency reasons. See convertMarkersToLinks.
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
