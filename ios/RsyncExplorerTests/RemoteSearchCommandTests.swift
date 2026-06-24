import XCTest
@testable import RsyncExplorer

final class RemoteSearchCommandTests: XCTestCase {

    // MARK: Probe

    func test_probe_command_lists_tools_in_priority_order() {
        let cmd = RemoteSearchCommand.probeCommand
        // fd before fdfind before plocate before find.
        let fd = cmd.range(of: "fd")!.lowerBound
        let fdfind = cmd.range(of: "fdfind")!.lowerBound
        let plocate = cmd.range(of: "plocate")!.lowerBound
        let find = cmd.range(of: " find")!.lowerBound   // leading space avoids matching "fdfind"
        XCTAssertTrue(fd < fdfind && fdfind < plocate && plocate < find)
    }

    func test_tool_parsing_from_probe_output() {
        XCTAssertEqual(RemoteSearchCommand.tool(fromProbeOutput: "fd\n"), .fd)
        XCTAssertEqual(RemoteSearchCommand.tool(fromProbeOutput: "  find  "), .find)
        XCTAssertEqual(RemoteSearchCommand.tool(fromProbeOutput: "plocate"), .plocate)
        XCTAssertNil(RemoteSearchCommand.tool(fromProbeOutput: ""))
        XCTAssertNil(RemoteSearchCommand.tool(fromProbeOutput: "ripgrep"))
    }

    // MARK: shellQuote

    func test_shellQuote_escapes_embedded_single_quotes() {
        XCTAssertEqual(RemoteSearchCommand.shellQuote("a'b"), "'a'\\''b'")
        XCTAssertEqual(RemoteSearchCommand.shellQuote("plain"), "'plain'")
    }

    // MARK: command construction

    func test_find_command_uses_iname_glob_and_quoted_roots() {
        let cmd = RemoteSearchCommand.command(tool: .find, term: "rep ort",
                                              roots: ["/backup/latest", "/backup/2023"])
        XCTAssertTrue(cmd.hasPrefix("find '/backup/latest' '/backup/2023' "))
        XCTAssertTrue(cmd.contains("-iname '*rep ort*'"))
        XCTAssertTrue(cmd.hasSuffix("2>/dev/null"))
    }

    func test_fd_command_is_literal_caseinsensitive_absolute() {
        let cmd = RemoteSearchCommand.command(tool: .fd, term: "photo", roots: ["/b/latest"])
        XCTAssertTrue(cmd.hasPrefix("fd "))
        XCTAssertTrue(cmd.contains("--fixed-strings"))
        XCTAssertTrue(cmd.contains("--ignore-case"))
        XCTAssertTrue(cmd.contains("--absolute-path"))
        XCTAssertTrue(cmd.contains("--hidden"))
        XCTAssertTrue(cmd.contains("--no-ignore"))
        XCTAssertTrue(cmd.contains("-- 'photo' '/b/latest'"))
    }

    func test_fdfind_command_uses_fdfind_binary() {
        let cmd = RemoteSearchCommand.command(tool: .fdfind, term: "x", roots: ["/b"])
        XCTAssertTrue(cmd.hasPrefix("fdfind "))
    }

    func test_plocate_command_globs_term_case_insensitive() {
        let cmd = RemoteSearchCommand.command(tool: .plocate, term: "song", roots: ["/b"])
        XCTAssertTrue(cmd.contains("plocate --ignore-case"))
        XCTAssertTrue(cmd.contains("'*song*'"))
    }

    func test_command_injection_term_is_fully_quoted() {
        let evil = "a'; rm -rf / #"
        let cmd = RemoteSearchCommand.command(tool: .find, term: evil, roots: ["/b"])
        // The whole payload appears only inside the escaped quoting...
        XCTAssertTrue(cmd.contains(RemoteSearchCommand.shellQuote("*\(evil)*")))
        // ...and the breakout signature (a bare quote directly closing into `; rm`)
        // never appears — the term's `'` is rewritten to `'\''`, not left raw.
        XCTAssertFalse(cmd.contains("a'; rm"))
    }

    // MARK: parseResults — the correctness boundary

    func test_parseResults_keeps_only_basename_matches_within_roots() {
        let roots = ["/backup/latest"]
        let stdout = """
        /backup/latest/Reports/2023/summary.pdf
        /backup/latest/report_final.txt
        /other/report.txt
        /backup/latest/Quarterly Report.pdf
        """
        // term "report": ancestor-dir match (plocate-style) and out-of-root path are dropped;
        // basename matches (incl. case-insensitive, with spaces) are kept.
        let hits = RemoteSearchCommand.parseResults(stdout, term: "report", roots: roots)
        XCTAssertEqual(hits, ["/backup/latest/report_final.txt",
                              "/backup/latest/Quarterly Report.pdf"])
    }

    func test_parseResults_trims_blank_lines_and_dedupes() {
        let roots = ["/b"]
        let stdout = "\n  /b/a.txt  \n/b/a.txt\n\n/b/b.txt\n"
        let hits = RemoteSearchCommand.parseResults(stdout, term: "txt", roots: roots)
        XCTAssertEqual(hits, ["/b/a.txt", "/b/b.txt"])
    }

    func test_parseResults_tolerates_trailing_slash_on_root() {
        let hits = RemoteSearchCommand.parseResults("/b/latest/report.txt",
                                                    term: "report", roots: ["/b/latest/"])
        XCTAssertEqual(hits, ["/b/latest/report.txt"])
    }

    func test_parseResults_prefix_collision_is_safe() {
        // "/b/latest2" must not be treated as under "/b/latest".
        let hits = RemoteSearchCommand.parseResults("/b/latest2/report.txt",
                                                    term: "report", roots: ["/b/latest"])
        XCTAssertEqual(hits, [])
    }

    func test_parseResults_matches_directory_names_too() {
        let hits = RemoteSearchCommand.parseResults("/b/Reports",
                                                    term: "report", roots: ["/b"])
        XCTAssertEqual(hits, ["/b/Reports"])
    }
}
