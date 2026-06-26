import XCTest
@testable import RsyncExplorer

@MainActor
final class FolderSizeStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fss-\(UUID().uuidString).json")
    }

    func test_set_then_get() {
        let store = FolderSizeStore(fileURL: tempURL())
        XCTAssertNil(store.size(for: "/snap/latest/A"))
        store.set(.complete(123), for: "/snap/latest/A")
        XCTAssertEqual(store.size(for: "/snap/latest/A"), .complete(123))
    }

    func test_persists_across_instances() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = FolderSizeStore(fileURL: url)
        writer.set(.complete(500), for: "/x")
        writer.set(.partial(40), for: "/y")

        // A fresh instance pointed at the same file must see the saved sizes.
        let reader = FolderSizeStore(fileURL: url)
        XCTAssertEqual(reader.size(for: "/x"), .complete(500))
        XCTAssertEqual(reader.size(for: "/y"), .partial(40))
    }

    func test_foldersize_codable_roundtrip() throws {
        for size in [FolderSize.complete(0), .complete(987654321), .partial(0), .partial(42)] {
            let data = try JSONEncoder().encode(size)
            XCTAssertEqual(try JSONDecoder().decode(FolderSize.self, from: data), size)
        }
    }
}
