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
        if FileManager.default.fileExists(atPath: u.path) { progress(1.0); return u }

        // Ride an in-flight download for the same destination if there is one.
        if let existing = inFlight[u.path] { return try await existing.value }

        let task = Task<URL, Error> { try await Self.download(e, to: u, via: service, progress: progress) }
        inFlight[u.path] = task
        defer { inFlight[u.path] = nil }
        return try await task.value
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
}
