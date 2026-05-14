import SwiftUI

// ========== BLOCK 01: VIEW - START ==========
/// "Cached Audio Files" Section in the Reader Preferences sheet.
/// Lists every persistently cached M4A export across all documents,
/// with per-row Delete and a section-footer Delete All + total bytes.
///
/// This view is intentionally NOT scoped to the currently-open
/// document — the cache is global. Showing the list here lets the
/// user audit what's taking up space without leaving the reader.
///
/// Data source is `AudioExportCache.shared.listCached()`, read on
/// every `body` render. The list is small in practice (a few rows)
/// so re-reading the directory is cheap; we refresh after Deletes
/// by bumping a SwiftUI state cookie.
struct CachedAudioFilesSection: View {

    /// Database access for looking up document titles by ID.
    let databaseManager: DatabaseManager

    /// Bumped after every mutation so the view re-reads the cache.
    @State private var refreshCookie: Int = 0

    /// Cached snapshot of the directory listing for this render pass.
    private var entries: [CachedAudioExport] {
        _ = refreshCookie
        return AudioExportCache.shared.listCached()
    }

    /// Title lookup so each row can show the document title rather
    /// than a UUID. Pulled from the app's database manager via the
    /// shared LibraryViewModel injection. If the lookup fails the
    /// row falls back to a friendly "(deleted)" label and the file
    /// is still removable.
    @State private var titlesByID: [UUID: String] = [:]

    var body: some View {
        Section {
            let rows = entries
            if rows.isEmpty {
                Text("No cached audio files yet. Exporting a document caches its audio here so you can replay or re-share without re-rendering.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.documentID) { entry in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(titlesByID[entry.documentID] ?? "(deleted)")
                                .font(.body)
                                .lineLimit(1)
                            Text(entry.bytes.formattedByteSize)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            AudioExportCache.shared.delete(for: entry.documentID)
                            refreshCookie &+= 1
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Delete cached audio for \(titlesByID[entry.documentID] ?? "deleted document")")
                        .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("Cached Audio Files")
        } footer: {
            if entries.isEmpty {
                Text("Cached files live under iOS's clearable storage and may be automatically removed when your device is low on space.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Total: \(AudioExportCache.shared.totalBytes().formattedByteSize)")
                        .font(.caption)
                    Button(role: .destructive) {
                        AudioExportCache.shared.deleteAll()
                        refreshCookie &+= 1
                    } label: {
                        Label("Delete All Cached Audio", systemImage: "trash")
                    }
                    .accessibilityIdentifier("preferences.cachedAudio.deleteAll")
                }
            }
        }
        .task(id: refreshCookie) {
            await loadTitles()
        }
    }

    /// Pull document titles from the injected DatabaseManager so
    /// rows can show human-readable names. Runs every time the
    /// cookie bumps (delete operations) and once on mount. Rows for
    /// documents that have since been deleted fall back to
    /// "(deleted)" but remain removable.
    private func loadTitles() async {
        let docs = (try? databaseManager.documents()) ?? []
        var map: [UUID: String] = [:]
        for doc in docs { map[doc.id] = doc.title }
        titlesByID = map
    }
}
// ========== BLOCK 01: VIEW - END ==========
