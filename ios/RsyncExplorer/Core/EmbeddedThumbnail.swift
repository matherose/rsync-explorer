import ImageIO
import UIKit

/// Extracts an *already-embedded* thumbnail (the EXIF/preview image most cameras
/// and phones write into a photo's header) from a chunk of file bytes — without
/// ever decoding the full image. That's what lets it run on just the first ~256 KB
/// of a remote file: if the embedded thumbnail's bytes are present it's returned,
/// otherwise nil and the caller falls back to a full download.
enum EmbeddedThumbnail {
    static func extract(from data: Data, maxPixel: Int = 200) -> UIImage? {
        guard !data.isEmpty,
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Embedded-only: never build a thumbnail from the full image (we may only
        // hold a truncated prefix), so a missing embedded thumbnail yields nil.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
