import XCTest
@testable import RsyncExplorer

final class ConfigImporterTests: XCTestCase {
    func test_imports_remote_with_key() {
        let text = """
        [remote.nas1]
        host=192.168.1.100
        ssh_user=user1
        ssh_key=/home/me/.ssh/id_ed25519
        dest=/mnt/nas/backup
        """
        let configs = ConfigImporter.servers(from: text)
        XCTAssertEqual(configs.count, 1)
        let c = configs[0]
        XCTAssertEqual(c.name, "nas1")
        XCTAssertEqual(c.host, "192.168.1.100")
        XCTAssertEqual(c.username, "user1")
        XCTAssertEqual(c.remotePath, "/mnt/nas/backup")
        XCTAssertEqual(c.authMethod, .ed25519Key)
        XCTAssertEqual(c.importedKeyPath, "/home/me/.ssh/id_ed25519")
    }
    func test_password_when_no_key() {
        let text = "[remote.x]\nhost=h\nssh_user=u\nssh_pass=secret\ndest=/d\n"
        XCTAssertEqual(ConfigImporter.servers(from: text).first?.authMethod, .password)
    }
    func test_ignores_local_sections() {
        let text = "[local.disk]\ndest=/media/ext\n[remote.x]\nhost=h\nssh_user=u\nssh_key=k\ndest=/d\n"
        let configs = ConfigImporter.servers(from: text)
        XCTAssertEqual(configs.map(\.name), ["x"])
    }
}
