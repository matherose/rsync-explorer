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

    private func file(_ name: String, _ ts: TimeInterval?) -> RemoteEntry {
        RemoteEntry(name: name, path: "/b/\(name)", isDirectory: false, size: 0,
                    modificationDate: ts.map { Date(timeIntervalSince1970: $0) })
    }

    func test_isDatedSnapshot() {
        XCTAssertTrue(SnapshotResolver.isDatedSnapshot("2026-06-12_02-00"))
        XCTAssertFalse(SnapshotResolver.isDatedSnapshot("latest"))
        XCTAssertFalse(SnapshotResolver.isDatedSnapshot("Photos"))
    }

    func test_datedSnapshots_newest_first_excludes_non_dated() {
        let entries = [dir("2026-06-05_02-00", 100), file("latest", 999),
                       dir("2026-06-12_02-00", 200), file("notes.txt", nil)]
        XCTAssertEqual(SnapshotResolver.datedSnapshots(from: entries).map(\.name),
                       ["2026-06-12_02-00", "2026-06-05_02-00"])
    }

    func test_context_with_latest_symlink() {
        let entries = [dir("2026-06-05_02-00", 100), dir("2026-06-12_02-00", 200),
                       file("latest", 999)]
        let ctx = SnapshotResolver.context(remotePath: "/b", entries: entries)
        XCTAssertEqual(ctx.latestRoot, "/b/latest")
        XCTAssertEqual(ctx.previousRoot, "/b/2026-06-05_02-00")
    }

    func test_context_without_latest_falls_back_to_newest_dated() {
        let entries = [dir("2026-06-05_02-00", 100), dir("2026-06-12_02-00", 200)]
        let ctx = SnapshotResolver.context(remotePath: "/b/", entries: entries)
        XCTAssertEqual(ctx.latestRoot, "/b/2026-06-12_02-00")
        XCTAssertEqual(ctx.previousRoot, "/b/2026-06-05_02-00")
    }

    func test_context_single_snapshot_has_no_previous() {
        let ctx = SnapshotResolver.context(remotePath: "/b", entries: [dir("2026-06-12_02-00", 200)])
        XCTAssertEqual(ctx.latestRoot, "/b/2026-06-12_02-00")
        XCTAssertNil(ctx.previousRoot)
    }

    func test_parentPath() {
        XCTAssertEqual(SnapshotResolver.parentPath("/mnt/nas/BACK_EXT/latest"), "/mnt/nas/BACK_EXT")
        XCTAssertEqual(SnapshotResolver.parentPath("/mnt/nas/BACK_EXT/"), "/mnt/nas")
        XCTAssertEqual(SnapshotResolver.parentPath("/foo"), "/")
        XCTAssertEqual(SnapshotResolver.parentPath("/"), "/")
    }
}
