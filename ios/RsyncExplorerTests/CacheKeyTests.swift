import XCTest
@testable import RsyncExplorer

final class CacheKeyTests: XCTestCase {
    func test_stable_for_same_inputs() {
        let a = CacheKey.make(path: "/b/x.jpg", size: 10, mtime: 1000)
        let b = CacheKey.make(path: "/b/x.jpg", size: 10, mtime: 1000)
        XCTAssertEqual(a, b)
    }
    func test_changes_when_mtime_changes() {
        let a = CacheKey.make(path: "/b/x.jpg", size: 10, mtime: 1000)
        let b = CacheKey.make(path: "/b/x.jpg", size: 10, mtime: 2000)
        XCTAssertNotEqual(a, b)
    }
    func test_is_filename_safe_hex() {
        let k = CacheKey.make(path: "/b/weird name?.jpg", size: 1, mtime: 1)
        XCTAssertTrue(k.allSatisfy { $0.isHexDigit })
    }
}
