import Foundation

/// Lists one folder across *every* snapshot root in a single server-side `find`,
/// instead of one SFTP round-trip per snapshot (which, with many `--link-dest`
/// snapshots, made each first-time folder open slow regardless of its contents).
///
/// One `find` over all the per-snapshot folder paths emits each immediate child as
/// `type\tsize\tmtime\tpath`; `parse` groups them back per root (newest first, for
/// `SnapshotMerge`). A trailing sentinel, gated on `find` existing, lets the parser
/// tell "genuinely empty" from "find unavailable" so the caller only falls back to
/// the per-root SFTP loop when the command truly couldn't run.
enum RemoteListing {
    static let sentinel = "@@RFEOK@@"

    static func run(roots: [String], rel: String, service: SFTPService) async -> [[RemoteEntry]]? {
        guard !roots.isEmpty else { return nil }
        guard let out = try? await service.runCommand(command(roots: roots, rel: rel)) else { return nil }
        return parse(out, roots: roots)
    }

    static func command(roots: [String], rel: String) -> String {
        let folders = roots
            .map { rel.isEmpty ? $0 : $0 + "/" + rel }
            .map(shellQuote)
            .joined(separator: " ")
        // -H: dereference the start paths (the `latest` pointer symlink) but not entry
        // symlinks. -mindepth/-maxdepth 1: immediate children only. printf path LAST so
        // a tab in a name can't shift the fixed columns. Sentinel marks a real run.
        return "command -v find >/dev/null 2>&1 && { "
            + "find -H \(folders) -mindepth 1 -maxdepth 1 -printf '%y\\t%s\\t%T@\\t%p\\n' 2>/dev/null; "
            + "printf '\(sentinel)\\n'; }"
    }

    /// Per-root listings in `roots` order, or nil if the output lacks the sentinel
    /// (find unavailable / command failed → caller should fall back to SFTP).
    static func parse(_ stdout: String, roots: [String]) -> [[RemoteEntry]]? {
        guard stdout.contains(sentinel) else { return nil }
        let norm = roots.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        var byRoot = [[RemoteEntry]](repeating: [], count: norm.count)
        for raw in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw == Substring(sentinel) { continue }
            let cols = raw.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard cols.count == 4 else { continue }
            let type = cols[0]
            let size = Int64(cols[1]) ?? 0
            let mtime = Double(cols[2])
            let path = String(cols[3])
            guard let ri = norm.firstIndex(where: { path.hasPrefix($0 + "/") }) else { continue }
            let name = (path as NSString).lastPathComponent
            if name.isEmpty || name == "." || name == ".." { continue }
            byRoot[ri].append(RemoteEntry(
                name: name, path: path, isDirectory: type == "d", size: size,
                modificationDate: mtime.map { Date(timeIntervalSince1970: $0) }))
        }
        return byRoot
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
