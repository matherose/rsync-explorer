import XCTest
@testable import RsyncExplorer

final class FakeSFTPServiceTests: XCTestCase {
    func test_resolves_latest_snapshot_then_lists_it() async throws {
        let svc = FakeSFTPService.sample()
        try await svc.connect()
        let snap = try await svc.resolveLatestSnapshot(under: "/backup")
        XCTAssertEqual(snap, "/backup/2026-06-20")
        let entries = try await svc.listDirectory(snap)
        XCTAssertEqual(Set(entries.map(\.name)), ["Photos", "readme.txt"])
    }
}
