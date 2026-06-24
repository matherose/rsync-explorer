import XCTest
@testable import RsyncExplorer

final class ConnectorTests: XCTestCase {
    private func dir(_ name: String, _ root: String, _ ts: TimeInterval) -> RemoteEntry {
        RemoteEntry(name: name, path: "\(root)/\(name)", isDirectory: true, size: 0,
                    modificationDate: Date(timeIntervalSince1970: ts))
    }
    private func file(_ name: String, _ root: String) -> RemoteEntry {
        RemoteEntry(name: name, path: "\(root)/\(name)", isDirectory: false, size: 1, modificationDate: nil)
    }

    func test_pointer_is_prepended_as_newest_root() async {
        let svc = FakeSFTPService(tree: [
            "/backup": [dir("2026-06-01", "/backup", 100),
                        dir("2026-06-20", "/backup", 300),
                        dir("latest", "/backup", 400),
                        file("note.txt", "/backup")],
        ])
        let roots = await Connector.resolveRoots(snapshotsPath: "/backup", pointerName: "latest", via: svc)
        XCTAssertEqual(roots, ["/backup/latest", "/backup/2026-06-20", "/backup/2026-06-01"])
    }

    func test_custom_pointer_name() async {
        let svc = FakeSFTPService(tree: [
            "/b": [dir("2026-06-20", "/b", 300), dir("current", "/b", 400)],
        ])
        let roots = await Connector.resolveRoots(snapshotsPath: "/b", pointerName: "current", via: svc)
        XCTAssertEqual(roots, ["/b/current", "/b/2026-06-20"])
    }

    func test_pointer_absent_uses_dated_only() async {
        let svc = FakeSFTPService(tree: [
            "/b": [dir("2026-06-20", "/b", 300), dir("2026-06-01", "/b", 100)],
        ])
        let roots = await Connector.resolveRoots(snapshotsPath: "/b", pointerName: "latest", via: svc)
        XCTAssertEqual(roots, ["/b/2026-06-20", "/b/2026-06-01"])
    }

    func test_no_snapshots_falls_back_to_path() async {
        let svc = FakeSFTPService(tree: ["/b": [file("x.txt", "/b")]])
        let roots = await Connector.resolveRoots(snapshotsPath: "/b", pointerName: "latest", via: svc)
        XCTAssertEqual(roots, ["/b"])
    }

    func test_pointerName_defaults_to_latest() {
        XCTAssertEqual(Connector.pointerName(nil), "latest")
        XCTAssertEqual(Connector.pointerName(""), "latest")
        XCTAssertEqual(Connector.pointerName("   "), "latest")
        XCTAssertEqual(Connector.pointerName("current"), "current")
        XCTAssertEqual(Connector.pointerName("  current  "), "current")
    }
}
