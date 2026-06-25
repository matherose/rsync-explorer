import UIKit
import ImageIO
import VLCKitSPM

/// Generates + caches list thumbnails. Images via ImageIO; videos via VLCKit's
/// thumbnailer pointed at the streaming URL (grabs a frame over HTTP range, no
/// full download). Cheap value type holding shared references.
struct ThumbnailService {
    let service: SFTPService
    let streamServer: LocalStreamServer
    private let cache = ThumbnailCache.shared

    func thumbnail(for e: RemoteEntry) async -> UIImage? {
        if let cached = cache.image(for: e) { return cached }
        let img: UIImage?
        switch e.kind {
        case .image: img = await imageThumb(e)
        case .video: img = await videoThumb(e)
        default: img = nil
        }
        if let img { cache.store(img, for: e) }
        return img
    }

    private static let headerBytes = 256 * 1024   // enough for a typical EXIF/preview thumbnail

    private func imageThumb(_ e: RemoteEntry) async -> UIImage? {
        // Fast path: for files bigger than the header window, pull just the header and
        // use the embedded EXIF/preview thumbnail — avoids downloading a multi-MB photo
        // to make a 200px thumb. (Small files fall straight through to the cached full
        // download, which is just as cheap and keeps the file warm for opening.)
        if e.size == 0 || e.size > Int64(Self.headerBytes),
           let header = await readPrefix(e, maxBytes: Self.headerBytes),
           let img = EmbeddedThumbnail.extract(from: header, maxPixel: 200) {
            return img
        }
        // Fallback: full download + downsample (covers images with no embedded thumbnail).
        guard let url = try? await FileCache.shared.fetch(e, via: service, progress: { _ in }),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 200,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Reads up to `maxBytes` from the start of the file, tolerating short SFTP reads
    /// (a single SFTP READ may return less than requested).
    private func readPrefix(_ e: RemoteEntry, maxBytes: Int) async -> Data? {
        var data = Data()
        var offset: UInt64 = 0
        let chunk = 64 * 1024
        while data.count < maxBytes {
            let want = UInt32(min(chunk, maxBytes - data.count))
            guard let part = try? await service.read(at: e.path, offset: offset, length: want),
                  !part.isEmpty else { break }
            data.append(part)
            offset += UInt64(part.count)
            if part.count < Int(want) { break }   // short read → EOF or server cap
        }
        return data.isEmpty ? nil : data
    }

    private func videoThumb(_ e: RemoteEntry) async -> UIImage? {
        guard let url = try? await streamServer.streamURL(path: e.path, size: e.size) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            Task { @MainActor in
                let delegate = VideoThumbDelegate { cont.resume(returning: $0) }
                delegate.start(media: VLCMedia(url: url))
            }
        }
    }
}

@MainActor
private final class VideoThumbDelegate: NSObject, VLCMediaThumbnailerDelegate {
    private let completion: (UIImage?) -> Void
    private var thumbnailer: VLCMediaThumbnailer?
    private var selfRef: VideoThumbDelegate?
    private var done = false

    init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }

    func start(media: VLCMedia) {
        selfRef = self   // keep alive until the (weak) delegate callback fires
        let t = VLCMediaThumbnailer(media: media, andDelegate: self)
        t.thumbnailWidth = 200
        t.thumbnailHeight = 200
        thumbnailer = t
        t.fetchThumbnail()
    }

    private func finish(_ image: UIImage?) {
        guard !done else { return }
        done = true
        completion(image)
        thumbnailer = nil
        selfRef = nil
    }

    nonisolated func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) {
        let img = UIImage(cgImage: thumbnail)
        Task { @MainActor in self.finish(img) }
    }
}
