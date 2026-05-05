import AVFoundation
import Combine
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

struct ReaderView: View {
    @StateObject private var viewModel: ReaderViewModel
    /// Mirrors the embedding-index notifications so we can show an
    /// "Indexing this document…" banner without blocking import.
    /// Owned by ReaderView so the banner survives across renders;
    /// LibraryView creates its own instance for the eventual library
    /// row indicator (not in v1).
    @StateObject private var indexingTracker = IndexingTracker()
    @Environment(\.scenePhase) private var scenePhase
    /// M9 landscape polish hook. iPhone rotation flips
    /// `verticalSizeClass`: portrait → .regular, landscape → .compact.
    /// We observe the change to re-fire the scroll-to-current-sentence
    /// pass once the new layout has settled.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var readerHorizontalSizeClass
    /// Honors the system "Reduce Motion" accessibility setting. When true,
    /// chrome fade and scroll animations skip their easing — visible state
    /// changes still happen but without the easing curve.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let isTestMode: Bool
    @State private var isShowingNotesSheet = false
    @State private var isShowingPreferencesSheet = false
    @State private var isShowingTOCSheet = false
    /// Holds the Ask Posey chat view model while the sheet is open.
    /// `nil` when the sheet is dismissed. Using a value-typed item
    /// (instead of a separate `isShowing` Bool) means the view model
    /// is reconstructed on every open — fresh anchor capture, fresh
    /// transcript — and dropped on close so the deinit cancels any
    /// in-flight task.
    @State private var askPoseyChat: AskPoseyChatViewModel? = nil
    @State private var isChromeVisible = true
    @State private var chromeFadeTask: Task<Void, Never>?
    @State private var expandedImageItem: ExpandedImageItem? = nil
    private let chromeTint = Color.white.opacity(0.9)
    private let chromeSecondaryTint = Color.white.opacity(0.62)

    init(
        document: Document,
        databaseManager: DatabaseManager,
        playbackMode: AppLaunchConfiguration.PlaybackMode = .system,
        isTestMode: Bool = false,
        shouldAutoPlayOnAppear: Bool = false,
        shouldAutoCreateNoteOnAppear: Bool = false,
        shouldAutoCreateBookmarkOnAppear: Bool = false,
        automationNoteBody: String = "Automated smoke note"
    ) {
        self.isTestMode = isTestMode
        _viewModel = StateObject(
            wrappedValue: ReaderViewModel(
                document: document,
                databaseManager: databaseManager,
                playbackService: SpeechPlaybackService(
                    mode: playbackMode == .simulated ? .simulated(stepInterval: 0.15) : .system,
                    voiceMode: PlaybackPreferences.shared.voiceMode
                ),
                shouldAutoPlayOnAppear: shouldAutoPlayOnAppear,
                shouldAutoCreateNoteOnAppear: shouldAutoCreateNoteOnAppear,
                shouldAutoCreateBookmarkOnAppear: shouldAutoCreateBookmarkOnAppear,
                automationNoteBody: automationNoteBody
            )
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {

                    if viewModel.usesDisplayBlocks {
                        ForEach(viewModel.displayBlocks) { block in
                            Group {
                                if block.kind == .visualPlaceholder {
                                    visualPlaceholder(block: block)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    Text(viewModel.displayText(for: block))
                                        .textSelection(.enabled)
                                        .font(viewModel.font(for: block))
                                        .fontWeight(viewModel.fontWeight(for: block))
                                        .foregroundStyle(viewModel.foregroundStyle(for: block))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .opacity(blockOpacity(block))
                            .scaleEffect(blockScale(block), anchor: .center)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: viewModel.currentSentenceIndex)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(blockBackground(block))
                            )
                            .id(block.id)
                            .accessibilityIdentifier("reader.segment.\(block.id)")
                            // 2026-05-04 — Single-tap-to-jump
                            // (Mark + cc, evening). Match the
                            // read-aloud genre convention: tapping
                            // a sentence jumps reading position
                            // there. Works now because the outer
                            // tap-to-toggle-chrome gesture was
                            // removed (chrome is persistent), so
                            // there's no competing single-tap
                            // recogniser. Skip on visual-placeholder
                            // blocks (no startOffset to jump to).
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if block.kind != .visualPlaceholder {
                                    viewModel.jumpToOffset(block.startOffset)
                                }
                            }
                        }
                    } else {
                        ForEach(viewModel.segments) { segment in
                            Text(segment.text)
                                .textSelection(.enabled)
                                .font(.system(size: motionFontSize(forSegment: segment)))
                                .opacity(segmentOpacity(segment))
                                .frame(maxWidth: .infinity, alignment: motionAlignment)
                                .multilineTextAlignment(motionTextAlignment)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .scaleEffect(segmentScale(segment), anchor: .center)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: viewModel.currentSentenceIndex)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(segmentBackground(segment))
                            )
                            .id(segment.id)
                            .accessibilityIdentifier("reader.segment.\(segment.id)")
                            // 2026-05-04 — Single-tap-to-jump
                            // (see displayBlock branch comment).
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.jumpToOffset(segment.startOffset)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .contentShape(Rectangle())
            // 2026-05-04 — Tap-to-toggle-chrome removed; single-tap
            // on a sentence row now jumps reading position there
            // (per-row `.onTapGesture` in the ForEach blocks above).
            // Chrome auto-fades after 3 s and re-reveals on scroll
            // motion (any scroll position change brings it back —
            // belt-and-suspenders for the "I want the controls now"
            // intent). Chrome-button taps also reveal chrome (each
            // chrome button calls revealChrome() in its action).
            .onScrollGeometryChange(for: CGFloat.self,
                                    of: { $0.contentOffset.y },
                                    action: { _, _ in revealChrome() })
            .navigationTitle(viewModel.document.title)
            .navigationBarTitleDisplayMode(.inline)
            // Centering strategy:
            //   • Bottom transport and top chrome BOTH float as overlays —
            //     they don't claim layout space.
            //   • Only the search bar uses safeAreaInset(.top), and only
            //     while it's active (search bar is interactive input, not
            //     translucent chrome — content can't scroll under typing).
            //   • Result: scroll content area = (nav bar bottom → home
            //     indicator top) which IS what the user perceives as the
            //     reading area when chrome is faded (the dominant state).
            //   • anchor: .center then puts the active sentence at the
            //     true perceived center, in both portrait and landscape,
            //     across all chrome states. The chrome capsules briefly
            //     overlay the top/bottom edges of the reading region
            //     when visible, but they're translucent and the active
            //     sentence (at center) is well clear of them in both
            //     orientations.
            .safeAreaInset(edge: .top) {
                if viewModel.isSearchActive {
                    SearchBarView(
                        query: Binding(
                            get: { viewModel.searchQuery },
                            set: { viewModel.updateSearchQuery($0) }
                        ),
                        matchCount: viewModel.searchMatchCount,
                        currentMatchPosition: viewModel.currentSearchMatchPosition,
                        onPrevious: { viewModel.goToPreviousSearchMatch() },
                        onNext: { viewModel.goToNextSearchMatch() },
                        onDismiss: {
                            viewModel.deactivateSearch()
                            revealChrome()
                        }
                    )
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                if !viewModel.isSearchActive {
                    HStack {
                        Spacer()
                        topControls
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                    .opacity(isChromeVisible ? 1 : 0)
                    .allowsHitTesting(isChromeVisible)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isChromeVisible)
                }
            }
            .overlay(alignment: .bottom) {
                controls
                    .opacity(isChromeVisible ? 1 : 0)
                    .offset(y: isChromeVisible ? 0 : (reduceMotion ? 0 : 20))
                    .allowsHitTesting(isChromeVisible)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isChromeVisible)
            }
            // 2026-05-04 — Mini-player. When chrome auto-fades during
            // playback, the play/pause button alone stays visible so
            // the user can pause without summoning full chrome (the
            // genre standard — Voice Dream / Speechify / Audible all
            // do this). When the user pauses via the mini-player,
            // chrome re-reveals so they have full controls right
            // when they're likely to want them. When playback stops
            // for any other reason (end of doc, etc.) chrome also
            // re-reveals.
            .overlay(alignment: .bottom) {
                miniPlayer
                    .opacity(miniPlayerVisible ? 1 : 0)
                    .allowsHitTesting(miniPlayerVisible)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: miniPlayerVisible)
            }
            .onChange(of: viewModel.playbackState) { oldValue, newValue in
                // Re-reveal chrome when playback transitions from
                // playing to not-playing. The user just stopped
                // listening; they probably want to do something
                // next (skip, change voice, ask a question) and
                // need the full chrome bar.
                if oldValue == .playing && newValue != .playing {
                    revealChrome()
                }
            }
            // Task 8 #54: TapCatcherView (BLOCK TC) is kept in the
            // file for future use but not mounted here. The always-
            // on overlay variant broke the ScrollView's pan gesture
            // on device (verified live), making the document
            // unscrollable. The .onTapGesture on the outer container
            // above is sufficient for the device-level behavior.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.isSearchActive)
            .onChange(of: viewModel.searchScrollSignal) { _, _ in
                viewModel.scrollToSearchMatch(with: proxy)
            }
            .overlay(alignment: .topLeading) {
                if isTestMode {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TEST MODE")
                            .fontWeight(.semibold)
                        Text(viewModel.playbackStateText)
                            .accessibilityIdentifier("reader.playbackState")
                        Text("\(viewModel.currentSentenceIndex)")
                            .accessibilityIdentifier("reader.currentSentenceIndex")
                        Text(viewModel.document.title)
                            .accessibilityIdentifier("reader.documentTitle")
                        Text("\(viewModel.notes.count)")
                            .accessibilityIdentifier("reader.noteCount")
                    }
                    .font(.caption2)
                    .padding(6)
                    .background(.thinMaterial)
                }
            }
            // Ask Posey indexing banner. Visible at the top center
            // while this document's embedding index is being built in
            // the background. Hidden entirely when AFM is unavailable
            // on this device — per spec, no degraded affordance, no
            // upsell. This is the user-visible signal that "Posey is
            // doing something" during the multi-second embedding
            // pass that previously made big imports (Illuminatus,
            // 1.6M chars / ~3,300 chunks) look frozen.
            .overlay(alignment: .top) {
                indexingBannerView
            }
            // Initial-load overlay. Big documents (Illuminatus,
            // 1.6M chars / ~5–10s NLTokenizer pass) need feedback
            // the moment the reader appears so the navigation push
            // doesn't look like a hang. For small docs the overlay
            // never gets a chance to render: `isLoading` flips to
            // false before the first SwiftUI render cycle.
            .overlay {
                if viewModel.isLoading {
                    openingDocumentOverlay
                }
            }
            .onAppear {
                viewModel.handleAppear()
                revealChrome()
                publishRemoteState()
                ReaderChromeState.shared.isVisible = isChromeVisible
                // Defer the initial scroll past the first layout pass so the
                // LazyVStack has time to realize rows up to the saved sentence
                // position. Calling scrollTo before that happens silently
                // no-ops because the target row doesn't yet exist in layout —
                // which is why pressing Play after open used to "fix" the
                // scroll: the on-change handler triggered realization.
                // Two nudges: one for the typical case, a second after a
                // longer pause for documents where the first scroll only
                // partially advanced the lazy realization.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    viewModel.scrollToCurrentSentence(with: proxy, animated: false)
                    try? await Task.sleep(for: .milliseconds(180))
                    viewModel.scrollToCurrentSentence(with: proxy, animated: false)
                }
            }
            .onChange(of: isChromeVisible) { _, newValue in
                ReaderChromeState.shared.isVisible = newValue
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteReaderToggleChrome)) { _ in
                toggleChrome()
            }
            .onDisappear {
                chromeFadeTask?.cancel()
                viewModel.persistPosition()
                viewModel.stopPlayback()
                clearRemoteStateIfOurs()
            }
            .onChange(of: viewModel.currentSentenceIndex) { _, _ in
                viewModel.scrollToCurrentSentence(with: proxy, animated: true)
                publishRemoteState()
            }
            .onChange(of: viewModel.focusedDisplayBlockID) { _, _ in
                viewModel.scrollToCurrentSentence(with: proxy, animated: true)
            }
            // M9 landscape polish: re-fire scrollToCurrentSentence
            // after orientation changes settle. Without this, rotating
            // mid-read leaves the active sentence off-center until the
            // next playback advance — the previous behavior Mark
            // accepted as "good enough for now" and asked to fix as
            // a polish pass. The two-stage delay (60ms + 180ms)
            // matches the initial-appear pattern: first scroll lands
            // approximately, second scroll catches up after the lazy
            // layout pass realizes the previously off-screen rows.
            .onChange(of: verticalSizeClass) { _, _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    viewModel.scrollToCurrentSentence(with: proxy, animated: false)
                    try? await Task.sleep(for: .milliseconds(180))
                    viewModel.scrollToCurrentSentence(with: proxy, animated: false)
                }
            }
            .onChange(of: readerHorizontalSizeClass) { _, _ in
                // iPad split-view + Mac Catalyst window resize also
                // shift the layout in ways that benefit from the
                // re-center pass.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    viewModel.scrollToCurrentSentence(with: proxy, animated: false)
                    try? await Task.sleep(for: .milliseconds(180))
                    viewModel.scrollToCurrentSentence(with: proxy, animated: false)
                }
            }
            // Task 13 (2026-05-03): catch within-orientation rotations
            // (e.g. landscape-left → landscape-right) that don't fire
            // a sizeClass change but still shift the safe-area
            // insets. UIDevice.orientationDidChangeNotification
            // observes the raw rotation event regardless of size
            // class, giving us full coverage on top of the existing
            // sizeClass-based hooks above.
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    viewModel.scrollToCurrentSentence(with: proxy, animated: false)
                    try? await Task.sleep(for: .milliseconds(180))
                    viewModel.scrollToCurrentSentence(with: proxy, animated: false)
                }
            }
            .onChange(of: scenePhase) { _, newValue in
                if newValue == .background || newValue == .inactive {
                    viewModel.persistPosition()
                }
            }
            .alert("Reader Error", isPresented: $viewModel.isShowingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage)
            }
            .sheet(isPresented: $isShowingNotesSheet) {
                NotesSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $isShowingPreferencesSheet) {
                ReaderPreferencesSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $isShowingTOCSheet) {
                TOCSheet(viewModel: viewModel)
            }
            .sheet(item: $expandedImageItem) { item in
                ExpandedImageSheet(imageID: item.id, viewModel: viewModel)
            }
            // Ask Posey modal sheet (M4: shell + echo stub; M5+: live
            // AFM). Item-bound so the view model's lifetime tracks
            // the sheet — `nil` when closed, a fresh instance with
            // captured anchor when open. The deinit cancels any
            // in-flight Task so a long generation doesn't keep
            // running after dismiss.
            .sheet(
                item: $askPoseyChat,
                onDismiss: {
                    askPoseyChat = nil
                    // The Ask Posey sheet may have appended a new
                    // anchor marker for this invocation — refresh
                    // the unified Saved Annotations list so it
                    // surfaces in the Notes sheet on next open.
                    viewModel.rebuildSavedAnnotations()
                }
            ) { chatVM in
                AskPoseyView(
                    viewModel: chatVM,
                    onJumpToChunk: { offset in
                        // M7 source-attribution tap: dismiss the
                        // sheet (the AskPoseyView calls dismiss()
                        // before invoking this) and jump the reader.
                        viewModel.jumpToOffset(offset)
                    }
                )
            }
            .onReceive(
                NotificationCenter.default
                    .publisher(for: .openAskPoseyForDocument)
            ) { notification in
                // M6 simulator-MCP UI driver: open the sheet when the
                // local API's /open-ask-posey endpoint dispatches the
                // notification. Only respond if this ReaderView is
                // hosting the matching document — multiple
                // simultaneous reader scenes are possible on iPad.
                guard
                    let info = notification.userInfo,
                    let documentID = info["documentID"] as? UUID,
                    documentID == viewModel.document.id
                else { return }
                let scopeStr = (info["scope"] as? String)?.lowercased() ?? "passage"
                let scope: AskPoseyScope = (scopeStr == "document") ? .document : .passage
                let initialAnchorStorageID = info["initialAnchorStorageID"] as? String
                openAskPosey(
                    scope: scope,
                    initialAnchorStorageID: initialAnchorStorageID
                )
            }
            // Remote-control observers (2026-05-02) bundled into a
            // single ViewModifier so adding 5 separate `.onReceive`
            // calls inline doesn't blow the SwiftUI type-checker
            // budget on this already-large body.
            .modifier(ReaderRemoteControlObservers(
                viewModel: viewModel,
                isShowingNotesSheet: $isShowingNotesSheet,
                isShowingPreferencesSheet: $isShowingPreferencesSheet,
                isShowingTOCSheet: $isShowingTOCSheet
            ))
        }
    }

    /// Push the live reader snapshot into the API-visible state cache.
    private func publishRemoteState() {
        let segments = viewModel.segments
        let idx = viewModel.currentSentenceIndex
        let offset = (idx >= 0 && idx < segments.count) ? segments[idx].startOffset : 0
        RemoteControlState.shared.visibleDocumentID = viewModel.document.id
        RemoteControlState.shared.currentSentenceIndex = idx
        RemoteControlState.shared.currentOffset = offset
    }

    private func clearRemoteStateIfOurs() {
        if RemoteControlState.shared.visibleDocumentID == viewModel.document.id {
            RemoteControlState.shared.visibleDocumentID = nil
        }
    }

    /// "Indexing this document…" pill at the top of the reader.
    /// Visible while the document's embedding index is being built in
    /// the background. Per `ask_posey_spec.md` resolved decision 5,
    /// the banner is hidden ENTIRELY when AFM is unavailable on this
    /// device — no greyed-out state, no informational text. The
    /// embedding index work itself still happens (it's useful for
    /// future semantic search regardless of AFM), but the user-facing
    /// surface is silent.
    @ViewBuilder
    private var indexingBannerView: some View {
        if AskPoseyAvailability.isAvailable,
           indexingTracker.isIndexing(viewModel.document.id) {
            let progress = indexingTracker.indexingProgress[viewModel.document.id]
            HStack(spacing: 10) {
                // Always show an animated indicator. When we have a
                // determinate progress fraction, use a small circular
                // progress ring so the user can SEE forward motion;
                // otherwise (very small docs that complete before the
                // first 50-chunk batch posts) fall back to the
                // indeterminate spinner.
                if let progress {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(indexingBannerPrimaryText(progress: progress))
                        .font(.footnote)
                        .foregroundStyle(.primary.opacity(0.85))
                    if let progress {
                        Text(indexingBannerCountText(progress: progress))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.primary.opacity(0.55))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(indexingBannerAccessibilityLabel(progress: progress))
            .accessibilityIdentifier("reader.indexingBanner")
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25),
                       value: indexingTracker.indexingDocumentIDs)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25),
                       value: progress)
        }
    }

    /// Full-screen loading affordance that covers the reader while
    /// segmentation + display block parsing run on the background
    /// queue. Uses `.background` with the system background color so
    /// the still-empty `LazyVStack` underneath doesn't briefly show
    /// "no content" while the load is in flight.
    private var openingDocumentOverlay: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.2)
                Text("Opening \(viewModel.document.title)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening document \(viewModel.document.title)")
        .accessibilityIdentifier("reader.openingOverlay")
        .transition(.opacity)
    }

    private func indexingBannerPrimaryText(
        progress: IndexingTracker.IndexingProgress?
    ) -> String {
        // Even with progress data we keep the primary line stable
        // ("Indexing this document…") rather than rewriting it on every
        // batch. The count line beneath provides the live signal.
        // Stable wording reduces visual noise during fast indexing.
        return "Indexing this document…"
    }

    private func indexingBannerCountText(
        progress: IndexingTracker.IndexingProgress
    ) -> String {
        let processed = Self.formattedChunkCount(progress.processed)
        let total = Self.formattedChunkCount(progress.total)
        return "\(processed) of \(total) sections"
    }

    private func indexingBannerAccessibilityLabel(
        progress: IndexingTracker.IndexingProgress?
    ) -> String {
        if let progress {
            let pct = Int((progress.fraction * 100).rounded())
            return "Indexing this document for Ask Posey, \(pct) percent complete"
        }
        return "Indexing this document for Ask Posey"
    }

    private static func formattedChunkCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 2026-05-04 — Mini-player visibility: only when chrome is
    /// faded AND playback is currently active. The user gets a
    /// always-tappable pause button without needing to summon
    /// full chrome.
    private var miniPlayerVisible: Bool {
        !isChromeVisible && viewModel.playbackState == .playing
    }

    /// Mini-player view — single play/pause button on a thin-material
    /// background so it's visible against any text behind it.
    /// Smaller than the full chrome bar; sits above the home indicator.
    private var miniPlayer: some View {
        Button {
            viewModel.togglePlayback()
            // After toggling, the playbackState change listener
            // (above) will reveal full chrome — the user just
            // paused and is likely about to interact further.
        } label: {
            Image(systemName: viewModel.playPauseImageName)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle().stroke(.white.opacity(0.15), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .padding(.bottom, 24)
        .accessibilityLabel(viewModel.playbackState == .playing ? "Pause" : "Play")
        .accessibilityIdentifier("reader.miniPlayer.playPause")
        .remoteRegister("reader.miniPlayer.playPause") {
            viewModel.togglePlayback()
        }
    }

    private var topControls: some View {
        HStack(spacing: 10) {
            Button {
                revealChrome()
                viewModel.isSearchActive = true
                chromeFadeTask?.cancel()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(chromeTint)
                    .frame(width: 44, height: 44)
            }
            .remoteRegister("reader.search") {
                revealChrome()
                viewModel.isSearchActive = true
                chromeFadeTask?.cancel()
            }
            .accessibilityLabel("Search in document")

            if !viewModel.tocEntries.isEmpty {
                Button {
                    revealChrome()
                    isShowingTOCSheet = true
                } label: {
                    Image(systemName: "list.bullet.indent")
                        .font(.headline)
                        .foregroundStyle(chromeTint)
                        .frame(width: 44, height: 44)
                }
                .remoteRegister("reader.toc") {
                    revealChrome()
                    isShowingTOCSheet = true
                }
                .accessibilityLabel("Table of contents")
            }

            Button {
                revealChrome()
                isShowingPreferencesSheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.headline)
                    .foregroundStyle(chromeTint)
                    .frame(width: 44, height: 44)
            }
            .remoteRegister("reader.preferences") {
                revealChrome()
                isShowingPreferencesSheet = true
            }
            .accessibilityLabel("Reader preferences")

            Button {
                revealChrome()
                viewModel.prepareForNotesEntry()
                isShowingNotesSheet = true
            } label: {
                Image(systemName: "note.text")
                    .font(.headline)
                    .foregroundStyle(chromeTint)
                    .frame(width: 44, height: 44)
            }
            .remoteRegister("reader.notes") {
                revealChrome()
                viewModel.prepareForNotesEntry()
                isShowingNotesSheet = true
            }
            .accessibilityLabel("Notes")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var controls: some View {
        HStack(spacing: 0) {
            // Ask Posey glyph — far left, opposite Restart, per
            // ARCHITECTURE.md "Ask Posey Architecture" §"Surface
            // Design". Hidden entirely when AFM is unavailable on
            // this device, per the AskPosey availability gate
            // captured in DECISIONS.md / ask_posey_spec.md
            // resolved decision 5. The glyph sits OUTSIDE the
            // existing transport HStack — no collision with
            // Previous / Play / Next / Restart spacing.
            if AskPoseyAvailability.isAvailable {
                // 2026-05-04 — Quick-actions menu replaces the
                // single-tap Button. Surfaces the four scoped
                // actions immediately on tap rather than dropping
                // the user into a free-text composer (which buries
                // the structured options behind a second tap on
                // the in-sheet sparkle icon). Each menu item opens
                // the sheet AND starts the corresponding action.
                Menu {
                    Button {
                        explainAction()
                    } label: {
                        Label("Explain this passage", systemImage: "text.bubble")
                    }
                    Button {
                        defineAction()
                    } label: {
                        Label("Define a term", systemImage: "character.book.closed")
                    }
                    Button {
                        findRelatedAction()
                    } label: {
                        Label("Find related passages", systemImage: "magnifyingglass")
                    }
                    Button {
                        askSpecificAction()
                    } label: {
                        Label("Ask something specific", systemImage: "ellipsis.bubble")
                    }
                } label: {
                    Image(systemName: "sparkle")
                        .font(.title3)
                        .foregroundStyle(chromeTint)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Ask Posey")
                // remoteRegister for the existing top-level id —
                // opens the sheet plainly (same as "Ask something
                // specific"). Each menu item also registers under
                // its own id so autonomous tests can fire the
                // specific action without needing to navigate the
                // popover menu.
                .remoteRegister("reader.askPosey") {
                    askSpecificAction()
                }
                .remoteRegister("reader.askPosey.explain", action: { explainAction() })
                .remoteRegister("reader.askPosey.define", action: { defineAction() })
                .remoteRegister("reader.askPosey.findRelated", action: { findRelatedAction() })
                .remoteRegister("reader.askPosey.askSpecific", action: { askSpecificAction() })

                Spacer(minLength: 24)
            }

            Button {
                revealChrome()
                viewModel.goToPreviousMarker()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
                    .foregroundStyle(chromeTint)
                    .frame(width: 44, height: 44)
            }
            .remoteRegister("reader.previous") {
                revealChrome()
                viewModel.goToPreviousMarker()
            }
            .accessibilityLabel("Previous sentence")

            Spacer(minLength: 24)

            Button {
                revealChrome()
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.playPauseImageName)
                    .font(.title3)
                    .foregroundStyle(chromeTint)
                    .frame(width: 44, height: 44)
            }
            .remoteRegister("reader.playPause") {
                revealChrome()
                viewModel.togglePlayback()
            }
            .accessibilityLabel(viewModel.playbackState == .playing ? "Pause" : "Play")

            Spacer(minLength: 24)

            Button {
                revealChrome()
                viewModel.goToNextMarker()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
                    .foregroundStyle(chromeTint)
                    .frame(width: 44, height: 44)
            }
            .remoteRegister("reader.next") {
                revealChrome()
                viewModel.goToNextMarker()
            }
            .accessibilityLabel("Next sentence")

            Spacer(minLength: 24)

            Button {
                revealChrome()
                viewModel.restartFromBeginning()
            } label: {
                Image(systemName: "gobackward")
                    .font(.title3)
                    .foregroundStyle(chromeSecondaryTint)
                    .frame(width: 44, height: 44)
            }
            .remoteRegister("reader.restart") {
                revealChrome()
                viewModel.restartFromBeginning()
            }
            .accessibilityLabel("Restart from beginning")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    private func visualPlaceholder(block: DisplayBlock) -> some View {
        Group {
            if let imageID = block.imageID,
               let data = viewModel.imageData(for: imageID),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                    .onTapGesture { expandedImageItem = ExpandedImageItem(id: imageID) }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(8)
                    }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Visual Element", systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                    Text(block.text)
                        .font(.body)
                    Text("Playback pauses here so you can inspect this visual before continuing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    /// M8 Reading Style render-path opacity. `.standard` returns 1.0
    /// for everything (current behavior). `.focus` dims non-active
    /// non-search-match segments to 0.45 so the eye is naturally
    /// drawn to the brightest one. `.immersive` applies a smooth
    /// distance-based falloff so sentences fade out as they move
    /// away from the active row. Search matches stay at full
    /// opacity in any mode so the search affordance never gets
    /// eaten by the dimming pass.
    private func segmentOpacity(_ segment: TextSegment) -> Double {
        if viewModel.isCurrentSearchMatch(segment: segment) { return 1.0 }
        if viewModel.isSearchMatch(segment: segment) { return 1.0 }
        switch viewModel.readingStyle {
        case .standard:
            return 1.0
        case .focus:
            return viewModel.isActive(segment: segment) ? 1.0 : 0.45
        case .immersive, .motion:
            return immersiveOpacity(forDistanceFromActive: viewModel.distanceFromActive(segment: segment))
        }
    }

    /// Display-block variant of `segmentOpacity`.
    private func blockOpacity(_ block: DisplayBlock) -> Double {
        if viewModel.isCurrentSearchMatch(block: block) { return 1.0 }
        if viewModel.isSearchMatch(block: block) { return 1.0 }
        switch viewModel.readingStyle {
        case .standard:
            return 1.0
        case .focus:
            return viewModel.isActive(block: block) ? 1.0 : 0.45
        case .immersive, .motion:
            return immersiveOpacity(forDistanceFromActive: viewModel.distanceFromActive(block: block))
        }
    }

    /// M8 Immersive scale factor. Active row at 1.0, falls off to
    /// 0.85 at distance 1, then keeps shrinking gently. `.motion`
    /// uses the same curve but the user typically only sees the
    /// active row anyway since it's the largest.
    private func segmentScale(_ segment: TextSegment) -> Double {
        switch viewModel.readingStyle {
        case .standard, .focus:
            return 1.0
        case .immersive, .motion:
            return immersiveScale(forDistanceFromActive: viewModel.distanceFromActive(segment: segment))
        }
    }

    private func blockScale(_ block: DisplayBlock) -> Double {
        switch viewModel.readingStyle {
        case .standard, .focus:
            return 1.0
        case .immersive, .motion:
            return immersiveScale(forDistanceFromActive: viewModel.distanceFromActive(block: block))
        }
    }

    /// Distance-based opacity curve for Immersive / Motion. Active
    /// row at 1.0; falls off geometrically with each row away. After
    /// 4 rows of distance the row is ~5% opacity — invisible but
    /// preserved in the layout so scrolling stays smooth.
    private func immersiveOpacity(forDistanceFromActive distance: Int) -> Double {
        guard distance > 0 else { return 1.0 }
        let raw = 1.0 - 0.30 * Double(distance)
        return max(0.05, raw)
    }

    /// Distance-based scale curve. Active row at 1.0; gentle 15%
    /// shrink per row outward, floor at 0.55.
    private func immersiveScale(forDistanceFromActive distance: Int) -> Double {
        guard distance > 0 else { return 1.0 }
        let raw = 1.0 - 0.15 * Double(distance)
        return max(0.55, raw)
    }

    /// M8 Motion mode: the active sentence renders at ~1.6× the
    /// configured font size, all other rows at the normal size. The
    /// distance-based opacity already handles fade — Motion just
    /// upscales the centerpiece.
    private func motionFontSize(forSegment segment: TextSegment) -> CGFloat {
        guard isMotionRenderActive else { return viewModel.fontSize }
        return viewModel.isActive(segment: segment)
            ? viewModel.fontSize * 1.6
            : viewModel.fontSize
    }

    /// Whether the render path should treat the current state as
    /// "Motion is on." Resolves the user's three-setting choice:
    /// .off never engages, .on always engages, .auto engages when
    /// CoreMotion reports the device is moving (and the user has
    /// consented). Reads `viewModel.isDeviceMoving` so it tracks
    /// the detector's @Published flag.
    private var isMotionRenderActive: Bool {
        guard viewModel.readingStyle == .motion else { return false }
        switch viewModel.motionPreference {
        case .off:  return false
        case .on:   return true
        case .auto: return viewModel.motionAutoConsent && viewModel.isDeviceMoving
        }
    }

    /// Motion mode centers the active sentence both vertically (via
    /// the scroll anchor) and horizontally so the user reading
    /// hands-free has a single bright row to follow.
    private var motionAlignment: Alignment {
        isMotionRenderActive ? .center : .leading
    }

    private var motionTextAlignment: TextAlignment {
        isMotionRenderActive ? .center : .leading
    }

    private func segmentBackground(_ segment: TextSegment) -> Color {
        if viewModel.isCurrentSearchMatch(segment: segment) {
            return Color.primary.opacity(0.28)
        } else if viewModel.isSearchMatch(segment: segment) {
            return Color.primary.opacity(0.10)
        } else if viewModel.isActive(segment: segment) {
            return Color.primary.opacity(0.14)
        }
        return Color.clear
    }

    private func blockBackground(_ block: DisplayBlock) -> Color {
        if viewModel.isCurrentSearchMatch(block: block) {
            return Color.primary.opacity(0.28)
        } else if viewModel.isSearchMatch(block: block) {
            return Color.primary.opacity(0.10)
        } else if viewModel.isActive(block: block) {
            return Color.primary.opacity(0.14)
        }
        return Color.clear
    }

    /// 2026-05-04 — Auto-fade restored (Mark, evening). Chrome
    /// reveals when summoned, fades after 3 s of no interaction.
    /// What changed from the previous design: tap-to-toggle on the
    /// outer ScrollView is GONE (single-tap on a sentence row now
    /// jumps reading position — see per-row .onTapGesture in the
    /// ForEach blocks). Reveal triggers that remain: scroll motion,
    /// chrome-button taps (search/TOC/prefs/Ask Posey/playback),
    /// onAppear, and notification-driven actions.
    private func revealChrome() {
        chromeFadeTask?.cancel()
        isChromeVisible = true
        chromeFadeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard Task.isCancelled == false else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                isChromeVisible = false
            }
        }
    }

    /// 2026-05-04 — No-op stub. The outer tap-to-toggle gesture was
    /// removed (it crowded out the standard tap-to-jump-sentence
    /// gesture). Some call sites still reference `toggleChrome`;
    /// they now just reveal chrome (with the standard auto-fade).
    private func toggleChrome() {
        revealChrome()
    }

    /// Capture the active sentence as the Ask Posey anchor and open
    /// the sheet. The captured anchor is the active sentence at the
    /// moment of invocation — playback paused or running — so the
    /// model has stable context even if playback advances while the
    /// sheet is presenting. M5+ will share this entry point with
    /// the passage-scoped invocation (text-selection menu); the
    /// only difference will be how the anchor is built.
    ///
    /// **M5 wiring (2026-05-01).** The chat view model now takes:
    /// - documentID + plainText so the prompt builder can reach into
    ///   `ask_posey_conversations` for prior history and compute
    ///   surrounding context around the anchor offset.
    /// - A live `AskPoseyService` (when available on the runtime
    ///   platform) so `send()` actually streams a real AFM response.
    ///   Both classifier and streamer are nil on platforms without
    ///   FoundationModels — the view model falls back to the M4 echo
    ///   stub so previews/tests keep running.
    ///
    /// **M6 (2026-05-01).** `scope` parameter selects between
    /// passage-scoped (anchor = current sentence; tight surrounding
    /// window; classifier routes mostly to `.immediate`) and
    /// document-scoped (anchor = nil; classifier routes mostly to
    /// `.general`; the prompt builder relies more heavily on RAG
    /// chunks since there's no anchor passage to ground the answer).
    enum AskPoseyScope { case passage, document }

    /// 2026-05-04 — Quick-action helpers used by the chrome
    /// Ask Posey menu AND the corresponding remoteRegister ids.
    /// Each helper opens the sheet with the right initial-query
    /// shape so a single tap fires the templated action.
    private func explainAction() {
        revealChrome()
        openAskPosey(
            scope: .passage,
            initialQuery: "Explain this passage in context — what's it saying?",
            autoSubmitInitialQuery: true
        )
    }
    private func defineAction() {
        revealChrome()
        openAskPosey(
            scope: .passage,
            initialQuery: "Define ",
            autoSubmitInitialQuery: false
        )
    }
    private func findRelatedAction() {
        revealChrome()
        openAskPosey(
            scope: .passage,
            initialQuery: "Find other passages in the document that discuss the same topic.",
            autoSubmitInitialQuery: true
        )
    }
    private func askSpecificAction() {
        revealChrome()
        openAskPosey(scope: .passage)
    }

    private func openAskPosey(
        scope: AskPoseyScope,
        initialAnchorStorageID: String? = nil,
        initialQuery: String? = nil,
        autoSubmitInitialQuery: Bool = false
    ) {
        let segments = viewModel.segments
        let active = segments.indices.contains(viewModel.currentSentenceIndex)
            ? segments[viewModel.currentSentenceIndex]
            : segments.first
        // Captured reading offset at invocation — populated for both
        // scopes so the persisted anchor marker is always tappable to
        // jump back to where the question was asked, even for
        // document-scoped invocations. Falls back to 0 when the
        // document has no segments yet (defensive — should never
        // happen in production since the reader is rendering them).
        let invocationOffset: Int = active?.startOffset ?? 0

        let anchor: AskPoseyAnchor?
        switch scope {
        case .passage:
            if let active {
                anchor = AskPoseyAnchor(
                    text: active.text,
                    plainTextOffset: active.startOffset
                )
            } else {
                anchor = nil
            }
        case .document:
            // Document-scoped: no AFM-side anchor (the prompt builder
            // skips the ANCHOR + SURROUNDING sections; RAG carries
            // the grounding). The persisted anchor MARKER row still
            // captures `invocationOffset` so the user can jump back
            // to where they asked the question.
            anchor = nil
        }
        // Stop playback while the sheet is open so the document
        // doesn't keep advancing under the user. We don't auto-resume
        // on dismiss — let the user decide.
        viewModel.stopPlayback()

        // Build a live service if AFM is available on this platform/OS.
        // Falls back to nil — the view model degrades gracefully to
        // its echo-stub send path in that case.
        let document = viewModel.document
        let database = viewModel.databaseManager
        var classifier: AskPoseyClassifying?
        var streamer: AskPoseyStreaming?
        var summarizer: AskPoseySummarizing?
        var navigator: AskPoseyNavigating?
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let service = AskPoseyService()
            classifier = service
            streamer = service
            summarizer = service
            navigator = service
        }
        #endif

        askPoseyChat = AskPoseyChatViewModel(
            documentID: document.id,
            documentPlainText: document.plainText,
            documentTitle: document.title,
            anchor: anchor,
            invocationReadingOffset: invocationOffset,
            initialScrollAnchorStorageID: initialAnchorStorageID,
            classifier: classifier,
            streamer: streamer,
            summarizer: summarizer,
            navigator: navigator,
            databaseManager: database,
            initialQuery: initialQuery,
            autoSubmitInitialQuery: autoSubmitInitialQuery
        )
    }
}

// ========== BLOCK TC: TAP CATCHER (Task 8 #54) - START ==========
/// UIKit-wrapped single-tap catcher matching the Apple Books pattern.
///
/// SwiftUI's gesture-resolution stack consumed every prior single-tap
/// variant inside the reader's ScrollView (`.onTapGesture`,
/// `.simultaneousGesture(TapGesture)`, transparent overlays with
/// either Color or Rectangle, and a plain UIKit recogniser without a
/// delegate). The verified-working pattern is a UITapGestureRecognizer
/// with:
///
/// - `cancelsTouchesInView = false` so the tap STILL reaches the
///   underlying buttons / text views — this catcher only listens,
///   it doesn't claim the touch.
/// - A `UIGestureRecognizerDelegate` that returns `true` from
///   `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)`,
///   so the SwiftUI text-selection long-press, the per-row
///   double-tap, and this single-tap all coexist without competing
///   for the same touch sequence.
///
/// Used as an always-on background of the reader content (NOT
/// conditional on `isChromeVisible`), so it never appears or
/// disappears during the touch sequence. The recogniser fires once
/// per tap and toggles `isChromeVisible = true` via the closure.
private struct TapCatcherView: UIViewRepresentable {
    @Binding var chromeVisible: Bool
    @Binding var chromeFadeTask: Task<Void, Never>?
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(reveal: { reveal() })
    }

    func makeUIView(context: Context) -> UIView {
        let v = TapPassthroughUIView()
        v.backgroundColor = .clear
        let g = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle)
        )
        g.numberOfTapsRequired = 1
        g.cancelsTouchesInView = false
        g.delaysTouchesBegan = false
        g.delaysTouchesEnded = false
        g.delegate = context.coordinator
        v.addGestureRecognizer(g)
        v.tapGestureRecognizer = g
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Refresh the closure on every body re-eval so the captured
        // bindings are the current ones.
        context.coordinator.reveal = { reveal() }
    }

    /// The reveal action — runs the same logic as the View's
    /// `revealChrome()` but writes through the @Binding so updates
    /// reach the @State container. Kept here as the proven-working
    /// fallback path; the live build uses the SwiftUI
    /// `.onTapGesture` + `.onScrollGeometryChange` reveal triggers
    /// (verified live on device).
    private func reveal() {
        chromeFadeTask?.cancel()
        chromeVisible = true
        chromeFadeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard Task.isCancelled == false else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                chromeVisible = false
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var reveal: () -> Void
        init(reveal: @escaping () -> Void) { self.reveal = reveal }
        @objc func handle() { reveal() }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// Tap-catcher container. Its hitTest returns SELF (so the
/// attached UITapGestureRecognizer observes touches), but the
/// recogniser uses `cancelsTouchesInView = false` so the touch
/// continues to be delivered to the view's children/siblings for
/// normal handling. Net effect: a single tap anywhere fires the
/// chrome-reveal closure AND still reaches the button beneath
/// (when there is one).
private final class TapPassthroughUIView: UIView {
    weak var tapGestureRecognizer: UITapGestureRecognizer?
    // Default UIView hitTest implementation is fine — returns self
    // for any point in bounds. `cancelsTouchesInView = false` on the
    // recogniser ensures the touch isn't consumed.
}
// ========== BLOCK TC: TAP CATCHER - END ==========


// 2026-05-04 — DoubleTapCatcherView removed before it shipped.
// The plan briefly was a UIKit double-tap-per-row recogniser to
// reintroduce the Task 1 #14 jump-on-double-tap behaviour. After
// surveying genre conventions (Voice Dream / Speechify / Pocket
// all use single-tap-on-text to jump reading position, with
// persistent chrome rather than tap-to-toggle), we pivoted to
// the simpler standard pattern instead. Per-row single-tap is
// now wired in the SwiftUI ForEach blocks above.


// ========== BLOCK RC: REMOTE-CONTROL OBSERVERS - START ==========
/// Bundles the local-API → ReaderView intent observers into one
/// ViewModifier so the main body's modifier chain stays small enough
/// for the SwiftUI type-checker. Each observer maps a notification
/// posted by `LibraryViewModel.executeAPICommand` to a real
/// view-model action — the same path a tap or gesture would take.
private struct ReaderRemoteControlObservers: ViewModifier {
    @ObservedObject var viewModel: ReaderViewModel
    @Binding var isShowingNotesSheet: Bool
    @Binding var isShowingPreferencesSheet: Bool
    @Binding var isShowingTOCSheet: Bool

    func body(content: Content) -> some View {
        content
            .modifier(ReaderRemoteControlAnnotationObservers(
                viewModel: viewModel,
                isShowingNotesSheet: $isShowingNotesSheet
            ))
            .modifier(ReaderRemoteControlPlaybackObservers(viewModel: viewModel))
            .modifier(ReaderRemoteControlSheetObservers(
                viewModel: viewModel,
                isShowingPreferencesSheet: $isShowingPreferencesSheet,
                isShowingTOCSheet: $isShowingTOCSheet
            ))
            .modifier(ReaderRemoteControlPreferencesObservers(viewModel: viewModel))
            .modifier(ReaderRemoteControlSearchObservers(viewModel: viewModel))
    }
}

/// Annotations + jump observers — already shipped surface, kept in
/// their own modifier to share the SwiftUI type-checker budget.
private struct ReaderRemoteControlAnnotationObservers: ViewModifier {
    @ObservedObject var viewModel: ReaderViewModel
    @Binding var isShowingNotesSheet: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .remoteReaderJumpToOffset)) { note in
                guard matches(note, viewModel: viewModel), let offset = offsetIn(note) else { return }
                viewModel.jumpToOffset(offset)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteReaderDoubleTap)) { note in
                guard matches(note, viewModel: viewModel), let offset = offsetIn(note) else { return }
                viewModel.jumpToOffset(offset)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteOpenNotesSheet)) { _ in
                isShowingNotesSheet = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteCreateBookmark)) { note in
                guard matches(note, viewModel: viewModel), let offset = offsetIn(note) else { return }
                viewModel.jumpToOffset(offset)
                viewModel.addBookmarkForCurrentSentence()
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteCreateNote)) { note in
                guard matches(note, viewModel: viewModel),
                      let offset = offsetIn(note),
                      let body = note.userInfo?["body"] as? String else { return }
                viewModel.jumpToOffset(offset)
                viewModel.noteDraft = body
                viewModel.saveDraftNoteForCurrentSentence()
            }
    }
}

private struct ReaderRemoteControlPlaybackObservers: ViewModifier {
    @ObservedObject var viewModel: ReaderViewModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .remotePlaybackPlay)) { note in
                guard matches(note, viewModel: viewModel) else { return }
                if viewModel.playbackState != .playing { viewModel.togglePlayback() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .remotePlaybackPause)) { note in
                guard matches(note, viewModel: viewModel) else { return }
                if viewModel.playbackState == .playing { viewModel.togglePlayback() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .remotePlaybackNext)) { note in
                guard matches(note, viewModel: viewModel) else { return }
                viewModel.goToNextMarker()
            }
            .onReceive(NotificationCenter.default.publisher(for: .remotePlaybackPrevious)) { note in
                guard matches(note, viewModel: viewModel) else { return }
                viewModel.goToPreviousMarker()
            }
            .onReceive(NotificationCenter.default.publisher(for: .remotePlaybackRestart)) { note in
                guard matches(note, viewModel: viewModel) else { return }
                viewModel.restartFromBeginning()
            }
            .onReceive(viewModel.$playbackState) { newState in
                let label: String
                switch newState {
                case .idle:     label = "idle"
                case .playing:  label = "playing"
                case .paused:   label = "paused"
                case .finished: label = "finished"
                }
                RemoteControlState.shared.playbackState = label
            }
    }
}

private struct ReaderRemoteControlSheetObservers: ViewModifier {
    @ObservedObject var viewModel: ReaderViewModel
    @Binding var isShowingPreferencesSheet: Bool
    @Binding var isShowingTOCSheet: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .remoteOpenPreferencesSheet)) { _ in
                isShowingPreferencesSheet = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteOpenTOCSheet)) { _ in
                isShowingTOCSheet = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteOpenAudioExportSheet)) { _ in
                // The Audio Export sheet is a sub-sheet of the
                // Preferences sheet — present preferences first, then
                // flip the export flag after the preferences sheet is
                // mounted so its `.sheet(isPresented:)` modifier is
                // live and can react.
                isShowingPreferencesSheet = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    viewModel.showAudioExport = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteOpenSearchBar)) { _ in
                viewModel.isSearchActive = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteJumpToPage)) { note in
                guard matches(note, viewModel: viewModel),
                      let page = note.userInfo?["page"] as? Int else { return }
                _ = viewModel.jumpToPage(page)
            }
    }
}

private struct ReaderRemoteControlPreferencesObservers: ViewModifier {
    @ObservedObject var viewModel: ReaderViewModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .remoteSetVoiceMode)) { note in
                guard let isCustom = note.userInfo?["isCustom"] as? Bool else { return }
                viewModel.setVoiceMode(isCustom: isCustom)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteSetRate)) { note in
                guard let pct = note.userInfo?["ratePercentage"] as? Float else { return }
                viewModel.setCustomRate(percentage: pct)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteSetFontSize)) { note in
                guard let size = note.userInfo?["fontSize"] as? Double else { return }
                viewModel.fontSize = CGFloat(size)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteSetReadingStyle)) { note in
                guard let raw = note.userInfo?["readingStyle"] as? String,
                      let style = PlaybackPreferences.ReadingStyle(rawValue: raw) else { return }
                viewModel.readingStyle = style
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteSetMotionPreference)) { note in
                guard let raw = note.userInfo?["motionPreference"] as? String,
                      let pref = PlaybackPreferences.MotionPreference(rawValue: raw) else { return }
                viewModel.motionPreference = pref
            }
    }
}

private struct ReaderRemoteControlSearchObservers: ViewModifier {
    @ObservedObject var viewModel: ReaderViewModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .remoteSetSearchQuery)) { note in
                guard let query = note.userInfo?["query"] as? String else { return }
                viewModel.isSearchActive = true
                viewModel.updateSearchQuery(query)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteSearchNext)) { _ in
                viewModel.goToNextSearchMatch()
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteSearchPrevious)) { _ in
                viewModel.goToPreviousSearchMatch()
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteSearchClear)) { _ in
                viewModel.deactivateSearch()
            }
            .onReceive(viewModel.$searchQuery) { newQuery in
                RemoteControlState.shared.searchQuery = newQuery
            }
            .onReceive(viewModel.$isSearchActive) { active in
                RemoteControlState.shared.isSearchActive = active
            }
            .onReceive(viewModel.$searchMatchIndices) { matches in
                RemoteControlState.shared.searchMatchCount = matches.count
            }
            .onReceive(viewModel.$currentSearchMatchPosition) { pos in
                RemoteControlState.shared.currentSearchMatchPosition = pos ?? 0
            }
    }
}

private func matches(_ note: Notification, viewModel: ReaderViewModel) -> Bool {
    guard let docID = note.userInfo?["documentID"] as? UUID else { return false }
    return docID == viewModel.document.id
}

private func offsetIn(_ note: Notification) -> Int? {
    note.userInfo?["offset"] as? Int
}
// ========== BLOCK RC: REMOTE-CONTROL OBSERVERS - END ==========


// ========== BLOCK P1: READER PREFERENCES SHEET - START ==========
private struct ReaderPreferencesSheet: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    /// Draft rate percentage shown live while the slider is dragged.
    /// Committed to the viewModel only on drag end to avoid rapid re-enqueue.
    @State private var draftRatePercentage: Float = 100.0

    private var isCustomMode: Bool {
        if case .custom = viewModel.voiceMode { return true }
        return false
    }

    private var currentVoiceIdentifier: String {
        if case .custom(let id, _) = viewModel.voiceMode { return id }
        return ""
    }

    var body: some View {
        NavigationStack {
            Form {
                // Reading section
                Section("Reading") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Font Size")
                            Spacer()
                            Text("\(Int(viewModel.fontSize))")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $viewModel.fontSize, in: 14...44, step: 1)
                            .accessibilityIdentifier("preferences.fontSize")
                    }
                }

                // Reading Style section (M8)
                Section {
                    Picker("Reading Style", selection: $viewModel.readingStyle) {
                        ForEach(PlaybackPreferences.ReadingStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("preferences.readingStyle")
                    Text(viewModel.readingStyle.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Reading Style")
                } footer: {
                    Text("Standard keeps surrounding text at full opacity. Focus dims it. Immersive centers the active sentence and fades the rest. Motion enlarges one sentence at a time for hands-free reading.")
                        .font(.caption2)
                }

                // Motion sub-settings (only visible when Motion is the chosen Reading Style)
                // Audio export section (M8)
                Section {
                    Button {
                        viewModel.beginAudioExport()
                    } label: {
                        HStack {
                            Image(systemName: "waveform.badge.plus")
                            Text("Export to Audio File")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                    }
                    .remoteRegister("preferences.exportAudio") {
                        viewModel.beginAudioExport()
                    }
                } header: {
                    Text("Audio Export")
                } footer: {
                    Text("Render this document to an .m4a file you can save or share. Best Available voices are usually gated from capture; switch to a Custom voice in Playback above if export refuses.")
                        .font(.caption2)
                }

                if viewModel.readingStyle == .motion {
                    Section {
                        Picker("When to use Motion", selection: $viewModel.motionPreference) {
                            ForEach(PlaybackPreferences.MotionPreference.allCases, id: \.self) { p in
                                Text(p.displayName).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("preferences.motionPreference")

                        if viewModel.motionPreference == .auto && !viewModel.motionAutoConsent {
                            Button {
                                viewModel.showMotionConsent = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text("Auto needs your permission to read motion sensors. Tap to review.")
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .remoteRegister("preferences.motionConsentReview") {
                                viewModel.showMotionConsent = true
                            }
                        } else {
                            Text(viewModel.motionPreference.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Motion Mode")
                    } footer: {
                        Text("Auto monitors device motion via CoreMotion to switch between Motion and your last non-Motion style. Motion data stays on this device.")
                            .font(.caption2)
                    }
                }

                // Playback section
                Section("Playback") {
                    Picker("Voice Mode", selection: Binding(
                        get: { isCustomMode },
                        set: { viewModel.setVoiceMode(isCustom: $0) }
                    )) {
                        Text("Best Available").tag(false)
                        Text("Custom").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("preferences.voiceMode")

                    if isCustomMode {
                        NavigationLink {
                            VoicePickerView(
                                selectedIdentifier: Binding(
                                    get: { currentVoiceIdentifier },
                                    set: { viewModel.setCustomVoice(identifier: $0) }
                                )
                            )
                        } label: {
                            HStack {
                                Text("Voice")
                                Spacer()
                                Text(viewModel.customVoiceDisplayName)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .accessibilityIdentifier("preferences.voicePicker")

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Speed")
                                Spacer()
                                Text("\(Int(draftRatePercentage))%")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            // Rate applies on drag-end only to avoid rapid stop/re-enqueue.
                            Slider(value: $draftRatePercentage, in: 75...150, step: 5) { editing in
                                if !editing {
                                    viewModel.setCustomRate(percentage: draftRatePercentage)
                                }
                            }
                            .accessibilityIdentifier("preferences.rateSlider")
                        }
                    } else {
                        Text("Using the highest-quality voice on your device. Adjust speed and voice in Settings > Accessibility > Spoken Content.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Reader Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .remoteDismissPresentedSheet)
            ) { _ in
                dismiss()
            }
            .onAppear {
                draftRatePercentage = viewModel.customRatePercentage
                RemoteControlState.shared.presentedSheet = "preferences"
            }
            .onDisappear {
                if RemoteControlState.shared.presentedSheet == "preferences" {
                    RemoteControlState.shared.presentedSheet = nil
                }
            }
            .onChange(of: viewModel.voiceMode) { _, _ in
                draftRatePercentage = viewModel.customRatePercentage
            }
            .sheet(isPresented: $viewModel.showMotionConsent) {
                MotionConsentSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showAudioExport) {
                AudioExportSheet(viewModel: viewModel)
            }
        }
    }
}
// ========== BLOCK P1: READER PREFERENCES SHEET - END ==========


// ========== BLOCK P1B: MOTION CONSENT SHEET - START ==========
/// M8 Motion-Auto consent screen. Surfaces the privacy contract for
/// CoreMotion monitoring before the user can pick Auto. Per
/// `DECISIONS.md` "Motion Mode Three-Setting Design" (2026-05-01)
/// CoreMotion monitoring is privacy-sensitive and never engages
/// without explicit opt-in.
private struct MotionConsentSheet: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "figure.walk.motion")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                        .padding(.top, 8)
                    Text("Auto Motion Mode")
                        .font(.title2.weight(.semibold))
                    Text("To switch automatically between Motion mode and your standard reading style based on whether you're moving, Posey reads movement data from your iPhone's motion sensors via CoreMotion.")
                        .font(.body)
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Motion data stays on this device.", systemImage: "lock.shield")
                        Label("Posey doesn't send movement data anywhere — no analytics, no servers.", systemImage: "wifi.slash")
                        Label("You can switch Motion to Off or On at any time and the monitoring stops immediately.", systemImage: "hand.raised")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    HStack {
                        Button("Cancel") {
                            // User declined — revert Auto to Off so
                            // CoreMotion never engages. The picker
                            // re-renders accordingly.
                            viewModel.motionPreference = .off
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button("Allow Motion Monitoring") {
                            viewModel.motionAutoConsent = true
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Motion Permission")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
// ========== BLOCK P1B: MOTION CONSENT SHEET - END ==========


// ========== BLOCK P1C: AUDIO EXPORT SHEET - START ==========
/// M8 audio export progress + completion sheet. Drives the export
/// from `ReaderViewModel.audioExporter`, which the ReaderViewModel
/// rebuilds on each export kickoff. Three states surface as
/// distinct UI: rendering (progress + cancel), finished (share +
/// done), failed (error message + dismiss).
private struct AudioExportSheet: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingShare: Bool = false
    @State private var shareURL: URL? = nil

    /// Display name of the voice the export is currently rendering
    /// with — surfaced in the progress UI so the user knows which
    /// voice the .m4a will use (especially useful when their
    /// playback voice was Best Available and we auto-fell-back to a
    /// Custom voice for capture).
    private var exportingVoiceName: String? {
        guard let exporter = viewModel.audioExporter else { return nil }
        let mode = exporter.exportingVoiceMode
        switch mode {
        case .bestAvailable:
            return "Best Available (system)"
        case .custom(let id, _):
            return AVSpeechSynthesisVoice(identifier: id)?.name ?? id
        case .none:
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Export Audio")
                    .font(.title2.weight(.semibold))
                if let exporter = viewModel.audioExporter {
                    body(for: exporter)
                } else {
                    Text("Export not started.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("Audio Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        viewModel.audioExporter?.cancel()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isShowingShare) {
                if let url = shareURL {
                    ShareLink(item: url) {
                        Text("Share \(url.lastPathComponent)")
                    }
                    .padding(20)
                }
            }
        }
    }

    @ViewBuilder
    private func body(for exporter: AudioExporter) -> some View {
        switch exporter.state {
        case .idle:
            Text("Preparing…")
                .foregroundStyle(.secondary)
        case .rendering(let progress, let i, let total):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("Rendering segment \(i) of \(total) — \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let voiceName = exportingVoiceName {
                    Text("Voice: \(voiceName)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button("Cancel", role: .destructive) {
                    exporter.cancel()
                }
                .padding(.top, 8)
            }
        case .finished(let url):
            VStack(alignment: .leading, spacing: 12) {
                Label("Export complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(url.lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ShareLink(item: url) {
                    Label("Share or Save to Files", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 12) {
                Label("Export failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
// ========== BLOCK P1C: AUDIO EXPORT SHEET - END ==========

// ========== BLOCK NS1: SAVED ANNOTATION MODEL - START ==========

/// Unified annotation entry surfaced in the Notes sheet's "Saved
/// Annotations" list. Combines three underlying record types into a
/// single shape so the sheet can render them in one chronological
/// feed:
///
/// - `.conversation` — derived from `ask_posey_conversations` rows
///   where `role = 'anchor'`. The anchor text or document title (for
///   doc-scope anchors) is the row's display label. Tap → reopen the
///   Ask Posey sheet scrolled to that anchor's position in the thread.
/// - `.note` — derived from `notes` rows where `kind = 'note'`. Tap
///   expands the body inline; secondary tap navigates the reader.
/// - `.bookmark` — derived from `notes` rows where `kind = 'bookmark'`.
///   Tap navigates the reader and dismisses.
///
/// `id` is composed (`"<kind>:<storage>"`) so SwiftUI can identify
/// rows stably across re-aggregation passes without UUID collisions
/// between the two backing tables.
struct SavedAnnotation: Identifiable, Equatable {

    enum Kind: Equatable {
        case conversation
        case note
        case bookmark
    }

    let id: String
    let kind: Kind
    let anchorText: String   // shown as the row label
    let offset: Int          // for jumping the reader
    let timestamp: Date      // for sort order
    let body: String?        // note body (inline-expandable); nil otherwise
    /// Storage id of the anchor row in `ask_posey_conversations`.
    /// Set only when `kind == .conversation`. Threaded into the
    /// open-ask-posey notification's userInfo so the sheet opens
    /// scrolled to this anchor.
    let conversationStorageID: String?
    /// Note row id (in the `notes` table). Set only for `.note` /
    /// `.bookmark` entries. Used by the existing reader-jump path.
    let noteID: UUID?
}

// ========== BLOCK NS1: SAVED ANNOTATION MODEL - END ==========


private struct NotesSheet: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Per-row expansion state for `.note` entries. Keyed by the
    /// row's id so collapsing one note doesn't affect others. Lives
    /// in the sheet (not the view model) because it's purely UI
    /// affordance; persisted state isn't needed.
    @State private var expandedNoteIDs: Set<String> = []

    /// Task 12 (2026-05-03 — Data Portability): the export URL is
    /// computed lazily inside a SwiftUI `View` body. We render it
    /// only when the toolbar `ShareLink` needs it. The exporter
    /// builds Markdown, writes to a temp .md file, and returns the
    /// URL the share sheet hands to whichever extension the user
    /// picks. nil while the database is unavailable.
    private var annotationsExportURL: URL? {
        let payload = AnnotationExporter.export(
            document: viewModel.document,
            databaseManager: viewModel.databaseManager
        )
        return try? payload.temporaryFileURL()
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { listProxy in
            List {
                Section("Current Position") {
                    Text(viewModel.currentSentencePreview)
                        .font(.body)
                        .accessibilityIdentifier("notes.currentSentence")
                    TextField("Add a note for this sentence", text: $viewModel.noteDraft, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("notes.draft")

                    Button("Save Note") {
                        viewModel.saveDraftNoteForCurrentSentence()
                    }
                    .disabled(viewModel.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .remoteRegister("notes.save") {
                        viewModel.saveDraftNoteForCurrentSentence()
                    }

                    Button("Bookmark Here") {
                        viewModel.addBookmarkForCurrentSentence()
                    }
                    .remoteRegister("notes.bookmark") {
                        viewModel.addBookmarkForCurrentSentence()
                    }
                }

                Section("Saved Annotations") {
                    if viewModel.savedAnnotations.isEmpty {
                        Text("No notes, bookmarks, or conversations yet.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("notes.empty")
                    } else {
                        ForEach(viewModel.savedAnnotations) { entry in
                            savedAnnotationRow(entry)
                                .id(entry.id)
                        }
                    }
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .remoteScrollSavedAnnotations)
            ) { note in
                guard let entryID = note.userInfo?["entryID"] as? String else { return }
                withAnimation { listProxy.scrollTo(entryID, anchor: .top) }
            }
            } // ScrollViewReader
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Task 12 (2026-05-03 — Data Portability): export
                // every annotation + Ask Posey conversation tied to
                // this document as a single Markdown file via the
                // standard iOS share sheet (Files / Mail / Messages /
                // AirDrop / etc.). Built lazily on tap so opening
                // the Notes sheet doesn't pay the rendering cost
                // for users who never export.
                ToolbarItem(placement: .topBarLeading) {
                    if let exportURL = annotationsExportURL {
                        ShareLink(item: exportURL) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Export annotations and conversations")
                        .remoteRegister("notes.export") {
                            // Surface the URL via remote-control for
                            // automation; share sheet itself is
                            // user-driven.
                            _ = exportURL
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .remoteDismissPresentedSheet)
            ) { _ in
                dismiss()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .remoteTapSavedAnnotation)
            ) { note in
                guard let entryID = note.userInfo?["entryID"] as? String,
                      let entry = viewModel.savedAnnotations.first(where: { $0.id == entryID })
                else { return }
                handleSavedAnnotationTap(entry)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .remoteTapJumpToNote)
            ) { note in
                guard let entryID = note.userInfo?["entryID"] as? String,
                      let entry = viewModel.savedAnnotations.first(where: { $0.id == entryID })
                else { return }
                viewModel.jumpToOffset(entry.offset)
                dismiss()
            }
            .onAppear {
                RemoteControlState.shared.presentedSheet = "notes"
                viewModel.rebuildSavedAnnotations()
            }
            .onDisappear {
                if RemoteControlState.shared.presentedSheet == "notes" {
                    RemoteControlState.shared.presentedSheet = nil
                }
            }
        }
    }

    /// Renders one entry in the unified Saved Annotations list. Icon
    /// + anchor text + tap-to-act behavior depend on the entry kind:
    /// - `.bookmark` → tap jumps the reader and dismisses.
    /// - `.note` → tap toggles inline expansion of the note body;
    ///   "Jump" sub-button navigates the reader without auto-collapsing
    ///   so the user can keep reading other notes after their reader
    ///   position has moved.
    /// - `.conversation` → tap dismisses the Notes sheet and posts a
    ///   notification with `initialAnchorStorageID` so the Ask Posey
    ///   sheet opens scrolled to that anchor's row in the thread.
    @ViewBuilder
    private func savedAnnotationRow(_ entry: SavedAnnotation) -> some View {
        let icon: String = {
            switch entry.kind {
            case .conversation: return "bubble.left.fill"
            case .note: return "note.text"
            case .bookmark: return "bookmark.fill"
            }
        }()
        let kindLabel: String = {
            switch entry.kind {
            case .conversation: return "Conversation"
            case .note: return "Note"
            case .bookmark: return "Bookmark"
            }
        }()
        let isExpanded = expandedNoteIDs.contains(entry.id)

        Button {
            handleSavedAnnotationTap(entry)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon)
                        .imageScale(.medium)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kindLabel)
                            .font(.caption2.smallCaps())
                            .foregroundStyle(.secondary)
                        Text(entry.anchorText)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(isExpanded ? nil : 3)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                if entry.kind == .note,
                   isExpanded,
                   let body = entry.body, !body.isEmpty {
                    Text(body)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .padding(.leading, 30)
                        .multilineTextAlignment(.leading)
                    HStack {
                        Spacer()
                        Button("Jump to Note") {
                            viewModel.jumpToOffset(entry.offset)
                            dismiss()
                        }
                        .font(.caption.weight(.semibold))
                        .remoteRegister("notes.jump.\(entry.id)") {
                            viewModel.jumpToOffset(entry.offset)
                            dismiss()
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kindLabel): \(entry.anchorText)")
        .remoteRegister("notes.row.\(entry.id)") {
            handleSavedAnnotationTap(entry)
        }
    }

    private func handleSavedAnnotationTap(_ entry: SavedAnnotation) {
        switch entry.kind {
        case .bookmark:
            viewModel.jumpToOffset(entry.offset)
            dismiss()
        case .note:
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                if expandedNoteIDs.contains(entry.id) {
                    expandedNoteIDs.remove(entry.id)
                } else {
                    expandedNoteIDs.insert(entry.id)
                }
            }
        case .conversation:
            // Dismiss Notes; the ReaderView's notification observer
            // for `.openAskPoseyForDocument` constructs the Ask Posey
            // sheet with `initialAnchorStorageID` so it opens
            // scrolled to this specific anchor's row in the thread.
            dismiss()
            var info: [AnyHashable: Any] = [
                "documentID": viewModel.document.id,
                "scope": "passage"
            ]
            if let storageID = entry.conversationStorageID {
                info["initialAnchorStorageID"] = storageID
            }
            // Brief delay so Notes-sheet dismiss animation completes
            // before the Ask Posey sheet presents — back-to-back
            // sheet transitions otherwise visibly stutter on iPhone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NotificationCenter.default.post(
                    name: .openAskPoseyForDocument,
                    object: nil,
                    userInfo: info
                )
            }
        }
    }
}

@MainActor
final class ReaderViewModel: ObservableObject {
    /// Explicit empty deinit marked `nonisolated` to opt out of
    /// `swift_task_deinitOnExecutorImpl` executor-hopping at
    /// dealloc time. Without this, XCTest deallocates the view
    /// model from a runner thread, the synthesised deinit hops
    /// to MainActor, and the runtime trips a known Swift
    /// Concurrency bug in `TaskLocal::StopLookupScope::~StopLookupScope`
    /// — same shape as the crash that previously hit
    /// `DocumentEmbeddingIndex` and was solved by marking that
    /// class `nonisolated`. We can't make `ReaderViewModel`
    /// nonisolated wholesale (it talks to AVSpeechSynthesizer,
    /// Combine publishers, and SwiftUI bindings), so instead we
    /// give the deinit explicit nonisolated discipline and let
    /// it run wherever the last release happened. The body is
    /// empty because all our cleanup is already driven by
    /// `cancellables` going out of scope and SQLite finalisation
    /// happening through `DatabaseManager`'s own deinit.
    nonisolated deinit {}

    @Published var fontSize: CGFloat = PlaybackPreferences.shared.fontSize {
        didSet { PlaybackPreferences.shared.fontSize = fontSize }
    }

    /// M8 Reading Style preference. Reflects the user's choice from
    /// the preferences sheet; persisted via `PlaybackPreferences`.
    /// `didSet` writes back so the choice survives launches and
    /// across documents.
    @Published var readingStyle: PlaybackPreferences.ReadingStyle = PlaybackPreferences.shared.readingStyle {
        didSet {
            PlaybackPreferences.shared.readingStyle = readingStyle
            reconcileMotionDetector()
        }
    }

    /// M8 Motion sub-preference (Off / On / Auto). Honored only when
    /// `readingStyle == .motion`. Persisted via PlaybackPreferences.
    @Published var motionPreference: PlaybackPreferences.MotionPreference = PlaybackPreferences.shared.motionPreference {
        didSet {
            PlaybackPreferences.shared.motionPreference = motionPreference
            reconcileMotionDetector()
            // Task 2 #26 — when the user picks Auto without prior
            // consent, surface the in-app consent sheet immediately
            // (one tap, not two). Previously the user had to pick
            // Auto, see a "Tap to review" warning, then tap that to
            // open the sheet — Mark called this out as feeling like
            // the app was "asking on launch" the moment the prefs
            // sheet was opened.
            if motionPreference == .auto && !motionAutoConsent {
                showMotionConsent = true
            }
        }
    }

    /// M8 Motion-Auto consent. Required before CoreMotion monitoring
    /// engages. The preferences sheet routes the user through a
    /// dedicated consent screen the first time they pick Auto.
    @Published var motionAutoConsent: Bool = PlaybackPreferences.shared.motionAutoConsent {
        didSet {
            PlaybackPreferences.shared.motionAutoConsent = motionAutoConsent
            reconcileMotionDetector()
        }
    }

    /// Drives the Motion-consent sheet's presentation from the
    /// preferences UI. Set to true when the user taps "review
    /// permission"; cleared when they accept or dismiss.
    @Published var showMotionConsent: Bool = false

    /// CoreMotion-backed detector for the Motion-Auto path. Started
    /// only when the user has chosen .motion + .auto + consented.
    /// Observed by the render path's `isMotionRenderActive` so the
    /// reading style flips between large-centered and the user's
    /// last non-Motion style as they walk / stop.
    @Published private(set) var isDeviceMoving: Bool = false
    private let motionDetector = MotionDetector()
    private var motionDetectorCancellable: AnyCancellable?

    /// M8 audio export. The exporter is recreated on each kickoff so
    /// the UI's progress observation always sees a fresh state
    /// machine. `showAudioExport` drives the presentation of the
    /// export sheet from the preferences UI.
    @Published var showAudioExport: Bool = false
    @Published private(set) var audioExporter: AudioExporter?

    /// Kick off an audio export. Builds a fresh AudioExporter,
    /// presents the export sheet, and starts rendering on a
    /// background Task. The sheet observes the exporter's state
    /// directly.
    ///
    /// Task 7 (2026-05-03 — sensible defaults): when the user's
    /// current playback voice is `.bestAvailable`, the export
    /// auto-falls-back to the highest-quality non-novelty English
    /// Custom voice on the device. Best Available voices are not
    /// `AVSpeechSynthesizer.write(_:toBufferCallback:)`-capturable
    /// (Apple gates Siri-tier voices from third-party file
    /// rendering). Surfacing "switch your playback voice to use
    /// export" is hostile UX — the export should just work with the
    /// best capturable voice on the device. The user's reading
    /// experience is unchanged.
    func beginAudioExport() {
        let exporter = AudioExporter()
        audioExporter = exporter
        showAudioExport = true
        let segmentsCopy = segments
        let exportVoiceMode = Self.audioExportVoiceMode(for: voiceMode)
        let title = document.title
        Task { @MainActor in
            do {
                _ = try await exporter.render(
                    segments: segmentsCopy,
                    voiceMode: exportVoiceMode,
                    documentTitle: title
                )
            } catch {
                // exporter.state already carries .failed(reason:); the
                // sheet renders that. Nothing else to do here.
            }
        }
    }

    /// Pick the voice mode the export should actually run with.
    /// - If the user's current mode is `.custom`, honour it directly.
    /// - If the user's current mode is `.bestAvailable`, pick the
    ///   highest-quality English voice available on the device,
    ///   defaulting rate to `AVSpeechUtteranceDefaultSpeechRate`
    ///   (natural reading pace).
    static func audioExportVoiceMode(
        for currentMode: SpeechPlaybackService.VoiceMode
    ) -> SpeechPlaybackService.VoiceMode {
        if case .custom = currentMode { return currentMode }

        // Rank candidates: enhanced > premium > default; then prefer
        // English; then prefer voices marked as not-novelty (Apple's
        // VoiceQuality.enhanced is the highest tier we can access for
        // capture). Stable tiebreak by identifier so the default is
        // deterministic across launches.
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en")
        }
        let ranked = voices.sorted { lhs, rhs in
            // .premium (3) > .enhanced (2) > .default (1) — higher
            // raw value = better. Tie-break on identifier ascending.
            let lq = lhs.quality.rawValue
            let rq = rhs.quality.rawValue
            if lq != rq { return lq > rq }
            return lhs.identifier < rhs.identifier
        }
        // Apple's identifiers `com.apple.voice.enhanced.en-US.*` and
        // `com.apple.voice.premium.en-US.*` are the high-quality
        // tiers. If none are present (rare on a fresh device), fall
        // back to the first English voice; if even that's missing,
        // fall back to the system-resolved en-US (Samantha, Daniel,
        // etc.).
        let pick = ranked.first
                ?? AVSpeechSynthesisVoice(language: "en-US")
                ?? AVSpeechSynthesisVoice.speechVoices().first
        guard let chosen = pick else {
            // No voices at all — return what was passed in. Export
            // will fail with .voiceNotCapturable and the sheet's
            // existing error path surfaces a clear message.
            return currentMode
        }
        return .custom(
            voiceIdentifier: chosen.identifier,
            rate: AVSpeechUtteranceDefaultSpeechRate
        )
    }
    @Published private(set) var currentSentenceIndex: Int = 0
    @Published private(set) var playbackState: SpeechPlaybackService.PlaybackState = .idle
    @Published private(set) var focusedDisplayBlockID: Int?
    @Published var isShowingError = false
    @Published var errorMessage = ""
    @Published var noteDraft = ""
    @Published private(set) var notes: [Note] = []
    /// Unified Saved Annotations list for the Notes sheet — combines
    /// notes, bookmarks, and Ask Posey conversation anchors into one
    /// chronologically-sorted feed. Recomputed every time `notes` is
    /// reloaded AND every time the Ask Posey sheet dismisses (so a
    /// new anchor created during the conversation surfaces here
    /// without the user having to do anything else). Sorted newest
    /// first.
    @Published private(set) var savedAnnotations: [SavedAnnotation] = []
    @Published private(set) var voiceMode: SpeechPlaybackService.VoiceMode = .bestAvailable

    // ========== BLOCK VM-SEARCH: SEARCH STATE - START ==========
    @Published var searchQuery: String = ""
    @Published var isSearchActive: Bool = false
    @Published private(set) var searchMatchIndices: [Int] = []
    @Published private(set) var currentSearchMatchPosition: Int? = nil
    /// Emitted each time the view should scroll to a search match.
    /// Uses a counter so repeated navigation to the same index still fires onChange.
    @Published private(set) var searchScrollSignal: SearchScrollSignal? = nil

    struct SearchScrollSignal: Equatable {
        let segmentIndex: Int
        let id: Int
    }
    private var searchScrollCounter = 0

    var searchMatchCount: Int { searchMatchIndices.count }
    // ========== BLOCK VM-SEARCH: SEARCH STATE - END ==========

    let document: Document
    /// True between `init` returning and the background content load
    /// completing. The reader view shows an "Opening this document…"
    /// overlay during this window so big documents (Illuminatus's
    /// 1.6M chars takes ~5–10s to segment via NLTokenizer) don't
    /// look frozen. For small docs the loading task completes before
    /// the first render cycle so the overlay never gets a chance to
    /// render.
    @Published private(set) var isLoading: Bool = true
    @Published private(set) var segments: [TextSegment] = []
    @Published private(set) var displayBlocks: [DisplayBlock] = []
    /// Table of contents entries for this document. Empty if not available.
    @Published private(set) var tocEntries: [StoredTOCEntry] = []
    /// Page-number → plainText offset map for the Go-to-page input in
    /// the TOC sheet. Empty for formats with no page concept (TXT, MD,
    /// RTF, DOCX, HTML); populated for PDF (form-feed-counted) and
    /// hocr-to-epub-style EPUBs (synthesized from "Page N" TOC titles).
    /// See `DocumentPageMap` for construction details.
    @Published private(set) var pageMap: DocumentPageMap = .empty

    /// Public read access for the database handle so external sites
    /// (Ask Posey M5+) can persist and read per-document state without
    /// re-injecting it. Storage stays internal — only the manager is
    /// exposed, never the underlying SQLite handle.
    let databaseManager: DatabaseManager
    private let playbackService: SpeechPlaybackService

    /// M8 lock-screen + background-audio controller. Lazily created
    /// on first content-load completion so the document title is
    /// available; subsequent `update(...)` calls reflect the active
    /// sentence + playback state. Built only on real iOS (UIKit
    /// available); preview/test paths can keep it nil.
    private var nowPlayingController: NowPlayingController?
    private let shouldAutoPlayOnAppear: Bool
    private let shouldAutoCreateNoteOnAppear: Bool
    private let shouldAutoCreateBookmarkOnAppear: Bool
    private let automationNoteBody: String
    /// Updated by the loader once segments + displayBlocks land. Empty
    /// until then. Consumers that need the mapping should gate on
    /// `isLoading == false` (or `segments.isEmpty == false`).
    private var visualPauseBlockIDsBySentenceIndex: [Int: Int] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var didRunAutomationActions = false
    private var acknowledgedVisualBlockIDs: Set<Int> = []
    /// The async task that builds the heavy content (segmentation,
    /// display block parsing, visual-pause map). Tests await this via
    /// `awaitContentLoaded()`; the reader view doesn't need to —
    /// `isLoading` drives its overlay.
    private var contentLoadTask: Task<Void, Never>?

    init(
        document: Document,
        databaseManager: DatabaseManager,
        playbackService: SpeechPlaybackService? = nil,
        shouldAutoPlayOnAppear: Bool = false,
        shouldAutoCreateNoteOnAppear: Bool = false,
        shouldAutoCreateBookmarkOnAppear: Bool = false,
        automationNoteBody: String = "Automated smoke note"
    ) {
        self.document = document
        self.databaseManager = databaseManager
        let persistedMode = PlaybackPreferences.shared.voiceMode
        self.voiceMode = persistedMode
        self.playbackService = playbackService ?? SpeechPlaybackService(voiceMode: persistedMode)
        self.shouldAutoPlayOnAppear = shouldAutoPlayOnAppear
        self.shouldAutoCreateNoteOnAppear = shouldAutoCreateNoteOnAppear
        self.shouldAutoCreateBookmarkOnAppear = shouldAutoCreateBookmarkOnAppear
        self.automationNoteBody = automationNoteBody
        // Init returns immediately so the navigation push doesn't block
        // on multi-second NLTokenizer + display block work for big
        // documents. The actual content load runs on a background
        // dispatch queue and updates the @Published state on main when
        // it completes; the reader view shows a loading overlay while
        // `isLoading` is true.
        self.contentLoadTask = Task { [weak self] in
            await self?.loadContent()
        }
    }

    /// Awaitable hook for tests: completes when the in-flight load
    /// finishes. Safe to call after the load has already completed —
    /// awaiting a finished Task returns immediately.
    func awaitContentLoaded() async {
        await contentLoadTask?.value
    }

    /// Bundle of values produced by the heavy content-load pass.
    /// Pure data so the work can run on a background dispatch queue
    /// without crossing actor boundaries.
    fileprivate struct LoadedContent: Sendable {
        let segments: [TextSegment]
        let displayBlocks: [DisplayBlock]
        let visualPauseMap: [Int: Int]
    }

    /// Heavy synchronous compute. Runs on a background dispatch queue
    /// from `loadContent`. Pure function (only reads from `document`),
    /// no MainActor-isolated state touched. The expensive piece is
    /// `SentenceSegmenter().segments(for: plainText)` which runs
    /// NLTokenizer over the entire plainText — for Illuminatus's
    /// 1.6M chars this takes ~5–10s and is the reason this pass
    /// can't run on init's main-thread call.
    nonisolated fileprivate static func computeContent(
        for document: Document
    ) -> LoadedContent {
        let skipUntil = max(0, document.playbackSkipUntilOffset)
        let allSegments = SentenceSegmenter().segments(for: document.plainText)
        let bodySegments = (skipUntil > 0)
            ? allSegments.filter { $0.startOffset >= skipUntil }
            : allSegments
        // Re-number IDs to be 0-based contiguous (the rest of the view
        // model treats segment.id as an array index — see currentSegment,
        // playPauseImageName, marker navigation, etc.).
        let segments: [TextSegment] = bodySegments.enumerated().map { index, seg in
            TextSegment(id: index, text: seg.text, startOffset: seg.startOffset, endOffset: seg.endOffset)
        }
        let rawBlocks: [DisplayBlock]
        if document.fileType == "md" || document.fileType == "markdown" {
            rawBlocks = MarkdownParser().parse(markdown: document.displayText).blocks
        } else if document.fileType == "pdf" {
            rawBlocks = PDFDisplayParser().parse(displayText: document.displayText).blocks
        } else if document.fileType == "epub" {
            rawBlocks = EPUBDisplayParser().parse(displayText: document.displayText)
        } else {
            rawBlocks = []
        }
        let bodyBlocks: [DisplayBlock] = (skipUntil > 0)
            ? rawBlocks.filter { $0.startOffset >= skipUntil }
            : rawBlocks
        let displayBlocks = ReaderViewModel.splitParagraphBlocks(bodyBlocks, segments: segments)
        let visualPauseMap = ReaderViewModel.buildVisualPauseIndexMap(
            displayBlocks: displayBlocks,
            segments: segments
        )
        return LoadedContent(
            segments: segments,
            displayBlocks: displayBlocks,
            visualPauseMap: visualPauseMap
        )
    }

    /// Async loader. Runs the heavy compute on a userInitiated
    /// background queue, then applies results on main and clears
    /// `isLoading`. Lightweight DB-bound work (TOC entries, page map
    /// derivation, position restoration) runs on main where it
    /// belongs since DatabaseManager is single-threaded.
    ///
    /// Order matters here: segments / displayBlocks / visualPauseMap
    /// are applied first, then position is restored (uses segments),
    /// then playback observation is wired (initial emission uses
    /// the restored position, not the default zero), then
    /// `isLoading` flips false (so the loading overlay dismisses on
    /// fully-prepared state), then automation hooks run (need
    /// segments + currentSentenceIndex). Anything that violates
    /// this order risks the user seeing a half-prepared reader.
    private func loadContent() async {
        let document = self.document
        let computed = await Task.detached(priority: .userInitiated) {
            ReaderViewModel.computeContent(for: document)
        }.value

        // 1. Heavy results.
        self.segments = computed.segments
        self.displayBlocks = computed.displayBlocks
        self.visualPauseBlockIDsBySentenceIndex = computed.visualPauseMap

        // 2. DB side dishes (cheap).
        self.tocEntries = (try? databaseManager.tocEntries(for: document.id)) ?? []
        self.pageMap = DocumentPageMap.build(for: document, tocEntries: self.tocEntries)

        // 3. Position restore + playback prepare (depend on segments).
        //    Wrapped so a DB error here doesn't leave the reader
        //    permanently in the loading state.
        do {
            let position = try databaseManager.readingPosition(for: document.id)
                ?? .initial(for: document.id)
            self.currentSentenceIndex = self.restoreSentenceIndex(from: position)
            self.playbackService.prepare(at: self.currentSentenceIndex)
        } catch {
            self.present(error)
        }

        // 4. Subscribe to playback events. Done AFTER prepare so the
        //    initial sink emission carries the restored sentence
        //    index, not a stale zero.
        self.observePlayback()

        // 5. Surface the reader.
        self.isLoading = false

        // 6. Test-mode automation hooks (depend on segments).
        self.runAutomationIfNeeded()

        // 7. M8 lock-screen / Control Center plumbing. Build the
        //    NowPlayingController now that segments + title are
        //    available and seed the initial metadata. Subsequent
        //    state/sentence changes flow through `updateNowPlaying()`.
        self.installNowPlayingController()
    }

    /// Build the NowPlayingController and seed initial metadata.
    /// Idempotent — re-installing on a re-load just overwrites the
    /// previous controller. M8 lock-screen + background-audio support.
    private func installNowPlayingController() {
        let controller = NowPlayingController(commands: NowPlayingController.Commands(
            togglePlayback:   { [weak self] in self?.togglePlayback() },
            nextSentence:     { [weak self] in self?.goToNextMarker() },
            previousSentence: { [weak self] in self?.goToPreviousMarker() }
        ))
        self.nowPlayingController = controller
        updateNowPlaying()
    }

    /// Push current document title + active sentence + playback state
    /// to the lock screen / Control Center. Called on every sentence
    /// advance and every state change so the lock screen stays current.
    func updateNowPlaying() {
        guard let controller = nowPlayingController else { return }
        let activeSentence = segments.indices.contains(currentSentenceIndex)
            ? segments[currentSentenceIndex].text
            : nil
        let isPlaying = (playbackState == .playing)
        controller.update(
            title: document.title,
            sentenceText: activeSentence,
            isPlaying: isPlaying
        )
    }

    var usesDisplayBlocks: Bool {
        displayBlocks.isEmpty == false
    }

    var playPauseImageName: String {
        switch playbackState {
        case .playing:
            return "pause.fill"
        case .paused, .idle, .finished:
            return "play.fill"
        }
    }

    var playbackStateText: String {
        switch playbackState {
        case .idle:
            return "idle"
        case .playing:
            return "playing"
        case .paused:
            return "paused"
        case .finished:
            return "finished"
        }
    }

    var currentSentencePreview: String {
        currentSegment?.text ?? document.plainText
    }

    var capturedNotesContextPreview: String {
        notesCaptureText()
    }

    func handleAppear() {
        // The heavy "open this document" work (segmentation, display
        // block parsing, position restore, playback observation,
        // automation hooks) happens in `loadContent` — kicked off
        // from init and awaited before `isLoading` flips false.
        // handleAppear's only responsibility is the segment-
        // independent piece: loading the saved notes list. Wrapped
        // in a Task that awaits the load so notes appear AFTER the
        // reader content settles, not in a brief flash before.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.contentLoadTask?.value
            self.loadNotes()
        }
    }

    func togglePlayback() {
        switch playbackState {
        case .playing:
            playbackState = .paused
            playbackService.pause()
            persistPosition()
        case .paused:
            focusedDisplayBlockID = nil
            playbackState = .playing
            playbackService.play(segments: segments, startingAt: currentSentenceIndex)
        case .idle, .finished:
            focusedDisplayBlockID = nil
            playbackState = .playing
            playbackService.play(segments: segments, startingAt: currentSentenceIndex)
        }
    }

    func goToPreviousMarker() {
        jumpToMarker(direction: -1)
    }

    func goToNextMarker() {
        jumpToMarker(direction: 1)
    }

    func restartFromBeginning() {
        focusedDisplayBlockID = nil
        currentSentenceIndex = 0
        playbackService.stop()
        playbackService.prepare(at: currentSentenceIndex)
        persistPosition()
    }

    func prepareForNotesEntry() {
        if playbackState == .playing {
            playbackService.pause()
            persistPosition()
        }

        // Mark's M4 device pass surfaced this: previously we'd populate
        // `noteDraft` with the surrounding-sentences capture AND show
        // the active sentence as readonly context above the TextField.
        // That meant the user saw the active sentence twice (once
        // readonly, once in an editable draft they hadn't written) and
        // got the previous sentence prepended — which on a PDF whose
        // first segment jammed title + date + heading into one
        // "sentence" looked outright broken. The active sentence is
        // already visible above the TextField as reference; the user
        // doesn't need it again in the draft.
        //
        // We still copy the surrounding-sentences capture to the
        // clipboard so the share-with-other-app workflow that the
        // capture text was originally designed for keeps working.
        let capture = notesCaptureText()
        noteDraft = ""
        copyToClipboard(capture)
    }

    func saveDraftNoteForCurrentSentence() {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, let segment = currentSegment else {
            return
        }

        saveAnnotation(kind: .note, body: trimmed, segment: segment)
        noteDraft = ""
    }

    func addBookmarkForCurrentSentence() {
        guard let segment = currentSegment else {
            return
        }

        saveAnnotation(kind: .bookmark, body: nil, segment: segment)
    }

    func jump(to note: Note) {
        if let index = segments.firstIndex(where: { segment in
            note.startOffset >= segment.startOffset && note.startOffset < segment.endOffset
        }) {
            currentSentenceIndex = index
            playbackService.prepare(at: currentSentenceIndex)
            persistPosition()
        }
    }

    func persistPosition() {
        guard let segment = currentSegment else {
            return
        }

        let position = ReadingPosition(
            documentID: document.id,
            updatedAt: .now,
            characterOffset: segment.startOffset,
            sentenceIndex: currentSentenceIndex
        )

        do {
            try databaseManager.upsertReadingPosition(position)
        } catch {
            present(error)
        }
    }

    func stopPlayback() {
        playbackService.stop()
    }

    // ========== BLOCK VM-VOICE: VOICE MODE CONTROLS - START ==========

    /// Switch between Best Available and Custom mode.
    ///
    /// Switching to Custom picks the best voice available on the device as the default.
    /// Switching back to Best Available preserves the custom settings for if the user returns.
    func setVoiceMode(isCustom: Bool) {
        if isCustom {
            // If already in custom, keep existing settings.
            if case .custom = voiceMode { return }
            // Restore last persisted custom settings, or fall back to sensible defaults.
            let restoredMode = PlaybackPreferences.shared.lastCustomVoiceMode
                ?? .custom(
                    voiceIdentifier: bestAvailableVoiceIdentifier(),
                    rate: AVSpeechUtteranceDefaultSpeechRate
                )
            applyAndPersist(restoredMode)
        } else {
            // Persist custom settings before leaving so they restore correctly on return.
            applyAndPersist(.bestAvailable)
        }
    }

    /// Update the voice identifier within Custom mode.
    func setCustomVoice(identifier: String) {
        guard case .custom(_, let rate) = voiceMode else { return }
        applyAndPersist(.custom(voiceIdentifier: identifier, rate: rate))
    }

    /// Update the playback rate within Custom mode.
    /// Accepts a percentage (75–200); converts to AVSpeech rate internally.
    func setCustomRate(percentage: Float) {
        guard case .custom(let identifier, _) = voiceMode else { return }
        let avRate = (percentage / 100.0) * AVSpeechUtteranceDefaultSpeechRate
        applyAndPersist(.custom(voiceIdentifier: identifier, rate: avRate))
    }

    /// Current rate as a percentage label for the preferences UI (returns 100 for bestAvailable).
    var customRatePercentage: Float {
        guard case .custom(_, let rate) = voiceMode else { return 100.0 }
        return (rate / AVSpeechUtteranceDefaultSpeechRate) * 100.0
    }

    /// Display name for the currently selected custom voice.
    var customVoiceDisplayName: String {
        guard case .custom(let identifier, _) = voiceMode,
              let voice = AVSpeechSynthesisVoice(identifier: identifier)
        else { return "None" }
        return voice.name
    }

    private func applyAndPersist(_ newMode: SpeechPlaybackService.VoiceMode) {
        voiceMode = newMode
        playbackService.applyVoiceMode(newMode)
        PlaybackPreferences.shared.voiceMode = newMode
    }

    private func bestAvailableVoiceIdentifier() -> String {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let preferred = voices.first(where: { $0.quality == .premium })
            ?? voices.first(where: { $0.quality == .enhanced })
            ?? voices.first
        return preferred?.identifier ?? ""
    }

    // ========== BLOCK VM-VOICE: VOICE MODE CONTROLS - END ==========

    // ========== BLOCK VM-SEARCH: SEARCH METHODS - START ==========

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchMatchIndices = []
            currentSearchMatchPosition = nil
            searchScrollSignal = nil
            return
        }
        searchMatchIndices = segments.indices.filter {
            segments[$0].text.localizedCaseInsensitiveContains(trimmed)
        }
        if searchMatchIndices.isEmpty {
            currentSearchMatchPosition = nil
            searchScrollSignal = nil
        } else {
            currentSearchMatchPosition = 0
            emitSearchScroll(to: searchMatchIndices[0])
        }
    }

    func goToNextSearchMatch() {
        guard !searchMatchIndices.isEmpty else { return }
        let next = ((currentSearchMatchPosition ?? -1) + 1) % searchMatchIndices.count
        currentSearchMatchPosition = next
        emitSearchScroll(to: searchMatchIndices[next])
    }

    func goToPreviousSearchMatch() {
        guard !searchMatchIndices.isEmpty else { return }
        let prev = ((currentSearchMatchPosition ?? 0) - 1 + searchMatchIndices.count) % searchMatchIndices.count
        currentSearchMatchPosition = prev
        emitSearchScroll(to: searchMatchIndices[prev])
    }

    func deactivateSearch() {
        isSearchActive = false
        searchQuery = ""
        searchMatchIndices = []
        currentSearchMatchPosition = nil
        searchScrollSignal = nil
    }

    func scrollToSearchMatch(with proxy: ScrollViewProxy) {
        guard let signal = searchScrollSignal else { return }
        let idx = signal.segmentIndex
        guard segments.indices.contains(idx) else { return }
        let scrollID: Int
        if usesDisplayBlocks {
            let seg = segments[idx]
            scrollID = displayBlocks.first(where: {
                seg.startOffset < $0.endOffset && seg.endOffset > $0.startOffset
            })?.id ?? idx
        } else {
            scrollID = idx
        }
        if Self.reduceMotionEnabled {
            proxy.scrollTo(scrollID, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(scrollID, anchor: .center)
            }
        }
    }

    /// Reads UIAccessibility's Reduce Motion flag. ViewModel methods can't
    /// pull `\.accessibilityReduceMotion` from the SwiftUI environment, so we
    /// check the UIKit static instead. Safe to call from any thread.
    static var reduceMotionEnabled: Bool {
        #if canImport(UIKit) && os(iOS)
        return UIAccessibility.isReduceMotionEnabled
        #else
        return false
        #endif
    }

    func isSearchMatch(segment: TextSegment) -> Bool {
        !searchMatchIndices.isEmpty && searchMatchIndices.contains(segment.id)
    }

    func isCurrentSearchMatch(segment: TextSegment) -> Bool {
        guard let pos = currentSearchMatchPosition,
              searchMatchIndices.indices.contains(pos) else { return false }
        return segment.id == searchMatchIndices[pos]
    }

    func isSearchMatch(block: DisplayBlock) -> Bool {
        guard !searchMatchIndices.isEmpty else { return false }
        return searchMatchIndices.contains { idx in
            guard segments.indices.contains(idx) else { return false }
            let seg = segments[idx]
            return seg.startOffset < block.endOffset && seg.endOffset > block.startOffset
        }
    }

    func isCurrentSearchMatch(block: DisplayBlock) -> Bool {
        guard let pos = currentSearchMatchPosition,
              searchMatchIndices.indices.contains(pos) else { return false }
        let idx = searchMatchIndices[pos]
        guard segments.indices.contains(idx) else { return false }
        let seg = segments[idx]
        return seg.startOffset < block.endOffset && seg.endOffset > block.startOffset
    }

    private func emitSearchScroll(to segmentIndex: Int) {
        searchScrollCounter += 1
        searchScrollSignal = SearchScrollSignal(segmentIndex: segmentIndex, id: searchScrollCounter)
    }

    // ========== BLOCK VM-SEARCH: SEARCH METHODS - END ==========

    func isActive(segment: TextSegment) -> Bool {
        segment.id == currentSentenceIndex
    }

    /// Start or stop the CoreMotion-backed motion detector based on
    /// the current readingStyle + motionPreference + consent state.
    /// Called from the property `didSet` hooks of all three so the
    /// detector is always in the right state without an explicit
    /// "rebuild" lifecycle. Safe to call repeatedly.
    private func reconcileMotionDetector() {
        let shouldRun = readingStyle == .motion
            && motionPreference == .auto
            && motionAutoConsent
        if shouldRun {
            // Subscribe to the detector's published flag if we
            // haven't yet — once subscribed, we mirror the value to
            // our own @Published `isDeviceMoving` so the render path
            // can re-evaluate without dipping into a sub-object.
            if motionDetectorCancellable == nil {
                motionDetectorCancellable = motionDetector.$isMoving
                    .receive(on: RunLoop.main)
                    .sink { [weak self] value in
                        self?.isDeviceMoving = value
                    }
            }
            motionDetector.start(consented: motionAutoConsent)
        } else {
            motionDetector.stop()
            motionDetectorCancellable?.cancel()
            motionDetectorCancellable = nil
            isDeviceMoving = false
        }
    }

    /// M8 Immersive/Motion render distance — how many rows away the
    /// segment is from the active sentence. Active row returns 0,
    /// neighbours return 1, and so on. Used by the render path to
    /// derive opacity + scale falloff curves.
    func distanceFromActive(segment: TextSegment) -> Int {
        return abs(segment.id - currentSentenceIndex)
    }

    /// Display-block variant of `distanceFromActive`. Computes the
    /// distance between this block's anchor sentence and the
    /// currently-active sentence. Blocks that don't carry a sentence
    /// anchor (visual-only PDF pages) report a generous default
    /// (effectively "far") so the falloff treats them as background.
    func distanceFromActive(block: DisplayBlock) -> Int {
        if isActive(block: block) { return 0 }
        // Block-to-segment proxy: find the segment whose start offset
        // matches the block's start; failing that, walk to the
        // nearest segment by character offset. Unknown → far.
        if let sentenceForBlock = segments.firstIndex(where: { $0.startOffset >= block.startOffset && $0.startOffset < block.endOffset }) {
            return abs(sentenceForBlock - currentSentenceIndex)
        }
        return 8
    }

    func isActive(block: DisplayBlock) -> Bool {
        if focusedDisplayBlockID == block.id {
            return true
        }

        guard let segment = currentSegment else {
            return false
        }

        return segment.startOffset < block.endOffset && segment.endOffset > block.startOffset
    }

    func annotationSymbol(for segment: TextSegment) -> String? {
        let segmentNotes = notes.filter { note in
            note.startOffset >= segment.startOffset && note.startOffset < segment.endOffset
        }

        if segmentNotes.contains(where: { $0.kind == .note }) {
            return "note.text"
        }

        if segmentNotes.contains(where: { $0.kind == .bookmark }) {
            return "bookmark.fill"
        }

        return nil
    }

    func annotationSymbol(for block: DisplayBlock) -> String? {
        let blockNotes = notes.filter { note in
            note.startOffset >= block.startOffset && note.startOffset < block.endOffset
        }

        if blockNotes.contains(where: { $0.kind == .note }) {
            return "note.text"
        }

        if blockNotes.contains(where: { $0.kind == .bookmark }) {
            return "bookmark.fill"
        }

        return nil
    }

    func displayText(for block: DisplayBlock) -> String {
        if let displayPrefix = block.displayPrefix {
            return "\(displayPrefix) \(block.text)"
        }

        return block.text
    }

    func font(for block: DisplayBlock) -> Font {
        switch block.kind {
        case .heading(let level):
            let size = max(fontSize + CGFloat(10 - level), fontSize + 2)
            return .system(size: size)
        default:
            return .system(size: fontSize)
        }
    }

    func fontWeight(for block: DisplayBlock) -> Font.Weight {
        switch block.kind {
        case .heading:
            return .bold
        default:
            return .regular
        }
    }

    func foregroundStyle(for block: DisplayBlock) -> Color {
        switch block.kind {
        case .quote:
            return .secondary
        case .visualPlaceholder:
            return .primary
        default:
            return .primary
        }
    }

    func previewText(for note: Note) -> String {
        guard let index = segments.firstIndex(where: { segment in
            note.startOffset >= segment.startOffset && note.startOffset < segment.endOffset
        }) else {
            return document.title
        }

        return segments[index].text
    }

    func scrollToCurrentSentence(with proxy: ScrollViewProxy, animated: Bool) {
        let scrollTargetID: Int

        if let blockID = currentDisplayBlockID {
            scrollTargetID = blockID
        } else if segments.isEmpty == false {
            scrollTargetID = currentSentenceIndex
        } else {
            return
        }

        let action = {
            proxy.scrollTo(scrollTargetID, anchor: .center)
        }

        if animated && !Self.reduceMotionEnabled {
            withAnimation(.easeInOut(duration: 0.25), action)
        } else {
            action()
        }
    }

    private var currentSegment: TextSegment? {
        guard segments.indices.contains(currentSentenceIndex) else {
            return nil
        }
        return segments[currentSentenceIndex]
    }

    private var currentDisplayBlockID: Int? {
        if let focusedDisplayBlockID {
            return focusedDisplayBlockID
        }

        guard let segment = currentSegment else {
            return nil
        }

        return displayBlocks.first(where: { block in
            segment.startOffset < block.endOffset && segment.endOffset > block.startOffset
        })?.id
    }

    private func boundedSentenceIndex(_ candidate: Int) -> Int {
        guard segments.isEmpty == false else {
            return 0
        }
        return min(max(candidate, 0), segments.count - 1)
    }

    private func restoreSentenceIndex(from position: ReadingPosition) -> Int {
        guard segments.isEmpty == false else {
            return 0
        }

        // The saved character offset may fall inside a region that has been
        // FILTERED OUT of segments (e.g. a PDF Table of Contents). In that
        // case there's no segment to match — we land on the first body
        // sentence (segment 0), which is now the natural start of the
        // reading flow. This also handles the first-open case where the
        // saved position is the default zero offset.
        let skipUntil = document.playbackSkipUntilOffset
        if skipUntil > 0, position.characterOffset < skipUntil {
            return 0
        }

        if let offsetMatch = segments.firstIndex(where: { segment in
            position.characterOffset >= segment.startOffset && position.characterOffset < segment.endOffset
        }) {
            return offsetMatch
        }

        return boundedSentenceIndex(position.sentenceIndex)
    }

    private func jumpToMarker(direction: Int) {
        guard direction != 0 else {
            return
        }

        if let targetIndex = markerSentenceIndex(direction: direction) {
            jump(toSentenceIndex: targetIndex, shouldRestartPlayback: playbackState == .playing)
        }
    }

    private func markerSentenceIndex(direction: Int) -> Int? {
        if usesDisplayBlocks,
           let currentBlockIndex = currentDisplayBlockIndex {
            var nextBlockIndex = currentBlockIndex + direction
            while displayBlocks.indices.contains(nextBlockIndex) {
                if let candidateIndex = sentenceIndex(forOffset: displayBlocks[nextBlockIndex].startOffset),
                   candidateIndex != currentSentenceIndex {
                    return candidateIndex
                }
                nextBlockIndex += direction
            }
            return nil
        }

        let nextSentenceIndex = currentSentenceIndex + direction
        guard segments.indices.contains(nextSentenceIndex) else {
            return nil
        }
        return nextSentenceIndex
    }

    private func sentenceIndex(forOffset offset: Int) -> Int? {
        segments.firstIndex(where: { segment in
            offset >= segment.startOffset && offset < segment.endOffset
        }) ?? segments.lastIndex(where: { segment in
            offset >= segment.startOffset
        })
    }

    private var currentDisplayBlockIndex: Int? {
        guard let blockID = currentDisplayBlockID else {
            return nil
        }

        return displayBlocks.firstIndex(where: { $0.id == blockID })
    }

    private func jump(toSentenceIndex sentenceIndex: Int, shouldRestartPlayback: Bool) {
        let boundedIndex = boundedSentenceIndex(sentenceIndex)
        focusedDisplayBlockID = nil
        currentSentenceIndex = boundedIndex
        if shouldRestartPlayback {
            playbackService.restart(segments: segments, startingAt: boundedIndex)
        } else {
            playbackService.prepare(at: boundedIndex)
        }
        persistPosition()
    }

    private func notesCaptureText() -> String {
        guard let currentSegment else {
            return document.plainText
        }

        var context: [String] = []

        let previousIndex = currentSentenceIndex - 1
        if segments.indices.contains(previousIndex) {
            context.append(segments[previousIndex].text)
        }

        context.append(currentSegment.text)

        return context.joined(separator: "\n\n")
    }

    private func observePlayback() {
        guard cancellables.isEmpty else {
            return
        }

        playbackService.$currentSentenceIndex
            .compactMap { $0 }
            .sink { [weak self] index in
                guard let self else { return }
                self.currentSentenceIndex = self.boundedSentenceIndex(index)
                self.pauseForVisualBlockIfNeeded(atSentenceIndex: self.currentSentenceIndex)
                self.persistPosition()
                // M8: refresh lock-screen sentence text on every advance.
                self.updateNowPlaying()
            }
            .store(in: &cancellables)

        playbackService.$state
            .sink { [weak self] state in
                self?.playbackState = state
                // M8: refresh lock-screen play/pause indicator on
                // every state change.
                self?.updateNowPlaying()
            }
            .store(in: &cancellables)
    }

    private func pauseForVisualBlockIfNeeded(atSentenceIndex sentenceIndex: Int) {
        guard playbackService.state == .playing,
              let visualBlockID = visualPauseBlockIDsBySentenceIndex[sentenceIndex],
              acknowledgedVisualBlockIDs.contains(visualBlockID) == false else {
            return
        }

        guard let visualBlock = displayBlocks.first(where: { $0.id == visualBlockID }) else {
            focusedDisplayBlockID = nil
            return
        }

        acknowledgedVisualBlockIDs.insert(visualBlock.id)
        focusedDisplayBlockID = visualBlock.id
        playbackService.pause()
    }

    nonisolated private static func buildVisualPauseIndexMap(displayBlocks: [DisplayBlock], segments: [TextSegment]) -> [Int: Int] {
        guard displayBlocks.isEmpty == false, segments.isEmpty == false else {
            return [:]
        }

        var mapping: [Int: Int] = [:]

        for (blockIndex, block) in displayBlocks.enumerated() where block.kind == .visualPlaceholder {
            var nextBlockIndex = blockIndex + 1
            while displayBlocks.indices.contains(nextBlockIndex) {
                let candidateBlock = displayBlocks[nextBlockIndex]
                if let sentenceIndex = sentenceIndex(forOffset: candidateBlock.startOffset, segments: segments) {
                    mapping[sentenceIndex] = block.id
                    break
                }
                nextBlockIndex += 1
            }
        }

        return mapping
    }

    nonisolated private static func sentenceIndex(forOffset offset: Int, segments: [TextSegment]) -> Int? {
        segments.firstIndex(where: { segment in
            offset >= segment.startOffset && offset < segment.endOffset
        }) ?? segments.lastIndex(where: { segment in
            offset >= segment.startOffset
        })
    }

    // ========== BLOCK VM-SPLIT: PARAGRAPH BLOCK SPLITTING - START ==========

    /// Replaces each `.paragraph` DisplayBlock with one sub-block per TTS segment
    /// that starts within it.  Non-paragraph blocks (headings, images, bullets,
    /// quotes) pass through unchanged with reassigned sequential IDs.
    ///
    /// After splitting, `isActive(block:)` returns true only for the one block
    /// containing the active utterance — so highlight and auto-scroll target
    /// exactly what is being spoken rather than an entire paragraph.
    nonisolated private static func splitParagraphBlocks(
        _ blocks: [DisplayBlock],
        segments: [TextSegment]
    ) -> [DisplayBlock] {
        var result: [DisplayBlock] = []
        for block in blocks {
            guard block.kind == .paragraph else {
                result.append(DisplayBlock(
                    id: result.count,
                    kind: block.kind,
                    text: block.text,
                    displayPrefix: block.displayPrefix,
                    startOffset: block.startOffset,
                    endOffset: block.endOffset,
                    imageID: block.imageID
                ))
                continue
            }

            // Segments that START within this paragraph's offset range.
            // Using startOffset (not overlap) ensures each segment maps to
            // exactly one block — no duplicates across paragraph boundaries.
            let inBlock = segments.filter { seg in
                seg.startOffset >= block.startOffset && seg.startOffset < block.endOffset
            }

            if inBlock.isEmpty {
                // Rare: paragraph too short to own a segment start (content is
                // absorbed into an adjacent segment by the tokenizer). Keep as-is.
                result.append(DisplayBlock(
                    id: result.count,
                    kind: .paragraph,
                    text: block.text,
                    displayPrefix: nil,
                    startOffset: block.startOffset,
                    endOffset: block.endOffset
                ))
            } else {
                for seg in inBlock {
                    result.append(DisplayBlock(
                        id: result.count,
                        kind: .paragraph,
                        text: seg.text,
                        displayPrefix: nil,
                        startOffset: seg.startOffset,
                        endOffset: seg.endOffset
                    ))
                }
            }
        }
        return result
    }

    // ========== BLOCK VM-SPLIT: PARAGRAPH BLOCK SPLITTING - END ==========

    private func loadNotes() {
        do {
            notes = try databaseManager.notes(for: document.id)
        } catch {
            present(error)
        }
        rebuildSavedAnnotations()
    }

    /// Recomputes `savedAnnotations` by merging the current `notes`
    /// list (split by kind into `.note` / `.bookmark` entries) with
    /// the document's anchor rows from `ask_posey_conversations`
    /// (mapped to `.conversation` entries). Sorted newest-first.
    /// Best-effort — DB failures fall back to the notes-only subset.
    func rebuildSavedAnnotations() {
        var entries: [SavedAnnotation] = []
        for note in notes {
            entries.append(SavedAnnotation(
                id: "note:\(note.id.uuidString)",
                kind: note.kind == .bookmark ? .bookmark : .note,
                anchorText: previewText(for: note),
                offset: note.startOffset,
                timestamp: note.createdAt,
                body: note.body,
                conversationStorageID: nil,
                noteID: note.id
            ))
        }
        if let anchorRows = try? databaseManager.askPoseyAnchorRows(for: document.id) {
            for row in anchorRows {
                let display = row.content.trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(SavedAnnotation(
                    id: "conversation:\(row.id)",
                    kind: .conversation,
                    anchorText: display.isEmpty ? document.title : display,
                    offset: row.anchorOffset ?? 0,
                    timestamp: row.timestamp,
                    body: nil,
                    conversationStorageID: row.id,
                    noteID: nil
                ))
            }
        }
        entries.sort { $0.timestamp > $1.timestamp }
        savedAnnotations = entries
    }

    private func saveAnnotation(kind: NoteKind, body: String?, segment: TextSegment) {
        let now = Date()
        let note = Note(
            id: UUID(),
            documentID: document.id,
            createdAt: now,
            updatedAt: now,
            kind: kind,
            startOffset: segment.startOffset,
            endOffset: segment.endOffset,
            body: body
        )

        do {
            try databaseManager.insertNote(note)
            loadNotes()
        } catch {
            present(error)
        }
    }

    private func runAutomationIfNeeded() {
        guard didRunAutomationActions == false else {
            return
        }

        didRunAutomationActions = true

        if shouldAutoCreateNoteOnAppear {
            noteDraft = automationNoteBody
            saveDraftNoteForCurrentSentence()
        }

        if shouldAutoCreateBookmarkOnAppear {
            addBookmarkForCurrentSentence()
        }

        if shouldAutoPlayOnAppear, playbackState == .idle, segments.isEmpty == false {
            togglePlayback()
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }

    private func copyToClipboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #endif
    }

    // ========== BLOCK VM-IMAGE: IMAGE LOADING - START ==========

    private var imageCache: [String: Data] = [:]

    /// Returns PNG data for the given imageID, caching after the first load.
    func imageData(for imageID: String) -> Data? {
        if let cached = imageCache[imageID] { return cached }
        let data = try? databaseManager.imageData(for: imageID)
        if let data { imageCache[imageID] = data }
        return data
    }

    // ========== BLOCK VM-IMAGE: IMAGE LOADING - END ==========

    // ========== BLOCK VM-TOC: TABLE OF CONTENTS NAVIGATION - START ==========

    /// Jumps playback and scroll position to the sentence nearest to a TOC entry's
    /// plainTextOffset. Stops any active playback before jumping.
    func jumpToTOCEntry(_ entry: StoredTOCEntry) {
        jumpToOffset(entry.plainTextOffset)
    }

    /// Jump the reader to the sentence at-or-before `plainTextOffset`.
    /// Shared infrastructure for TOC entries (`jumpToTOCEntry`),
    /// page-jumps (`jumpToPage`), and M7 Ask Posey source-attribution
    /// pill taps. Stops playback so the user lands on a stable
    /// position rather than an immediately-advancing one.
    func jumpToOffset(_ plainTextOffset: Int) {
        guard plainTextOffset >= 0 else { return }
        stopPlayback()
        let targetIndex = segments.lastIndex(where: { $0.startOffset <= plainTextOffset })
            ?? 0
        currentSentenceIndex = targetIndex
        persistPosition()
    }

    /// Jump to the nearest sentence at the offset corresponding to the
    /// given 1-indexed page number. Returns true on a successful jump,
    /// false when the document has no page map or the page is out of
    /// range — caller surfaces a gentle "page out of range" message.
    /// Same semantics as `jumpToTOCEntry`: stops playback, updates
    /// `currentSentenceIndex` to the closest segment at-or-before the
    /// page-start offset, persists the new position.
    @discardableResult
    func jumpToPage(_ page: Int) -> Bool {
        guard pageMap.hasPages,
              let offset = pageMap.offset(forPage: page) else { return false }
        stopPlayback()
        let targetIndex = segments.lastIndex(where: { $0.startOffset <= offset }) ?? 0
        currentSentenceIndex = targetIndex
        persistPosition()
        return true
    }

    // ========== BLOCK VM-TOC: TABLE OF CONTENTS NAVIGATION - END ==========
}

// ========== BLOCK P2: EXPANDED IMAGE SHEET - START ==========

/// Token passed to `.sheet(item:)` — the imageID is both key and payload.
struct ExpandedImageItem: Identifiable {
    let id: String   // imageID
}

private struct ExpandedImageSheet: View {
    let imageID: String
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let data = viewModel.imageData(for: imageID),
                   let uiImage = UIImage(data: data) {
                    ZoomableImageView(image: uiImage)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView(
                        "Image Unavailable",
                        systemImage: "photo.slash",
                        description: Text("This image could not be loaded.")
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// ========== BLOCK P2: EXPANDED IMAGE SHEET - END ==========

// ========== BLOCK P3: TABLE OF CONTENTS SHEET - START ==========

/// Sheet that lists a document's TOC entries. Tapping an entry jumps the reader
/// to that section and dismisses the sheet. Only shown when TOC data is available.
/// Also hosts the Go-to-page input below the chapter list when the document has
/// recoverable per-page offsets (see `DocumentPageMap`).
private struct TOCSheet: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var pageInputText: String = ""
    @State private var pageInputErrorMessage: String? = nil
    @FocusState private var pageInputFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Task 8 (2026-05-03): composite id avoids the
                    // crash some EPUBs caused when synthesized TOC
                    // entries shared `playOrder = 0` (e.g. a nav.xhtml
                    // and a notice.html both starting at 0). Combine
                    // playOrder + offset + title so duplicates stay
                    // unique even when one of them is empty.
                    ForEach(viewModel.tocEntries, id: \.compositeID) { entry in
                        Button {
                            viewModel.jumpToTOCEntry(entry)
                            dismiss()
                        } label: {
                            Text(entry.title)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if viewModel.pageMap.hasPages {
                    Section {
                        goToPageRow
                    } header: {
                        Text("Go to page")
                    } footer: {
                        Text(goToPageFooter)
                            .font(.caption2)
                    }
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .remoteDismissPresentedSheet)
            ) { _ in
                dismiss()
            }
            .onAppear {
                RemoteControlState.shared.presentedSheet = "toc"
            }
            .onDisappear {
                if RemoteControlState.shared.presentedSheet == "toc" {
                    RemoteControlState.shared.presentedSheet = nil
                }
            }
        }
    }

    // MARK: - Go-to-page

    private var goToPageRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Page", text: $pageInputText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .focused($pageInputFocused)
                    .submitLabel(.go)
                    .accessibilityIdentifier("toc.pageInput")
                    .accessibilityLabel(pageInputAccessibilityLabel)
                    .accessibilityHint("Type a page number then tap Go")
                    .onSubmit { performJump() }
                Button("Go") { performJump() }
                    .buttonStyle(.borderedProminent)
                    .disabled(pageInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Go to page")
                    .remoteRegister("toc.pageGoButton") { performJump() }
                Spacer(minLength: 0)
                // Task 13 (2026-05-03): stepper alternative for users
                // who prefer ±1 paging over typing. Disabled when the
                // document has no page index. Operates on the parsed
                // input value (defaults to the document's first page
                // when the input is blank or non-numeric).
                if let range = viewModel.pageMap.pageRange {
                    Stepper(
                        value: stepperBinding(in: range),
                        in: range,
                        step: 1
                    ) {
                        Text("of \(range.upperBound)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .labelsHidden()
                    .accessibilityLabel("Adjust page number")
                    Text("of \(range.upperBound)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let error = pageInputErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("toc.pageError")
                    .accessibilityLabel("Page error: \(error)")
            }
        }
    }

    /// Task 13 (2026-05-03): accessibility label that reads the valid
    /// page range alongside the field name. Helps VoiceOver users know
    /// the bounds without first triggering an error.
    private var pageInputAccessibilityLabel: String {
        if let range = viewModel.pageMap.pageRange {
            return "Page number, \(range.lowerBound) to \(range.upperBound)"
        }
        return "Page number"
    }

    /// Two-way binding the stepper drives. Reads the current
    /// `pageInputText` (defaulting to the range's lower bound when
    /// blank / non-numeric); writes back the stepped value clamped to
    /// the range. The Go button still runs the actual jump — this
    /// only adjusts the staged value.
    private func stepperBinding(in range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: {
                let parsed = Int(pageInputText.trimmingCharacters(in: .whitespacesAndNewlines))
                return parsed.flatMap { range.contains($0) ? $0 : nil } ?? range.lowerBound
            },
            set: { newValue in
                let clamped = max(range.lowerBound, min(range.upperBound, newValue))
                pageInputText = String(clamped)
                pageInputErrorMessage = nil
            }
        )
    }

    private var goToPageFooter: String {
        switch viewModel.document.fileType.lowercased() {
        case "pdf":
            return "Page numbers track the source PDF's pages."
        case "epub":
            return "Page mapping for EPUBs is approximate — pages are inferred from the file's internal structure and may not match a print edition."
        default:
            return ""
        }
    }

    private func performJump() {
        let trimmed = pageInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            pageInputErrorMessage = "Type a page number first."
            return
        }
        guard let page = Int(trimmed) else {
            pageInputErrorMessage = "\"\(trimmed)\" isn't a page number — use digits only."
            return
        }
        guard let range = viewModel.pageMap.pageRange else {
            pageInputErrorMessage = "This document doesn't have page numbers."
            return
        }
        guard range.contains(page) else {
            pageInputErrorMessage = "There's no page \(page). Try \(range.lowerBound)–\(range.upperBound)."
            return
        }
        if viewModel.jumpToPage(page) {
            pageInputErrorMessage = nil
            pageInputFocused = false
            dismiss()
        } else {
            // jumpToPage returned false despite a valid range — should
            // be unreachable given the guard above, but render a
            // generic error rather than swallowing silently.
            pageInputErrorMessage = "Couldn't jump to page \(page) — please try again."
        }
    }
}

// ========== BLOCK P3: TABLE OF CONTENTS SHEET - END ==========
