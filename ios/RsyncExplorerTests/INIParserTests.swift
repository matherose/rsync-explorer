import XCTest
@testable import RsyncExplorer

final class INIParserTests: XCTestCase {
    func test_parses_sections_and_keys() {
        let text = """
        [remote.nas1]
        host=192.168.1.100
        ssh_user=user1
        ssh_key=/home/me/.ssh/id_ed25519
        dest=/mnt/nas/backup
        """
        let sections = INIParser.parse(text)
        XCTAssertEqual(sections["remote.nas1"]?["host"], "192.168.1.100")
        XCTAssertEqual(sections["remote.nas1"]?["dest"], "/mnt/nas/backup")
    }
    func test_ignores_comments_and_blank_lines() {
        let text = "# comment\n\n[remote.x]\n; also comment\nhost=h\n"
        XCTAssertEqual(INIParser.parse(text)["remote.x"]?["host"], "h")
    }
    func test_trims_whitespace() {
        let text = "[remote.x]\n  host =  h  \n"
        XCTAssertEqual(INIParser.parse(text)["remote.x"]?["host"], "h")
    }
}
