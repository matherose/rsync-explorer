import XCTest
@testable import RsyncExplorer

final class RemoteListingTests: XCTestCase {
    private let roots = ["/snap/new", "/snap/old"]

    // type\tsize\tmtime\tpath, newest root first, then the sentinel.
    private func findOutput() -> String {
        """
        d\t4096\t300.0\t/snap/new/Photos
        f\t12\t250.5\t/snap/new/readme.txt
        d\t4096\t100.0\t/snap/old/Photos
        f\t99\t90\t/snap/old/oldfile.txt
        \(RemoteListing.sentinel)
        """
    }

    func test_command_shape() {
        let cmd = RemoteListing.command(roots: roots, rel: "sub dir")
        XCTAssertTrue(cmd.contains("command -v find"))
        XCTAssertTrue(cmd.contains("find -H"))
        XCTAssertTrue(cmd.contains("-mindepth 1 -maxdepth 1"))
        XCTAssertTrue(cmd.contains("'/snap/new/sub dir'"))   // quoted, rel appended
        XCTAssertTrue(cmd.contains("'/snap/old/sub dir'"))
        XCTAssertTrue(cmd.contains(RemoteListing.sentinel))
        // path printed LAST so a tab in a name can't shift the columns.
        XCTAssertTrue(cmd.contains("%y\\t%s\\t%T@\\t%p"))
    }

    func test_parse_returns_nil_without_sentinel() {
        // Sentinel absent => find unavailable / failed => caller falls back to SFTP.
        XCTAssertNil(RemoteListing.parse("f\t1\t1\t/snap/new/x.txt\n", roots: roots))
    }

    func test_parse_groups_by_root_with_metadata() {
        let listings = RemoteListing.parse(findOutput(), roots: roots)!
        XCTAssertEqual(listings.count, 2)

        XCTAssertEqual(listings[0].map(\.name), ["Photos", "readme.txt"])
        XCTAssertEqual(listings[0].map(\.isDirectory), [true, false])
        XCTAssertEqual(listings[0][1].size, 12)
        XCTAssertEqual(listings[0][1].modificationDate, Date(timeIntervalSince1970: 250.5))

        XCTAssertEqual(listings[1].map(\.name), ["Photos", "oldfile.txt"])
        XCTAssertEqual(listings[1][1].size, 99)
    }

    func test_parse_empty_folder_is_nonnil_all_empty() {
        // Sentinel present, no entries => genuinely empty (not a failure).
        let listings = RemoteListing.parse(RemoteListing.sentinel + "\n", roots: roots)
        XCTAssertEqual(listings?.map(\.count), [0, 0])
    }

    func test_parse_prefix_collision_safe() {
        // "/snap/new2" entries must not be filed under "/snap/new".
        let out = "f\t1\t1\t/snap/new2/x.txt\n\(RemoteListing.sentinel)\n"
        let listings = RemoteListing.parse(out, roots: roots)!
        XCTAssertEqual(listings.map(\.count), [0, 0])
    }

    func test_run_feeds_find_output_through_parse() async {
        let svc = FakeSFTPService(tree: [:]) { [out = findOutput()] cmd in
            cmd.contains("find -H") ? out : ""
        }
        let listings = await RemoteListing.run(roots: roots, rel: "", service: svc)
        XCTAssertEqual(listings?.map(\.count), [2, 2])
        // And it merges into the union the browser shows (oldfile.txt only in old).
        let merged = SnapshotMerge.merge(listings!)
        let deleted = Dictionary(uniqueKeysWithValues: merged.map { ($0.entry.name, $0.isDeleted) })
        XCTAssertEqual(deleted["oldfile.txt"], true)
        XCTAssertEqual(deleted["readme.txt"], false)
    }

    func test_run_returns_nil_when_command_unsupported() async {
        let svc = FakeSFTPService(tree: [:])   // default responder "" -> no sentinel
        let listings = await RemoteListing.run(roots: roots, rel: "", service: svc)
        XCTAssertNil(listings)
    }
}
