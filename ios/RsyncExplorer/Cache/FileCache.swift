import Foundation

/// Caches downloaded files in Caches/files, keyed by path+size+mtime so a refreshed
/// backup file re-downloads automatically. The original extension is preserved so
/// players/QuickLook can infer the type from the URL.
actor FileCache {
    static let shared = FileCache()
    private let root: URL
    /// Downloads in progress, keyed by destination path. A second request for the
    /// same file rides the existing download instead of racing on the `.part` temp
    /// file or fetching the (possibly multi-GB) file twice.
    private var inFlight: [String: Task<URL, Error>] = [:]
    /// Soft cap on the downloaded-files cache; eviction trims back to `evictTarget`.
    private let maxBytes: Int64 = 1_500_000_000          // ~1.5 GB
    private let evictTarget: Int64 = 1_200_000_000       // trim down to ~1.2 GB

    init() {
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func url(for e: RemoteEntry) -> URL {
        let key = CacheKey.make(path: e.path, size: e.size,
                                mtime: e.modificationDate?.timeIntervalSince1970 ?? 0)
        let ext = (e.name as NSString).pathExtension
        let base = root.appendingPathComponent(key)
        return ext.isEmpty ? base : base.appendingPathExtension(ext)
    }

    func cachedURL(for e: RemoteEntry) -> URL? {
        let u = url(for: e)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func fetch(_ e: RemoteEntry, via service: SFTPService,
               progress: @escaping (Double) -> Void) async throws -> URL {
        let u = url(for: e)
        if FileManager.default.fileExists(atPath: u.path) {
            touch(u)            // mark as recently used for LRU eviction
            progress(1.0)
            return u
        }

        // Ride an in-flight download for the same destination if there is one.
        if let existing = inFlight[u.path] { return try await existing.value }

        let task = Task<URL, Error> { try await Self.download(e, to: u, via: service, progress: progress) }
        inFlight[u.path] = task
        defer { inFlight[u.path] = nil }
        let result = try await task.value
        enforceLimit()          // trim the cache after adding a new file
        return result
    }

    /// Downloads to a private temp file then atomically publishes it at `u`.
    private static func download(_ e: RemoteEntry, to u: URL, via service: SFTPService,
                                 progress: @escaping (Double) -> Void) async throws -> URL {
        let tmp = u.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)
        try await service.download(e.path, to: tmp, progress: progress)
        try? FileManager.default.removeItem(at: u)
        try FileManager.default.moveItem(at: tmp, to: u)
        return u
    }

    /// Bumps a file's modification date to now so LRU eviction treats it as fresh.
    private func touch(_ u: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
    }

    /// Evicts least-recently-used files once the cache exceeds `maxBytes`. Skips
    /// in-progress `.part` files. Streaming playback never goes through this cache,
    /// so eviction can't pull a file out from under an active video/audio stream.
    private func enforceLimit() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys) else { return }
        let items: [CacheEviction.Item] = urls.compactMap { url in
            guard url.pathExtension != "part",
                  let v = try? url.resourceValues(forKeys: Set(keys)),
                  let size = v.fileSize else { return nil }
            return CacheEviction.Item(url: url, size: Int64(size),
                                      lastUsed: v.contentModificationDate ?? .distantPast)
        }
        for victim in CacheEviction.targets(items, maxBytes: maxBytes, target: evictTarget) {
            try? FileManager.default.removeItem(at: victim)
        }
    }
}
