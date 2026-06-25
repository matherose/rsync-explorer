import XCTest
@testable import RsyncExplorer

final class RemoteFolderSizeTests: XCTestCase {

    func test_command_shape() {
        let cmd = RemoteFolderSize.command(path: "/snap/latest/My Photos")
        XCTAssertTrue(cmd.hasPrefix("du -sb -- "))
        XCTAssertTrue(cmd.contains("'/snap/latest/My Photos'"))   // shell-quoted
        XCTAssertTrue(cmd.contains("2>/dev/null"))
        XCTAssertTrue(cmd.contains("EXIT:"))                      // captures du's exit code
    }

    func test_command_escapes_quotes() {
        let cmd = RemoteFolderSize.command(path: "/a/b's dir")
        XCTAssertTrue(cmd.contains("'/a/b'\\''s dir'"))
    }

    func test_parse_complete_when_exit_zero() {
        XCTAssertEqual(RemoteFolderSize.parse("12345\t/snap/latest/Photos\nEXIT:0\n"), .complete(12345))
        // A genuinely empty folder that du fully read is complete(0), not "unreadable".
        XCTAssertEqual(RemoteFolderSize.parse("0\t/empty\nEXIT:0\n"), .complete(0))
    }

    func test_parse_partial_when_exit_nonzero() {
        // du couldn't traverse everything (permission) -> lower bound.
        XCTAssertEqual(RemoteFolderSize.parse("0\t/root-owned\nEXIT:1\n"), .partial(0))
        XCTAssertEqual(RemoteFolderSize.parse("4096\t/mostly\nEXIT:1\n"), .partial(4096))
    }

    func test_parse_nil_on_garbage_or_empty() {
        XCTAssertNil(RemoteFolderSize.parse(""))
        XCTAssertNil(RemoteFolderSize.parse("EXIT:0\n"))   // no byte count
    }

    func test_run_returns_complete_size() async {
        let svc = FakeSFTPService(tree: [:]) { cmd in
            cmd.hasPrefix("du -sb") ? "987654321\t/snap/latest/Movies\nEXIT:0\n" : ""
        }
        let size = await RemoteFolderSize.run(path: "/snap/latest/Movies", service: svc)
        XCTAssertEqual(size, .complete(987654321))
    }

    func test_run_nil_when_unsupported() async {
        let svc = FakeSFTPService(tree: [:])   // default responder "" -> unparseable
        let size = await RemoteFolderSize.run(path: "/x", service: svc)
        XCTAssertNil(size)
    }
}
