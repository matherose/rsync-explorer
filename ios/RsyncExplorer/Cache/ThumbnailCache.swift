import UIKit

/// Small on-disk JPEG thumbnails in Caches/thumbs, keyed by path+size+mtime.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let root: URL

    private init() {
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func url(for e: RemoteEntry) -> URL {
        let key = CacheKey.make(path: e.path, size: e.size,
                                mtime: e.modificationDate?.timeIntervalSince1970 ?? 0)
        return root.appendingPathComponent(key).appendingPathExtension("jpg")
    }

    func image(for e: RemoteEntry) -> UIImage? {
        UIImage(contentsOfFile: url(for: e).path)
    }

    func store(_ image: UIImage, for e: RemoteEntry) {
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: url(for: e))
        }
    }
}
