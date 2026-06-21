import XCTest
@testable import RsyncExplorer

final class SnapshotResolverTests: XCTestCase {
    private func dir(_ name: String, _ ts: TimeInterval) -> RemoteEntry {
        RemoteEntry(name: name, path: "/b/\(name)", isDirectory: true,
                    size: 0, modificationDate: Date(timeIntervalSince1970: ts))
    }
    func test_picks_newest_by_mtime() {
        let entries = [dir("2026-06-01", 100), dir("2026-06-20", 300), dir("2026-06-10", 200)]
        XCTAssertEqual(SnapshotResolver.latest(from: entries)?.name, "2026-06-20")
    }
    func test_mtime_tie_breaks_on_name_desc() {
        let entries = [dir("2026-06-19", 300), dir("2026-06-20", 300)]
        XCTAssertEqual(SnapshotResolver.latest(from: entries)?.name, "2026-06-20")
    }
    func test_ignores_files() {
        let file = RemoteEntry(name: "z.txt", path: "/b/z.txt", isDirectory: false,
                               size: 1, modificationDate: Date(timeIntervalSince1970: 999))
        XCTAssertEqual(SnapshotResolver.latest(from: [dir("snap", 1), file])?.name, "snap")
    }
    func test_empty_returns_nil() {
        XCTAssertNil(SnapshotResolver.latest(from: []))
    }
}
