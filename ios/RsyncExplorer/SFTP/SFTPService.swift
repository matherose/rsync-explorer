import Foundation

enum SFTPServiceError: Error { case commandsUnsupported }

protocol SFTPService: Sendable {
    func connect() async throws
    func listDirectory(_ path: String) async throws -> [RemoteEntry]
    func resolveLatestSnapshot(under path: String) async throws -> String
    func download(_ path: String, to localURL: URL,
                  progress: @escaping (Double) -> Void) async throws
    func read(at path: String, offset: UInt64, length: UInt32) async throws -> Data
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
}
