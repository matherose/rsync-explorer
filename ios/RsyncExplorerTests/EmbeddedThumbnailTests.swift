import XCTest
import ImageIO
import UIKit
@testable import RsyncExplorer

final class EmbeddedThumbnailTests: XCTestCase {

    /// A solid-colour CGImage at `size` (scale 1 so pixel dims are exact).
    private func solidImage(_ size: CGSize) -> CGImage {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return img.cgImage!
    }

    /// Random-noise CGImage — JPEG-encodes large (noise doesn't compress), so a
    /// header prefix is a genuine fraction of the file, like a real photo.
    private func noisyImage(_ side: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for i in pixels.indices { pixels[i] = UInt8.random(in: 0...255) }
        let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// Encodes `cg` as JPEG, optionally asking ImageIO to embed an EXIF thumbnail.
    private func jpegData(_ cg: CGImage, embedThumbnail: Bool) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        let opts: [CFString: Any] = embedThumbnail ? [kCGImageDestinationEmbedThumbnail: true] : [:]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    func test_extracts_embedded_thumbnail() {
        let data = jpegData(solidImage(CGSize(width: 1200, height: 1200)), embedThumbnail: true)
        let thumb = EmbeddedThumbnail.extract(from: data, maxPixel: 200)
        XCTAssertNotNil(thumb)
        XCTAssertLessThanOrEqual(max(thumb!.size.width, thumb!.size.height), 200)
    }

    func test_returns_nil_when_no_embedded_thumbnail() {
        // Embedded-only: must NOT synthesize a thumbnail from the full image.
        let data = jpegData(solidImage(CGSize(width: 1200, height: 1200)), embedThumbnail: false)
        XCTAssertNil(EmbeddedThumbnail.extract(from: data))
    }

    func test_finds_thumbnail_in_truncated_prefix() {
        // The whole point: the embedded thumbnail lives in the header (EXIF APP1 is
        // <= 64 KB and at the start), so a prefix of a large file is enough — no need
        // to download the multi-MB main image.
        let full = jpegData(noisyImage(1200), embedThumbnail: true)
        let prefix = Data(full.prefix(128 * 1024))
        XCTAssertLessThan(prefix.count, full.count)   // genuinely truncated
        XCTAssertNotNil(EmbeddedThumbnail.extract(from: prefix, maxPixel: 200))
    }

    func test_returns_nil_for_garbage_or_empty() {
        XCTAssertNil(EmbeddedThumbnail.extract(from: Data()))
        XCTAssertNil(EmbeddedThumbnail.extract(from: Data([0x00, 0x01, 0x02, 0x03, 0x04])))
    }
}
