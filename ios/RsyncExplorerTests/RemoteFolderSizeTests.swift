import XCTest
@testable import RsyncExplorer

final class RemoteFolderSizeTests: XCTestCase {

    func test_command_shape() {
        let cmd = RemoteFolderSize.command(path: "/snap/latest/My Photos")
        XCTAssertTrue(cmd.hasPrefix("du -sb -- "))
        XCTAssertTrue(cmd.contains("'/snap/latest/My Photos'"))   // shell-quoted
        XCTAssertTrue(cmd.hasSuffix("2>/dev/null"))
    }

    func test_command_escapes_quotes() {
        let cmd = RemoteFolderSize.command(path: "/a/b's dir")
        XCTAssertTrue(cmd.contains("'/a/b'\\''s dir'"))
    }

    func test_parse_reads_leading_byte_count() {
        XCTAssertEqual(RemoteFolderSize.parse("12345\t/snap/latest/Photos\n"), 12345)
        XCTAssertEqual(RemoteFolderSize.parse("0\t/empty\n"), 0)
    }

    func test_parse_nil_on_garbage_or_empty() {
        XCTAssertNil(RemoteFolderSize.parse(""))
        XCTAssertNil(RemoteFolderSize.parse("du: cannot access '/x': Permission denied\n"))
    }

    func test_run_returns_size() async {
        let svc = FakeSFTPService(tree: [:]) { cmd in
            cmd.hasPrefix("du -sb") ? "987654321\t/snap/latest/Movies\n" : ""
        }
        let size = await RemoteFolderSize.run(path: "/snap/latest/Movies", service: svc)
        XCTAssertEqual(size, 987654321)
    }

    func test_run_nil_when_unsupported() async {
        let svc = FakeSFTPService(tree: [:])   // default responder "" -> unparseable
        let size = await RemoteFolderSize.run(path: "/x", service: svc)
        XCTAssertNil(size)
    }
}
