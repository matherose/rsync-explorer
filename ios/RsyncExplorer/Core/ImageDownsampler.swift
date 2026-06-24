import UIKit
import ImageIO

/// Decodes an image file at a bounded pixel size using ImageIO, so a 50-megapixel
/// photo doesn't get fully decoded into memory (which can crash on device). Never
/// upscales: if the source is already smaller than `maxPixel`, it decodes at the
/// original size.
enum ImageDownsampler {
    static func downsample(fileURL: URL, maxPixel: CGFloat) -> UIImage? {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, srcOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honor EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
