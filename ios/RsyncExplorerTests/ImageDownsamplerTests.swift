import XCTest
import UIKit
@testable import RsyncExplorer

final class ImageDownsamplerTests: XCTestCase {
    private func makePNG(width: CGFloat, height: CGFloat) throws -> URL {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // 1 point == 1 pixel, so the PNG is exactly width x height pixels
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let img = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        try img.pngData()!.write(to: url)
        return url
    }

    func test_caps_largest_dimension() throws {
        let url = try makePNG(width: 4000, height: 3000)
        defer { try? FileManager.default.removeItem(at: url) }
        let out = ImageDownsampler.downsample(fileURL: url, maxPixel: 200)
        let cg = try XCTUnwrap(out?.cgImage)
        XCTAssertLessThanOrEqual(max(cg.width, cg.height), 200)
        XCTAssertGreaterThan(min(cg.width, cg.height), 0)
    }

    func test_does_not_upscale_small_image() throws {
        let url = try makePNG(width: 100, height: 100)
        defer { try? FileManager.default.removeItem(at: url) }
        let out = ImageDownsampler.downsample(fileURL: url, maxPixel: 500)
        let cg = try XCTUnwrap(out?.cgImage)
        XCTAssertEqual(cg.width, 100)
        XCTAssertEqual(cg.height, 100)
    }

    func test_missing_file_returns_nil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        XCTAssertNil(ImageDownsampler.downsample(fileURL: url, maxPixel: 200))
    }
}
