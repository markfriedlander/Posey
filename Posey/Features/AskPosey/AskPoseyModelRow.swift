import SwiftUI

// ========== BLOCK 01: STATUS DOT - START ==========

/// Single status-dot language, ported from Hal's `modelStatusDot`
/// (one dot, one meaning, consistent everywhere):
///   - green  = downloaded AND active (the selected model)
///   - grey   = downloaded, inactive
///   - no dot = not downloaded
/// Per Mark (2026-05-28): "Port Hal's single status language exactly."
@ViewBuilder
func modelStatusDot(isDownloaded: Bool, isActive: Bool) -> some View {
    if isDownloaded {
        Circle()
            .fill(isActive ? Color.green : Color.gray.opacity(0.5))
            .frame(width: 8, height: 8)
            .accessibilityLabel(isActive ? "Downloaded and active" : "Downloaded")
    }
    // No dot when not downloaded.
}

// ========== BLOCK 01: STATUS DOT - END ==========

// ========== BLOCK 02: MODEL LIBRARY ROW - START ==========

/// One accordion-expand-in-place row in the LLM picker. Ported from
/// Hal's `ModelLibraryRow`. Collapsed: status dot + name + size +
/// chevron. Tap to expand the detail card (or in-flight progress) plus
/// the primary action. Per-row `@State isExpanded` keeps each row's
/// accordion independent.
///
/// 2026-05-28 — replaces commit `985cd55`'s always-expanded
/// goodAt/strugglesWith inline rows as part of the faithful Hal
/// model-management port (task #1).
struct AskPoseyModelRow: View {
    let model: ModelConfiguration
    let isActive: Bool
    @ObservedObject var downloader: MLXModelDownloader

    /// Expansion is parent-driven (single-open accordion) so the
    /// antenna can open a specific card for phone verification via
    /// `SCROLL_PREFS_TO_LLM:<id>`. A plain @State toggle couldn't be
    /// reached remotely.
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    private var downloadState: MLXModelDownloader.DownloadState? {
        downloader.downloadStates[model.id]
    }
    private var isDownloaded: Bool {
        model.source == .appleFoundation || downloader.isModelDownloaded(model.id)
    }
    private var isDownloading: Bool {
        downloadState?.isDownloading == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Collapsed header (always visible) ──────────────────
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { onToggleExpand() }
            } label: {
                HStack(spacing: 10) {
                    Text(model.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let size = model.sizeGB {
                        Text("\(String(format: "%.1f", size)) GB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    modelStatusDot(isDownloaded: isDownloaded, isActive: isActive)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // ── Expanded body ──────────────────────────────────────
            if isExpanded {
                Divider().padding(.vertical, 8)
                if isDownloading, let state = downloadState {
                    downloadProgressView(state)
                } else {
                    AskPoseyModelDetailCard(model: model)
                    actionRow
                }
            }
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
    }

    // MARK: - Action row

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 12) {
            if isDownloaded {
                Button(action: onSelect) {
                    HStack(spacing: 4) {
                        Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        Text(isActive ? "Active" : "Select")
                    }
                    .font(.subheadline)
                    .foregroundStyle(isActive ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(isActive)

                Spacer()

                // Delete is only meaningful for downloaded MLX models
                // (AFM is system-managed; never-downloaded models have
                // nothing to free). Can't delete the active model.
                if model.source == .mlx && !isActive {
                    Button(action: onDelete) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("Delete")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            } else if let state = downloadState, state.error != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.error ?? "Download failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button(action: onDownload) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry")
                        }
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button(action: onDownload) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Download")
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func downloadProgressView(_ state: MLXModelDownloader.DownloadState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: state.progress)
            HStack {
                Text(state.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// ========== BLOCK 02: MODEL LIBRARY ROW - END ==========

// ========== BLOCK 03: MODEL DETAIL CARD - START ==========

/// The expanded card body for a model row. Ported from Hal's
/// `ModelDetailCard`: voice-tag chip → description → performance grid
/// (generation / prefill / context / download) → reading scorecard →
/// license. Each section adapts to nil data so AFM (no tok/s, no
/// license, no size) and the not-yet-measured / not-yet-tuned fields
/// still render cleanly.
struct AskPoseyModelDetailCard: View {
    let model: ModelConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Voice tag chip
            if let tag = model.voiceTag {
                HStack(spacing: 6) {
                    Text(tag)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    Spacer()
                }
            }

            // Description (full text — reading-companion character)
            if let description = model.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            performanceSection

            // Reading scorecard — only when honest tuning data exists (#82)
            if let scorecard = model.readingScorecard, !scorecard.isEmpty {
                ReadingScorecardView(scorecard: scorecard)
            }

            // License
            if let license = model.license {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("License: \(license.uppercased())")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Performance", systemImage: "gauge.with.dots.needle.67percent")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading)
                ],
                alignment: .leading,
                spacing: 10
            ) {
                if let gen = model.generationTokensPerSec {
                    statCell("Generation", "\(String(format: "%.1f", gen)) tok/s")
                }
                if let ttft = model.timeToFirstTokenSeconds {
                    statCell("Time to First Token", "\(String(format: "%.1f", ttft))s")
                }
                statCell("Context", formatContextWindow(model.contextWindow))
                if let size = model.sizeGB {
                    statCell("Download", "\(String(format: "%.1f", size)) GB")
                } else if model.source == .appleFoundation {
                    statCell("Download", "System")
                }
            }
        }
    }

    /// Stacked label-above-value cell so labels don't compete
    /// horizontally with their values.
    @ViewBuilder
    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .monospacedDigit()
        }
    }

    /// User-facing rounded context window: "128K", "262K", "4K".
    /// Per Mark: readers, not engineers.
    private func formatContextWindow(_ tokens: Int) -> String {
        tokens >= 1000 ? "\(tokens / 1000)K" : "\(tokens)"
    }
}

// ========== BLOCK 03: MODEL DETAIL CARD - END ==========

// ========== BLOCK 04: READING SCORECARD VIEW - START ==========

/// Six-axis at-a-glance reading-companion capability summary, one row
/// per rated axis. Same structured presentation as Hal's
/// `MaximScorecardView` (tinted icon + label + rating word + caption),
/// but only renders axes that have an honest rating — empty axes are
/// skipped (the whole section is hidden when nothing is rated, which is
/// the current state pending `#82` tuning).
struct ReadingScorecardView: View {
    let scorecard: ReadingScorecard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("How it reads", systemImage: "list.bullet.indent")
                .font(.caption)
                .foregroundStyle(.secondary)
            axisRow(scorecard.grounding,          "Grounding",           "Answers from the text, not fabrication.")
            axisRow(scorecard.interpretation,     "Interpretation",      "Engages with what the text means.")
            axisRow(scorecard.honestyAboutGaps,   "Honesty about gaps",  "Says \"I don't know\" rather than guessing.")
            axisRow(scorecard.conversationalDepth, "Conversational depth", "Holds a thread across multiple turns.")
            axisRow(scorecard.curiosity,          "Curiosity",           "Surfaces interesting things unprompted.")
            axisRow(scorecard.concision,          "Concision",           "Answers precisely, without padding.")
        }
    }

    @ViewBuilder
    private func axisRow(_ rating: ReadingScorecard.Rating?, _ label: String, _ caption: String) -> some View {
        if let rating {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: rating.systemImage)
                    .foregroundStyle(rating.tint)
                    .font(.caption)
                    .frame(width: 14)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(label)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(rating.summary)
                            .font(.caption2)
                            .foregroundStyle(rating.tint)
                    }
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private extension ReadingScorecard.Rating {
    var systemImage: String {
        switch self {
        case .standout: return "star.fill"
        case .pass:     return "checkmark.circle.fill"
        case .mixed:    return "minus.circle.fill"
        case .fail:     return "xmark.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .standout: return .yellow
        case .pass:     return .green
        case .mixed:    return .orange
        case .fail:     return .red
        }
    }
    var summary: String {
        switch self {
        case .standout: return "Standout"
        case .pass:     return "Good"
        case .mixed:    return "Mixed"
        case .fail:     return "Weak"
        }
    }
}

// ========== BLOCK 04: READING SCORECARD VIEW - END ==========

// ========== BLOCK 05: HARDWARE DISCLOSURE SHEET - START ==========

/// One-time hardware/storage expectation-setting sheet, shown before the
/// first MLX download or switch. Ported from Hal's
/// `HardwareDisclosureSheet`. Gated by `askPosey.hasSeenHardwareDisclosure`.
struct AskPoseyHardwareDisclosureSheet: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Local Models on Your iPhone")
                                .font(.title2)
                                .fontWeight(.semibold)
                            Text("First-time setup")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)

                    Text("Posey's local models run entirely on your iPhone — nothing leaves the device, and they work fully offline. The trade-off compared to Apple Intelligence is they need more memory and storage, and respond more slowly.")
                        .font(.body)

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Storage & download", systemImage: "internaldrive")
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 4) {
                            bullet("Each model is roughly 2–4 GB")
                            bullet("First download is one-time per model")
                            bullet("Wi-Fi strongly recommended for the initial download")
                            bullet("After download, the model runs fully offline")
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Hardware", systemImage: "memorychip")
                            .font(.headline)
                        Text("Newer iPhones (16 and later) run these comfortably. Older devices may run slowly or, for the largest model, fail to load — Posey will tell you and fall back to Apple Intelligence rather than crash.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Before You Continue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("I Understand") { onContinue() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.subheadline)
            Spacer(minLength: 0)
        }
    }
}

// ========== BLOCK 05: HARDWARE DISCLOSURE SHEET - END ==========

// ========== BLOCK 06: MODEL LICENSE SHEET - START ==========

/// License acceptance sheet shown before download. Ported from Hal's
/// `ModelLicenseSheet`. Names the license, sets the download-size
/// expectation, links to the full terms on Hugging Face.
struct AskPoseyModelLicenseSheet: View {
    let model: ModelConfiguration
    let onAccept: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(licenseName)
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("By downloading \(model.displayName), you agree to its license terms.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let size = model.sizeGB {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("Download: \(String(format: "%.1f", size)) GB")
                                    .fontWeight(.semibold)
                            }
                            Text("Requires \(String(format: "%.1f", size)) GB of storage and bandwidth. Wi-Fi recommended.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("License: \(model.license?.uppercased() ?? "CUSTOM")")
                            .font(.headline)
                        if let description = licenseDescription {
                            Text(description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let url = URL(string: "https://huggingface.co/\(model.id)") {
                            Link(destination: url) {
                                HStack {
                                    Image(systemName: "link")
                                    Text("View full license on Hugging Face")
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                }
                                .font(.subheadline)
                            }
                            .padding()
                            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    Divider()

                    VStack(spacing: 12) {
                        Button(action: onAccept) {
                            Text("Accept & Download")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button(action: onCancel) {
                            Text("Cancel").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationTitle(model.displayName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var licenseName: String {
        guard let license = model.license else { return "License Agreement" }
        switch license.lowercased() {
        case "mit":         return "MIT License"
        case "apache-2.0":  return "Apache 2.0"
        case "llama2":      return "Llama 2 Community License"
        case "llama3", "llama3.1", "llama3.2": return "Llama 3 Community License"
        case "gemma":       return "Gemma Terms of Use"
        default:            return "\(license.uppercased()) License"
        }
    }

    private var licenseDescription: String? {
        guard let license = model.license else { return nil }
        switch license.lowercased() {
        case "mit":
            return "Permissive license allowing commercial and private use with minimal restrictions."
        case "apache-2.0":
            return "Permissive license allowing commercial use with a patent grant."
        case "llama2", "llama3", "llama3.1", "llama3.2":
            return "Meta's community license. Review full terms for commercial-use restrictions."
        case "gemma":
            return "Google's Gemma Terms. Review full terms for usage requirements."
        default:
            return "Please review the full license terms before downloading."
        }
    }
}

// ========== BLOCK 06: MODEL LICENSE SHEET - END ==========
