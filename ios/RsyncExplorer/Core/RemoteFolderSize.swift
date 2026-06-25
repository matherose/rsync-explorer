import Foundation

/// Computes a folder's recursive size on the server with `du -sb` (apparent bytes),
/// on demand. Within one snapshot the files aren't hardlinked to each other, so the
/// sum is the folder's logical size. Results are stable (snapshots are immutable),
/// so callers cache them per path. Returns nil if the command can't run or parse.
enum RemoteFolderSize {
    static func command(path: String) -> String {
        "du -sb -- \(RemoteSearchCommand.shellQuote(path)) 2>/dev/null"
    }

    /// First parseable byte count in `du`'s output ("<bytes>\t<path>").
    static func parse(_ stdout: String) -> Int64? {
        for line in stdout.split(separator: "\n") {
            if let token = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
               let bytes = Int64(token) {
                return bytes
            }
        }
        return nil
    }

    /// Runs `du` on the server with a generous timeout so a giant folder (e.g. a whole
    /// snapshot root, which must walk the entire tree) can't leave the UI "Calculating…"
    /// forever. Returns nil on timeout, connection error, or unparseable output.
    static func run(path: String, service: SFTPService, timeout: TimeInterval = 300) async -> Int64? {
        let out = try? await withTimeout(seconds: timeout) {
            try await service.runCommand(command(path: path))
        }
        guard let out else { return nil }
        return parse(out)
    }
}
