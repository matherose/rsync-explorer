import XCTest
@testable import RsyncExplorer

final class DirectoryListerTests: XCTestCase {
    private let roots = ["/snap/new", "/snap/old"]

    private func file(_ name: String, _ root: String) -> RemoteEntry {
        RemoteEntry(name: name, path: root + "/" + name, isDirectory: false, size: 1,
                    modificationDate: Date(timeIntervalSince1970: 1))
    }

    func test_prefers_server_side_find_when_available() async {
        let out = "f\t1\t1\t/snap/new/a.txt\nf\t1\t1\t/snap/old/b.txt\n\(RemoteListing.sentinel)\n"
        let svc = FakeSFTPService(tree: [:]) { cmd in cmd.contains("find -H") ? out : "" }
        let result = await DirectoryLister.load(roots: roots, rel: "", service: svc)
        XCTAssertEqual(result?.listings.map(\.count), [1, 1])
        XCTAssertEqual(result?.complete, true)
    }

    func test_falls_back_to_sftp_and_is_complete_when_all_read() async {
        // No find tool -> per-root SFTP. Every root read OK -> complete (cacheable).
        let svc = FakeSFTPService(tree: [
            "/snap/new": [file("a.txt", "/snap/new")],
            "/snap/old": [file("b.txt", "/snap/old")],
        ])
        let result = await DirectoryLister.load(roots: roots, rel: "", service: svc)
        XCTAssertEqual(result?.listings.map { $0.map(\.name) }, [["a.txt"], ["b.txt"]])
        XCTAssertEqual(result?.complete, true)
    }

    func test_partial_read_surfaces_data_but_is_incomplete() async {
        // The newest snapshot reads; an older one fails transiently. We still show what
        // we got, but the result is INCOMPLETE so the caller must not cache it (this is
        // exactly the "only the latest snapshot" symptom — it must not stick).
        let svc = FakeSFTPService(
            tree: ["/snap/new": [file("a.txt", "/snap/new")]],
            unreadablePaths: ["/snap/old"])
        let result = await DirectoryLister.load(roots: roots, rel: "", service: svc)
        XCTAssertEqual(result?.listings.map { $0.map(\.name) }, [["a.txt"], []])
        XCTAssertEqual(result?.complete, false)
    }

    func test_total_failure_returns_nil() async {
        // Nothing could be read at all -> surface a load error, don't return empty.
        let svc = FakeSFTPService(tree: [:], unreadablePaths: Set(roots))
        let result = await DirectoryLister.load(roots: roots, rel: "", service: svc)
        XCTAssertNil(result)
    }

    func test_empty_roots_returns_nil() async {
        let svc = FakeSFTPService(tree: [:])
        let result = await DirectoryLister.load(roots: [], rel: "", service: svc)
        XCTAssertNil(result)
    }
}
