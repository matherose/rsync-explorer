import Foundation

/// Result of a folder-size `du`. `partial` means `du` couldn't traverse everything
/// (e.g. a permission-denied or non-executable subdir), so the byte count is only a
/// lower bound — distinct from a folder that's genuinely (near) empty.
enum FolderSize: Equatable, Codable {
    case complete(Int64)
    case partial(Int64)

    var bytes: Int64 {
        switch self {
        case .complete(let n), .partial(let n): return n
        }
    }
}

/// Computes a folder's recursive size on the server with `du -sb` (apparent bytes),
/// on demand. Within one snapshot the files aren't hardlinked to each other, so the
/// sum is the folder's logical size. Results are stable (snapshots are immutable),
/// so callers cache them per path.
enum RemoteFolderSize {
    static func command(path: String) -> String {
        // Capture du's exit status: nonzero => it couldn't fully traverse (permissions),
        // so the total is only a lower bound. stderr is dropped; the EXIT line is stdout.
        "du -sb -- \(RemoteSearchCommand.shellQuote(path)) 2>/dev/null; printf 'EXIT:%s\\n' \"$?\""
    }

    static func parse(_ stdout: String) -> FolderSize? {
        var bytes: Int64?
        var exit: Int?
        for line in stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("EXIT:") {
                exit = Int(trimmed.dropFirst(5))
            } else if bytes == nil,
                      let token = trimmed.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
                      let n = Int64(token) {
                bytes = n
            }
        }
        guard let bytes else { return nil }
        return exit == 0 ? .complete(bytes) : .partial(bytes)
    }

    /// Runs `du` with a generous timeout so a giant folder (a whole snapshot root must
    /// walk the entire tree) can't leave the UI "Calculating…" forever. Returns nil on
    /// timeout, connection error, or unparseable output.
    static func run(path: String, service: SFTPService, timeout: TimeInterval = 300) async -> FolderSize? {
        let out = try? await withTimeout(seconds: timeout) {
            try await service.runCommand(command(path: path))
        }
        guard let out else { return nil }
        return parse(out)
    }
}
