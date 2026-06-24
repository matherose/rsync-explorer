import XCTest
@testable import RsyncExplorer

/// Counts downloads and writes a small payload, with a brief delay so two
/// concurrent fetches of the same file genuinely overlap.
private actor CountingDownloadService: SFTPService {
    private(set) var downloadCount = 0

    func connect() async throws {}
    func disconnect() async {}
    func listDirectory(_ path: String) async throws -> [RemoteEntry] { [] }
    func resolveLatestSnapshot(under path: String) async throws -> String { path }
    func read(at path: String, offset: UInt64, length: UInt32) async throws -> Data { Data() }

    func download(_ path: String, to localURL: URL, progress: @escaping (Double) -> Void) async throws {
        downloadCount += 1
        try? await Task.sleep(nanoseconds: 50_000_000)   // keep the download "in flight"
        try Data("payload".utf8).write(to: localURL)
        progress(1.0)
    }
}

final class FileCacheTests: XCTestCase {
    private func uniqueEntry() -> RemoteEntry {
        // Unique path => guaranteed not already cached on disk for this run.
        RemoteEntry(name: "f.bin", path: "/test/\(UUID().uuidString)/f.bin",
                    isDirectory: false, size: 7, modificationDate: Date(timeIntervalSince1970: 1))
    }

    func test_concurrent_fetch_downloads_once() async throws {
        let svc = CountingDownloadService()
        let entry = uniqueEntry()

        async let a = FileCache.shared.fetch(entry, via: svc, progress: { _ in })
        async let b = FileCache.shared.fetch(entry, via: svc, progress: { _ in })
        let urls = try await [a, b]

        XCTAssertEqual(urls[0], urls[1])                       // same cached URL
        let count = await svc.downloadCount
        XCTAssertEqual(count, 1)                               // not downloaded twice
        try? FileManager.default.removeItem(at: urls[0])       // tidy up the shared cache
    }

    func test_second_fetch_hits_cache() async throws {
        let svc = CountingDownloadService()
        let entry = uniqueEntry()

        let first = try await FileCache.shared.fetch(entry, via: svc, progress: { _ in })
        let second = try await FileCache.shared.fetch(entry, via: svc, progress: { _ in })

        XCTAssertEqual(first, second)
        let count = await svc.downloadCount
        XCTAssertEqual(count, 1)                               // cached after the first
        try? FileManager.default.removeItem(at: first)
    }
}
