import Foundation

// ========== BLOCK 01: TYPES - START ==========
/// One entry in the audio-export cache, used by Preferences UI.
public struct CachedAudioExport: Hashable, Sendable {
    public let documentID: UUID
    public let url: URL
    public let bytes: Int64
    public let createdAt: Date
}
// ========== BLOCK 01: TYPES - END ==========


// ========== BLOCK 02: CACHE SERVICE - START ==========
/// One persistent cached `.m4a` per document, stored under
/// `Library/Caches/Posey/AudioExports/`. Caches dir is iOS-clearable
/// under storage pressure, doesn't count as user-managed storage in
/// Settings → iPhone Storage, and survives across app launches.
///
/// Filename convention: `<documentID>.m4a`. One file per document.
/// Re-export of the same doc overwrites the cached file.
///
/// The class is a thin file-system wrapper — no SQL, no state — so
/// the source of truth is always the on-disk directory. Listening,
/// deletion, and totals are all derived from `FileManager` calls.
///
/// **Source-doc invalidation.** Subscribes to `.documentDidDelete`
/// notifications posted by the library and removes the matching
/// cached file. The notification carries the document UUID under
/// `notificationDocumentIDKey`.
public final class AudioExportCache: @unchecked Sendable {

    public static let shared = AudioExportCache()

    /// Notification posted right after a document is removed from
    /// the database. Posters: `LibraryViewModel.deleteDocument(_:)`.
    public static let documentDidDelete = Notification.Name("AudioExportCache.documentDidDelete")
    public static let notificationDocumentIDKey = "documentID"

    private let fileManager: FileManager
    private let directoryURL: URL
    private var observerToken: NSObjectProtocol?

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let caches = (try? fileManager.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? fileManager.temporaryDirectory
        self.directoryURL = caches
            .appendingPathComponent("Posey", isDirectory: true)
            .appendingPathComponent("AudioExports", isDirectory: true)
        try? fileManager.createDirectory(
            at: self.directoryURL, withIntermediateDirectories: true
        )
        // Subscribe to document-deletion notifications so the cache
        // is purged in lockstep with the library. The observer is
        // retained for the singleton's lifetime (process-wide).
        observerToken = NotificationCenter.default.addObserver(
            forName: Self.documentDidDelete,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard
                let self,
                let id = note.userInfo?[Self.notificationDocumentIDKey] as? UUID
            else { return }
            self.delete(for: id)
        }
    }

    deinit {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// The on-disk directory this cache is using. Exposed for tests
    /// and diagnostics.
    public var directory: URL { directoryURL }

    /// URL that a cached export for `documentID` SHOULD live at.
    /// Does not check existence — pair with `cachedURL(for:)` or
    /// `FileManager.fileExists` to test presence.
    public func intendedURL(for documentID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(documentID.uuidString).m4a")
    }

    /// Returns the URL of the cached export for `documentID` if one
    /// exists, otherwise nil.
    public func cachedURL(for documentID: UUID) -> URL? {
        let url = intendedURL(for: documentID)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Move (or copy) a rendered M4A from `sourceURL` into the cache
    /// for `documentID`. Atomically replaces any existing cached file.
    /// Returns the new cached URL.
    @discardableResult
    public func store(_ sourceURL: URL, for documentID: UUID) throws -> URL {
        let destination = intendedURL(for: documentID)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        // Prefer move (avoids doubling disk usage); fall back to copy
        // if the source isn't on the same volume or the caller wants
        // the source preserved.
        do {
            try fileManager.moveItem(at: sourceURL, to: destination)
        } catch {
            try fileManager.copyItem(at: sourceURL, to: destination)
        }
        return destination
    }

    /// Remove the cached export for `documentID` if any. Safe to call
    /// when no file exists.
    public func delete(for documentID: UUID) {
        let url = intendedURL(for: documentID)
        try? fileManager.removeItem(at: url)
    }

    /// Remove every cached export. Used by the "Delete All" button
    /// in Preferences. Safe to call when the cache is empty.
    public func deleteAll() {
        for entry in listCached() {
            try? fileManager.removeItem(at: entry.url)
        }
    }

    /// Enumerate every cached file, sorted newest-first. Reads
    /// `creationDate` + file size from disk; no separate index needed.
    public func listCached() -> [CachedAudioExport] {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        let contents: [URL] = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        var rows: [CachedAudioExport] = []
        for url in contents where url.pathExtension.lowercased() == "m4a" {
            let base = url.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: base) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.fileSize ?? 0)
            let date = values?.creationDate ?? Date(timeIntervalSince1970: 0)
            rows.append(CachedAudioExport(
                documentID: id, url: url, bytes: size, createdAt: date
            ))
        }
        rows.sort { $0.createdAt > $1.createdAt }
        return rows
    }

    /// Sum of every cached file's size in bytes. Convenience for the
    /// "Total: X.X MB" footer.
    public func totalBytes() -> Int64 {
        listCached().reduce(0) { $0 + $1.bytes }
    }
}
// ========== BLOCK 02: CACHE SERVICE - END ==========


// ========== BLOCK 03: FORMATTING HELPERS - START ==========
extension Int64 {
    /// Human-readable byte size: "324 KB", "4.2 MB", etc. Uses
    /// `ByteCountFormatter` with binary (KB/MB) units.
    var formattedByteSize: String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: self)
    }
}
// ========== BLOCK 03: FORMATTING HELPERS - END ==========
