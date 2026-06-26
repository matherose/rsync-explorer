import Foundation

// Immutable after init (only a `let` tree of value types), so safe to share.
final class FakeSFTPService: SFTPService, @unchecked Sendable {
    private let tree: [String: [RemoteEntry]]
    /// Maps a remote command to canned stdout (default: "", i.e. no search tool
    /// found, so `RemoteSearch` falls back to the in-app walk).
    private let commandResponder: @Sendable (String) -> String
    /// Paths whose read should fail transiently (connection/IO) — `listDirectory`
    /// throws and `listDirectoryOutcome` reports `.failed`, modelling a dropped read.
    private let unreadablePaths: Set<String>
    init(tree: [String: [RemoteEntry]],
         unreadablePaths: Set<String> = [],
         commandResponder: @escaping @Sendable (String) -> String = { _ in "" }) {
        self.tree = tree
        self.unreadablePaths = unreadablePaths
        self.commandResponder = commandResponder
    }

    enum FakeError: Error { case unreadable }

    func connect() async throws {}
    func disconnect() async {}

    func listDirectory(_ path: String) async throws -> [RemoteEntry] {
        if unreadablePaths.contains(path) { throw FakeError.unreadable }
        return tree[path] ?? []
    }
    func listDirectoryOutcome(_ path: String) async -> DirectoryReadOutcome {
        unreadablePaths.contains(path) ? .failed : .listed(tree[path] ?? [])
    }
    func resolveLatestSnapshot(under path: String) async throws -> String {
        try await defaultResolveLatestSnapshot(under: path)
    }
    func download(_ path: String, to localURL: URL,
                  progress: @escaping (Double) -> Void) async throws {
        progress(1.0)
        try Data().write(to: localURL)
    }
    func read(at path: String, offset: UInt64, length: UInt32) async throws -> Data { Data() }
    func runCommand(_ command: String) async throws -> String { commandResponder(command) }

    static func sample() -> FakeSFTPService {
        func d(_ n: String, _ p: String, _ ts: TimeInterval) -> RemoteEntry {
            RemoteEntry(name: n, path: p, isDirectory: true, size: 0,
                        modificationDate: Date(timeIntervalSince1970: ts))
        }
        func f(_ n: String, _ p: String) -> RemoteEntry {
            RemoteEntry(name: n, path: p, isDirectory: false, size: 12,
                        modificationDate: Date(timeIntervalSince1970: 1))
        }
        return FakeSFTPService(tree: [
            "/backup": [d("2026-06-01", "/backup/2026-06-01", 100),
                        d("2026-06-20", "/backup/2026-06-20", 300)],
            "/backup/2026-06-20": [d("Photos", "/backup/2026-06-20/Photos", 300),
                                   f("readme.txt", "/backup/2026-06-20/readme.txt")],
        ])
    }
}
