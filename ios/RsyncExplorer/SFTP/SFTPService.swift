import Foundation

enum SFTPServiceError: Error { case commandsUnsupported }

protocol SFTPService: Sendable {
    func connect() async throws
    func listDirectory(_ path: String) async throws -> [RemoteEntry]
    /// Lists a directory, distinguishing a definitive "not there" (a snapshot that
    /// legitimately lacks this folder) from a transient read failure, so callers can
    /// avoid caching a listing that's only partial because a read dropped. Default
    /// treats any thrown error conservatively as `.failed`; the real service classifies.
    func listDirectoryOutcome(_ path: String) async -> DirectoryReadOutcome
    func resolveLatestSnapshot(under path: String) async throws -> String
    func download(_ path: String, to localURL: URL,
                  progress: @escaping (Double) -> Void) async throws
    func read(at path: String, offset: UInt64, length: UInt32) async throws -> Data
    /// Reads up to `maxBytes` from the start of a file (for header/thumbnail
    /// extraction). Default loops `read`; the real service opens the file once.
    func readHeader(_ path: String, maxBytes: Int) async throws -> Data
    /// Runs a shell command on the server and returns its stdout. Used for
    /// server-side search; conformers that can't exec inherit the throwing default.
    func runCommand(_ command: String) async throws -> String
    func disconnect() async
}

extension SFTPService {
    /// Default snapshot resolution: list `path`, pick latest dir, fall back to `path` itself.
    func defaultResolveLatestSnapshot(under path: String) async throws -> String {
        let entries = try await listDirectory(path)
        return SnapshotResolver.latest(from: entries)?.path ?? path
    }

    /// Default: no remote command execution. `RemoteSearch` probes through this and
    /// silently falls back to the in-app walk when it throws.
    func runCommand(_ command: String) async throws -> String {
        throw SFTPServiceError.commandsUnsupported
    }

    /// Default outcome: any thrown error is treated conservatively as `.failed` (so a
    /// partial listing is never cached). The real service overrides this to tell a
    /// definitive "not there" from a dropped connection.
    func listDirectoryOutcome(_ path: String) async -> DirectoryReadOutcome {
        do { return .listed(try await listDirectory(path)) }
        catch { return .failed }
    }

    /// Default header read: a single `read` from offset 0 (real services override to
    /// open once and accumulate, tolerating short reads).
    func readHeader(_ path: String, maxBytes: Int) async throws -> Data {
        try await read(at: path, offset: 0, length: UInt32(maxBytes))
    }
}
