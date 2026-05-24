import SwiftUI

// ========== BLOCK 01: UNIT ROW VIEW - START ==========

/// One SwiftUI row per `ContentUnit`. The unified renderer that
/// replaces the prior dual paths (displayBlocks vs sentence-row).
/// Every format renders through this view; the look of any given
/// unit is governed by its `kind`, not its format origin.
///
/// **Sentence highlighting**: for prose-bearing units, when a
/// sentence inside this unit is the playback-active sentence, the
/// renderer highlights that range. Inactive units, and inactive
/// portions of the active unit, render plainly.
///
/// **Image units**: rendered from the side-store image referenced
/// by `metadata.imageID`. Loading is best-effort; a failed load
/// falls back to a small placeholder.
///
/// **Page-break / horizontal-rule**: a thin centered separator.
///
/// 2026-05-23 — introduced as part of the architecture rebuild.
struct UnitRowView: View {
    /// The unit to render.
    let unit: ContentUnit

    /// The active sentence within this unit, when playback is
    /// currently on a sentence inside this unit. `nil` when playback
    /// isn't active on this unit (the common case for any row that
    /// isn't the active one).
    let activeSentence: Sentence?

    /// User-controlled body font size. Threaded down so the row
    /// scales with reader preferences.
    let bodyFontSize: CGFloat

    /// Optional closure for resolving image bytes by id. Injected so
    /// the row view doesn't depend on `DatabaseManager` directly;
    /// reader plumbing supplies a closure that consults the side
    /// store. Returns nil if loading fails.
    let imageDataProvider: (String) -> Data?

    var body: some View {
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
    }

    // MARK: - Prose

    /// Body paragraph. The active sentence's range is highlighted
    /// with a subtle background tint while the rest of the unit
    /// renders plainly. Range-attributed via `AttributedString` so
    /// SwiftUI lays it out as one text view (no line-break artifacts
    /// from splitting into pre/active/post Text views).
    private var proseRow: some View {
        Text(attributedProse)
            .font(.system(size: bodyFontSize))
            .lineSpacing(bodyFontSize * 0.35)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private var attributedProse: AttributedString {
        var attributed = AttributedString(unit.text)
        guard let active = activeSentence,
              active.unitID == unit.id,
              active.intraStart >= 0,
              active.intraEnd <= unit.text.count,
              active.intraStart < active.intraEnd else {
            return attributed
        }
        // Convert intra-unit character offsets to AttributedString indices.
        // These are character-counted offsets into the same string we
        // built the AttributedString from, so distance-based indexing is
        // safe.
        let plain = unit.text
        guard let lower = plain.index(plain.startIndex, offsetBy: active.intraStart, limitedBy: plain.endIndex),
              let upper = plain.index(plain.startIndex, offsetBy: active.intraEnd, limitedBy: plain.endIndex),
              let attrLower = AttributedString.Index(lower, within: attributed),
              let attrUpper = AttributedString.Index(upper, within: attributed) else {
            return attributed
        }
        attributed[attrLower..<attrUpper].backgroundColor = Color.primary.opacity(0.12)
        return attributed
    }

    // MARK: - Heading

    private var headingRow: some View {
        let level = max(1, min(6, unit.metadata.headingLevel ?? 1))
        // Level 1 is largest, level 6 is barely larger than body.
        let multipliers: [Int: CGFloat] = [
            1: 1.75, 2: 1.40, 3: 1.20, 4: 1.10, 5: 1.05, 6: 1.00
        ]
        let scale = multipliers[level] ?? 1.0
        return Text(unit.text)
            .font(.system(size: bodyFontSize * scale, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, bodyFontSize * 0.75)
            .padding(.bottom, bodyFontSize * 0.3)
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

    private var pageBreakRow: some View {
        HStack(spacing: 8) {
            line
            if let page = unit.metadata.pageNumber {
                Text("page \(page + 1)")
                    .font(.system(size: bodyFontSize * 0.75))
                    .foregroundStyle(Color.primary.opacity(0.4))
            }
            line
        }
        .padding(.vertical, 12)
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
