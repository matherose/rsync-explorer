import XCTest
@testable import RsyncExplorer

final class SnapshotProvenanceTests: XCTestCase {
    private let roots = ["/backup/latest", "/backup/2026-06-20", "/backup/2026-06-01"]

    func test_name_for_file_in_dated_snapshot() {
        XCTAssertEqual(
            SnapshotResolver.snapshotName(forPath: "/backup/2026-06-01/Photos/x.jpg", roots: roots),
            "2026-06-01")
    }

    func test_name_for_file_via_latest_pointer() {
        XCTAssertEqual(
            SnapshotResolver.snapshotName(forPath: "/backup/latest/Music/song.mp3", roots: roots),
            "latest")
    }

    func test_matches_exact_root_path() {
        XCTAssertEqual(SnapshotResolver.snapshotName(forPath: "/backup/2026-06-20", roots: roots),
                       "2026-06-20")
    }

    func test_path_under_no_root_returns_nil() {
        XCTAssertNil(SnapshotResolver.snapshotName(forPath: "/elsewhere/file.txt", roots: roots))
    }

    func test_prefix_collision_is_not_matched() {
        // "/backup/2026-06-2099" must NOT match root "/backup/2026-06-20".
        XCTAssertNil(SnapshotResolver.snapshotName(forPath: "/backup/2026-06-2099/x", roots: roots))
    }
}
