import Foundation

/// Reports and clears the on-disk caches (downloaded files + thumbnails).
enum CacheManager {
    private static var dirs: [URL] {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return [caches.appendingPathComponent("files"), caches.appendingPathComponent("thumbs")]
    }

    static func totalSize() -> Int64 {
        var total: Int64 = 0
        for dir in dirs {
            guard let en = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in en {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    static func clear() {
        for dir in dirs {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
