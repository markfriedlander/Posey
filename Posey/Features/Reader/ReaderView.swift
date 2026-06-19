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
    // 2026-06-17 — Use the SHARED app-lifetime tracker, not a fresh instance.
    // A per-reader IndexingTracker is created when the document opens, so it
    // MISSES the `didStart` that already fired for an in-flight reindex/embed and
    // only catches up on the next `didProgress` (~5s at Nomic speed) — which made
    // the reading-ahead pill flicker in late / not appear. The shared instance
    // persists across reader opens and already holds the current in-flight state.
    @ObservedObject private var indexingTracker = IndexingTracker.sharedForChat
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
    /// 2026-05-28 — Chrome lives over `.ultraThinMaterial`, which adapts
    /// to system color scheme (light-translucent in Light, dark-
    /// translucent in Dark). The prior hard-coded
    /// `Color.white.opacity(0.9)` chromeTint was white-on-light-
    /// translucent in Light mode — effectively invisible on a white
    /// page background. Mark caught it. Drive the tint off
    /// `colorScheme` so chrome inverts cleanly with the user's mode.
    @Environment(\.colorScheme) private var colorScheme
    /// 2026-06-18 — top-chrome redesign: the Back action moved out of the system
    /// nav bar into the custom fading cluster (Row B), so the reader drives the
    /// pop itself.
    @Environment(\.dismiss) private var dismiss
    private let isTestMode: Bool
    @State private var isShowingNotesSheet = false
    @State private var isShowingPreferencesSheet = false
    @State private var isShowingTOCSheet = false
    /// 2026-05-07 (parity #5): test-only modal entry point for the
    /// Voice picker. The user-facing path is the NavigationLink inside
    /// Preferences, unchanged. This sheet exists so the antenna's
    /// OPEN_VOICE_PICKER_SHEET verb can drive verification of the
    /// picker (empty-state, voice-list rendering) without going
    /// through Preferences-sheet navigation that the antenna can't
    /// reach. Routed via `.remoteOpenVoicePickerSheet` notification.
    @State private var isShowingVoicePickerSheet = false
    /// Holds the Ask Posey chat view model while the sheet is open.
    /// `nil` when the sheet is dismissed. Using a value-typed item
    /// (instead of a separate `isShowing` Bool) means the view model
    /// is reconstructed on every open — fresh anchor capture, fresh
    /// transcript — and dropped on close so the deinit cancels any
    /// in-flight task.
    @State private var askPoseyChat: AskPoseyChatViewModel? = nil
    @State private var isChromeVisible = true
    @State private var chromeFadeTask: Task<Void, Never>?

    /// 2026-05-04 — Programmatic-scroll guard. The reader auto-scrolls
    /// to track the highlighted sentence during playback; that scroll
    /// motion would otherwise trigger the `.onScrollGeometryChange`
    /// chrome-reveal hook and pop full chrome on every sentence
    /// advance — exactly the "horrible experience" Mark called out.
    /// Each programmatic scroll stamps this timestamp; the scroll
    /// handler skips chrome reveal when the most recent stamp is
    /// within the suppression window (covers both the scroll's
    /// initial frame AND the animation's coast-down to a stop).
    @State private var lastProgrammaticScrollAt: Date = .distantPast
    private let programmaticScrollSuppressionWindow: TimeInterval = 0.7
    @State private var expandedImageItem: ExpandedImageItem? = nil
    /// Glyph color for chrome buttons. Inverts with colorScheme so
    /// the ultraThinMaterial capsule reads cleanly in both modes.
    /// Light: dark text on light translucent background.
    /// Dark: light text on dark translucent background.
    private var chromeTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.9) : Color.black.opacity(0.85)
    }
    /// Lower-weight chrome tint for inactive / secondary glyphs.
    private var chromeSecondaryTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.62) : Color.black.opacity(0.55)
    }

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

                    // Step 9 — unified units-based renderer. Walks
                    // every `ContentUnit` (prose / heading / blockquote
                    // / listItem / image / pageBreak / horizontalRule)
                    // and delegates to `UnitRowView`. Sentence-precise
                    // tap is delivered via per-sentence link ranges
                    // inside the row's `AttributedString`; the openURL
                    // action below dispatches to `jumpToSentenceID`.
                    ForEach(viewModel.units) { unit in
                        unitRow(unit)
                    }

                    // 2026-05-21 — End-of-book indicator. Appears at
                    // the very bottom of the scroll content when the
                    // document has a known content-end boundary
                    // (Gutenberg `*** END *** ` marker detected at
                    // import time → contentEndOffset > 0 → reader
                    // truncates segments/blocks past that offset).
                    // Without this the doc just stops mid-scroll and
                    // the user can wonder if something broke. The
                    // treatment is intentionally understated: a thin
                    // centered separator + the book's title in small
                    // italic. No "THE END" copy — the typographic
                    // colophon carries the meaning. Monochrome,
                    // consistent with Posey's standing style.
                    if viewModel.shouldShowEndOfBookIndicator {
                        VStack(spacing: 14) {
                            Rectangle()
                                .fill(Color.primary.opacity(0.25))
                                .frame(width: 60, height: 0.5)
                            Text(viewModel.document.title)
                                .italic()
                                .font(.system(size: viewModel.fontSize * 0.85, weight: .regular))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 56)
                        .padding(.bottom, 24)
                        .accessibilityIdentifier("reader.endOfBook")
                    }
                }
                .padding(.vertical)
            }
            .contentShape(Rectangle())
            // Step 9 — sentence-precise tap. The per-sentence
            // AttributedString ranges inside UnitRowView emit
            // posey-sentence:// URLs on tap; intercept here, jump
            // playback to the matching sentence, and return
            // `.handled` so SwiftUI doesn't try to open the URL in
            // Safari.
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == UnitRowView.sentenceURLScheme,
                      let host = url.host(),
                      let sentenceID = UUID(uuidString: host) else {
                    return .systemAction
                }
                viewModel.jumpToSentenceID(sentenceID)
                return .handled
            })
            // 2026-05-04 — Tap-to-toggle-chrome removed; single-tap
            // on a sentence row now jumps reading position there
            // (sentence-link tap in UnitRowView, plus the per-unit
            // `.onTapGesture` fallback for image / pageBreak rows).
            // Chrome auto-fades after 3 s and re-reveals on scroll
            // motion (any scroll position change brings it back —
            // belt-and-suspenders for the "I want the controls now"
            // intent). Chrome-button taps also reveal chrome (each
            // chrome button calls revealChrome() in its action).
            .onScrollGeometryChange(for: CGFloat.self,
                                    of: { $0.contentOffset.y },
                                    action: { _, _ in
                if Date().timeIntervalSince(lastProgrammaticScrollAt)
                    < programmaticScrollSuppressionWindow {
                    return
                }
                revealChrome()
            })
            // 2026-06-18 — top-chrome redesign: the title + back now live in the
            // custom fading cluster (`topChromeCluster`), so hide the system nav
            // bar entirely.
            .toolbar(.hidden, for: .navigationBar)
            // Hiding the nav bar disables UIKit's interactive edge-swipe-back
            // (confirmed on device, Mark 2026-06-18). This shim re-enables it by
            // giving the pop gesture a delegate that allows the swipe whenever
            // there's a screen to pop back to. (Mark requires edge-swipe kept.)
            .background(InteractivePopGestureEnabler())
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
            .overlay(alignment: .top) {
                if !viewModel.isSearchActive {
                    topChromeCluster
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
            // 2026-05-16 — Ambient progress meter. Always-visible thin
            // bar + "~N min left" sits at the very bottom of the
            // reading area, below the (overlay) chrome strip. Quiet
            // typography so it never pulls focus from the document.
            .safeAreaInset(edge: .bottom) {
                ReaderProgressMeter(viewModel: viewModel, indexingTracker: indexingTracker)
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
                lastProgrammaticScrollAt = Date()
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
            // 2026-06-17 — The top-center "Posey is reading ahead…" banner moved
            // to a floating low-key pill on the bottom-left, mirroring the
            // time-left label (Mark: less intrusive to reading). See
            // `ReaderProgressMeter.readingAheadPill`. The old `indexingBannerView`
            // + its helpers are retired below.
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
                publishReadingPositionForEnhancement()
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
                    lastProgrammaticScrollAt = Date()
                    // 2026-06-13 — OPEN scroll pins content-start to the TOP, not
                    // .center (DEFECT-reader-open-position-anchor): centering put
                    // a long first unit's head above the fold (P&P preface) /
                    // scrolled a chapter heading off (illustrated-alice). Re-armed
                    // before each nudge (scrollToCurrentSentence resets the anchor).
                    // Orientation re-scrolls below intentionally keep .center.
                    viewModel.scrollToContentStartOnOpen(with: proxy, animated: false)
                    try? await Task.sleep(for: .milliseconds(180))
                    lastProgrammaticScrollAt = Date()
                    viewModel.scrollToContentStartOnOpen(with: proxy, animated: false)
                    // #12 — segments have populated by now; publish
                    // the resolved unit so the enhancement service's
                    // page lock sees a real currentUnitID.
                    publishReadingPositionForEnhancement()
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
                // #12 — clear ReaderObservation so the enhancement
                // service stops treating this doc as the foregrounded
                // reader once the user navigates away.
                ReaderObservation.shared.setOpenDocument(nil)
            }
            .onChange(of: viewModel.currentSentenceIndex) { _, _ in
                lastProgrammaticScrollAt = Date()
                viewModel.scrollToCurrentSentence(with: proxy, animated: true)
                publishRemoteState()
                publishReadingPositionForEnhancement()
                // TTS-verify harness: log the on-screen-highlight transition on
                // the shared CACurrentMediaTime clock (no-op unless a run is
                // recording). This is the "seen" timeline — the exact index that
                // drives the highlight — to be compared against ASR of the live
                // captured audio ("heard"). DEBUG-only; Release stub ignores it.
                let segs = viewModel.segments
                let i = viewModel.currentSentenceIndex
                let off = (i >= 0 && i < segs.count) ? segs[i].startOffset : 0
                TTSVerifyHarness.shared.recordHighlight(index: i, offset: off)
            }
            // c13: during playback, the active sentence's measured pixel midY is
            // published; pin it to the upper third. Fires AFTER the anchor has
            // been repositioned to the new sentence (avoids the stale-anchor
            // race). In a ViewModifier so it type-checks outside the body's
            // already-large modifier chain.
            .modifier(C13PinScrollModifier(viewModel: viewModel, proxy: proxy))
            .modifier(ReaderRemoteSnapshotPublisher(viewModel: viewModel, publish: publishRemoteState))
            .onChange(of: viewModel.focusedUnitID) { _, _ in
                lastProgrammaticScrollAt = Date()
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
                    lastProgrammaticScrollAt = Date()
                    viewModel.scrollToCurrentSentence(with: proxy, animated: false)
                    try? await Task.sleep(for: .milliseconds(180))
                    lastProgrammaticScrollAt = Date()
                    viewModel.scrollToCurrentSentence(with: proxy, animated: false)
                }
            }
            .onChange(of: readerHorizontalSizeClass) { _, _ in
                // iPad split-view + Mac Catalyst window resize also
                // shift the layout in ways that benefit from the
                // re-center pass.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    lastProgrammaticScrollAt = Date()
                    viewModel.scrollToCurrentSentence(with: proxy, animated: false)
                    try? await Task.sleep(for: .milliseconds(180))
                    lastProgrammaticScrollAt = Date()
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
                    lastProgrammaticScrollAt = Date()
                    viewModel.scrollToCurrentSentence(with: proxy, animated: false)
                    try? await Task.sleep(for: .milliseconds(180))
                    lastProgrammaticScrollAt = Date()
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
            // 2026-05-21 — Smart skip prompt. Posey-voiced confirmation
            // dialog, fires once per heuristic-detected skip on a
            // non-Gutenberg document. Wrapped in a separate modifier
            // to keep the top-level body modifier chain short enough
            // for the Swift type-checker.
            .modifier(SmartSkipPromptModifier(viewModel: viewModel))
            .sheet(isPresented: $isShowingNotesSheet) {
                NotesSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $isShowingPreferencesSheet) {
                ReaderPreferencesSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $isShowingTOCSheet) {
                TOCSheet(viewModel: viewModel)
            }
            // 2026-05-07 (parity #5): test-only modal Voice picker
            // entry point (see `isShowingVoicePickerSheet` doc).
            .sheet(isPresented: $isShowingVoicePickerSheet) {
                NavigationStack {
                    VoicePickerView(
                        selectedIdentifier: Binding(
                            get: {
                                if case .custom(let id, _) = viewModel.voiceMode { return id }
                                return ""
                            },
                            set: { viewModel.setCustomVoice(identifier: $0) }
                        )
                    )
                    .navigationTitle("Voice")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { isShowingVoicePickerSheet = false }
                        }
                    }
                }
            }
            // The full-screen image viewer sheet + its OPEN_FIRST_IMAGE (c7)
            // antenna-verb observer, bundled into ONE modifier (like
            // SmartSkipPromptModifier above) so the top-level body chain stays
            // short enough for the Swift type-checker — adding either inline
            // overflowed it.
            .modifier(ExpandedImageModifier(expandedImageItem: $expandedImageItem,
                                            viewModel: viewModel))
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
                    onJumpToChunk: { offset, fromCitation in
                        // M7 source-attribution tap: dismiss the
                        // sheet (the AskPoseyView calls dismiss()
                        // before invoking this) and jump the reader.
                        // 2026-05-05 — fromCitation = true triggers
                        // the citation-return flow (return-pill at
                        // the cited row, extended chrome dwell,
                        // pulse animation on the chrome Ask Posey
                        // button). false is a non-citation jump
                        // (e.g., user tapped their own anchor pill).
                        if fromCitation {
                            viewModel.jumpToOffsetFromCitation(offset)
                        } else {
                            viewModel.jumpToOffset(offset)
                        }
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
                    let documentID = info["documentID"] as? UUID
                else {
                    dbgLog("ReaderView openAskPoseyForDocument: no documentID in userInfo")
                    return
                }
                guard documentID == viewModel.document.id else {
                    dbgLog("ReaderView openAskPoseyForDocument: docID mismatch %@ vs %@", documentID.uuidString, viewModel.document.id.uuidString)
                    return
                }
                let scopeStr = (info["scope"] as? String)?.lowercased() ?? "passage"
                let scope: AskPoseyScope = (scopeStr == "document") ? .document : .passage
                let initialAnchorStorageID = info["initialAnchorStorageID"] as? String
                dbgLog("ReaderView openAskPoseyForDocument: invoking openAskPosey scope=%@", scopeStr)
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
                isShowingTOCSheet: $isShowingTOCSheet,
                isShowingVoicePickerSheet: $isShowingVoicePickerSheet
            ))
        }
    }

    /// 2026-05-23 — Step 8f: this used to post .readerPositionDidUpdate
    /// for the Phase B BackgroundEnhancementScheduler's reader-aware
    /// priority. Scheduler + notification both torn out in 8f. **8f
    /// follow-up #12 — re-wired** to publish to `ReaderObservation`
    /// so `PDFEnhancementService.pageIsLockedForUpdate` can detect
    /// when a Tier 2 page rewrite would touch the unit the reader is
    /// currently sitting on. The published fields:
    ///
    ///   - `openDocumentID` — set once per reader-open, cleared on
    ///     disappear. Kicks the hub into per-document tracking mode.
    ///   - `currentOffset` — startOffset of the active segment, in
    ///     plainText character coordinates.
    ///   - `currentUnitID` — unit_id of the unit covering that
    ///     offset, resolved via `DatabaseManager.unitID(documentID:
    ///     plainTextOffset:)`. Strictly the lock signal that
    ///     PDFEnhancementService consumes.
    ///
    /// Called from every place the reader's position can change:
    /// `.onAppear` (after content loads), `.onChange(currentSentenceIndex)`,
    /// and `.onChange(segments.count)` (handles late-arriving content).
    /// `.onDisappear` clears `openDocumentID` (which the hub uses to
    /// reset all per-document state, including currentUnitID).
    private func publishReadingPositionForEnhancement() {
        let obs = ReaderObservation.shared
        if obs.openDocumentID != viewModel.document.id {
            obs.setOpenDocument(viewModel.document.id)
        }
        let segments = viewModel.segments
        let idx = viewModel.currentSentenceIndex
        guard idx >= 0, idx < segments.count else {
            obs.setCurrentOffset(nil)
            obs.setCurrentUnit(nil)
            return
        }
        let offset = segments[idx].startOffset
        obs.setCurrentOffset(offset)
        // Resolve unit id off-actor via the DB helper. The hub
        // setter is cheap (Int compare); the resolve is linear in
        // unit count so on a 10k-unit doc it's ~100µs. Still
        // dwarfed by the user reading at human speed.
        let docID = viewModel.document.id
        if let unitID = try? viewModel.databaseManager.unitID(
            documentID: docID, plainTextOffset: offset
        ) {
            obs.setCurrentUnit(unitID)
        } else {
            obs.setCurrentUnit(nil)
        }
    }

    private func publishRemoteState() {
        let segments = viewModel.segments
        let idx = viewModel.currentSentenceIndex
        let offset = (idx >= 0 && idx < segments.count) ? segments[idx].startOffset : 0
        RemoteControlState.shared.visibleDocumentID = viewModel.document.id
        RemoteControlState.shared.currentSentenceIndex = idx
        RemoteControlState.shared.currentOffset = offset
        // 2026-05-07 (parity #10): publish flat snapshots so the
        // antenna's LIST_SEGMENTS_MATCHING verb can search by text.
        RemoteControlState.shared.segmentTexts = segments.enumerated().map { i, seg in
            (index: i, text: seg.text, startOffset: seg.startOffset, endOffset: seg.endOffset)
        }
        // Step 9 — displayBlocks gone; publish units instead so the
        // antenna's LIST_DISPLAY_BLOCKS_MATCHING verb keeps working
        // against the new shape.
        RemoteControlState.shared.displayBlockTexts = viewModel.units.enumerated().map { i, unit in
            let kindLabel: String
            switch unit.kind {
            case .heading: kindLabel = "heading\(unit.metadata.headingLevel ?? 1)"
            case .prose: kindLabel = "paragraph"
            case .listItem: kindLabel = "bullet"
            case .blockquote: kindLabel = "quote"
            case .image: kindLabel = "visualPlaceholder"
            case .table: kindLabel = "table"
            case .pageBreak: kindLabel = "pageBreak"
            case .horizontalRule: kindLabel = "horizontalRule"
            case .code: kindLabel = "code"
            }
            return (index: i, kind: kindLabel, text: unit.text, startOffset: 0, endOffset: unit.text.count)
        }
    }

    private func clearRemoteStateIfOurs() {
        if RemoteControlState.shared.visibleDocumentID == viewModel.document.id {
            RemoteControlState.shared.visibleDocumentID = nil
        }
    }

    /// One unit row + all its modifiers. Extracted from the `ForEach` body so
    /// the main `body` expression type-checks (adding the c13 anchor overlay +
    /// publish closure tipped the Swift type-checker over its time limit).
    /// Behavior is unchanged from the prior inline row.
    @ViewBuilder
    private func unitRow(_ unit: ContentUnit) -> some View {
        // 2026-05-28 — incorporate unitAnnotationVersion into the row's id() so
        // SwiftUI re-runs the body when the version changes (annotationFlags is
        // a method call SwiftUI doesn't observe otherwise).
        let annotationVersion = viewModel.unitAnnotationVersion
        let annotations = viewModel.annotationFlags(for: unit)
        UnitRowView(
            unit: unit,
            sentencesInUnit: viewModel.sentencesByUnit[unit.id] ?? [],
            activeSentence: viewModel.activeSentence,
            activeSentenceIndex: viewModel.currentSentenceIndex,
            sentenceIndexBase: viewModel.sentenceIndexBase(for: unit),
            readingStyle: viewModel.readingStyle,
            hasNote: annotations.hasNote,
            hasBookmark: annotations.hasBookmark,
            annotationVersion: annotationVersion,
            onTapBookmark: { openAnnotationFromGlyph(unit: unit, kind: .bookmark) },
            onTapNote: { openAnnotationFromGlyph(unit: unit, kind: .note) },
            bodyFontSize: viewModel.fontSize,
            imageDataProvider: { viewModel.imageData(for: $0) },
            isSearchMatchUnit: viewModel.isSearchActive && viewModel.currentSearchMatchUnitID == unit.id,
            onActiveLine: { tv, range in viewModel.setActiveProseLine(tv, range) }
        )
        .padding(.horizontal, 14)
        .id(unit.id)
        .accessibilityIdentifier("reader.unit.\(unit.id.uuidString)")
        #if POSEY_ENABLE_ASK_POSEY
        .overlay(alignment: .topTrailing) {
            if isCitedRow(unit: unit) {
                citationReturnPill()
                    .padding(.trailing, 8)
                    .padding(.top, 2)
            }
        }
        #endif
        // Tap behavior for non-prose rows (image / pageBreak / horizontalRule),
        // which carry no sentence ranges:
        //   • IMAGE rows with real bytes → open the full-screen zoomable viewer
        //     (ExpandedImageSheet → ZoomableImageView). This trigger was MISSING:
        //     `.sheet(item: $expandedImageItem)` and ZoomableImageView were fully
        //     wired, but nothing ever set `expandedImageItem`, and this very tap
        //     hijacked image taps to JUMP — so the image viewer was dead code and
        //     there was no way to view an image (2026-06-14, Mark caught it).
        //   • everything else (pageBreak / hr / image with no bytes) → legacy
        //     "tap-the-image-block" jump to the first sentence of the next prose unit.
        .contentShape(Rectangle())
        .onTapGesture {
            // `.table` renders as an image (2026-06-15) and is carriesProseText,
            // so it would hit the prose early-return below — handle it FIRST so
            // tapping a table opens the zoomable viewer like an image.
            if unit.kind == .table,
               let imageID = unit.metadata.imageID,
               viewModel.imageData(for: imageID) != nil {
                expandedImageItem = ExpandedImageItem(id: imageID)
                return
            }
            guard !unit.kind.carriesProseText else { return }
            if unit.kind == .image,
               let imageID = unit.metadata.imageID,
               viewModel.imageData(for: imageID) != nil {
                expandedImageItem = ExpandedImageItem(id: imageID)
                return
            }
            if let firstAfter = viewModel.sentences.first(where: { s in
                guard let u = viewModel.units.first(where: { $0.id == s.unitID }) else { return false }
                return u.sequence > unit.sequence
            }) {
                viewModel.jumpToSentenceID(firstAfter.id)
            }
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
                // 2026-05-07 (Mark's directive): book-scale documents
                // (>200K chars — roughly 60+ pages of dense prose) take
                // ~5-10 seconds to segment + parse. Without explanatory
                // text, the spinner alone reads as a hang or crash.
                // Threshold picked from observed timings: 4-Hour Body
                // (~970K chars) was the trigger case at ~10 seconds.
                if viewModel.document.characterCount > 200_000 {
                    Text("Large document — this may take a few seconds.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .accessibilityIdentifier("reader.openingOverlay.largeDocHint")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening document \(viewModel.document.title)")
        .accessibilityIdentifier("reader.openingOverlay")
        .transition(.opacity)
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
                // 2026-05-28 — same colorScheme-driven tint as the
                // rest of the chrome (see chromeTint). Was hardcoded
                // white-on-ultraThin = invisible in Light mode.
                .foregroundStyle(chromeTint)
                .frame(width: 56, height: 56)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle().stroke(
                        (colorScheme == .dark ? Color.white : Color.black).opacity(0.10),
                        lineWidth: 0.5
                    )
                )
        }
        .buttonStyle(.plain)
        // 2026-05-04 — Softened opacity so the mini-player doesn't
        // pop as hard as the text behind it. 0.6 lets text show
        // through at a glance but the button is still clearly
        // tappable when the user looks at it.
        .opacity(0.6)
        .padding(.bottom, 24)
        .accessibilityLabel(viewModel.playbackState == .playing ? "Pause" : "Play")
        .accessibilityIdentifier("reader.miniPlayer.playPause")
        .remoteRegister("reader.miniPlayer.playPause") {
            viewModel.togglePlayback()
        }
    }

    /// **Reader UI bundle #3 — annotation-glyph tap.** Resolves the
    /// note this unit's glyph references and opens the Notes sheet
    /// scrolled to that entry. Looks up `viewModel.notes` for an
    /// entry of the requested kind whose offset falls within the
    /// unit's plainText range, then resolves the matching
    /// `SavedAnnotation.id` so the existing
    /// `.remoteScrollSavedAnnotations` notification can target it.
    private func openAnnotationFromGlyph(unit: ContentUnit, kind: NoteKind) {
        let range = viewModel.plainTextRange(for: unit)
        let match = viewModel.notes.first { note in
            note.kind == kind && note.startOffset >= range.lowerBound && note.startOffset < range.upperBound
        }
        guard let match else { return }
        let entry = viewModel.savedAnnotations.first(where: { $0.noteID == match.id })
        guard let entry else { return }
        // Open the sheet first; the scroll notification fires only
        // after the sheet's ScrollViewReader has rendered, so we
        // post a small delay to land on the right entry.
        revealChrome()
        isShowingNotesSheet = true
        let entryID = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(
                name: .remoteScrollSavedAnnotations,
                object: nil,
                userInfo: ["entryID": entryID]
            )
        }
    }

    // MARK: - Top chrome cluster (2026-06-18 redesign)

    /// The redesigned top chrome: ONE pill with TWO rows (Mark, 2026-06-18) that
    /// fades with the rest of the chrome (title + back now fade too, unlike the
    /// old system nav bar) and is sized + centered to BOOKEND the bottom controls
    /// — same full-width `.ultraThinMaterial` Capsule, same horizontal insets.
    /// **Row A = Title only** (centered, shrink-to-fit ~0.7 → truncate). **Row B
    /// = Back · TOC · Notes · Search · Preferences** (Mark's order), spread like
    /// the bottom transport row.
    private var topChromeCluster: some View {
        VStack(spacing: 8) {
            // Row A — title, centered, shrink-to-fit then truncate.
            Text(viewModel.document.title)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.tail)
                .foregroundStyle(chromeTint)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("reader.title")

            // Row B — the five controls, spread across the pill.
            HStack(spacing: 0) {
                chromeGlyphButton(system: "chevron.left",
                                  label: "Back to library", hook: "reader.back") {
                    dismiss()
                }
                Spacer(minLength: 8)
                // TOC keeps a CONSTANT position — greyed + disabled when the
                // document has no entries (Mark: grey-out is enough, no tooltip).
                chromeGlyphButton(system: "list.bullet.indent",
                                  label: "Table of contents", hook: "reader.toc",
                                  enabled: !viewModel.visibleTOCEntries.isEmpty) {
                    isShowingTOCSheet = true
                }
                Spacer(minLength: 8)
                chromeGlyphButton(system: "note.text",
                                  label: "Notes", hook: "reader.notes") {
                    viewModel.prepareForNotesEntry()
                    isShowingNotesSheet = true
                }
                Spacer(minLength: 8)
                chromeGlyphButton(system: "magnifyingglass",
                                  label: "Search in document", hook: "reader.search") {
                    viewModel.isSearchActive = true
                    chromeFadeTask?.cancel()
                }
                Spacer(minLength: 8)
                chromeGlyphButton(system: "slider.horizontal.3",
                                  label: "Reader preferences", hook: "reader.preferences") {
                    isShowingPreferencesSheet = true
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal)
        .padding(.top, 6)
    }

    /// One Row-B glyph button. Reveals chrome, runs `action`, and registers the
    /// same effect on the antenna `hook` so device verification + the remote
    /// driver both work. When `enabled` is false (only TOC, when the doc has no
    /// entries) it greys out and ignores taps but keeps its slot, so the row's
    /// positions stay constant.
    private func chromeGlyphButton(system: String, label: String, hook: String,
                                   enabled: Bool = true,
                                   action: @escaping () -> Void) -> some View {
        Button {
            guard enabled else { return }
            revealChrome()
            action()
        } label: {
            Image(systemName: system)
                .font(.headline)
                .foregroundStyle(enabled ? chromeTint : chromeSecondaryTint.opacity(0.5))
                .frame(width: 44, height: 44)
        }
        .disabled(!enabled)
        .remoteRegister(hook) {
            guard enabled else { return }
            revealChrome()
            action()
        }
        .accessibilityLabel(label)
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
            #if POSEY_ENABLE_ASK_POSEY
            // 2026-06-17 — readiness affordance (Option B). The old four-template
            // Menu was an AFM-only quick-actions surface; the release answer path
            // is MLX-only and free-form, so the template menu is gone (Mark:
            // "no submenu regardless of how you activate Ask Posey"). The glyph
            // now opens the chat directly when ready, and otherwise shows an
            // in-character "reading ahead / upgrading" hint with a progress ring.
            //
            // Visibility keys on `isSetUp` (Nomic + an MLX model present), NOT
            // `isUnlocked`/`isAvailable` — so during an embedder swap the sparkle
            // STAYS and reports "upgrading…" instead of vanishing (the "where did
            // Ask Posey go?" gap). When Ask Posey isn't set up at all, there's no
            // glyph — the Preferences on-ramp is the path.
            if AskPoseyAvailability.isSetUp {
                AskPoseyReaderGlyph(
                    documentID: viewModel.document.id,
                    tint: chromeTint,
                    onOpen: { askSpecificAction() },
                    indexingTracker: indexingTracker
                )
                // `reader.askPosey` + `reader.askPosey.askSpecific` test hooks are
                // registered INSIDE the glyph (on its stable root) so they survive
                // the readiness branch swaps. The legacy template hooks
                // (explain/define/findRelated) are retired with the template menu.

                Spacer(minLength: 24)
            }
            #endif

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

    // Step 9 — legacy renderer helpers deleted: horizontalRuleView,
    // visualPlaceholder(block:), segmentOpacity/Scale/Font/Weight/
    // TopPadding/Background, blockOpacity/Scale/Background,
    // headingTopPadding, motionFontSize, isMotionRenderActive,
    // motionAlignment, motionTextAlignment, immersiveOpacity,
    // immersiveScale. The unified UnitRowView replaces all of them;
    // its built-in `attributedProse` does the active-sentence
    // highlight, and the renderer no longer has dual paths.
    //
    // M8 reading-style dimming (Standard / Focus / Immersive / Motion)
    // is tracked for re-introduction on top of UnitRowView in a
    // follow-up — the units-based renderer needs an equivalent of
    // `isActive(unit:)` + opacity / scale modifiers. For now, every
    // row renders at full opacity / scale — same visual baseline as
    // Standard mode without dimming. The reading-style toggle is
    // still functional (it controls TTS announcements + motion mode
    // gating), it just doesn't drive visual dimming on this commit.

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
        // Test-mode skips the 3-second auto-fade so automated
        // screenshot capture can reliably show the chrome controls.
        // Doesn't affect end-user behavior.
        guard !isTestMode else { return }
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

    /// 2026-05-05 — Citation-return action. Triggered when the user
    /// taps the floating pill that appears next to a cited passage
    /// after they jumped here via an Ask Posey citation. Clears the
    /// citation context state and re-opens the Ask Posey sheet on
    /// the same document. The chat view model loads the persisted
    /// conversation from SQLite, so the user lands back in the same
    /// conversation at the most-recent message — "exact scroll
    /// position" in the practical sense.
    #if POSEY_ENABLE_ASK_POSEY
    private func returnToAskPoseyAction() {
        viewModel.clearCitationReturnContext()
        openAskPosey(scope: .passage)
    }
    #endif

    /// 2026-05-05 — Floating return-to-Ask-Posey pill rendered next
    /// to the cited row. Small capsule with back-arrow + sparkle
    /// glyph. Muted gray (Color(white: 0.45)) with 60% opacity per
    /// Mark's design feedback — reads as a quiet affordance, not a
    /// distraction from the document. Disappears naturally when the
    /// cited row scrolls off (the pill is part of the row's view
    /// tree); tap returns to Ask Posey.
    #if POSEY_ENABLE_ASK_POSEY
    @ViewBuilder
    private func citationReturnPill() -> some View {
        Button {
            returnToAskPoseyAction()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.caption)
                    .accessibilityHidden(true)
                Image(systemName: "sparkle")
                    .font(.caption)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color(white: 0.45))
                    .opacity(0.60)
            )
            // 2026-05-08 a11y — enforce 44pt minimum hit area without
            // visually inflating the pill. The hit-test rect grows
            // around the smaller capsule via .contentShape so VoiceOver
            // / large-finger taps land reliably.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Return to Ask Posey conversation")
        .accessibilityHint("Jumps back to the Ask Posey thread that cited this passage.")
        .accessibilityIdentifier("reader.citationReturnPill")
        .remoteRegister("reader.citationReturn") {
            returnToAskPoseyAction()
        }
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
    #endif

    /// True when this row is the cited row that should host the
    /// return-pill overlay. Centralises the comparison so the two
    /// row-rendering branches (displayBlocks + segments) stay in
    /// sync. Compares by the segment-index resolution that
    /// jumpToOffsetFromCitation captured, falling back to a
    /// straight offset match for displayBlocks.
    private func isCitedRow(segmentIndex: Int) -> Bool {
        guard let ctx = viewModel.citationReturnContext else { return false }
        return ctx.citedSentenceIndex == segmentIndex
    }

    private func isCitedRow(blockStartOffset: Int) -> Bool {
        guard let ctx = viewModel.citationReturnContext else { return false }
        // Exact match on the canonical block's startOffset, captured
        // at citation-jump time. Replaces an earlier fuzzy "within
        // 80 chars" comparison that produced multiple pills on
        // densely-packed byline content.
        return blockStartOffset == ctx.canonicalBlockStartOffset
    }

    /// **Step 9 — citation pill on the unit-based renderer.**
    /// True iff the unit contains the cited sentence (matched by the
    /// citation context's sentence index — same data the segment-row
    /// flavor compares against).
    private func isCitedRow(unit: ContentUnit) -> Bool {
        guard let ctx = viewModel.citationReturnContext else { return false }
        let citedIdx = ctx.citedSentenceIndex
        guard citedIdx >= 0, citedIdx < viewModel.sentences.count else { return false }
        return viewModel.sentences[citedIdx].unitID == unit.id
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
        var streamer: AskPoseyStreaming?
        var summarizer: AskPoseySummarizing?
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let service = AskPoseyService()
            streamer = service
            summarizer = service
        }
        #endif

        // 2026-05-05 (revised) — Force a nil → non-nil transition so
        // .sheet(item:) reliably re-presents on subsequent calls.
        // Without the nil-out + delay, when the sheet was just
        // dismissed via .remoteDismissPresentedSheet, SwiftUI can be
        // mid-dismissal-animation and a same-tick re-assignment to
        // askPoseyChat is silently swallowed. The /open-ask-posey
        // verb hitting a doc that's already loaded was hitting this.
        let buildAndAssign: () -> Void = {
            let vm = AskPoseyChatViewModel(
                documentID: document.id,
                documentPlainText: document.plainText,
                documentTitle: document.title,
                anchor: anchor,
                invocationReadingOffset: invocationOffset,
                initialScrollAnchorStorageID: initialAnchorStorageID,
                streamer: streamer,
                summarizer: summarizer,
                databaseManager: database,
                initialQuery: initialQuery,
                autoSubmitInitialQuery: autoSubmitInitialQuery
            )
            // 2026-05-12 — give the VM a way to ask the IndexingTracker
            // whether this doc is still indexing. When the weak-RAG
            // shortcut fires AND indexing is in flight, the VM swaps
            // its canned refusal for a "still learning" message so
            // first-time users don't think Posey can't help them.
            vm.isStillIndexingChecker = { docID in
                IndexingTracker.sharedForChat.isEnhancing(docID)
            }
            askPoseyChat = vm
        }
        // 2026-05-05 — Idempotency: if a sheet is already presenting,
        // a redelivered notification (Library re-posts after delay)
        // should be a no-op. Otherwise we churn the sheet's lifecycle
        // and SwiftUI dismisses it mid-presentation.
        if askPoseyChat != nil {
            dbgLog("openAskPosey: sheet already presenting; ignoring duplicate")
            return
        }
        buildAndAssign()
        dbgLog("openAskPosey: assigned new VM")
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
    @Binding var isShowingVoicePickerSheet: Bool

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
                isShowingTOCSheet: $isShowingTOCSheet,
                isShowingVoicePickerSheet: $isShowingVoicePickerSheet
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

/// 2026-05-07 (parity #10): re-publishes the segments/displayBlocks
/// snapshot to RemoteControlState whenever either array's count
/// changes. The initial onAppear publish captures empty arrays
/// because loadContent runs async; this modifier keeps the snapshot
/// in sync as content settles. Extracted to its own modifier to keep
/// the main reader body's type-checker budget under control.
private struct ReaderRemoteSnapshotPublisher: ViewModifier {
    @ObservedObject var viewModel: ReaderViewModel
    let publish: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel.segments.count) { _, _ in publish() }
            .onChange(of: viewModel.units.count) { _, _ in publish() }
    }
}

/// c13 auto-scroll pin: when the active prose line updates (`activeLineTick`),
/// scroll the backing UIScrollView so the active line holds at the fixed
/// upper-third viewport position during playback. In its own ViewModifier so it
/// type-checks outside the reader body's large modifier chain.
private struct C13PinScrollModifier: ViewModifier {
    @ObservedObject var viewModel: ReaderViewModel
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel.activeLineTick) { _, _ in
                viewModel.scrollToActiveAnchor(with: proxy)
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
            .onReceive(NotificationCenter.default.publisher(for: .remoteTTSVerifyRun)) { note in
                guard matches(note, viewModel: viewModel) else { return }
                let start = note.userInfo?["startSentence"] as? Int ?? 0
                let num = note.userInfo?["numSentences"] as? Int ?? 8
                let runID = note.userInfo?["runID"] as? String ?? UUID().uuidString
                // Start the recorder + shared clock FIRST, then play live from
                // `start` so audio and highlight share one timeline.
                let ok = TTSVerifyHarness.shared.begin(
                    runID: runID,
                    segments: viewModel.segments,
                    startSentence: start,
                    numSentences: num,
                    onStop: { viewModel.ttsVerifyStopPlayback() }
                )
                guard ok else { return }
                viewModel.ttsVerifyStartPlayback(fromSentence: start)
                // Anchor sample for the start sentence at t≈0 (onChange won't
                // fire if currentSentenceIndex was already `start`).
                let segs = viewModel.segments
                let off = (start >= 0 && start < segs.count) ? segs[start].startOffset : 0
                TTSVerifyHarness.shared.recordHighlight(index: start, offset: off)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteDebugForcePlaybackState)) { note in
                // No doc-id matching — the verb is global; whatever
                // doc is currently visible gets the state forced. The
                // viewModel guards by checking its own segments so
                // nothing breaks if no doc is open.
                guard let stateName = note.userInfo?["state"] as? String else { return }
                viewModel.debugForcePlaybackState(stateName)
            }
            .onReceive(viewModel.$playbackState) { newState in
                // TTS-verify: if playback finishes on its own, close the run so
                // the trailing audio is flushed and the JSON is written.
                if newState == .finished {
                    TTSVerifyHarness.shared.end(reason: "playback-finished")
                }
                let label: String
                switch newState {
                case .idle:     label = "idle"
                case .playing:  label = "playing"
                case .paused:   label = "paused"
                case .finished: label = "finished"
                }
                RemoteControlState.shared.playbackState = label
            }
            // 2026-05-13 (A1) — mirror readingStyle and the focused
            // visual block ID into RemoteControlState so the antenna
            // can confirm the Motion-aware policy is applied correctly
            // and that the Continue affordance's three gate conditions
            // (focused block + paused + non-motion) are all true.
            .onReceive(viewModel.$readingStyle) { style in
                RemoteControlState.shared.readingStyle = style.rawValue
            }
            .onReceive(viewModel.$focusedUnitID) { id in
                // Step 9 — units-based focused-row signal replaces
                // focusedDisplayBlockID. RemoteControlState's field
                // is still Int-typed; publish the unit's sequence
                // (a stable monotonic identifier per doc) so the
                // antenna verifier can still see a value change.
                guard let unitID = id else {
                    RemoteControlState.shared.focusedDisplayBlockID = nil
                    return
                }
                let seq = viewModel.units.first(where: { $0.id == unitID })?.sequence
                RemoteControlState.shared.focusedDisplayBlockID = seq
            }
    }
}

private struct ReaderRemoteControlSheetObservers: ViewModifier {
    @ObservedObject var viewModel: ReaderViewModel
    @Binding var isShowingPreferencesSheet: Bool
    @Binding var isShowingTOCSheet: Bool
    @Binding var isShowingVoicePickerSheet: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .remoteOpenPreferencesSheet)) { _ in
                isShowingPreferencesSheet = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteOpenTOCSheet)) { _ in
                isShowingTOCSheet = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteOpenVoicePickerSheet)) { _ in
                isShowingVoicePickerSheet = true
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
            .onReceive(NotificationCenter.default.publisher(for: .remoteBeginAudioExport)) { note in
                guard matches(note, viewModel: viewModel) else { return }
                viewModel.beginAudioExport()
            }
            .onReceive(NotificationCenter.default.publisher(for: .audioExportNotificationTapped)) { note in
                // Notification-tap routing when the export sheet is
                // NOT currently presented. Record the URL on the
                // view model and re-present Preferences → AudioExport
                // so the user lands on the Share button. Same staged
                // present pattern as `.remoteOpenAudioExportSheet`.
                if let url = note.userInfo?[AudioExportNotificationKeys.fileURL] as? URL {
                    viewModel.acceptDeliveredExportURL(url)
                }
                if !viewModel.showAudioExport {
                    isShowingPreferencesSheet = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        viewModel.showAudioExport = true
                    }
                }
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
            // 2026-05-16 — remoteSetReadingStyle + remoteSetMotionPreference
            // observers removed. The picker + the antenna verbs that
            // posted them are also gone. Notification names remain
            // declared so any stragglers (e.g. test fixtures persisted
            // to disk) don't fail to compile if they reference them.
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
                RemoteControlState.shared.searchMatchIndices = matches
            }
            .onReceive(viewModel.$currentSearchMatchPosition) { pos in
                RemoteControlState.shared.currentSearchMatchPosition = pos ?? 0
            }
    }
}

/// 2026-05-21 — Smart skip prompt. Extracted into a ViewModifier so
/// the ReaderView's body modifier chain stays under the Swift
/// type-checker's complexity budget. Posey's voice: declarative,
/// warm, a little personality. Gutenberg-detected skips never reach
/// this modifier (shouldPromptForSkip returns false) — silent by
/// design.
///
/// 2026-05-27 — Converted from `.confirmationDialog` (native iOS alert
/// that blocks the screen, can't be dismissed programmatically, can't
/// be antenna-tested) to a swipe-dismissable bottom sheet. Reasoning:
/// the native alert was jarring when the user just wants to start
/// reading; the sheet leaves the document visible behind it, can be
/// ignored or swiped away, and can be driven by the local API via
/// `RESPOND_SKIP_PROMPT:<keep|beginning>` for testing. Swipe-dismiss
/// without choosing maps to `confirmSkipKeep()` — the reader is already
/// at the skip offset, swiping down = "leave it as is, stop asking."
private struct SmartSkipPromptModifier: ViewModifier {
    @ObservedObject var viewModel: ReaderViewModel
    func body(content: Content) -> some View {
        content.sheet(isPresented: $viewModel.isPresentingSkipPrompt) {
            // Swipe-down without choosing = same as "Jump to Chapter"
            // (the reader is already at the skip offset; user just
            // dismissed without changing anything). Stops the prompt
            // from re-appearing.
            viewModel.confirmSkipKeep()
        } content: {
            SmartSkipPromptSheet(viewModel: viewModel)
        }
    }
}

/// 2026-05-27 — Bottom-sheet body for the smart-skip prompt. Compact
/// detent so the document stays visible behind it. Two action buttons,
/// styled to match Posey's quiet/declarative voice.
private struct SmartSkipPromptSheet: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text("Skip the housekeeping?")
                    .font(.headline)
                Spacer()
            }
            Text("This one starts with some front-matter before the good stuff. Want to jump to the first chapter, or start from the beginning?")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                Button {
                    viewModel.confirmSkipKeep()
                    dismiss()
                } label: {
                    Text("Jump to Chapter")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("reader.skipPrompt.jumpToChapter")

                Button {
                    viewModel.revealFromBeginning()
                    dismiss()
                } label: {
                    Text("Start from Beginning")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("reader.skipPrompt.startFromBeginning")
            }
        }
        .padding(20)
        .presentationDetents([.height(240)])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled)
        .accessibilityIdentifier("reader.skipPrompt")
        // Antenna-driven choice support. The local API posts
        // `.remoteRespondSkipPrompt` with userInfo["choice"] ∈
        // {"keep", "beginning"}; we dispatch to the matching handler
        // and dismiss the sheet. Lets the antenna test the smart-skip
        // flow without UI interaction.
        .onReceive(NotificationCenter.default.publisher(for: .remoteRespondSkipPrompt)) { note in
            let choice = (note.userInfo?["choice"] as? String)?.lowercased() ?? ""
            switch choice {
            case "keep", "jumptochapter", "chapter":
                viewModel.confirmSkipKeep()
                dismiss()
            case "beginning", "startfrombeginning", "fromtop":
                viewModel.revealFromBeginning()
                dismiss()
            default:
                break
            }
        }
    }
}

@MainActor
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

    // 2026-05-29 — `draftStrictness` moved to AskPoseyModelLibraryView with
    // the preferences reorganization (the retrieval-strictness picker now
    // lives on the Model Library screen alongside the model + embedder).

    /// Push state for the Model Library screen. Owned here (the
    /// always-rendered sheet host) rather than in the below-the-fold
    /// `AskPoseyPreferencesSection`, so the user tap, the
    /// `OPEN_MODEL_LIBRARY` verb, and the `.navigationDestination` are all
    /// robust regardless of scroll position / lazy row instantiation.
    @State private var showModelLibrary = false
    /// 2026-05-31 — Ask Posey unlock onboarding (shown from the locked
    /// preferences invitation; flows into the Model Library). Repeats on each
    /// entry until Nomic + ≥1 MLX model are present.
    @State private var showAskPoseyOnboarding = false

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
            // 2026-05-28 — ScrollViewReader wraps Form so the antenna's
            // SCROLL_PREFS_TO_LLM verb can jump to the LLM picker
            // without the user (or test driver) having to swipe.
            // Listens for `.remoteScrollPrefsToLLM` notification and
            // scrolls to the AskPoseyPreferencesSection anchor.
            ScrollViewReader { proxy in
            Form {
                // ===== SOUND — everything that affects how Posey speaks =====
                // Voice selection + speed + audio export. 2026-05-29
                // preferences reorganization (Hal visual language): one
                // icon-headed section per Mark's Sound/Reading/Ask Posey
                // structure.
                Section {
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

                    // Audio export (notification-based background render).
                    Button {
                        viewModel.beginAudioExport()
                    } label: {
                        Label("Export to Audio File", systemImage: "waveform.badge.plus")
                            .frame(minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("preferences.exportAudio")
                    .accessibilityHint("Renders this document as an M4A audio file. The export runs in the background and notifies you when complete.")
                    .remoteRegister("preferences.exportAudio") {
                        viewModel.beginAudioExport()
                    }
                    Text("Renders this document as an M4A file. Continues in the background if you lock your phone or switch apps; you'll get a notification when it's ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Sound", systemImage: "speaker.wave.2")
                }

                // Cached Audio Files — lists M4As in the persistent cache
                // (its own component Section; sits with audio export under
                // the Sound grouping). iOS may purge under storage
                // pressure; re-export regenerates.
                CachedAudioFilesSection(databaseManager: viewModel.databaseManager)

                // ===== READING — everything that affects how the page looks =====
                // Font size + image handling today. Presentation mode
                // (standard / lyrics), light/dark, and serif/sans-serif
                // are planned additions to this section when those
                // features land (see NEXT.md "Reading appearance").
                Section {
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

                    Picker("Images & tables during playback",
                           selection: $viewModel.visualHandling) {
                        ForEach(PlaybackPreferences.VisualHandling.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("preferences.imageHandling")

                    Text(viewModel.visualHandling.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Reading", systemImage: "book")
                }

                // ===== ASK POSEY — links to the Model Library screen =====
                // The model catalog, search-breadth, and embedder picker
                // moved to AskPoseyModelLibraryView (a pushed screen) so
                // the gated-download disclosure/license sheets present
                // correctly. This section is the active-model row + the
                // "Browse Model Library" link (Hal's settings convention).
                AskPoseyPreferencesSection(
                    documentID: viewModel.document.id,
                    database: viewModel.databaseManager,
                    onBrowseModelLibrary: { showModelLibrary = true },
                    onGetStarted: { showAskPoseyOnboarding = true }
                )
                .id("preferences.askPosey.section")
            }
            .navigationTitle("Reader Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showModelLibrary) {
                AskPoseyModelLibraryView(
                    migrationCoordinator: EmbedderMigrationCoordinator.shared,
                    databaseManager: viewModel.databaseManager
                )
            }
            .sheet(isPresented: $showAskPoseyOnboarding) {
                AskPoseyOnboardingView(
                    onContinue: {
                        showAskPoseyOnboarding = false
                        showModelLibrary = true
                    },
                    onNotNow: { showAskPoseyOnboarding = false }
                )
            }
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
            .onReceive(
                NotificationCenter.default.publisher(for: .remoteOpenModelLibrary)
            ) { _ in
                showModelLibrary = true
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
            // 2026-05-16 — Motion consent sheet removed (Mark spec).
            // CoreMotion auto-detection retired entirely.
            .sheet(isPresented: $viewModel.showAudioExport) {
                AudioExportSheet(viewModel: viewModel)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .remoteScrollPrefsToLLM)
            ) { note in
                // Antenna-provided target id (per-model anchor when the
                // verb is called with an argument; section anchor when
                // not). Falls back to the section anchor if userInfo is
                // missing or malformed.
                let target = (note.userInfo?["target"] as? String)
                    ?? "preferences.askPosey.section"
                withAnimation {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
            } // ScrollViewReader
        }
    }
}
// ========== BLOCK P1: READER PREFERENCES SHEET - END ==========


// ========== BLOCK P1B: MOTION CONSENT SHEET - REMOVED 2026-05-16 ==========
// Mark spec removed Motion reading style + CoreMotion auto-detection
// entirely. The consent sheet is no longer reachable from the UI;
// `MotionDetector` remains in the codebase but is never started.
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
    /// 2026-05-08 redesign — set true when the user taps a delivered
    /// completion notification. Drives an inline highlight so the
    /// just-tapped notification's file feels "selected" in the sheet.
    /// The share sheet still requires an explicit Share-button tap.
    @State private var notificationDeliveredHighlight: Bool = false

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
                    .accessibilityAddTraits(.isHeader)
                if let exporter = viewModel.audioExporter {
                    body(for: exporter)
                } else if let url = viewModel.lastCompletedExportURL {
                    // No active exporter but we've got a previous
                    // result — typically the user dismissed the sheet
                    // mid-render and came back via a notification tap
                    // after completion. Surface the Share button.
                    finishedBody(for: url)
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
                // 2026-05-08 redesign: Done dismisses the sheet but
                // does NOT cancel the in-flight export. The export
                // continues under a UIApplication background task and
                // notifies on completion. Cancellation is now an
                // explicit action inside the sheet during rendering.
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityHint("Dismisses this view. Any export in progress keeps running and will notify you when done.")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .audioExportNotificationTapped)) { note in
                // The user tapped a delivered notification while
                // the sheet was visible. Light up the highlight and
                // ensure lastCompletedExportURL reflects the file
                // the notification carried (it should already, but
                // be defensive in case of multi-export sequencing).
                if let url = note.userInfo?[AudioExportNotificationKeys.fileURL] as? URL {
                    viewModel.acceptDeliveredExportURL(url)
                }
                notificationDeliveredHighlight = true
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
                    .accessibilityLabel("Audio export progress")
                    .accessibilityValue("\(Int(progress * 100)) percent. Segment \(i) of \(total).")
                Text("Rendering segment \(i) of \(total) — \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let voiceName = exportingVoiceName {
                    Text("Voice: \(voiceName)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("You can close this view; the export will continue and you'll get a notification when it's done.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Button("Cancel Export", role: .destructive) {
                    exporter.cancel()
                }
                .padding(.top, 8)
                .accessibilityHint("Stops the audio export in progress.")
            }
        case .finished(let url):
            finishedBody(for: url)
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

    @ViewBuilder
    private func finishedBody(for url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Export complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(url.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
            ShareLink(item: url) {
                Label("Share or Save to Files", systemImage: "square.and.arrow.up")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("audioExport.share")
            .remoteRegister("audioExport.share") { /* SwiftUI ShareLink is user-driven; antenna entry point exists for tap-discovery only. */ }
            if notificationDeliveredHighlight {
                Text("Opened from notification — tap Share to send the file.")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("audioExport.fromNotification")
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
                if reduceMotion {
                    listProxy.scrollTo(entryID, anchor: .top)
                } else {
                    withAnimation { listProxy.scrollTo(entryID, anchor: .top) }
                }
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

    /// 2026-05-21 — True when the document carries a known content-end
    /// boundary (set by the Gutenberg `*** END ***` detector or a
    /// future format-specific detector). When true, ReaderView renders
    /// a small colophon block at the very bottom of the scroll content
    /// so the user knows the book has ended rather than wondering if
    /// something broke. False means the document runs to plainText
    /// end with no explicit boundary — show nothing.
    var shouldShowEndOfBookIndicator: Bool {
        document.contentEndOffset > 0
    }

    /// 2026-05-21 — Smart skip prompt. True when the importer skipped
    /// past some front-matter via a heuristic detector (in-prose TOC,
    /// TOC-walker, PDF/DOCX/RTF TOCSkipDetector, EPUBFrontMatterDetector)
    /// on a non-Gutenberg document. The reader presents a one-time
    /// confirmation dialog after content has loaded: "Jump to Chapter"
    /// (keep skip) or "Start from Beginning" (skip = 0, read everything).
    ///
    /// Gutenberg-detected skips return false here — Mark's locked
    /// design: Gutenberg marker presence means the whole skip is
    /// authoritative and silent. The user is never asked.
    ///
    /// After the user makes a choice, `skipSource` transitions to
    /// `"user_keep"` or `"user_dismiss"`, this property returns false,
    /// and the prompt never reappears (even on relaunch — the state
    /// is persisted).
    var shouldPromptForSkip: Bool {
        document.skipSource == "heuristic" && document.playbackSkipUntilOffset > 0
    }

    /// Drives the `.confirmationDialog` presentation. Flipped true by
    /// `loadContent()` once `isLoading` goes false (so the user sees
    /// the reader chrome and a bit of content behind the dialog —
    /// gives the choice context). The user's action handlers flip
    /// it false again.
    @Published var isPresentingSkipPrompt: Bool = false

    /// User chose "Jump to Chapter" on the smart-skip prompt. Persist
    /// `skipSource = "user_keep"` so the prompt never reappears, and
    /// dismiss the dialog. No reposition needed — the reader already
    /// opened at the skip offset, which is exactly what the user just
    /// confirmed.
    func confirmSkipKeep() {
        isPresentingSkipPrompt = false
        guard document.skipSource == "heuristic" else { return }
        var updated = document
        updated.skipSource = "user_keep"
        do {
            try databaseManager.upsertDocument(updated)
            self.document = updated
        } catch DatabaseManager.DatabaseError.foreignKeyViolation {
            // Doc deleted under us — benign.
        } catch {
            present(error)
        }
    }

    /// User chose "Start from Beginning" on the smart-skip prompt.
    /// Persist `playbackSkipUntilOffset = 0` and `skipSource = "user_dismiss"`,
    /// then re-run content loading so the previously-filtered segments
    /// and display blocks re-enter the reader. Finally seek to offset 0
    /// so playback starts at the very first sentence.
    func revealFromBeginning() {
        isPresentingSkipPrompt = false
        // 2026-05-28 (defect #6 extension) — also honor `gutenberg`
        // skip-source. Pride / Sherlock / Frankenstein EPUBs set
        // skipSource="gutenberg" (from `GutenbergBoundaryDetector`),
        // not "heuristic" (which only the PDF importer / TXT heuristic
        // path uses). Without this, `:beginning` was a no-op for every
        // Gutenberg EPUB — the user couldn't reach the cover or the
        // legal preamble even via the explicit "Beginning" choice.
        // Empty source means the doc has no auto-skip, so there's
        // nothing to reveal — keep that as the early-return condition.
        guard document.skipSource == "heuristic"
                || document.skipSource == "gutenberg" else { return }
        var updated = document
        updated.playbackSkipUntilOffset = 0
        updated.skipSource = "user_dismiss"
        do {
            try databaseManager.upsertDocument(updated)
            // Defect #6 fix (2026-05-27 evening) — also clear the
            // unit-level skip reference. `loadContent`'s units fast
            // path filters by `unitSkipReferences().skipUnitID`, not
            // by `playbackSkipUntilOffset`. Without clearing this,
            // the reload below still hides everything before the
            // skip unit, so the reader stays on the skip-anchored
            // page even after `jumpToOffset(0)` runs (segments[0]
            // is still the post-skip first sentence).
            // contentEndUnitID is preserved — we're revealing the
            // skipped prefix, not the post-end suffix.
            let existing = (try? databaseManager.unitSkipReferences(for: document.id))
                ?? (skipUnitID: nil, contentEndUnitID: nil)
            try databaseManager.setUnitSkipReferences(
                skipUnitID: nil,
                contentEndUnitID: existing.contentEndUnitID,
                for: document.id
            )
            self.document = updated
        } catch DatabaseManager.DatabaseError.foreignKeyViolation {
            // Doc deleted under us — benign; bail out, nothing to reveal.
            return
        } catch {
            present(error)
            return
        }
        // Rebuild segments + display blocks without the skip filter,
        // then jump to offset 0. Done on a detached task so the heavy
        // segmenter pass doesn't block the dialog's dismiss animation.
        Task { [weak self] in
            guard let self else { return }
            await self.reloadContentAfterSkipChange()
        }
    }

    /// Re-run the heavy content compute after `document.playbackSkipUntilOffset`
    /// has changed, then seek to the start. Mirrors `loadContent()` but
    /// skips the position-restore step (we want offset 0, not whatever
    /// position was last persisted) and skips the now-playing reinstall
    /// (the controller is already wired).
    private func reloadContentAfterSkipChange() async {
        // Step 9 — rebuilt on top of the units pipeline. Re-snapshots
        // units + sentences from the DB with the (new) skip / content-
        // end window applied, then jumps to offset 0.
        await self.loadContent()
        self.jumpToOffset(0)
    }

    /// 2026-05-16 — Reading Style picker removed (Mark spec). The
    /// underlying `PlaybackPreferences.readingStyle` getter always
    /// returns `.standard` and the setter no-ops. This stored
    /// property exists so the existing switch sites in the render
    /// path keep compiling; the value is effectively a constant
    /// `.standard` going forward.
    @Published var readingStyle: PlaybackPreferences.ReadingStyle = .standard

    /// 2026-05-16 — Motion-auto detection removed. Constant `.off`.
    @Published var motionPreference: PlaybackPreferences.MotionPreference = .off

    /// 2026-05-16 — CoreMotion consent no longer requested. Constant
    /// `false`.
    @Published var motionAutoConsent: Bool = false

    /// 2026-05-16 — Consent sheet unreachable; kept to satisfy any
    /// remaining `viewModel.showMotionConsent` references during the
    /// transitional period.
    @Published var showMotionConsent: Bool = false

    /// 2026-05-16 — Motion detector no longer engaged. `isDeviceMoving`
    /// is always false. `motionDetector` / cancellable removed; the
    /// `MotionDetector` service still ships in the binary but its
    /// `start()` is never called.
    @Published private(set) var isDeviceMoving: Bool = false

    /// 2026-05-16 — New explicit image-handling preference replacing
    /// the prior implicit pause-when-Motion-on rule. didSet writes
    /// through to PlaybackPreferences and re-applies the visual-block
    /// policy so the change takes effect immediately mid-read.
    @Published var visualHandling: PlaybackPreferences.VisualHandling
        = PlaybackPreferences.shared.visualHandling {
        didSet {
            PlaybackPreferences.shared.visualHandling = visualHandling
            applyVisualBlockMotionPolicy()
        }
    }

    /// M8 audio export. The exporter is recreated on each kickoff so
    /// the UI's progress observation always sees a fresh state
    /// machine. `showAudioExport` drives the presentation of the
    /// export sheet from the preferences UI.
    @Published var showAudioExport: Bool = false
    @Published private(set) var audioExporter: AudioExporter?
    /// 2026-05-08 redesign — last successful export URL, retained on
    /// the view model so a re-presented `AudioExportSheet` (after the
    /// user dismissed and came back via a notification tap) can show
    /// the Share button without re-running the export. Survives sheet
    /// dismissal; cleared on next `beginAudioExport()`.
    @Published private(set) var lastCompletedExportURL: URL?

    /// Called from the AudioExportSheet's notification observer (and
    /// the top-level reader observer) to record the URL the most-
    /// recently-delivered notification carried. Idempotent.
    func acceptDeliveredExportURL(_ url: URL) {
        lastCompletedExportURL = url
    }

    /// Kick off an audio export. Builds a fresh AudioExporter,
    /// presents the export sheet, and starts rendering on a
    /// background Task. The sheet observes the exporter's state
    /// directly.
    ///
    /// 2026-05-08 redesign (notification flow):
    /// - Requests `UNUserNotifications` permission first (no-op if
    ///   already granted/denied).
    /// - Wraps the render in `UIApplication.beginBackgroundTask`
    ///   so the export survives lock screen / app switch.
    /// - On success fires a local notification via
    ///   `AudioExportNotifications.scheduleCompletionNotification`;
    ///   tapping the banner posts `.audioExportNotificationTapped`
    ///   and the sheet (re-)presents with the Share button live.
    /// - The share sheet **never** appears automatically — the
    ///   completion path delivers a banner only.
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
        lastCompletedExportURL = nil
        showAudioExport = true
        let segmentsCopy = segments
        let exportVoiceMode = Self.audioExportVoiceMode(for: voiceMode)
        let title = document.title
        let docID = document.id

        // Fire the notification permission request in parallel with
        // the export. The system prompt blocks ON THE USER, not on
        // the render — if we awaited it inline the user would see
        // "Preparing…" frozen until they tapped Allow / Don't Allow.
        // We re-check `notificationSettings()` at completion time
        // and only schedule the banner if authorized by then.
        Task { @MainActor in
            _ = await AudioExportNotifications.shared.requestAuthorizationIfNeeded()
        }

        Task { @MainActor in
            // Begin a background task so the export survives lock
            // screen / foreground swap. Stored ID is ended on every
            // exit path (success, failure, cancel). If iOS expires
            // the task before completion, the expirationHandler
            // cancels the in-flight render so we don't leak.
            #if canImport(UIKit)
            var bgTaskID: UIBackgroundTaskIdentifier = .invalid
            bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "audio-export") { [weak exporter] in
                // 2026-05-13 — A8: surface iOS-forced expiration as
                // its own error so the failure notification doesn't
                // misreport this as a user cancellation.
                Task { @MainActor in
                    exporter?.cancelDueToBackgroundExpiration()
                    if bgTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTaskID)
                        bgTaskID = .invalid
                    }
                }
            }
            // 2026-05-13 — A8 test hook. Posting
            // `.remoteSimulateAudioExportExpiration` (via the antenna
            // verb of the same name) drives the same .backgroundTime
            // Expired error path that iOS would trigger when the
            // beginBackgroundTask window runs out, without having to
            // wait the real ~30s while backgrounded. Test-only.
            let expirationObserver = NotificationCenter.default.addObserver(
                forName: .remoteSimulateAudioExportExpiration,
                object: nil,
                queue: .main
            ) { [weak exporter] _ in
                // queue: .main guarantees this fires on the main thread,
                // so assumeIsolated is safe here and lets us call the
                // main-actor-isolated `cancelDueToBackgroundExpiration()`
                // without bouncing through a Task.
                MainActor.assumeIsolated {
                    exporter?.cancelDueToBackgroundExpiration()
                }
            }
            #endif

            defer {
                #if canImport(UIKit)
                NotificationCenter.default.removeObserver(expirationObserver)
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
                #endif
            }

            do {
                let url = try await exporter.render(
                    segments: segmentsCopy,
                    voiceMode: exportVoiceMode,
                    documentTitle: title
                )
                self.lastCompletedExportURL = url
                // Re-check auth at completion time — by now the user
                // has had time to respond to the prompt that fired
                // in parallel.
                let canNotify = await AudioExportNotifications.shared.requestAuthorizationIfNeeded()
                if canNotify {
                    AudioExportNotifications.shared.scheduleCompletionNotification(
                        fileURL: url,
                        documentID: docID,
                        documentTitle: title
                    )
                }
            } catch {
                let canNotify = await AudioExportNotifications.shared.requestAuthorizationIfNeeded()
                if canNotify, let reason = (error as? LocalizedError)?.errorDescription {
                    AudioExportNotifications.shared.scheduleFailureNotification(
                        documentID: docID,
                        documentTitle: title,
                        reason: reason
                    )
                }
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
    // Step 9 — focusedDisplayBlockID deleted; focusedUnitID replaces it.
    @Published var isShowingError = false
    @Published var errorMessage = ""
    @Published var noteDraft = ""
    @Published private(set) var notes: [Note] = []
    /// 2026-05-28 — Bumped whenever the per-unit annotation cache is
    /// invalidated (after note insert / delete via UI or antenna).
    /// `annotationFlags(for:)` is a method, not a Published computed,
    /// so SwiftUI doesn't track it as a dependency of the unit row
    /// body. Without this version counter, antenna-created notes don't
    /// trigger a re-render of the row's annotation footer — glyphs
    /// silently stay absent until something else forces a redraw.
    /// The ForEach body reads `unitAnnotationVersion` so SwiftUI sees
    /// the dependency.
    @Published private(set) var unitAnnotationVersion: Int = 0
    /// Unified Saved Annotations list for the Notes sheet — combines
    /// notes, bookmarks, and Ask Posey conversation anchors into one
    /// chronologically-sorted feed. Recomputed every time `notes` is
    /// reloaded AND every time the Ask Posey sheet dismisses (so a
    /// new anchor created during the conversation surfaces here
    /// without the user having to do anything else). Sorted newest
    /// first.
    @Published private(set) var savedAnnotations: [SavedAnnotation] = []
    @Published private(set) var voiceMode: SpeechPlaybackService.VoiceMode = .bestAvailable

    // ========== BLOCK VM-CITATION-RETURN: RETURN-TO-ASK-POSEY STATE - START ==========

    /// 2026-05-05 — Set when the user arrived at the reader by
    /// tapping an Ask Posey citation (inline `[ⁿ]` or sources strip).
    /// Drives the floating return-pill rendered alongside the cited
    /// row. Cleared when the user taps the pill (which returns to
    /// the Ask Posey conversation). The pill disappears naturally
    /// when the cited row scrolls off-screen because it's part of
    /// the row's view tree; the context state itself can stay set
    /// (no harm — if the user scrolls back, the pill reappears).
    ///
    /// `canonicalBlockStartOffset` is the EXACT startOffset of the
    /// single block (in displayBlocks mode) that contains the
    /// citation. Computed once at citation-jump time so the pill
    /// renders against exactly one block, not every block within a
    /// fuzzy radius (which produced the three-pill bug Mark caught).
    struct CitationReturnContext: Equatable {
        let citedOffset: Int            // chunk's startOffset
        let citedSentenceIndex: Int     // resolved segment row index
        let canonicalBlockStartOffset: Int  // exact block startOffset
        let arrivedAt: Date
    }
    @Published var citationReturnContext: CitationReturnContext?

    /// Citation-arrival jump. Sets up the return-pill state before
    /// performing the standard jumpToOffset. Called from the Ask
    /// Posey sheet's onJumpToChunk callback when fromCitation = true
    /// (both inline citations and sources strip pills count).
    func jumpToOffsetFromCitation(_ plainTextOffset: Int) {
        let targetIndex = segments.lastIndex(where: { $0.startOffset <= plainTextOffset }) ?? 0
        // Step 9 — canonicalBlockStartOffset still set for any
        // legacy consumer; `isCitedRow(unit:)` (the units-based
        // pill rule) keys off `citedSentenceIndex` and ignores the
        // block offset, so its exact value no longer matters.
        citationReturnContext = CitationReturnContext(
            citedOffset: plainTextOffset,
            citedSentenceIndex: targetIndex,
            canonicalBlockStartOffset: plainTextOffset,
            arrivedAt: Date()
        )
        jumpToOffset(plainTextOffset)
    }

    /// Clear the citation-return state. Called when the user taps
    /// the pill (which then re-opens the Ask Posey conversation).
    func clearCitationReturnContext() {
        citationReturnContext = nil
    }

    // ========== BLOCK VM-CITATION-RETURN: RETURN-TO-ASK-POSEY STATE - END ==========

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

    /// 2026-05-21 — Was `let document: Document` until the smart-skip
    /// prompt landed. Now `@Published private(set) var` so the user's
    /// "Start from Beginning" / "Jump to Chapter" choice can be
    /// persisted and the in-memory document updated in lockstep. Most
    /// fields on `Document` are stable across the reader's lifetime;
    /// only `playbackSkipUntilOffset` and `skipSource` change in
    /// response to the smart-skip prompt.
    @Published private(set) var document: Document
    /// True between `init` returning and the background content load
    /// completing. The reader view shows an "Opening this document…"
    /// overlay during this window so big documents (Illuminatus's
    /// 1.6M chars takes ~5–10s to segment via NLTokenizer) don't
    /// look frozen. For small docs the loading task completes before
    /// the first render cycle so the overlay never gets a chance to
    /// render.
    @Published private(set) var isLoading: Bool = true
    @Published private(set) var segments: [TextSegment] = []
    /// **Step 9 — units-based renderer.** Walking these and delegating
    /// each to `UnitRowView` IS the renderer. `segments` is kept as a
    /// derived flat array of sentence offsets that `SpeechPlaybackService`
    /// continues to consume; `units` + `sentences` are the visual /
    /// interaction surface.
    @Published private(set) var units: [ContentUnit] = []
    /// Pre-filtered sentence list — skip / content-end have already
    /// been applied so `sentences[currentSentenceIndex]` ≡
    /// `segments[currentSentenceIndex]` (same row across both arrays).
    @Published private(set) var sentences: [Sentence] = []
    /// Lookup table: unit_id → ordered sentences inside that unit.
    /// Pre-computed at content-load so `UnitRowView` doesn't have to
    /// filter the full sentence list on every redraw.
    @Published private(set) var sentencesByUnit: [UUID: [Sentence]] = [:]
    // Step 9 — `displayBlocks` deleted. The unified renderer walks
    // `units` and stages sentence highlight via `sentencesByUnit`.
    /// Table of contents entries for this document. Empty if not available.
    @Published private(set) var tocEntries: [StoredTOCEntry] = []

    /// 2026-05-22 — Filtered TOC view: entries strictly inside the
    /// document's body content range. The full `tocEntries` array
    /// preserves every NCX/nav entry the importer saw — including
    /// front-matter sections (title page, Millennium Fulcrum edition
    /// statement, in-prose Contents listing) and trailing sections
    /// (Project Gutenberg license, transcriber's notes). Those are
    /// not navigation targets a reader should see: tapping them
    /// would either land at offset 0 (when the offset is before the
    /// filtered segments range) or read aloud the license boilerplate
    /// the content-end detector already trimmed away.
    ///
    /// Filter: `offset >= playbackSkipUntilOffset` AND
    /// `offset < contentEndOffset` (when set; 0 means no trailer cap).
    var visibleTOCEntries: [StoredTOCEntry] {
        let skip = document.playbackSkipUntilOffset
        let end = document.contentEndOffset
        return tocEntries.filter { entry in
            guard entry.plainTextOffset >= skip else { return false }
            if end > 0 { return entry.plainTextOffset < end }
            return true
        }
    }
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
    ///
    /// Step 9 — units-based visual-pause maps. Keys: sentence index.
    /// Values: the `.image` unit's id whose "next sentence" triggers
    /// the pause. `visualPauseUnitIDsBySentenceIndex` is the raw set
    /// from `computeContentFromUnits`; the *Active* counterpart is
    /// applied by `applyVisualBlockMotionPolicy()` based on the user's
    /// imageHandling preference (.pauseAtImages vs .skipImages).
    private var visualPauseUnitIDsBySentenceIndex: [Int: UUID] = [:]
    private var visualPauseActiveUnitIDsBySentenceIndex: [Int: UUID] = [:]
    // 2026-06-15 — table visual-block maps (set at content-load; applied by
    // applyVisualBlockMotionPolicy per the unified `visualHandling` pref).
    private var tableSegmentIndices: Set<Int> = []
    private var tablePauseUnitIDsBySentenceIndex: [Int: UUID] = [:]
    private var tableAnnounceSentenceIndices: Set<Int> = []
    @Published private(set) var focusedUnitID: UUID? = nil
    private var acknowledgedVisualUnitIDs: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []
    private var didRunAutomationActions = false
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
        /// Step 9 — units + filtered sentences for the unified renderer.
        let units: [ContentUnit]
        let sentences: [Sentence]
        /// Sentence index → image-unit id. Drives pause-at-image when
        /// playback reaches the first sentence following an image.
        let visualPauseUnitIDsBySentenceIndex: [Int: UUID]
        /// Reader UI bundle #4 — sentence indices that begin a new
        /// page (first prose sentence after a `pageBreak` unit).
        /// Playback applies a brief preUtteranceDelay to each.
        let pageBreakPauseSentenceIndices: Set<Int>
        /// 2026-06-15 — Segment/sentence indices whose owning unit is a
        /// `.table` (rendered as an image). TTS glides PAST these — the head
        /// moves to the other side of the table like it does an image —
        /// while they stay in the segments array so search + read-along
        /// indexing are unaffected. Passed to `SpeechPlaybackService` as
        /// `skipSegmentIndices` (skip mode only).
        let tableSegmentIndices: Set<Int>
        /// First sentence index of each table → table unit id. In pause mode,
        /// playback pauses here (table visible) and reads the rows on resume.
        let tablePauseUnitIDsBySentenceIndex: [Int: UUID]
        /// First sentence after each table run — the "Table." spoken cue
        /// attaches here in skip mode (mirrors the image "Image." cue).
        let tableAnnounceSentenceIndices: Set<Int>
        /// 2026-05-27 — Each unit's offset in the FULL (pre-skip)
        /// plainText. Used by `annotationFlags(for:)` to map a unit
        /// to its plainText range so notes (anchored to full-plainText
        /// offsets in the DB) match the correct unit even when the
        /// reader's `units` array is the skip-filtered subset. Without
        /// this, the previous walk-and-accumulate ran cursor from 0
        /// on filtered units and produced ranges that didn't intersect
        /// any of the persisted note offsets — so annotation glyphs
        /// silently never rendered on any skipped doc.
        let fullPlainTextOffsetByUnitID: [UUID: Int]
    }

    /// Re-tag paragraph blocks whose `startOffset` matches a TOC
    /// entry's plainText offset as `.heading(level: N)`, where N is
    /// the level the importer captured (chapter title, section,
    /// subsection, …). Applies on the displayBlocks render path: MD
    /// (always), PDF (with outline), DOCX / HTML / EPUB when they
    /// emit displayBlocks (with images, or when the parser produces
    /// blocks for other reasons).
    ///
    /// Sentence-row docs (TXT, plain DOCX/HTML/EPUB) are handled by
    /// `headingLevel(forOffset:)` below, which the renderer consults
    /// per-row so plain-text formats also get level-aware heading
    /// styling — the parity policy that matters here.
    // Step 9 — `applyHeadingStyling` + `headingLevel(forSegmentStartOffset:)`
    // deleted. Real `.heading` units carry the level now.

    /// Heavy synchronous compute. Runs on a background dispatch queue
    /// from `loadContent`. Pure function (only reads from `document`),
    /// no MainActor-isolated state touched. The expensive piece is
    /// `SentenceSegmenter().segments(for: plainText)` which runs
    /// NLTokenizer over the entire plainText — for Illuminatus's
    /// 1.6M chars this takes ~5–10s and is the reason this pass
    /// can't run on init's main-thread call.
    /// 2026-05-23 Architecture rebuild — units fast path.
    ///
    /// Build the reader's `LoadedContent` from pre-fetched units +
    /// sentences instead of running `NLTokenizer` over a plainText
    /// string. The result is wire-compatible with the legacy
    /// `computeContent`: same `segments` shape, same `displayBlocks`
    /// shape, same `visualPauseMap`. Downstream reader machinery
    /// doesn't care which path produced its inputs.
    ///
    /// Offset coherence: segments carry global offsets into the
    /// joined plainText the persister wrote at import. The join
    /// rule is `units.map(\.text).joined(separator: "\n\n")`, so a
    /// unit's "global offset" is the running sum of preceding
    /// prose-unit lengths plus 2 per separator.
    nonisolated fileprivate static func computeContentFromUnits(
        document: Document,
        units: [ContentUnit],
        sentences: [Sentence],
        skipUnitSequence: Int?,
        contentEndUnitSequence: Int?
    ) -> LoadedContent {
        // Compute the cumulative plainText offset of each unit so
        // sentence intra-offsets can be lifted into the global
        // offset space the rest of the reader anchors to. Sequence
        // is monotonically increasing but possibly non-contiguous;
        // we walk units in their stored order.
        var cumulativeOffsetByUnitID: [UUID: Int] = [:]
        var cumulative = 0
        var skipGlobalOffset = 0
        var endGlobalOffset = 0
        for unit in units {
            cumulativeOffsetByUnitID[unit.id] = cumulative
            if let s = skipUnitSequence, unit.sequence == s {
                skipGlobalOffset = cumulative
            }
            if let e = contentEndUnitSequence, unit.sequence == e {
                endGlobalOffset = cumulative
            }
            // Only prose-bearing units contribute to the joined
            // plainText (matches persistParsedDocument's filter).
            if unit.kind.carriesProseText {
                cumulative += unit.text.count + 2 // "\n\n" separator
            }
        }

        // Build segments. Filter by skip / content-end ranges in
        // sequence space (cleaner than offset comparison; same
        // semantics).
        var segments: [TextSegment] = []
        for sentence in sentences {
            if let s = skipUnitSequence, sentence.unitSequence < s { continue }
            if let e = contentEndUnitSequence, sentence.unitSequence >= e { continue }
            let unitOffset = cumulativeOffsetByUnitID[sentence.unitID] ?? 0
            segments.append(TextSegment(
                id: segments.count,
                text: sentence.text,
                startOffset: unitOffset + sentence.intraStart,
                endOffset: unitOffset + sentence.intraEnd
            ))
        }

        // Step 9 — emit the filtered sentence list parallel to segments
        // so the renderer can walk it on a unit basis.
        var filteredSentences: [Sentence] = []
        filteredSentences.reserveCapacity(segments.count)
        for sentence in sentences {
            if let s = skipUnitSequence, sentence.unitSequence < s { continue }
            if let e = contentEndUnitSequence, sentence.unitSequence >= e { continue }
            filteredSentences.append(sentence)
        }
        // Filter the unit list by the same skip / content-end window
        // so the renderer doesn't render pre-skip / post-end units.
        //
        // 2026-05-28 (#73) — Exception: `.image` units below the skip
        // threshold survive the filter. EPUB cover preservation (#72)
        // emits a `.image` unit at sequence 10 for every Gutenberg-
        // declared cover, but the post-skip filter was dropping it
        // because the skip floor (gutenberg-source) lands far past
        // sequence 10. Image units don't have sentences, never enter
        // the segments array, and never play TTS — so leaving them in
        // the visual stream doesn't affect playback, just lets the
        // user scroll UP from the smart-skip opening position to
        // discover the cover. Post-end image units (after the EOF
        // marker) stay filtered — those are typically appendix images
        // the reader shouldn't see beyond the content-end boundary.
        // PageBreaks + horizontalRules stay filtered both ways because
        // they're structural dividers for prose flow, not standalone
        // content worth wading through pre-skip.
        let filteredUnits: [ContentUnit] = units.filter { unit in
            if let e = contentEndUnitSequence, unit.sequence >= e { return false }
            if let s = skipUnitSequence, unit.sequence < s {
                // Keep image units (e.g. EPUB covers) visible pre-skip
                // so the user can scroll up to see them. Drop everything
                // else.
                return unit.kind == .image
            }
            return true
        }

        // Visual-pause map (units flavor): for every `.image` unit,
        // find the first sentence in the *next* prose-bearing unit
        // and key the image unit's id by that sentence index.
        var visualPauseUnitIDsBySentenceIndex: [Int: UUID] = [:]
        for (uIdx, unit) in filteredUnits.enumerated() where unit.kind == .image {
            // Find the next prose-bearing unit after this image.
            for j in (uIdx + 1)..<filteredUnits.count {
                let candidate = filteredUnits[j]
                guard candidate.kind.carriesProseText else { continue }
                // First sentence of that unit (lowest intra_start).
                let firstSentence = filteredSentences.first { $0.unitID == candidate.id }
                if let s = firstSentence,
                   let sentenceIndex = filteredSentences.firstIndex(of: s) {
                    visualPauseUnitIDsBySentenceIndex[sentenceIndex] = unit.id
                }
                break
            }
        }

        // **Reader UI bundle #4 — page-break TTS pauses.** Same
        // pattern as the visual-pause map: for every `.pageBreak`
        // unit, locate the first sentence in the next prose unit
        // and record its index. The playback service applies a
        // ~0.4s preUtteranceDelay to those utterances. PageBreak
        // units carry no text and never enter the sentences array,
        // so they're never spoken or highlighted by construction.
        var pageBreakPauseSentenceIndices: Set<Int> = []
        for (uIdx, unit) in filteredUnits.enumerated() where unit.kind == .pageBreak {
            for j in (uIdx + 1)..<filteredUnits.count {
                let candidate = filteredUnits[j]
                guard candidate.kind.carriesProseText else { continue }
                let firstSentence = filteredSentences.first { $0.unitID == candidate.id }
                if let s = firstSentence,
                   let sentenceIndex = filteredSentences.firstIndex(of: s) {
                    pageBreakPauseSentenceIndices.insert(sentenceIndex)
                }
                break
            }
        }

        // 2026-06-15 — Table visual-block maps (tables mirror images during
        // playback, governed by the unified `visualHandling` preference).
        // `filteredSentences` is parallel to `segments`, so its index IS the
        // segment index.
        //   • tableSegmentIndices         — ALL table sentences. In skip mode
        //     these are glided past (kept in `segments` for search/highlight).
        //   • tablePauseUnitIDsBySentenceIndex — first sentence of each table
        //     run → table unit id. In pause mode playback pauses here (table
        //     visible); resuming reads the rows.
        //   • tableAnnounceSentenceIndices — first sentence AFTER each table
        //     run. In skip mode a spoken "Table." cue attaches here (the table
        //     sentences themselves are skipped, so the cue rides the next
        //     prose, exactly like the image "Image." cue).
        let tableUnitIDs = Set(filteredUnits.filter { $0.kind == .table }.map(\.id))
        var tableSegmentIndices: Set<Int> = []
        var tablePauseUnitIDsBySentenceIndex: [Int: UUID] = [:]
        var tableAnnounceSentenceIndices: Set<Int> = []
        if !tableUnitIDs.isEmpty {
            var prevUnitID: UUID? = nil
            var prevIsTable = false
            for (i, sentence) in filteredSentences.enumerated() {
                let isTable = tableUnitIDs.contains(sentence.unitID)
                if isTable {
                    tableSegmentIndices.insert(i)
                    if sentence.unitID != prevUnitID {          // first sentence of this table
                        tablePauseUnitIDsBySentenceIndex[i] = sentence.unitID
                    }
                } else if prevIsTable {                          // first sentence after a table
                    tableAnnounceSentenceIndices.insert(i)
                }
                prevUnitID = sentence.unitID
                prevIsTable = isTable
            }
        }

        // Suppress unused-parameter warnings on the bridge fields.
        _ = skipGlobalOffset
        _ = endGlobalOffset
        _ = document

        return LoadedContent(
            segments: segments,
            units: filteredUnits,
            sentences: filteredSentences,
            visualPauseUnitIDsBySentenceIndex: visualPauseUnitIDsBySentenceIndex,
            pageBreakPauseSentenceIndices: pageBreakPauseSentenceIndices,
            tableSegmentIndices: tableSegmentIndices,
            tablePauseUnitIDsBySentenceIndex: tablePauseUnitIDsBySentenceIndex,
            tableAnnounceSentenceIndices: tableAnnounceSentenceIndices,
            fullPlainTextOffsetByUnitID: cumulativeOffsetByUnitID
        )
    }

    // Step 9 — legacy `computeContent(for:)` deleted. Every importer
    // now persists `document_units` + `document_sentences`, so the
    // reader's only load path is `computeContentFromUnits(...)`.
    // The legacy path's invocations of NLTokenizer + *DisplayParser +
    // splitParagraphBlocks / buildVisualPauseIndexMap all die with
    // this deletion.

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

        // 2026-05-23 Architecture rebuild — units fast path.
        // If this document was imported via the new unit-based
        // importer, units + sentences are pre-computed and live in
        // the DB. Reader-open becomes a sub-second indexed SELECT
        // instead of a multi-second NLTokenizer pass. Otherwise we
        // fall back to the legacy compute path so formats that
        // haven't been flipped to units yet still work.
        let preloadedSentences: [Sentence]
        let preloadedUnits: [ContentUnit]
        do {
            let units = try databaseManager.units(for: document.id)
            if units.isEmpty {
                preloadedUnits = []
                preloadedSentences = []
            } else {
                preloadedUnits = units
                preloadedSentences = (try? databaseManager.sentences(for: document.id)) ?? []
            }
        } catch {
            preloadedUnits = []
            preloadedSentences = []
        }

        let computed: LoadedContent
        if preloadedUnits.isEmpty == false {
            // Units fast path — build segments directly from
            // pre-computed sentences. No NLTokenizer at open time.
            let document = self.document
            let units = preloadedUnits
            let sentences = preloadedSentences
            let skipSeq: Int? = {
                guard let skipID = (try? databaseManager.unitSkipReferences(for: document.id).skipUnitID) ?? nil else { return nil }
                return units.first(where: { $0.id == skipID })?.sequence
            }()
            let endSeq: Int? = {
                guard let endID = (try? databaseManager.unitSkipReferences(for: document.id).contentEndUnitID) ?? nil else { return nil }
                return units.first(where: { $0.id == endID })?.sequence
            }()
            computed = await Task.detached(priority: .userInitiated) {
                ReaderViewModel.computeContentFromUnits(
                    document: document,
                    units: units,
                    sentences: sentences,
                    skipUnitSequence: skipSeq,
                    contentEndUnitSequence: endSeq
                )
            }.value
        } else {
            // Step 9 — legacy path deleted. If a doc has zero units
            // it can't be rendered. This should never happen in
            // practice — every importer persists units. The loader
            // bails by leaving `segments` empty and clearing
            // `isLoading`; the reader shows an empty scrollview.
            computed = LoadedContent(
                segments: [],
                units: [],
                sentences: [],
                visualPauseUnitIDsBySentenceIndex: [:],
                pageBreakPauseSentenceIndices: [],
                tableSegmentIndices: [],
                tablePauseUnitIDsBySentenceIndex: [:],
                tableAnnounceSentenceIndices: [],
                fullPlainTextOffsetByUnitID: [:]
            )
        }

        // **Bundle 2e (2026-05-26)** — restore the saved position
        // BEFORE publishing the segments array. Large EPUBs used to
        // briefly render segment 0 (the post-skip first body sentence,
        // visually fine but a flicker on resume) before the onChange
        // scroll caught up. By computing the restored index against
        // `computed.segments` and seeding `currentSentenceIndex`
        // first, the first render already targets the right row.
        let restoredIndex: Int = {
            do {
                let position = try databaseManager.readingPosition(for: document.id)
                    ?? .initial(for: document.id)
                return Self.restoreSentenceIndex(
                    from: position,
                    segments: computed.segments,
                    skipUntil: document.playbackSkipUntilOffset
                )
            } catch {
                self.present(error)
                return 0
            }
        }()
        self.currentSentenceIndex = restoredIndex

        // 1. Heavy results — publish after currentSentenceIndex so
        // the first render lands on the right row.
        self.segments = computed.segments
        // Step 9 — units-based renderer state.
        self.units = computed.units
        self.sentences = computed.sentences
        self.visualPauseUnitIDsBySentenceIndex = computed.visualPauseUnitIDsBySentenceIndex
        // Reader UI bundle #4 — hand the playback service the
        // sentence indices that follow a page break so it can apply
        // a brief preUtteranceDelay to each.
        self.playbackService.pageBreakPauseSentenceIndices = computed.pageBreakPauseSentenceIndices
        // Store the table visual-block maps; the actual skip/pause/announce
        // wiring is applied by applyVisualBlockMotionPolicy() (below) based on
        // the `visualHandling` preference — not unconditionally here.
        self.tableSegmentIndices = computed.tableSegmentIndices
        self.tablePauseUnitIDsBySentenceIndex = computed.tablePauseUnitIDsBySentenceIndex
        self.tableAnnounceSentenceIndices = computed.tableAnnounceSentenceIndices
        var byUnit: [UUID: [Sentence]] = [:]
        for sentence in computed.sentences {
            byUnit[sentence.unitID, default: []].append(sentence)
        }
        self.sentencesByUnit = byUnit
        self.sentenceIndexBaseByUnit.removeAll(keepingCapacity: true)
        self.unitAnnotationCache.removeAll(keepingCapacity: true)
        self.fullPlainTextOffsetByUnitID = computed.fullPlainTextOffsetByUnitID
        self.applyVisualBlockMotionPolicy()

        // 2. DB side dishes (cheap).
        self.tocEntries = (try? databaseManager.tocEntries(for: document.id)) ?? []
        self.pageMap = DocumentPageMap.build(
            for: document,
            tocEntries: self.tocEntries,
            units: self.units,
            plainTextOffsetByUnitID: self.fullPlainTextOffsetByUnitID)

        // 3. Prepare playback for the restored index.
        self.playbackService.prepare(at: self.currentSentenceIndex)

        // 4. Subscribe to playback events. Done AFTER prepare so the
        //    initial sink emission carries the restored sentence
        //    index, not a stale zero.
        self.observePlayback()

        // 5. Surface the reader.
        self.isLoading = false

        // 5a. 2026-05-21 — Smart skip prompt. Fire AFTER the reader is
        // visible so the user can see what they're being asked about
        // (content sitting at the heuristic skip position). Gutenberg
        // skips return false from shouldPromptForSkip and never trigger
        // this dialog. The flag stays true until the user picks Jump
        // to Chapter or Start from Beginning; both handlers persist
        // skipSource so this won't fire again on relaunch.
        if self.shouldPromptForSkip {
            self.isPresentingSkipPrompt = true
        }

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

    // Step 9 — `usesDisplayBlocks` deleted; the renderer no longer
    // has dual paths.

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
            focusedUnitID = nil
            playbackState = .playing
            playbackService.play(segments: segments, startingAt: currentSentenceIndex)
        case .idle, .finished:
            focusedUnitID = nil
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
        focusedUnitID = nil
        currentSentenceIndex = 0
        playbackService.stop()
        playbackService.prepare(at: currentSentenceIndex)
        persistPosition()
    }

    /// 2026-06-03 — TTS-verify harness driver. Starts LIVE playback fresh from
    /// `idx` (the same real playback path a user gets), so the harness's mic
    /// recording and the highlight log it captures share one clock.
    func ttsVerifyStartPlayback(fromSentence idx: Int) {
        guard !segments.isEmpty else { return }
        focusedUnitID = nil
        let bounded = max(0, min(idx, segments.count - 1))
        currentSentenceIndex = bounded
        playbackState = .playing
        playbackService.restart(segments: segments, startingAt: bounded)
    }

    /// Pause the live playback the harness started (invoked via the harness's
    /// onStop when a run ends).
    func ttsVerifyStopPlayback() {
        playbackService.pause()
        playbackState = .paused
        persistPosition()
    }

    /// 2026-05-07 (parity #8): test-only state forcer. Routes the
    /// antenna's `DEBUG_FORCE_PLAYBACK_STATE` verb through the view
    /// model so external tests can set up state transitions that
    /// would otherwise require playing real audio (e.g. .finished
    /// from natural end-of-doc).
    func debugForcePlaybackState(_ stateName: String) {
        let target: SpeechPlaybackService.PlaybackState
        switch stateName.lowercased() {
        case "playing":  target = .playing
        case "paused":   target = .paused
        case "finished": target = .finished
        default:         target = .idle
        }
        playbackService.debugForceState(target)
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
        } catch DatabaseManager.DatabaseError.foreignKeyViolation {
            // Document was deleted under us (RESET_ALL / swipe-delete /
            // DELETE_DOCUMENT verb fired while the reader was still
            // mounted). Position is meaningless once the doc is gone —
            // silent no-op, not a scary alert.
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
        // Step 9 — units-based scroll. The match's sentence belongs
        // to a unit; scroll to that unit's id.
        guard idx < sentences.count else { return }
        let scrollID = sentences[idx].unitID
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

    /// 2026-06-15 — The unit that owns the CURRENT search match (Mark's
    /// "search hit inside a table/image should highlight the table"). For
    /// a `.table` / `.image` unit the per-sentence text highlight can't
    /// show — the searchable text sits behind the rendered image — so the
    /// renderer flags the whole image instead. Returns the owning unit id
    /// of the current match segment, or nil when there's no active match.
    var currentSearchMatchUnitID: UUID? {
        guard let pos = currentSearchMatchPosition,
              searchMatchIndices.indices.contains(pos) else { return nil }
        let idx = searchMatchIndices[pos]
        guard sentences.indices.contains(idx) else { return nil }
        return sentences[idx].unitID
    }

    // Step 9 — isSearchMatch(block:) + isCurrentSearchMatch(block:)
    // deleted. The unified renderer doesn't render DisplayBlocks.

    private func emitSearchScroll(to segmentIndex: Int) {
        searchScrollCounter += 1
        searchScrollSignal = SearchScrollSignal(segmentIndex: segmentIndex, id: searchScrollCounter)
    }

    // ========== BLOCK VM-SEARCH: SEARCH METHODS - END ==========

    func isActive(segment: TextSegment) -> Bool {
        segment.id == currentSentenceIndex
    }

    /// M8 Immersive/Motion render distance — how many rows away the
    /// segment is from the active sentence. Active row returns 0,
    /// neighbours return 1, and so on. Used by the render path to
    /// derive opacity + scale falloff curves.
    func distanceFromActive(segment: TextSegment) -> Int {
        return abs(segment.id - currentSentenceIndex)
    }

    // Step 9 — distanceFromActive(block:) + isActive(block:) deleted.
    // The unified renderer doesn't render DisplayBlocks.

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

    // Step 9 — annotationSymbol(for: block), displayText(for: block),
    // font(for: block), fontWeight(for: block) all deleted. The
    // unified UnitRowView renders by `unit.kind` and resolves notes
    // by intersecting note offsets against the unit's text range
    // (annotation indicators are a follow-up polish — they were on
    // the legacy renderer's row chrome which is now gone).

    // 2026-06-08 (audit fix #4) — the static heading typography helpers
    // (headingFontSize / headingWeight / headingTopSpacing) were removed:
    // they were an unused duplicate of the live heading typography in
    // UnitRowView, which is the single source of truth post-Step-9.

    // Step 9 — foregroundStyle(for: block) deleted; UnitRowView styles
    // by kind directly (blockquote uses italic + secondary indent bar;
    // images use a placeholder if image data is missing).

    func previewText(for note: Note) -> String {
        guard let index = segments.firstIndex(where: { segment in
            note.startOffset >= segment.startOffset && note.startOffset < segment.endOffset
        }) else {
            return document.title
        }

        return segments[index].text
    }

    /// 2026-05-22 — One-shot anchor override consumed by the next
    /// `scrollToCurrentSentence` call. Defaults to `.center` (matches
    /// active-sentence centering during playback). TOC chapter taps
    /// set this to `.top` so the chapter heading pins to the top of
    /// the visible area on navigation — "Jump to chapter II" should
    /// land you AT chapter II, not in the middle of the screen with
    /// chapter I's last few lines visible above. Reset to `.center`
    /// after each scroll so the next sentence advance during playback
    /// re-centers normally.
    private var nextScrollAnchor: UnitPoint = .center

    func scrollToCurrentSentence(with proxy: ScrollViewProxy, animated: Bool) {
        // Visual-pause `focusedUnitID` wins when set so the user
        // lands on the image row that just paused playback.
        let scrollTargetID: UUID
        if let focusedUnitID {
            scrollTargetID = focusedUnitID
        } else if let activeUnitID {
            scrollTargetID = activeUnitID
        } else {
            return
        }

        let anchor = nextScrollAnchor
        nextScrollAnchor = .center

        // 2026-05-28 (post-cross-sentence-selection-fix) — units are
        // now single UITextView rows again (one render surface per
        // unit so native selection spans all sentences in the unit).
        // c13 auto-scroll fix (2026-06-04): for the STANDARD reader's
        // playback advance, pin the active SENTENCE to a fixed upper-third
        // viewport position (Apple-Music-lyrics behavior) instead of anchoring
        // the whole UNIT.
        //
        // The prior code set `anchor = UnitPoint(x:0.5, y:(k+0.5)/N)` on the
        // unit. Because `scrollTo` applies one anchor to BOTH the view and the
        // viewport, that placed sentence k of N at viewport-fraction k/N — so
        // as TTS advanced through a multi-sentence unit the line marched DOWN
        // the screen (0.05→0.95) before the next unit reset it. That sawtooth
        // is exactly the "highlight drifting down the screen" (measured: median
        // ~0.6, only ~10% in the top third, reaching the bottom edge).
        //
        // Fix: during PLAYBACK, `scrollToActiveAnchor` scrolls the backing
        // UIScrollView so the active SENTENCE's measured glyph rect sits at a
        // fixed `activeLineAnchorY` of the viewport — independent of where the
        // sentence sits within its unit. So we SKIP the unit scroll here during
        // playback (it's handled per-line by scrollToActiveAnchor). When NOT
        // playing (manual nav, TOC `.top`, visual-pause `focusedUnitID`), the
        // normal unit scroll applies.
        if focusedUnitID == nil, playbackState == .playing, activeProseTextView != nil {
            return
        }

        let action = { proxy.scrollTo(scrollTargetID, anchor: anchor) }
        if animated && !Self.reduceMotionEnabled {
            withAnimation(.easeInOut(duration: 0.25), action)
        } else {
            action()
        }
    }

    /// 2026-06-13 (DEFECT-reader-open-position-anchor) — the OPEN/RESUME scroll.
    /// Pins the landing unit to the TOP of the viewport, not `.center`. Centering
    /// pushed a long first unit's HEAD above the fold (P&P's preface → opened
    /// mid-paragraph; illustrated-alice → chapter heading scrolled off). On open
    /// the reader wants the START of the content visible. Mirrors the existing
    /// `.top` intent of TOC-tap / page nav (`jumpToTOCEntry` / `jumpToPage`);
    /// SEARCH (`scrollToSearchMatch`) and live-playback tracking keep their
    /// contextual `.center` anchor — this is the initial open scroll only.
    func scrollToContentStartOnOpen(with proxy: ScrollViewProxy, animated: Bool) {
        nextScrollAnchor = .top
        scrollToCurrentSentence(with: proxy, animated: animated)
    }

    /// c13: the fixed viewport fraction the active line is pinned to (upper
    /// third — Apple-Music-lyrics). Mark's sign-off: ~0.35.
    static let activeLineAnchorY: CGFloat = 0.35

    /// c13 upper-third pin (standard reader, during playback). Scrolls the
    /// backing UIScrollView so the active sentence's LIVE glyph rect sits at
    /// `activeLineAnchorY` of the viewport. Recomputes the rect from the current
    /// layout (always fresh). Falls back to the SwiftUI unit scroll if the
    /// UIScrollView can't be located. `proxy` retained for that fallback.
    func scrollToActiveAnchor(with proxy: ScrollViewProxy) {
        guard focusedUnitID == nil, playbackState == .playing,
              let tv = activeProseTextView, let range = activeProseRange,
              tv.window != nil else { return }
        // Walk up to the backing UIScrollView (SwiftUI ScrollView's UIKit host).
        var ancestor: UIView? = tv.superview
        while let v = ancestor, !(v is UIScrollView) { ancestor = v.superview }
        guard let scroll = ancestor as? UIScrollView, scroll.bounds.height > 0 else {
            if let unitID = activeUnitID {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(unitID, anchor: UnitPoint(x: 0.5, y: Self.activeLineAnchorY))
                }
            }
            return
        }
        // Active sentence glyph rect → content-Y in the scroll view, then set
        // contentOffset so it lands at activeLineAnchorY of the visible height.
        let lm = tv.layoutManager
        // Force complete layout first: a freshly-scrolled-in row's glyphs may not
        // be fully laid out yet, which would yield a short/low boundingRect and a
        // slightly-off pin that accumulates into a downward creep over a run.
        lm.ensureLayout(for: tv.textContainer)
        let glyph = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyph, in: tv.textContainer)
        rect = rect.offsetBy(dx: tv.textContainerInset.left, dy: tv.textContainerInset.top)
        let contentMidY = tv.convert(rect, to: scroll).midY
        let targetY = contentMidY - Self.activeLineAnchorY * scroll.bounds.height
        let maxOffset = max(0, scroll.contentSize.height - scroll.bounds.height)
        let newY = min(max(0, targetY), maxOffset)
        let action = { scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: newY), animated: !Self.reduceMotionEnabled) }
        action()
    }

    private var currentSegment: TextSegment? {
        guard segments.indices.contains(currentSentenceIndex) else {
            return nil
        }
        return segments[currentSentenceIndex]
    }

    // Step 9 — `currentDisplayBlockID` deleted. `activeUnitID` is the
    // replacement; scrollToCurrentSentence consumes it directly.

    private func boundedSentenceIndex(_ candidate: Int) -> Int {
        guard segments.isEmpty == false else {
            return 0
        }
        return min(max(candidate, 0), segments.count - 1)
    }

    private func restoreSentenceIndex(from position: ReadingPosition) -> Int {
        Self.restoreSentenceIndex(
            from: position,
            segments: segments,
            skipUntil: document.playbackSkipUntilOffset
        )
    }

    /// **Bundle 2e (2026-05-26)** — pure variant callable before
    /// `self.segments` is set. Lets `loadContent` compute the
    /// restored index from the freshly-loaded segments array and
    /// seed `currentSentenceIndex` BEFORE publishing segments, so
    /// the very first render lands on the right row.
    nonisolated fileprivate static func restoreSentenceIndex(
        from position: ReadingPosition,
        segments: [TextSegment],
        skipUntil: Int
    ) -> Int {
        guard segments.isEmpty == false else { return 0 }
        if skipUntil > 0, position.characterOffset < skipUntil { return 0 }
        if let offsetMatch = segments.firstIndex(where: { segment in
            position.characterOffset >= segment.startOffset && position.characterOffset < segment.endOffset
        }) {
            return offsetMatch
        }
        // Fallback: clamp the saved sentenceIndex to range.
        return max(0, min(position.sentenceIndex, segments.count - 1))
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
        // Step 9 — sentence-level marker nav (delete legacy block-jump
        // path). Previous / Next move by one sentence in the
        // pre-filtered sentences list.
        let nextSentenceIndex = currentSentenceIndex + direction
        guard segments.indices.contains(nextSentenceIndex) else {
            return nil
        }
        return nextSentenceIndex
    }

    private func jump(toSentenceIndex sentenceIndex: Int, shouldRestartPlayback: Bool) {
        let boundedIndex = boundedSentenceIndex(sentenceIndex)
        focusedUnitID = nil
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
        // Step 9 — legacy block branch deleted. Units-aware path is
        // the only path now; entry point keeps its name so playback
        // service callers don't need rewiring.
        pauseForVisualUnitIfNeeded(atSentenceIndex: sentenceIndex)
    }

    private func pauseForVisualUnitIfNeeded(atSentenceIndex sentenceIndex: Int) {
        guard playbackService.state == .playing,
              let visualUnitID = visualPauseActiveUnitIDsBySentenceIndex[sentenceIndex],
              acknowledgedVisualUnitIDs.contains(visualUnitID) == false else {
            return
        }
        acknowledgedVisualUnitIDs.insert(visualUnitID)
        focusedUnitID = visualUnitID
        playbackService.pause()
    }

    /// 2026-05-13 (A1) — applies the Motion-aware non-text-element policy.
    ///
    /// Posey reads + listens in two distinct user contexts that the Motion
    /// reading style explicitly separates:
    ///
    /// **Motion ON (`readingStyle == .motion`)** — user is moving (walking,
    /// commuting). Pausing playback at every image breaks flow. Instead:
    ///   - The active pause map is empty (no stop blocks)
    ///   - The speech engine gets an "Image." prefix on the first sentence
    ///     after each visualPlaceholder so the listener hears an audible
    ///     cue without losing prose continuity
    ///
    /// **Every other reading style** — user is stationary (Standard, Focus,
    /// Immersive). Inspecting visuals is desirable. The pause map is
    /// populated; reaching the sentence after a visualPlaceholder pauses
    /// the synthesizer. User taps the inline Continue affordance (or the
    /// chrome's Play button) to resume.
    ///
    /// This unifies behavior across every format. PDF used to ALWAYS pause
    /// at visual pages regardless of readingStyle — this method changes
    /// that so PDF follows the same Motion-aware logic as EPUB/DOCX/HTML.
    /// Called once at content load and again on every `readingStyle` change.
    /// 2026-05-16 — Now keyed off the explicit `imageHandling`
    /// preference (Pause vs Skip), replacing the prior implicit
    /// pause-when-Motion-on rule. `.skipImages` plays a brief
    /// "Image." announcement; `.pauseAtImages` stops playback at the
    /// image and surfaces the inline Continue affordance.
    func applyVisualBlockMotionPolicy() {
        // Step 9 — units flavor only. .skipImages → empty active map
        // + per-image announcement. .pauseAtImages → active map mirrors
        // the raw map; playback service stays silent at the image.
        switch visualHandling {
        case .skipVisuals:
            // No pause. Each image boundary speaks "Image."; each table's
            // trailing boundary speaks "Table." and the table's own sentences
            // are glided past (skipSegmentIndices).
            visualPauseActiveUnitIDsBySentenceIndex = [:]
            var announcements: [Int: String] = [:]
            for (sentenceIndex, _) in visualPauseUnitIDsBySentenceIndex {
                announcements[sentenceIndex] = "Image."
            }
            for sentenceIndex in tableAnnounceSentenceIndices {
                announcements[sentenceIndex] = "Table."
            }
            playbackService.visualAnnouncementText = announcements
            playbackService.skipSegmentIndices = tableSegmentIndices
        case .pauseAtVisuals:
            // Pause at each image boundary AND at the first sentence of each
            // table (table visible; its rows are read on resume → no skip).
            var active = visualPauseUnitIDsBySentenceIndex
            for (sentenceIndex, unitID) in tablePauseUnitIDsBySentenceIndex {
                active[sentenceIndex] = unitID
            }
            visualPauseActiveUnitIDsBySentenceIndex = active
            playbackService.visualAnnouncementText = [:]
            playbackService.skipSegmentIndices = []
        }
    }

    // Step 9 — `buildVisualPauseIndexMap` + `sentenceIndex(forOffset:)`
    // static + `splitParagraphBlocks` all deleted. The units flavor
    // (`computeContentFromUnits` → `visualPauseUnitIDsBySentenceIndex`)
    // is the only path. Sentence rows are no longer derived from
    // paragraph splitting either — the units pipeline computes
    // sentences at import time via `SentenceIndexer`.

    private func loadNotes() {
        do {
            notes = try databaseManager.notes(for: document.id)
        } catch {
            present(error)
        }
        // Step 9 carve-out — annotation indicators on unit rows.
        // Whenever the notes list refreshes, the per-unit flag
        // cache needs a wipe so the next render reflects new /
        // deleted annotations.
        invalidateUnitAnnotationCache()
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
            // 2026-05-07 (punch list #7): for notes with a real body,
            // show the body in the preview row — that's what the user
            // wrote and what's most useful to scan at a glance. The
            // expanded row still shows the body (now redundantly) plus
            // a Jump button. For bookmarks (no body) and notes that
            // were saved without a body, fall back to the anchor
            // sentence at the note's offset (the previous behavior).
            let isBookmark = note.kind == .bookmark
            let preview: String
            if !isBookmark, let body = note.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                preview = body
            } else {
                preview = previewText(for: note)
            }
            entries.append(SavedAnnotation(
                id: "note:\(note.id.uuidString)",
                kind: isBookmark ? .bookmark : .note,
                anchorText: preview,
                offset: note.startOffset,
                timestamp: note.createdAt,
                body: note.body,
                conversationStorageID: nil,
                noteID: note.id
            ))
        }
        // 2026-05-16 — Belt-and-suspenders: Ask Posey conversation rows
        // only surface in Saved Annotations when the Ask Posey UI is
        // compiled in (POSEY_ENABLE_ASK_POSEY). Posey 1.0 ships without
        // Ask Posey enabled; a user who somehow has pre-existing
        // conversation rows in their database (e.g. TestFlight upgrade)
        // would otherwise still see them surface here even though the
        // sheet is gone. The rows remain on disk — the build flag
        // controls visibility, not data deletion.
        #if POSEY_ENABLE_ASK_POSEY
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
        #endif
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
        } catch DatabaseManager.DatabaseError.foreignKeyViolation {
            // Doc deleted under us — benign.
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

    /// First `.image` unit whose imageID resolves to real bytes. Used by the
    /// `remoteOpenFirstImage` (c7) verification verb to open the same
    /// full-screen viewer the image-tap handler opens (6a8fc08).
    func firstImageIDWithBytes() -> String? {
        for unit in units where unit.kind == .image {
            if let id = unit.metadata.imageID, imageData(for: id) != nil {
                return id
            }
        }
        return nil
    }

    // ========== BLOCK VM-IMAGE: IMAGE LOADING - END ==========

    // ========== BLOCK VM-UNIT: UNIT-ROW HELPERS - START ==========

    /// Cached lookup: `unit.id → flat-array index of its first sentence
    /// in `sentences``. Rebuilt whenever the sentence list changes.
    /// Empty until content loads.
    private var sentenceIndexBaseByUnit: [UUID: Int] = [:]

    /// Returns the flat-array index of the FIRST sentence whose
    /// `unitID == unit.id` in the document's filtered sentence list.
    /// Used by `UnitRowView` to derive each sentence's global flat
    /// index (base + position-within-unit) so distance-from-active
    /// can be computed without scanning the whole list per redraw.
    /// Falls back to `currentSentenceIndex` for non-prose units —
    /// distance 0 keeps them at full opacity (they have no
    /// sentences anyway, so the value doesn't matter visually).
    func sentenceIndexBase(for unit: ContentUnit) -> Int {
        if let cached = sentenceIndexBaseByUnit[unit.id] { return cached }
        // Lazy compute + cache. Linear in the flat list; called once
        // per unit per content load, so cheap in aggregate.
        for (idx, sentence) in sentences.enumerated() where sentence.unitID == unit.id {
            sentenceIndexBaseByUnit[unit.id] = idx
            return idx
        }
        return currentSentenceIndex
    }

    /// Per-unit annotation flags. Computed by intersecting the
    /// document's notes list against the unit's plainText range —
    /// `[unitStart, unitEnd)` in the joined plainText coordinate
    /// space. Cached on the VM so the per-row recompute stays
    /// cheap; cache invalidated on note insert/delete.
    private var unitAnnotationCache: [UUID: (hasNote: Bool, hasBookmark: Bool)] = [:]

    /// 2026-05-27 — Each unit's offset in the FULL (pre-skip) plainText.
    /// Populated by loadContent from LoadedContent.fullPlainTextOffsetByUnitID.
    /// Used by annotationFlags to compute each unit's plainText range
    /// in DB-aligned coordinates (notes are anchored to full-plainText
    /// offsets; walking the filtered units array from cursor=0 produces
    /// post-skip-local offsets that don't intersect note offsets).
    private var fullPlainTextOffsetByUnitID: [UUID: Int] = [:]

    struct UnitAnnotationFlags {
        let hasNote: Bool
        let hasBookmark: Bool
    }

    /// Public accessor (called from ReaderView's ForEach). Builds the
    /// cache lazily — the first call for a doc walks the unit list to
    /// compute every unit's plainText range; subsequent calls hit the
    /// cache.
    func annotationFlags(for unit: ContentUnit) -> UnitAnnotationFlags {
        if let cached = unitAnnotationCache[unit.id] {
            return UnitAnnotationFlags(hasNote: cached.hasNote, hasBookmark: cached.hasBookmark)
        }
        // 2026-05-27 — use the full-plainText offset map instead of
        // walking-and-accumulating cursor on the filtered units. Notes
        // are persisted at full-plainText offsets (the unfiltered
        // joined-prose offset space); annotationFlags must compute the
        // unit's range in that same coordinate space. The previous
        // walk started cursor=0 on the FILTERED units array, producing
        // post-skip-local ranges that never intersected any persisted
        // note offset on a doc with non-zero skip — so glyphs silently
        // didn't render. Bug #annotation-glyph.
        guard let foundStart = fullPlainTextOffsetByUnitID[unit.id], unit.kind.carriesProseText else {
            // Non-prose units (image, pageBreak, horizontalRule) can't
            // carry annotations directly. Cache + return empty.
            let flags = (hasNote: false, hasBookmark: false)
            unitAnnotationCache[unit.id] = flags
            return UnitAnnotationFlags(hasNote: false, hasBookmark: false)
        }
        let foundEnd = foundStart + unit.text.count
        // Intersect notes against the unit's range.
        var hasNote = false
        var hasBookmark = false
        for note in notes where note.startOffset >= foundStart && note.startOffset < foundEnd {
            switch note.kind {
            case .note:     hasNote = true
            case .bookmark: hasBookmark = true
            }
            if hasNote && hasBookmark { break }
        }
        let flags = (hasNote: hasNote, hasBookmark: hasBookmark)
        unitAnnotationCache[unit.id] = flags
        return UnitAnnotationFlags(hasNote: hasNote, hasBookmark: hasBookmark)
    }

    /// Invalidate the unit-annotation cache. Called after a note
    /// insert / delete so the next row redraw sees fresh flags.
    func invalidateUnitAnnotationCache() {
        unitAnnotationCache.removeAll(keepingCapacity: true)
        // Bump the Published version so the SwiftUI ForEach body
        // re-runs annotationFlags(for:) on every visible unit.
        unitAnnotationVersion &+= 1
    }

    /// **Reader UI bundle #3.** Return the half-open plainText offset
    /// range `[unitStart, unitEnd)` for a given unit — the same
    /// coordinate space `notes.startOffset` uses. Helper for
    /// `openAnnotationFromGlyph` to find which notes belong to a
    /// tapped row.
    func plainTextRange(for unit: ContentUnit) -> Range<Int> {
        var cursor = 0
        var firstProseSeen = false
        for u in units {
            if !u.kind.carriesProseText { continue }
            if firstProseSeen { cursor += 2 }
            firstProseSeen = true
            let start = cursor
            let end = cursor + u.text.count
            cursor = end
            if u.id == unit.id { return start..<end }
        }
        return 0..<0
    }

    // ========== BLOCK VM-UNIT: UNIT-ROW HELPERS - END ==========

    // ========== BLOCK VM-TOC: TABLE OF CONTENTS NAVIGATION - START ==========

    /// Jumps playback and scroll position to the chapter heading at a
    /// TOC entry's plainTextOffset. Stops any active playback before
    /// jumping.
    ///
    /// 2026-05-22 — Two changes over the previous behavior:
    /// 1. Pick the first segment at-or-AFTER the TOC offset (not
    ///    at-or-before). The TOC offset points to the chapter heading;
    ///    `at-or-before` lands the user on the last sentence of the
    ///    PREVIOUS chapter, which is the opposite of what "jump to
    ///    Chapter II" should do. Page-jumps and TOC-walker offsets
    ///    use the same convention: the offset is the START of the
    ///    target region, so the first segment whose startOffset >= it
    ///    is what the user wants.
    /// 2. Request `.top` scroll anchor so the chapter heading pins to
    ///    the top of the visible area rather than centering.
    ///    Navigation should feel like navigation.
    func jumpToTOCEntry(_ entry: StoredTOCEntry) {
        stopPlayback()
        nextScrollAnchor = .top
        let target = entry.plainTextOffset
        let targetIndex = segments.firstIndex(where: { $0.startOffset >= target })
            ?? max(0, segments.count - 1)
        currentSentenceIndex = targetIndex
        persistPosition()
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

    /// **Step 9 — sentence-precise tap.**
    ///
    /// Dispatch target for `posey-sentence://<sentence-uuid>` taps
    /// fired by `UnitRowView`'s per-sentence link ranges. Resolves
    /// the sentence to its index in the flat `sentences` array
    /// (which mirrors `segments` 1-1 post-filter) and snaps
    /// playback there.
    func jumpToSentenceID(_ sentenceID: UUID) {
        guard let idx = sentences.firstIndex(where: { $0.id == sentenceID }) else { return }
        stopPlayback()
        currentSentenceIndex = idx
        persistPosition()
    }

    /// The sentence currently active for highlight / TTS. Equal to
    /// `sentences[currentSentenceIndex]` when in bounds, otherwise
    /// nil — used by `UnitRowView` to decide whether to draw the
    /// active-sentence background tint.
    var activeSentence: Sentence? {
        guard currentSentenceIndex >= 0, currentSentenceIndex < sentences.count else { return nil }
        return sentences[currentSentenceIndex]
    }

    /// The unit that contains the active sentence. Used by
    /// `scrollToCurrentSentence` to scroll to the right row.
    var activeUnitID: UUID? { activeSentence?.unitID }

    /// c13 auto-scroll fix (2026-06-04): the live (UITextView, sentence range)
    /// of the active prose line, published by `ProseUnitTextView`. `activeLineTick`
    /// bumps on each update to drive the upper-third pin scroll
    /// (`scrollToActiveAnchor`), which computes the glyph rect from these and
    /// scrolls the backing UIScrollView. `weak` so a recycled row's textview
    /// can't leak. This does NOT split the renderer — one UITextView per unit,
    /// native cross-sentence selection preserved.
    weak var activeProseTextView: UITextView?
    var activeProseRange: NSRange?
    @Published var activeLineTick: Int = 0
    func setActiveProseLine(_ textView: UITextView, _ range: NSRange) {
        // Dedup: ProseUnitTextView.updateUIView can fire several times per
        // sentence change; only bump the tick (→ one pin scroll) when the active
        // line actually changed. Avoids redundant scroll churn / oscillation.
        if activeProseTextView === textView, activeProseRange == range { return }
        activeProseTextView = textView
        activeProseRange = range
        activeLineTick &+= 1
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
        // 2026-05-22 — Same navigation intent as TOC tap: pin the
        // destination at the top of the visible area, not the center,
        // AND pick the first segment at-or-AFTER the page-start offset
        // (not at-or-before, which would land on the previous page's
        // last sentence).
        nextScrollAnchor = .top
        let targetIndex = segments.firstIndex(where: { $0.startOffset >= offset })
            ?? max(0, segments.count - 1)
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

/// 2026-06-14 (c7) — the full-screen image-viewer `.sheet` plus the
/// `remoteOpenFirstImage` antenna-verb observer, bundled into ONE `ViewModifier`
/// so the top-level ReaderView body chain stays short enough for the Swift
/// type-checker (its own `body` type-checks independently — attaching the sheet
/// AND a `.background`/`.onReceive` inline overflowed it). The observer resolves
/// the first image-with-bytes and sets `expandedImageItem` — the SAME thing the
/// image `.onTapGesture` (6a8fc08) does — so the tap-opens-viewer half of c7 is
/// verifiable on a physical phone (where a real touch on the image element can't
/// be synthesized through the antenna).
struct ExpandedImageModifier: ViewModifier {
    @Binding var expandedImageItem: ExpandedImageItem?
    let viewModel: ReaderViewModel
    func body(content: Content) -> some View {
        content
            .sheet(item: $expandedImageItem) { item in
                ExpandedImageSheet(imageID: item.id, viewModel: viewModel)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteOpenFirstImage)) { _ in
                if let imageID = viewModel.firstImageIDWithBytes() {
                    expandedImageItem = ExpandedImageItem(id: imageID)
                }
            }
    }
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

    /// 2026-05-13 (A1b) — top-of-sheet tab between Contents (existing
    /// chapter list) and Images (thumbnails of every visualPlaceholder
    /// in the doc with the surrounding sentence as context). Hidden
    /// when the doc has zero images so the picker doesn't appear on
    /// text-only docs.
    enum TOCTab: String, CaseIterable, Identifiable {
        case contents = "Contents"
        case images = "Images"
        var id: String { rawValue }
    }
    @State private var selectedTab: TOCTab = .contents

    /// Image entries derived from `.image` units. Each entry pairs the
    /// unit's imageID with the document offset (the next sentence's
    /// startOffset) and a context sentence. Tap → jumpToOffset(offset)
    /// + dismiss.
    private struct ImageEntry: Identifiable {
        let id: UUID
        let imageID: String?
        let offset: Int
        let contextSentence: String
    }
    private var imageEntries: [ImageEntry] {
        let segments = viewModel.segments
        let sentences = viewModel.sentences
        let units = viewModel.units
        return units
            .enumerated()
            .filter { _, unit in unit.kind == .image }
            .map { idx, unit -> ImageEntry in
                // Context: first sentence in the next prose-bearing
                // unit after this image; falls back to the image
                // caption (unit.text).
                var context = unit.text
                var offset = 0
                if let nextProse = units[(idx + 1)...].first(where: { $0.kind.carriesProseText }),
                   let nextSentence = sentences.first(where: { $0.unitID == nextProse.id }),
                   let segIdx = sentences.firstIndex(of: nextSentence),
                   segments.indices.contains(segIdx) {
                    context = segments[segIdx].text
                    offset = segments[segIdx].startOffset
                }
                return ImageEntry(
                    id: unit.id,
                    imageID: unit.metadata.imageID,
                    offset: offset,
                    contextSentence: context
                )
            }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !imageEntries.isEmpty {
                    Picker("View", selection: $selectedTab) {
                        ForEach(TOCTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .accessibilityIdentifier("toc.tabPicker")
                }

                if selectedTab == .images && !imageEntries.isEmpty {
                    imagesList
                } else {
                    contentsList
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
            .onReceive(
                NotificationCenter.default.publisher(for: .remoteTapTOCEntry)
            ) { note in
                guard let playOrder = note.userInfo?["playOrder"] as? Int,
                      let entry = viewModel.visibleTOCEntries.first(where: { $0.playOrder == playOrder })
                else { return }
                viewModel.jumpToTOCEntry(entry)
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

    /// 2026-05-13 (A1b) — image-tab list. Small leading thumbnail
    /// (44×44, scaledToFit, rounded) plus the surrounding sentence
    /// as caption. Tap → jumpToOffset + dismiss.
    private var imagesList: some View {
        List {
            ForEach(imageEntries) { entry in
                Button {
                    viewModel.jumpToOffset(entry.offset)
                    dismiss()
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        thumbnail(for: entry)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(entry.contextSentence)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("toc.image.\(entry.id)")
                .accessibilityHint("Jump to this image in the document.")
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for entry: ImageEntry) -> some View {
        if let imageID = entry.imageID,
           let data = viewModel.imageData(for: imageID),
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.secondary.opacity(0.12)
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var contentsList: some View {
        let entries = viewModel.visibleTOCEntries
        return List {
            if entries.isEmpty {
                // 2026-05-07 (parity #5): real empty state when
                // no TOC entries are detected. The button that
                // opens this sheet only appears when there are
                // entries today, so this is mostly defensive —
                // the API can still open the sheet on a doc
                // with no TOC, and visible empty-state copy is
                // better than a blank list either way.
                Section {
                    Text("No table of contents in this document.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("toc.empty")
                }
            } else {
                Section {
                    // Task 8 (2026-05-03): composite id avoids the
                    // crash some EPUBs caused when synthesized TOC
                    // entries shared `playOrder = 0` (e.g. a nav.xhtml
                    // and a notice.html both starting at 0). Combine
                    // playOrder + offset + title so duplicates stay
                    // unique even when one of them is empty.
                    ForEach(entries, id: \.compositeID) { entry in
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

// ========== BLOCK SW: EDGE-SWIPE-BACK SHIM - START ==========

#if canImport(UIKit)
/// Re-enables the interactive edge-swipe-back gesture for a view whose host has
/// hidden the navigation bar. Hiding the bar makes UIKit disable
/// `interactivePopGestureRecognizer`; this finds the enclosing
/// `UINavigationController` and installs a lightweight delegate that permits the
/// swipe whenever there's a screen to pop back to. Only the *should-begin* veto
/// is overridden — the gesture's action target (UIKit's transition driver) is
/// untouched, so the pop still animates normally. (2026-06-18, reader
/// top-chrome redesign — Mark requires edge-swipe kept.)
private struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController {
        Proxy(coordinator: context.coordinator)
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }

    final class Proxy: UIViewController {
        private let coordinator: Coordinator
        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
            view.isUserInteractionEnabled = false   // stay transparent to touches
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            installIfPossible()
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installIfPossible()   // nav controller is reliably resolvable by now
        }
        private func installIfPossible() {
            guard let nav = navigationController else { return }
            coordinator.navigationController = nav
            nav.interactivePopGestureRecognizer?.isEnabled = true
            nav.interactivePopGestureRecognizer?.delegate = coordinator
        }
    }
}
#endif

// ========== BLOCK SW: EDGE-SWIPE-BACK SHIM - END ==========
