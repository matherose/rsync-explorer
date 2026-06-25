import Foundation

/// A remote search backend, fastest/most-precise first. `find` is the universal
/// fallback that exists on every POSIX host.
enum RemoteSearchTool: String, CaseIterable {
    case fd        // modern, fast, respects .gitignore by default (we disable that)
    case fdfind    // Debian/Ubuntu rename of fd
    case plocate   // index-backed; can be much faster but matches the *path* and may be stale
    case find      // always present
}

/// Builds the shell commands for server-side recursive search and parses their
/// output, with no SSH/SFTP dependency so it's fully unit-testable offline.
///
/// Design: the per-tool commands are allowed to *over-match* (plocate matches the
/// whole path; `find -iname` honours glob metacharacters in the term), and
/// ``parseResults(_:term:roots:)`` is the single correctness boundary — it keeps
/// only paths whose **basename** contains `term` (case-insensitive) and that live
/// under one of `roots`. That yields identical results to the in-app
/// `find -iname "*term*"`-equivalent walk no matter which backend ran.
///
/// Wiring to the live host (a `runCommand` exec channel on `SFTPService`, plus a
/// fall-back-to-find when `plocate` returns nothing because its db is stale) is
/// deferred until the NAS is reachable; this type is the testable core.
enum RemoteSearchCommand {
    /// Probe order: try these in turn, use the first that exists.
    static let probeOrder: [RemoteSearchTool] = [.fd, .fdfind, .plocate, .find]

    /// Shell snippet that echoes the name of the first available tool (nothing if
    /// none exist). Run once per connection and cache the result.
    static var probeCommand: String {
        let names = probeOrder.map(\.rawValue).joined(separator: " ")
        return "for t in \(names); do command -v \"$t\" >/dev/null 2>&1 && { echo \"$t\"; break; }; done"
    }

    /// Maps the probe's stdout back to a tool (nil if empty or unrecognised).
    static func tool(fromProbeOutput output: String) -> RemoteSearchTool? {
        RemoteSearchTool(rawValue: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Builds the remote search command for `tool` searching `roots` for `term`.
    /// The term and roots are shell-quoted, so arbitrary user input is safe to
    /// interpolate. May over-match by design; pair with ``parseResults(_:term:roots:)``.
    /// When `limit` is set, the output is capped server-side with `head` so a broad
    /// query can't stream back unbounded bytes (the early pipe close stops the tool).
    static func command(tool: RemoteSearchTool, term: String, roots: [String], limit: Int? = nil) -> String {
        let quotedTerm = shellQuote(term)
        let quotedRoots = roots.map(shellQuote).joined(separator: " ")
        let base: String
        switch tool {
        case .fd, .fdfind:
            // --fixed-strings: literal (no regex) substring; --ignore-case: parity with -iname;
            // --hidden/--no-ignore: a backup tree must include dotfiles and ignore .gitignore;
            // --absolute-path: emit absolute paths; `--` ends options so a leading-`-` term is safe.
            base = "\(tool.rawValue) --hidden --no-ignore --ignore-case --fixed-strings"
                + " --absolute-path -- \(quotedTerm) \(quotedRoots)"
        case .plocate:
            // plocate has no path-restriction flag, so roots are enforced in parseResults.
            base = "plocate --ignore-case -- \(shellQuote("*\(term)*"))"
        case .find:
            // 2>/dev/null drops permission-denied noise; -iname is a basename glob.
            base = "find \(quotedRoots) -iname \(shellQuote("*\(term)*")) 2>/dev/null"
        }
        guard let limit else { return base }
        return base + " | head -n \(limit)"
    }

    /// Filters raw stdout to absolute paths whose **basename** contains `term`
    /// (case-insensitive) and that live under one of `roots`, de-duplicated and in
    /// output order. This is what guarantees `find -iname "*term*"` parity across
    /// every backend, and discards anything a backend returned outside our roots.
    static func parseResults(_ stdout: String, term: String, roots: [String]) -> [String] {
        let normalizedRoots = roots.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        var seen = Set<String>()
        var results: [String] = []
        for raw in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let path = raw.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, !seen.contains(path) else { continue }
            let underRoot = normalizedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
            guard underRoot else { continue }
            let base = (path as NSString).lastPathComponent
            guard base.localizedCaseInsensitiveContains(term) else { continue }
            seen.insert(path)
            results.append(path)
        }
        return results
    }

    /// POSIX single-quote escaping: wrap in single quotes and replace each embedded
    /// `'` with `'\''`. Neutralises every shell metacharacter, so user-supplied
    /// terms can't break out of the command.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
