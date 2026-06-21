import XCTest
@testable import RsyncExplorer

final class DeletionDiffTests: XCTestCase {
    private func f(_ name: String) -> RemoteEntry {
        RemoteEntry(name: name, path: "/p/\(name)", isDirectory: false, size: 1, modificationDate: nil)
    }

    func test_deleted_are_in_previous_not_latest() {
        let latest = [f("a.jpg"), f("b.jpg")]
        let previous = [f("a.jpg"), f("b.jpg"), f("gone.jpg")]
        XCTAssertEqual(DeletionDiff.deleted(latest: latest, previous: previous).map(\.name),
                       ["gone.jpg"])
    }

    func test_no_deletions() {
        let latest = [f("a.jpg"), f("b.jpg")]
        XCTAssertTrue(DeletionDiff.deleted(latest: latest, previous: latest).isEmpty)
    }

    func test_all_deleted_when_latest_empty() {
        let previous = [f("a.jpg"), f("b.jpg")]
        XCTAssertEqual(Set(DeletionDiff.deleted(latest: [], previous: previous).map(\.name)),
                       ["a.jpg", "b.jpg"])
    }
}
