import XCTest
@testable import RsyncExplorer

final class RemoteSearchTests: XCTestCase {

    // Two snapshots: "new" (newest, roots[0]) and "old". Same name across both
    // collapses to one hit; a name only in "old" is flagged deleted.
    private func file(_ name: String, _ path: String) -> RemoteEntry {
        RemoteEntry(name: name, path: path, isDirectory: false, size: 1, modificationDate: nil)
    }
    private func dir(_ name: String, _ path: String) -> RemoteEntry {
        RemoteEntry(name: name, path: path, isDirectory: true, size: 0, modificationDate: nil)
    }

    private func tree() -> [String: [RemoteEntry]] {
        [
            "/snap/new": [dir("Photos", "/snap/new/Photos"),
                          file("report2026.txt", "/snap/new/report2026.txt")],
            "/snap/new/Photos": [file("beach.jpg", "/snap/new/Photos/beach.jpg")],
            "/snap/old": [dir("Photos", "/snap/old/Photos"),
                          file("report2026.txt", "/snap/old/report2026.txt"),
                          file("oldreport.txt", "/snap/old/oldreport.txt")],
            "/snap/old/Photos": [file("beach.jpg", "/snap/old/Photos/beach.jpg"),
                                 file("report_old.png", "/snap/old/Photos/report_old.png")],
        ]
    }
    private let roots = ["/snap/new", "/snap/old"]

    /// A responder that returns `tool` for the probe and `paths` for the search.
    private func responder(tool: String, paths: [String]) -> @Sendable (String) -> String {
        { cmd in cmd.contains("command -v") ? tool : paths.joined(separator: "\n") }
    }

    func test_returns_nil_when_no_remote_tool() async {
        let svc = FakeSFTPService(tree: tree())   // default responder -> "" -> no tool
        let hits = await RemoteSearch.run(query: "report", baseRel: "", roots: roots, service: svc)
        XCTAssertNil(hits)   // caller will fall back to the in-app walk
    }

    func test_unions_snapshots_and_flags_deleted() async {
        let fdPaths = ["/snap/new/report2026.txt",
                       "/snap/old/report2026.txt",
                       "/snap/old/oldreport.txt",
                       "/snap/old/Photos/report_old.png"]
        let svc = FakeSFTPService(tree: tree(),
                                  commandResponder: responder(tool: "fdfind", paths: fdPaths))
        let hits = await RemoteSearch.run(query: "report", baseRel: "", roots: roots, service: svc)
        let unwrapped = try! XCTUnwrap(hits)

        // Three union hits (order is the app's locale-sensitive sort, so assert by name).
        XCTAssertEqual(Set(unwrapped.map(\.entry.name)),
                       ["oldreport.txt", "report2026.txt", "report_old.png"])
        let byName = Dictionary(uniqueKeysWithValues: unwrapped.map { ($0.entry.name, $0) })
        // report2026.txt is in the newest snapshot -> not deleted; the other two are old-only.
        XCTAssertEqual(byName["report2026.txt"]?.isDeleted, false)
        XCTAssertEqual(byName["report2026.txt"]?.relPath, "report2026.txt")
        XCTAssertEqual(byName["oldreport.txt"]?.isDeleted, true)
        XCTAssertEqual(byName["oldreport.txt"]?.relPath, "oldreport.txt")
        XCTAssertEqual(byName["report_old.png"]?.isDeleted, true)
        XCTAssertEqual(byName["report_old.png"]?.relPath, "Photos/report_old.png")
    }

    func test_plocate_empty_falls_back_to_find() async {
        // find returns one match path; resolveHits re-scans that parent across all
        // snapshots, so the result also surfaces oldreport.txt (old-only) by union.
        let findPaths = ["/snap/new/report2026.txt", "/snap/old/report2026.txt"]
        let svc = FakeSFTPService(tree: tree()) { cmd in
            if cmd.contains("command -v") { return "plocate" }   // probe picks plocate
            if cmd.hasPrefix("plocate") { return "" }            // stale db -> nothing
            if cmd.hasPrefix("find") { return findPaths.joined(separator: "\n") }
            return ""
        }
        let result = await RemoteSearch.run(query: "report", baseRel: "", roots: roots, service: svc)
        let hits = try! XCTUnwrap(result)
        XCTAssertEqual(Set(hits.map(\.entry.name)), ["oldreport.txt", "report2026.txt"])
        let deleted = Dictionary(uniqueKeysWithValues: hits.map { ($0.entry.name, $0.isDeleted) })
        XCTAssertEqual(deleted["report2026.txt"], false)
        XCTAssertEqual(deleted["oldreport.txt"], true)
    }

    func test_empty_results_returns_empty_not_nil() async {
        // Tool present, but it matched nothing — distinct from "no tool" (nil).
        let svc = FakeSFTPService(tree: tree(),
                                  commandResponder: responder(tool: "find", paths: []))
        let hits = await RemoteSearch.run(query: "zzz", baseRel: "", roots: roots, service: svc)
        XCTAssertEqual(try! XCTUnwrap(hits).count, 0)
    }

    func test_relativePath_is_prefix_collision_safe() {
        XCTAssertEqual(RemoteSearch.relativePath(of: "/b/latest/x.txt", roots: ["/b/latest"]), "x.txt")
        XCTAssertEqual(RemoteSearch.relativePath(of: "/b/latest", roots: ["/b/latest"]), "")
        XCTAssertNil(RemoteSearch.relativePath(of: "/b/latest2/x.txt", roots: ["/b/latest"]))
        XCTAssertEqual(RemoteSearch.relativePath(of: "/b/latest/x", roots: ["/b/latest/"]), "x")
    }
}
