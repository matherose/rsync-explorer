import Foundation

/// Caches downloaded files in Caches/files, keyed by path+size+mtime so a refreshed
/// backup file re-downloads automatically. The original extension is preserved so
/// players/QuickLook can infer the type from the URL.
actor FileCache {
    static let shared = FileCache()
    private let root: URL

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
        let tmp = u.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)
        try await service.download(e.path, to: tmp, progress: progress)
        try? FileManager.default.removeItem(at: u)
        try FileManager.default.moveItem(at: tmp, to: u)
        return u
    }
}
