import XCTest
@testable import RsyncExplorer

final class SnapshotMergeTests: XCTestCase {
    private func f(_ name: String, _ root: String) -> RemoteEntry {
        RemoteEntry(name: name, path: "\(root)/\(name)", isDirectory: false, size: 1, modificationDate: nil)
    }

    func test_union_marks_deleted_and_keeps_newest_representative() {
        let newest = [f("a", "/s2"), f("b", "/s2")]
        let older = [f("a", "/s1"), f("b", "/s1"), f("gone", "/s1")]
        let items = SnapshotMerge.merge([newest, older])
        XCTAssertEqual(items.map(\.entry.name), ["a", "b", "gone"])
        XCTAssertEqual(items.map(\.isDeleted), [false, false, true])
        XCTAssertEqual(items.first { $0.entry.name == "a" }?.entry.path, "/s2/a")
        XCTAssertEqual(items.first { $0.entry.name == "gone" }?.entry.path, "/s1/gone")
    }

    func test_empty() {
        XCTAssertTrue(SnapshotMerge.merge([]).isEmpty)
    }

    func test_single_snapshot_no_deletions() {
        XCTAssertEqual(SnapshotMerge.merge([[f("a", "/s1")]]).map(\.isDeleted), [false])
    }
}
