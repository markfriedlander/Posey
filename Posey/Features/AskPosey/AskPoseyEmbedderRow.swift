import SwiftUI
import SharedModelStoreKit

// ========== BLOCK 01: ASK POSEY EMBEDDER ROW - START ==========

/// One embedder-backend row in the Model Library's Embedding Model section.
///
/// Mirrors the language-model row (`AskPoseyModelRow`) and Hal Universal's
/// `EmbedderBackendRow` so managing an embedder reads exactly like managing an
/// answer model: a single status dot (green = active, grey = downloaded) plus an
/// accordion whose action row is **Active / Download / Select / Delete**.
///
/// The built-in Apple **NLContextual** backend (`modelID == nil`) is the one
/// exception, per Mark's decision (2026-07-08): iOS installs its asset in the
/// background, so it can't be downloaded or deleted from here and shows **Select
/// only**. It is the always-available fallback floor — if every downloadable
/// embedder is removed, retrieval reverts to it (and Ask Posey re-locks, since
/// the unlock is present-based on an advanced embedder being active).
///
/// Download / delete run through `MLXModelDownloader` (the same pipeline as the
/// answer models); swift-embeddings then loads the fetched bundle from disk. The
/// heavy Select → re-embed migration is surfaced by the section's shared status
/// footer, so the row's Select button stays quiet and just triggers it.
struct AskPoseyEmbedderRow: View {
    let backend: EmbeddingBackend
    /// The active (read) backend — drives the green dot + the "Active" state.
    let isActive: Bool
    /// A backend swap / re-embed migration is in flight — actions are disabled
    /// so a second switch can't race a half-built column.
    let isBusy: Bool
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @ObservedObject private var downloader = MLXModelDownloader.shared

    private var isDownloading: Bool {
        guard let id = backend.modelID else { return false }
        return downloader.downloadStates[id]?.isDownloading == true
    }

    /// Built-in NLContextual (`modelID == nil`) is always "downloaded" — iOS
    /// manages its asset. A downloadable backend counts as present if it's on
    /// disk by ANY path (this app's downloader, or a prior swift-embeddings /
    /// App-Group copy), but never while a fetch is mid-flight into a partial dir
    /// (that's the Download-progress state below).
    private var isDownloaded: Bool {
        guard let id = backend.modelID else { return true }
        if isDownloading { return false }
        return downloader.isModelDownloaded(id) || SharedModelStore.isRepoDownloaded(id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header: name + size + status dot + chevron.
            Button(action: onToggleExpand) {
                HStack(spacing: 10) {
                    Text(backend.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let size = backend.sizeBlurb {
                        Text(size)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    // green = active, grey = downloaded, none = not downloaded.
                    if isActive {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                            .accessibilityLabel("Active")
                    } else if isDownloaded {
                        Circle().fill(Color.gray.opacity(0.5)).frame(width: 8, height: 8)
                            .accessibilityLabel("Downloaded")
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.vertical, 8)
                Text(backend.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                Text("\(backend.dimension)-dim sentence vectors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                actionRow
            }
        }
        .padding(.vertical, 4)
    }

    // Action row matches the language-model row's visual weight: SF-Symbol +
    // short label, .plain buttons, Delete in red. NLContextual (`modelID == nil`)
    // never shows Download or Delete — only Select.
    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 12) {
            if isActive {
                Button(action: {}) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Active")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(true)
                Spacer()
                // The active advanced embedder CAN be deleted — it reverts to the
                // NLContextual floor (Mark's rule). NLContextual itself has no
                // Delete (modelID == nil).
                if backend.modelID != nil { deleteButton }
            } else if !isDownloaded {
                if isDownloading {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: downloader.downloadStates[backend.modelID ?? ""]?.progress ?? 0)
                        if let msg = downloader.downloadStates[backend.modelID ?? ""]?.message, !msg.isEmpty {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
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
                    .disabled(isBusy)
                    Spacer()
                }
            } else {
                // Downloaded but not active — Select triggers the re-embed
                // migration (surfaced by the section's status footer).
                Button(action: onSelect) {
                    HStack(spacing: 4) {
                        Image(systemName: "circle")
                        Text("Select")
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                Spacer()
                if backend.modelID != nil { deleteButton }
            }
        }
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            HStack(spacing: 4) {
                Image(systemName: "trash")
                Text("Delete")
            }
            .font(.subheadline)
            .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }
}
// ========== BLOCK 01: ASK POSEY EMBEDDER ROW - END ==========
