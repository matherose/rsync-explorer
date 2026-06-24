import XCTest
@testable import RsyncExplorer

final class TimeoutTests: XCTestCase {
    func test_returns_value_when_fast() async throws {
        let value = try await withTimeout(seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func test_throws_timedOut_when_slow() async {
        do {
            try await withTimeout(seconds: 0.1) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? SFTPConnectError, .timedOut)
        }
    }

    func test_propagates_operation_error() async {
        struct Boom: Error {}
        do {
            try await withTimeout(seconds: 5) { throw Boom() }
            XCTFail("expected the operation error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }
}
