import XCTest
@testable import RsyncExplorer

final class RecursiveSearchTests: XCTestCase {
    // Newest snapshot first, then an older one. The older snapshot still holds
    // files/folders that were later deleted (absent from the newest snapshot).
    private let newest = "/s_new"
    private let older = "/s_old"

    private func dir(_ name: String, _ root: String) -> RemoteEntry {
        RemoteEntry(name: name, path: "\(root)/\(name)", isDirectory: true, size: 0, modificationDate: nil)
    }
    private func file(_ name: String, _ root: String) -> RemoteEntry {
        RemoteEntry(name: name, path: "\(root)/\(name)", isDirectory: false, size: 10, modificationDate: nil)
    }

    /// Two snapshots sharing most structure. "Old Band" (folder) and
    /// "2011 - Demo.flac" (file) exist ONLY in the older snapshot — i.e. deleted.
    private func service() -> FakeSFTPService {
        FakeSFTPService(tree: [
            newest: [dir("Music", newest)],
            older:  [dir("Music", older)],

            "\(newest)/Music": [dir("Arch Enemy", "\(newest)/Music")],
            "\(older)/Music":  [dir("Arch Enemy", "\(older)/Music"),
                                dir("Old Band", "\(older)/Music")],

            "\(newest)/Music/Arch Enemy": [file("Khaos Legions.flac", "\(newest)/Music/Arch Enemy")],
            "\(older)/Music/Arch Enemy":  [file("Khaos Legions.flac", "\(older)/Music/Arch Enemy"),
                                           file("2011 - Demo.flac", "\(older)/Music/Arch Enemy")],

            // Present only in the old snapshot.
            "\(older)/Music/Old Band": [file("track.mp3", "\(older)/Music/Old Band")],
        ])
    }

    private func run(_ query: String) async -> [SearchHit] {
        await RecursiveSearch.run(query: query, baseRel: "",
                                  roots: [newest, older], service: service())
    }

    func test_finds_folder_case_insensitive_with_space() async {
        let hits = await run("arch enemy")          // lowercase, with the space
        let hit = hits.first { $0.entry.name == "Arch Enemy" }
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.relPath, "Music/Arch Enemy")
        XCTAssertEqual(hit?.isDeleted, false)
    }

    func test_finds_deleted_file_only_in_old_snapshot() async {
        let hits = await run("2011")                 // the case that previously failed
        let hit = hits.first { $0.entry.name == "2011 - Demo.flac" }
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.relPath, "Music/Arch Enemy/2011 - Demo.flac")
        XCTAssertTrue(hit?.isDeleted ?? false)
        // The hit must point at a real path in the snapshot that still has it.
        XCTAssertEqual(hit?.entry.path, "/s_old/Music/Arch Enemy/2011 - Demo.flac")
    }

    func test_finds_deleted_folder_only_in_old_snapshot() async {
        let hits = await run("old band")
        let hit = hits.first { $0.entry.name == "Old Band" }
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit?.isDeleted ?? false)
    }

    func test_recurses_into_deleted_subtree() async {
        // "track.mp3" lives under the deleted "Old Band" folder — search must descend.
        let hits = await run("track")
        XCTAssertTrue(hits.contains { $0.entry.name == "track.mp3" && $0.isDeleted })
    }

    func test_substring_match() async {
        let hits = await run("khaos")               // partial, lowercased
        let hit = hits.first { $0.entry.name == "Khaos Legions.flac" }
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.isDeleted, false)        // still present in newest
    }

    func test_no_match_returns_empty() async {
        let hits = await run("nonexistent")
        XCTAssertTrue(hits.isEmpty)
    }

    func test_empty_query_returns_empty() async {
        let hits = await run("")
        XCTAssertTrue(hits.isEmpty)
    }
}
