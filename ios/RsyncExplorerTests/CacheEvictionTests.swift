import XCTest
@testable import RsyncExplorer

final class CacheEvictionTests: XCTestCase {
    private func item(_ name: String, _ size: Int64, secondsAgo: TimeInterval) -> CacheEviction.Item {
        CacheEviction.Item(url: URL(fileURLWithPath: "/cache/\(name)"),
                           size: size, lastUsed: Date(timeIntervalSinceNow: -secondsAgo))
    }

    func test_no_eviction_when_within_cap() {
        let items = [item("a", 100, secondsAgo: 10), item("b", 100, secondsAgo: 5)]
        XCTAssertTrue(CacheEviction.targets(items, maxBytes: 1000, target: 800).isEmpty)
    }

    func test_evicts_oldest_first_down_to_target() {
        let items = [item("oldest", 300, secondsAgo: 100),
                     item("mid", 300, secondsAgo: 50),
                     item("newest", 400, secondsAgo: 1)]   // total 1000
        let victims = CacheEviction.targets(items, maxBytes: 900, target: 600)
        XCTAssertEqual(victims.map(\.lastPathComponent), ["oldest", "mid"])
    }

    func test_keeps_most_recently_used() {
        let items = [item("oldest", 800, secondsAgo: 100),
                     item("newest", 800, secondsAgo: 1)]   // total 1600
        let victims = CacheEviction.targets(items, maxBytes: 1000, target: 800)
        XCTAssertEqual(victims.map(\.lastPathComponent), ["oldest"])
    }
}
