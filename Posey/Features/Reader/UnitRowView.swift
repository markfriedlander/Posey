import SwiftUI

// ========== BLOCK 01: UNIT ROW VIEW - START ==========

/// One SwiftUI row per `ContentUnit`. The unified renderer that
/// replaces the prior dual paths (displayBlocks vs sentence-row).
/// Every format renders through this view; the look of any given
/// unit is governed by its `kind`, not its format origin.
///
/// **Sentence highlighting + sentence-precise tap (Step 9)**: for
/// prose-bearing units (prose / heading / blockquote / listItem),
/// each sentence is rendered as its own range inside one
/// `AttributedString`. The active sentence gets a subtle background
/// tint; every sentence range carries a `posey-sentence://<uuid>`
/// link so tapping a specific sentence inside a paragraph jumps
/// playback there. SwiftUI's `Text(AttributedString)` lays the
/// paragraph out as one continuous flow (no per-sentence row
/// stacking — reading experience preserved) while keeping the link
/// dispatch per-sentence-precise via `openURL`.
///
/// Link styling (the default blue + underline) is suppressed by
/// overriding `foregroundColor` to `.primary` and clearing
/// `underlineStyle` on every sentence range — visually identical to
/// non-link prose.
///
/// **Image units**: rendered from the side-store image referenced
/// by `metadata.imageID`. Loading is best-effort; a failed load
/// falls back to a small placeholder.
///
/// **Page-break / horizontal-rule**: a thin centered separator.
///
/// 2026-05-23 — introduced as part of the architecture rebuild.
/// 2026-05-26 — Step 9: wired live as the reader's renderer;
/// sentence-link tap shape added; `sentencesInUnit` parameter added
/// so the row can resolve the right sentences without re-filtering
/// the document-wide list.
struct UnitRowView: View {
    /// The unit to render.
    let unit: ContentUnit

    /// The sentences that belong to this unit, in playback order.
    /// Empty for non-prose-bearing kinds (image / pageBreak /
    /// horizontalRule). Supplied by the caller so the row doesn't
    /// have to filter the document-wide sentences list on every
    /// redraw — the parent VM keeps a `sentencesByUnit` lookup.
    let sentencesInUnit: [Sentence]

    /// The active sentence in the WHOLE document. The row only
    /// styles it when `activeSentence?.unitID == unit.id`.
    let activeSentence: Sentence?

    /// Index of the active sentence in the flat `sentences` array on
    /// the VM. Used together with `sentenceIndexBase` and the per-
    /// sentence index to compute distance-from-active, which feeds
    /// the M8 reading-style dimming + scaling curves.
    let activeSentenceIndex: Int

    /// Flat-array index of THIS unit's first sentence (added to a
    /// sentence's position within the unit to derive its global
    /// flat-array index). Computed once at the call site so the row
    /// doesn't need the full sentences list.
    let sentenceIndexBase: Int

    /// Reading style (Standard / Focus / Immersive / Motion) — drives
    /// the dimming + scaling curves applied per-sentence.
    let readingStyle: PlaybackPreferences.ReadingStyle

    /// Note + bookmark presence flags for this unit, computed by the
    /// VM from intersecting note offsets with the unit's plainText
    /// range. The unit row overlays a small glyph at top-trailing
    /// when either flag is set — preserves the annotation indicator
    /// affordance the legacy renderer had per-row.
    let hasNote: Bool
    let hasBookmark: Bool

    /// **Reader UI bundle #3 — tap to navigate.** Fired when the
    /// user taps the bookmark / note glyph in the annotation
    /// overlay. ReaderView wires these to open the Notes sheet and
    /// scroll to the relevant entry. Glyphs are *not* part of the
    /// AttributedString — they're overlay UI — so they don't enter
    /// the TTS or highlight paths.
    let onTapBookmark: (() -> Void)?
    let onTapNote: (() -> Void)?

    /// User-controlled body font size. Threaded down so the row
    /// scales with reader preferences.
    let bodyFontSize: CGFloat

    /// Optional closure for resolving image bytes by id. Injected so
    /// the row view doesn't depend on `DatabaseManager` directly;
    /// reader plumbing supplies a closure that consults the side
    /// store. Returns nil if loading fails.
    let imageDataProvider: (String) -> Data?

    /// URL scheme used by the sentence-link tap shape. Parsed by
    /// `ReaderView`'s `.environment(\.openURL, …)` action handler.
    /// Format: `posey-sentence://<sentence-uuid>`.
    static let sentenceURLScheme = "posey-sentence"

    // MARK: - Dimming curves (M8 reading-style)

    /// Per-sentence opacity. Active sentence at 1.0; non-active at
    /// 0.45 in Standard / Focus; distance-based geometric falloff in
    /// Immersive / Motion (active 1.0; one row out 0.70; two out
    /// 0.40; floor 0.05).
    fileprivate func opacityForSentence(at flatIndex: Int) -> Double {
        let distance = abs(flatIndex - activeSentenceIndex)
        if distance == 0 { return 1.0 }
        switch readingStyle {
        case .standard, .focus:
            return 0.45
        case .immersive, .motion:
            let raw = 1.0 - 0.30 * Double(distance)
            return max(0.05, raw)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch unit.kind {
            case .prose:
                proseRow
            case .heading:
                headingRow
            case .blockquote:
                blockquoteRow
            case .listItem:
                listItemRow
            case .image:
                imageRow
            case .pageBreak:
                pageBreakRow
            case .horizontalRule:
                horizontalRuleRow
            }
            // **Bundle fix #1 (2026-05-26)** — annotation glyphs
            // moved out of the prose overlay into a footer row
            // below the unit. Mark's feedback: overlaying on top of
            // the active highlighted sentence obscured the text.
            // Footer renders only when annotations exist, takes
            // zero height when absent, and trails right so a
            // dense reader sees the glyph in their peripheral
            // vision without it covering the text.
            annotationFooter
        }
    }

    // MARK: - Prose

    /// Body paragraph. Sentence ranges are tagged with
    /// `posey-sentence://` URLs so tap-to-jump is sentence-precise;
    /// the active sentence range gets a subtle background tint.
    private var proseRow: some View {
        Text(attributedProse)
            .font(.system(size: bodyFontSize))
            .lineSpacing(bodyFontSize * 0.35)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .textSelection(.enabled)
    }

    // MARK: - AttributedString builder (shared by prose / quote / list)

    /// Lay sentence-link ranges, suppress link styling, apply the
    /// active highlight. The same builder is used by every
    /// prose-bearing kind — they share text-flow semantics and
    /// differ only in surrounding chrome (italic for quote, bullet
    /// for list, etc.). Heading uses its own builder below because
    /// it doesn't need sentence-link granularity (one heading =
    /// one sentence, basically).
    private var attributedProse: AttributedString {
        var attributed = AttributedString(unit.text)
        let plain = unit.text
        let active = (activeSentence?.unitID == unit.id) ? activeSentence : nil

        for (positionInUnit, sentence) in sentencesInUnit.enumerated() {
            guard sentence.intraStart >= 0,
                  sentence.intraEnd <= plain.count,
                  sentence.intraStart < sentence.intraEnd,
                  let lower = plain.index(plain.startIndex, offsetBy: sentence.intraStart, limitedBy: plain.endIndex),
                  let upper = plain.index(plain.startIndex, offsetBy: sentence.intraEnd, limitedBy: plain.endIndex),
                  let attrLower = AttributedString.Index(lower, within: attributed),
                  let attrUpper = AttributedString.Index(upper, within: attributed),
                  let url = URL(string: "\(Self.sentenceURLScheme)://\(sentence.id.uuidString)") else {
                continue
            }
            let range = attrLower..<attrUpper
            attributed[range].link = url
            // M8 reading-style dimming: per-sentence opacity by
            // distance-from-active. Standard / Focus dim non-active
            // rows to 0.45; Immersive / Motion apply a distance-based
            // geometric falloff. Also suppresses the default link
            // styling (blue + underline) — prose stays prose, not
            // a list of underlined items.
            let flatIdx = sentenceIndexBase + positionInUnit
            let opacity = opacityForSentence(at: flatIdx)
            attributed[range].foregroundColor = Color.primary.opacity(opacity)
            attributed[range].underlineStyle = nil
            // Active highlight on top of the link range — same
            // subtle background as the prior segment-row treatment.
            if let active, sentence.id == active.id {
                attributed[range].backgroundColor = Color.primary.opacity(0.12)
            }
        }
        return attributed
    }

    // MARK: - Annotation overlay

    /// Small note / bookmark glyph anchored top-trailing when this
    /// unit contains at least one annotation. Mirrors the per-row
    /// indicator the legacy renderer drew.
    /// **Bundle fix #1 (2026-05-26)** — annotation footer.
    /// Renders below the unit's text, right-aligned, small. Out of
    /// the prose layout so glyphs never obscure the active
    /// sentence. Tap targets remain padded for thumb-friendliness.
    @ViewBuilder
    private var annotationFooter: some View {
        if hasNote || hasBookmark {
            // 2026-05-27 — glyphs were rendering at bodyFontSize*0.6/0.65 with
            // .secondary tint, which on the device made them visible but
            // not glanceable. Bumped to 0.85 + .primary opacity 0.7, with
            // distinct shapes by design (bookmark.fill = filled
            // bookmark, square.and.pencil = pencil-on-paper for notes —
            // more recognizable as "I wrote something" than note.text's
            // lines-on-paper which reads as "stationery").
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if hasBookmark {
                    Button {
                        onTapBookmark?()
                    } label: {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: bodyFontSize * 0.85))
                            .foregroundStyle(Color.primary.opacity(0.7))
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open bookmark")
                }
                if hasNote {
                    Button {
                        onTapNote?()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: bodyFontSize * 0.85))
                            .foregroundStyle(Color.primary.opacity(0.7))
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open note")
                }
            }
            .padding(.top, 4)
            .accessibilityIdentifier("reader.unit.annotationIndicator")
        }
    }

    // MARK: - Heading

    private var headingRow: some View {
        let level = max(1, min(6, unit.metadata.headingLevel ?? 1))
        // Level 1 is largest, level 6 is barely larger than body.
        let multipliers: [Int: CGFloat] = [
            1: 1.75, 2: 1.40, 3: 1.20, 4: 1.10, 5: 1.05, 6: 1.00
        ]
        let scale = multipliers[level] ?? 1.0
        // Defect #10 (2026-05-27): when the importer's heading
        // anchor lands inside a paragraph that contains BOTH the
        // title and the opening body text (PDF / EPUB / DOCX / HTML
        // commonly produce this), `metadata.titleLength` records how
        // many characters belong to the title. The base attributed
        // string already carries sentence-precise link ranges; we
        // overlay a larger bold font on the title prefix only and
        // restore the body font on the remainder. Returns a single
        // Text so the whole unit lays out as one continuous block
        // (heading + first paragraph) without losing the sentence
        // link / highlight machinery.
        var attributed = attributedProse
        let baseFont = Font.system(size: bodyFontSize)
        attributed.font = baseFont
        let plain = unit.text
        let titleLen = unit.metadata.titleLength ?? plain.count
        if let lower = plain.index(plain.startIndex, offsetBy: 0, limitedBy: plain.endIndex),
           let upper = plain.index(plain.startIndex, offsetBy: min(titleLen, plain.count), limitedBy: plain.endIndex),
           let attrLower = AttributedString.Index(lower, within: attributed),
           let attrUpper = AttributedString.Index(upper, within: attributed),
           attrLower < attrUpper {
            attributed[attrLower..<attrUpper].font = .system(size: bodyFontSize * scale, weight: .bold)
        }
        return Text(attributed)
            .lineSpacing(bodyFontSize * 0.35)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, bodyFontSize * 0.75)
            .padding(.bottom, bodyFontSize * 0.3)
            .textSelection(.enabled)
    }

    // MARK: - Blockquote

    private var blockquoteRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(Color.primary.opacity(0.3))
                .frame(width: 3)
            Text(attributedProse)
                .font(.system(size: bodyFontSize).italic())
                .lineSpacing(bodyFontSize * 0.35)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    // MARK: - List item

    private var listItemRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(unit.metadata.listMarker ?? "• ")
                .font(.system(size: bodyFontSize))
                .frame(width: 24, alignment: .leading)
            Text(attributedProse)
                .font(.system(size: bodyFontSize))
                .lineSpacing(bodyFontSize * 0.35)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Image

    private var imageRow: some View {
        VStack(alignment: .center, spacing: 8) {
            if let imageID = unit.metadata.imageID,
               let data = imageDataProvider(imageID),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else {
                // Placeholder — image data missing or failed to load.
                Rectangle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: 80)
                    .overlay(
                        Text("[image]")
                            .font(.system(size: bodyFontSize * 0.85))
                            .foregroundStyle(Color.primary.opacity(0.5))
                    )
            }
            if !unit.text.isEmpty {
                Text(unit.text)
                    .font(.system(size: bodyFontSize * 0.85).italic())
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Page break

    /// **Reader UI bundle #4 — page-break visual treatment.**
    /// Page-break units carry no text, never enter the sentences
    /// array, and never see the TTS / highlight paths. Rendered as
    /// a thin centered marker (rule | label | rule), so the user
    /// reads it as structural information rather than content. Label
    /// uses `.smallCaps()` + `.secondary` foreground so it sits
    /// clearly outside the prose hierarchy. `accessibilityHidden`
    /// keeps VoiceOver from reading it as a row.
    private var pageBreakRow: some View {
        HStack(spacing: 10) {
            line
            if let page = unit.metadata.pageNumber {
                Text("page \(page + 1)")
                    .font(.system(size: bodyFontSize * 0.7).smallCaps())
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
            }
            line
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page break")
    }

    // MARK: - Horizontal rule

    private var horizontalRuleRow: some View {
        HStack {
            Spacer()
            line.frame(maxWidth: 120)
            Spacer()
        }
        .padding(.vertical, 16)
    }

    private var line: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.2))
            .frame(height: 1)
    }
}

// ========== BLOCK 01: UNIT ROW VIEW - END ==========
