import Foundation

/// Runs `operation`, throwing `SFTPConnectError.timedOut` if it doesn't finish
/// within `seconds`. Used to bound a connection attempt to an unreachable host.
func withTimeout<T: Sendable>(seconds: Double,
                              operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw SFTPConnectError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
