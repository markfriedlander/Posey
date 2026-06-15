import SwiftUI
import UIKit

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

    /// 2026-05-28 — Identity-bump for the annotation cache. The VM
    /// bumps `unitAnnotationVersion` whenever it invalidates the
    /// cache (note insert / delete via UI or antenna). Threading it
    /// here makes SwiftUI re-evaluate the row body when version
    /// changes — `hasNote` / `hasBookmark` change ARE tracked, but
    /// the FIRST render after a create might have stale `false`
    /// flags because annotationFlags(for:) is a method, not a
    /// Published computed. This forces a re-pass.
    let annotationVersion: Int

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

    /// Custom attribute that marks a sentence's character range in the
    /// UITextView prose path, used INSTEAD of `.link`. UITextView force-renders
    /// `.link` ranges with a blue underline that TextKit 2 won't let us
    /// suppress (neither `linkTextAttributes[.underlineStyle:0]` nor per-range
    /// `underlineStyle`/`underlineColor` removes it — confirmed on device,
    /// 2026-06-08). Marking ranges with this custom key instead means no link
    /// styling is ever applied; `ProseUnitTextView`'s tap gesture maps a tap
    /// location to this attribute and dispatches the jump. Value: sentence
    /// UUID `uuidString`.
    static let sentenceIDAttribute = NSAttributedString.Key("poseySentenceID")

    /// Bound to the openURL action ReaderView installs via
    /// `.environment(\.openURL, ...)`. Captured here so the UITextView
    /// wrapper's sentence-tap callback can dispatch a posey-sentence://
    /// URL through the same handler the SwiftUI Text link-tap path
    /// uses. Without this, the URL would try to open externally and
    /// fail (the scheme isn't registered with the system).
    @Environment(\.openURL) private var openURL

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

    /// c13: forwarded to `ProseUnitTextView` so the active prose row can
    /// publish its live (UITextView, sentence range) for upper-third pinning.
    var onActiveLine: ((UITextView, NSRange) -> Void)? = nil

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
            case .table:
                tableRow
            case .pageBreak:
                pageBreakRow
            case .horizontalRule:
                horizontalRuleRow
            case .code:
                codeRow
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

    /// Body paragraph rendered through `ProseUnitTextView` — a
    /// UIKit-backed UITextView wrapper. This is a deliberate
    /// architectural choice and worth explaining.
    ///
    /// **2026-05-28 (post-N2/N3 reconsideration).** The N2/N3 commit
    /// (`2891340`) split multi-sentence prose units into a VStack of
    /// per-sentence SwiftUI Text views to win sentence-precise scroll
    /// anchoring. The trade-off it accepted was loss of multi-sentence
    /// text selection (SwiftUI's `.textSelection(.enabled)` is per-Text;
    /// selection can't span sibling Text views in a stack). Mark called
    /// that trade-off out as false: scroll anchoring and cross-sentence
    /// selection are independent problems and both should be solved.
    /// He's right.
    ///
    /// The right architecture is one rendering surface per unit that
    /// supports both intra-text geometry queries (for scroll precision)
    /// AND native selection (for cross-sentence copy/quote). SwiftUI's
    /// `Text` exposes neither intra-text geometry nor cross-Text
    /// selection. UITextView does both — natively, with the
    /// platform-standard selection UX (handles, magnifier, callout
    /// menu) the reader expects from every other iOS app.
    ///
    /// `ProseUnitTextView` wraps a single UITextView per prose unit:
    ///   - Holds the full unit's NSAttributedString (one render surface)
    ///   - Native selection spans the entire unit's text
    ///   - Sentence-link taps still dispatch via posey-sentence:// URLs
    ///     (intercepted in `shouldInteractWith:`)
    ///   - M8 dimming opacity per sentence applied as
    ///     `.foregroundColor` NSAttributedString attributes
    ///   - Active-sentence highlight applied as `.backgroundColor`
    ///   - Native iOS callout menu (Copy / Define / Translate / Share)
    ///     works for free without us re-implementing any of it
    ///
    /// Scroll anchoring (the N3 problem) goes back to unit-level
    /// `scrollTo(unit.id, anchor: UnitPoint(0.5, k/N))` for now — the
    /// fractional UnitPoint approximates upper-third positioning. A
    /// future iteration can expose `boundingRect(forCharacterRange:)`
    /// from this view + a SwiftUI `ScrollPosition` (iOS 17+) for
    /// pixel-precise sentence-y anchoring; that polish lives separately
    /// from the selection fix that motivated this commit.
    private var proseRow: some View {
        ProseUnitTextView(
            attributedText: nsAttributedProse,
            onSentenceTap: { sentenceID in
                // Dispatch through SwiftUI's openURL environment action
                // (set up by ReaderView's `.environment(\.openURL, ...)`)
                // so the existing sentence-link routing handles it.
                guard let url = URL(string: "\(Self.sentenceURLScheme)://\(sentenceID.uuidString)") else { return }
                openURL(url)
            },
            onActiveLine: onActiveLine
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    /// NSAttributedString version of the prose, with sentence-link
    /// URLs, per-sentence opacity, and active-sentence background —
    /// the same shape `attributedProse` produces, but in the AppKit/
    /// UIKit attribute namespace that UITextView consumes natively.
    /// Pulled out so `ProseUnitTextView` can stay a thin wrapper and
    /// all the per-sentence logic stays in one place.
    private var nsAttributedProse: NSAttributedString {
        let plain = unit.text
        let attributed = NSMutableAttributedString(string: plain)
        let fullRange = NSRange(location: 0, length: attributed.length)
        // Body font for the whole string — sentence-specific attributes
        // override locally.
        attributed.addAttribute(.font, value: UIFont.systemFont(ofSize: bodyFontSize), range: fullRange)
        attributed.addAttribute(
            .foregroundColor,
            value: UIColor.label,
            range: fullRange
        )
        // Match SwiftUI line spacing: bodyFontSize * 0.35.
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = bodyFontSize * 0.35
        attributed.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

        let active = (activeSentence?.unitID == unit.id) ? activeSentence : nil
        let utf16 = plain.utf16

        for (positionInUnit, sentence) in sentencesInUnit.enumerated() {
            guard sentence.intraStart >= 0,
                  sentence.intraEnd <= plain.count,
                  sentence.intraStart < sentence.intraEnd else { continue }
            // Convert character offsets to UTF-16 offsets for NSRange.
            // For ASCII / Latin text these match; for emoji or
            // surrogate-pair content the conversion matters.
            guard let lower = plain.index(plain.startIndex, offsetBy: sentence.intraStart, limitedBy: plain.endIndex),
                  let upper = plain.index(plain.startIndex, offsetBy: sentence.intraEnd, limitedBy: plain.endIndex) else {
                continue
            }
            let nsLower = lower.utf16Offset(in: plain)
            let nsUpper = upper.utf16Offset(in: plain)
            guard nsLower >= 0, nsUpper <= utf16.count, nsLower < nsUpper else { continue }
            let range = NSRange(location: nsLower, length: nsUpper - nsLower)

            // Sentence marker for tap-to-jump dispatch. CUSTOM attribute, NOT
            // `.link`: UITextView force-renders `.link` ranges with a blue
            // underline that TextKit 2 won't suppress. The tap gesture in
            // ProseUnitTextView maps a tap location to this attribute and
            // dispatches the jump — so prose renders as plain prose, zero link
            // styling.
            attributed.addAttribute(Self.sentenceIDAttribute, value: sentence.id.uuidString, range: range)

            // M8 dimming opacity for non-active sentences.
            let flatIdx = sentenceIndexBase + positionInUnit
            let opacity = opacityForSentence(at: flatIdx)
            attributed.addAttribute(
                .foregroundColor,
                value: UIColor.label.withAlphaComponent(opacity),
                range: range
            )

            // Active-sentence accent background.
            if let active, sentence.id == active.id {
                attributed.addAttribute(
                    .backgroundColor,
                    value: UIColor(named: "AccentColor")?.withAlphaComponent(0.30)
                        ?? UIColor.systemBlue.withAlphaComponent(0.30),
                    range: range
                )
            }
        }
        return attributed
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
            // Active highlight on top of the link range.
            // 2026-05-28 — Mark caught: the 0.12 opacity was so subtle
            // that at standard reading distance the active sentence
            // was effectively unmarked, even though `currentSentenceIndex`
            // was advancing correctly. The read-along feature requires
            // the user to actually SEE which sentence is being spoken.
            // Bumped to Color.accentColor at 0.30 — accents to brand
            // color (not gray-on-gray), opacity readable in both Light
            // and Dark mode without overpowering the prose.
            if let active, sentence.id == active.id {
                attributed[range].backgroundColor = Color.accentColor.opacity(0.30)
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
        // 2026-05-28 sentinel — REMOVED after diagnosis confirmed
        // hasNote / hasBookmark do reach UnitRowView correctly. The
        // glyphs were rendering but at low opacity at the right edge
        // and being overlapped by the always-on reading-time chrome
        // strip. Real fix: bump opacity + use accent color (matches
        // the highlight band Mark just approved) + nudge inward so
        // the chrome strip doesn't sit on top of them.
        if hasNote || hasBookmark {
            // 2026-05-27 — glyphs were rendering at bodyFontSize*0.6/0.65 with
            // .secondary tint, which on the device made them visible but
            // not glanceable. Bumped to 0.85 + .primary opacity 0.7, with
            // distinct shapes by design (bookmark.fill = filled
            // bookmark, square.and.pencil = pencil-on-paper for notes —
            // more recognizable as "I wrote something" than note.text's
            // lines-on-paper which reads as "stationery").
            // 2026-05-28 — Mark caught: annotation glyphs were
            // effectively invisible (Color.primary.opacity(0.7) icons
            // at the right edge being overlapped by the always-on
            // reading-time chrome strip "Nh Nm left"). Fix: use the
            // accent color (matches the new TTS highlight band), bump
            // opacity to 0.85, slightly larger size, and inset the
            // HStack from the trailing edge by enough that the
            // reading-time pill doesn't sit on top of it. Padded tap
            // target unchanged.
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                if hasBookmark {
                    Button {
                        onTapBookmark?()
                    } label: {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: bodyFontSize * 0.95))
                            .foregroundStyle(Color.accentColor.opacity(0.85))
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
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
                            .font(.system(size: bodyFontSize * 0.95))
                            .foregroundStyle(Color.accentColor.opacity(0.85))
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open note")
                }
            }
            .padding(.top, 6)
            // Inset from the trailing edge so the always-on
            // reading-time chrome pill (which floats at screen
            // bottom-right) doesn't cover the glyphs as the user
            // scrolls.
            .padding(.trailing, 90)
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

    // MARK: - Table (rendered as image)

    /// 2026-06-15 — A DOCX table rasterized to an image (`ContentUnitKind.table`).
    /// Renders the PNG like `imageRow` (tap-to-zoom is wired in ReaderView's
    /// per-row `.onTapGesture`), but does NOT show `unit.text` as a caption —
    /// that text is the pipe-delimited searchable representation kept for
    /// search / RAG / TTS, not something to print under the image. If the
    /// image is missing (rasterize failed / old import), fall back to showing
    /// the text monospaced so the table content is never lost.
    private var tableRow: some View {
        VStack(alignment: .center, spacing: 8) {
            if let imageID = unit.metadata.imageID,
               let data = imageDataProvider(imageID),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else if !unit.text.isEmpty {
                Text(unit.text)
                    .font(.system(size: bodyFontSize * 0.9, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
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

    // MARK: - Code block

    /// 2026-06-11 — Fenced code block. Monospaced, verbatim (newlines +
    /// indentation preserved), in a tinted box, horizontally scrollable so
    /// long lines don't reflow or clip. Never styled as prose; text selection
    /// stays enabled for copy. Deliberately NOT routed through the per-sentence
    /// prose path — code is one unit, read/skip decisions are a TTS concern.
    private var codeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(unit.text)
                .font(.system(size: bodyFontSize * 0.9, design: .monospaced))
                .lineSpacing(bodyFontSize * 0.25)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.vertical, 6)
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


// ========== BLOCK 02: PROSE UNIT TEXT VIEW (UITextView wrapper) - START ==========

/// UITextView-backed prose renderer per ContentUnit, used by
/// `UnitRowView.proseRow`.
///
/// **Why UITextView, not SwiftUI Text.** SwiftUI's Text is wonderful
/// but limited in two ways that matter here: text selection is
/// per-Text view (selections can't span sibling Texts in a VStack),
/// and there's no intra-text geometry query (you can't ask where
/// inside a Text a given character offset lives). Prose-reading
/// requires both: a reader needs to be able to select a multi-
/// sentence quote, and the reader needs to land the active TTS
/// sentence at a fixed viewport position regardless of where it
/// falls within its paragraph.
///
/// UITextView does both natively. Selection works across the whole
/// `attributedText` with the familiar iOS handles, magnifier, and
/// callout menu (Copy / Look Up / Translate / Share). Intra-text
/// geometry is `layoutManager.boundingRect(forGlyphRange:in:)`. A
/// future iteration can publish per-sentence rects from this view
/// up to `ReaderView` so `scrollToCurrentSentence` can land
/// sentence-y-pixel-precise. For now, scrollTo still targets the
/// unit and uses a fractional `UnitPoint` anchor — the active
/// sentence drifts slightly within the unit but stays in roughly
/// the upper-third viewport zone.
///
/// **Behaviors preserved from the prior SwiftUI Text implementation:**
///   - Sentence-link tap dispatch (intercepted in
///     `shouldInteractWith:` and routed via `onSentenceTap`).
///   - Body font + line spacing match `Text(attributedProse)`.
///   - Per-sentence M8 opacity dimming (applied as
///     `.foregroundColor` attributes on each sentence range).
///   - Active-sentence accent-color background (applied as
///     `.backgroundColor` on the active sentence's range).
///
/// **Behaviors gained:**
///   - Multi-sentence text selection (native, with handles).
///   - Native callout menu (Copy works without us re-implementing it).
///
/// 2026-05-28 — introduced to fix the N2/N3 cross-sentence-selection
/// trade-off Mark flagged as a false dichotomy.
struct ProseUnitTextView: UIViewRepresentable {

    let attributedText: NSAttributedString

    /// Sentence-link tap callback. Posey's prose attributes each
    /// sentence range with a `posey-sentence://<uuid>` URL; the
    /// UITextView delegate intercepts those and dispatches to this
    /// closure with the parsed UUID. Returning false from the
    /// delegate prevents UITextView from trying to open the URL in
    /// Safari.
    let onSentenceTap: (UUID) -> Void

    /// c13 auto-scroll fix (2026-06-04): when this row carries the active
    /// sentence highlight, publishes the live (UITextView, sentence range) so the
    /// reader can pin that sentence to a fixed upper-third viewport position by
    /// scrolling the backing UIScrollView. The reader recomputes the glyph rect
    /// at scroll time (always-current layout). Does NOT touch the renderer: one
    /// UITextView per unit, native cross-sentence selection preserved.
    var onActiveLine: ((UITextView, NSRange) -> Void)? = nil

    /// Make the UITextView. Configuration mirrors what a SwiftUI
    /// Text would render — no editable text, no internal scrolling
    /// (the outer ScrollView handles that), transparent background,
    /// zero padding around glyphs.
    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        // Disable data detectors (UITextView would otherwise underline
        // URLs in the prose text itself, which we don't want).
        tv.dataDetectorTypes = []
        tv.delegate = context.coordinator
        // Single-tap → sentence jump. We mark sentence ranges with a CUSTOM
        // attribute (not `.link`, which UITextView force-underlines), so the
        // tap is dispatched here by mapping the tap location to the sentence
        // attribute. `cancelsTouchesInView = false` keeps long-press text
        // selection working.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSentenceTap(_:)))
        tap.cancelsTouchesInView = false
        tv.addGestureRecognizer(tap)
        // Let SwiftUI's parent (`.frame(maxWidth: .infinity)`) decide
        // the width; we'll size height to fit the wrapped text via
        // `sizeThatFits` below. Horizontal compression resistance low
        // so SwiftUI can size the width freely.
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.required, for: .vertical)
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.attributedText = attributedText
        // Force the layout manager to re-flow against the current
        // bounds. Without this, font/opacity/highlight changes can
        // leave the cached glyph layout stale and clip text.
        uiView.invalidateIntrinsicContentSize()

        // c13: locate the active-sentence highlight (the ONLY range carrying a
        // .backgroundColor attribute). Non-active rows have none.
        let full = NSRange(location: 0, length: attributedText.length)
        var activeRange: NSRange?
        attributedText.enumerateAttribute(.backgroundColor, in: full, options: []) { value, range, stop in
            if value != nil { activeRange = range; stop.pointee = true }
        }

        if let activeRange {
            #if DEBUG
            // ACTIVE_LINE_FRAME antenna verb reads the live on-screen position.
            RemoteControlState.shared.setActiveProseLine(textView: uiView, range: activeRange)
            #endif
            // Publish the live (textView, range) so the reader can pin this
            // sentence to the upper third by scrolling the backing UIScrollView.
            // Deferred to the next runloop tick to avoid mutating SwiftUI state
            // during a view update.
            if let publish = onActiveLine {
                DispatchQueue.main.async { publish(uiView, activeRange) }
            }
        }
    }

    /// SwiftUI sizing hook (iOS 16+). Called by the SwiftUI layout
    /// system with the proposed width; we return the text's natural
    /// height for that width. This is the missing piece that made
    /// the initial integration clip text on the right edge — without
    /// it, UITextView reported its default-empty intrinsic size and
    /// the textContainer stayed at the wrong width forever.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else {
            return nil
        }
        // Set the textContainer's width explicitly so the layout
        // manager wraps glyphs against the SwiftUI-proposed width.
        // (`widthTracksTextView` would normally do this, but only
        // when the textView is auto-resizing via constraints; under
        // UIViewRepresentable the SwiftUI layout drives the frame
        // and the container width has to be set in lockstep here.)
        uiView.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        let fitted = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: fitted.height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSentenceTap: onSentenceTap)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let onSentenceTap: (UUID) -> Void
        init(onSentenceTap: @escaping (UUID) -> Void) {
            self.onSentenceTap = onSentenceTap
        }

        /// Single-tap handler. Maps the tap location to a character index
        /// (via UITextInput — TextKit-version agnostic), reads the custom
        /// `sentenceIDAttribute` at that index, and dispatches the jump. Taps
        /// that don't land on a sentence range (margins, trailing space) carry
        /// no attribute and are ignored. Replaces the old `.link`
        /// `primaryActionFor` path, which forced a blue underline we couldn't
        /// suppress.
        @objc func handleSentenceTap(_ gesture: UITapGestureRecognizer) {
            guard let tv = gesture.view as? UITextView else { return }
            let point = gesture.location(in: tv)
            guard let pos = tv.closestPosition(to: point) else { return }
            let idx = tv.offset(from: tv.beginningOfDocument, to: pos)
            guard let attributed = tv.attributedText, idx >= 0, idx < attributed.length else { return }
            if let raw = attributed.attribute(
                    UnitRowView.sentenceIDAttribute, at: idx, effectiveRange: nil) as? String,
               let id = UUID(uuidString: raw) {
                onSentenceTap(id)
            }
        }
    }
}

// ========== BLOCK 02: PROSE UNIT TEXT VIEW - END ==========
