# iPhone Media Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A sideloaded SwiftUI iPhone app that connects to the NAS over SFTP, opens on the latest rsync snapshot, browses it as a file browser, and views media (swipeable image carousel + FFmpeg/VLCKit video player), read-only.

**Architecture:** Native SwiftUI app in a new `ios/` directory. UI talks to an `SFTPService` protocol (real impl backed by Citadel/SwiftNIO-SSH; fake impl for tests/previews). Video plays through MobileVLCKit (FFmpeg decode, VideoToolbox HW + software fallback, Metal render). Secrets in Keychain. No C engine reuse.

**Tech Stack:** Swift 5.9+, SwiftUI, iOS 16+, Citadel (SPM), MobileVLCKit, swift-crypto, ImageIO/Core Image, XcodeGen (reproducible project), XCTest.

---

## Sequencing rationale (read first)

The riskiest, least-reversible unknowns come first so we fail fast:

1. **Phase A** — project bootstraps, builds, runs on device (no logic yet).
2. **Phase B** — pure logic, full TDD, no network/UI (fast, high-confidence).
3. **Phase C** — prove **Citadel SFTP auth against the real NAS** (spec open-Q #1/#3).
4. **Phase D** — prove **MobileVLCKit plays a local file** (spec open-Q #2).
5. **Phase E–H** — storage, browser UI, cache, thumbnails, media views, polish.

Do not start Phase E until Phase C and D have a green manual check — they are the two things most likely to force a design change.

## File structure

```
ios/
  project.yml                         # XcodeGen project definition
  RsyncExplorer/
    App/
      RsyncExplorerApp.swift          # @main App entry
      RootView.swift                  # routes onboarding vs browser
    Models/
      ServerConfig.swift              # connection settings (non-secret)
      RemoteEntry.swift               # one listed file/folder
      FileKind.swift                  # extension -> kind classification
    Core/
      INIParser.swift                 # parse config.ini text
      ConfigImporter.swift            # INI -> [ServerConfig]
      SnapshotResolver.swift          # pick latest snapshot from a listing
      CacheKey.swift                  # deterministic cache key
      OpenSSHKey.swift                # parse OpenSSH ed25519 private key
    SFTP/
      SFTPService.swift               # protocol + RemoteEntry mapping
      CitadelSFTPService.swift        # real impl (Citadel)
      FakeSFTPService.swift           # in-memory impl for tests/previews
    Security/
      CredentialStore.swift           # Keychain: key/password per server
      HostKeyStore.swift              # Keychain: trust-on-first-use pinning
    Cache/
      FileCache.swift                 # downloaded files on disk
      ThumbnailService.swift          # image + video thumbnails
      ThumbnailCache.swift            # thumbnails on disk
    UI/
      OnboardingView.swift            # enter/import connection
      DirectoryView.swift             # list one folder, route taps
      DirectoryRow.swift              # one row (thumbnail/name/size/date)
      MediaCarouselView.swift         # swipeable zoomable image gallery
      ZoomableImageView.swift         # Metal/CIContext-backed image
      VideoPlayerView.swift           # VLCKit player + download progress
      QuickLookView.swift             # catch-all preview
  RsyncExplorerTests/
    INIParserTests.swift
    ConfigImporterTests.swift
    FileKindTests.swift
    SnapshotResolverTests.swift
    CacheKeyTests.swift
    OpenSSHKeyTests.swift
    HostKeyStoreTests.swift
    FakeSFTPServiceTests.swift
```

---

## Phase A — Project bootstrap

### Task 1: Create the Xcode project with XcodeGen

**Files:**
- Create: `ios/project.yml`
- Create: `ios/RsyncExplorer/App/RsyncExplorerApp.swift`
- Create: `ios/RsyncExplorer/App/RootView.swift`

- [ ] **Step 1: Install XcodeGen**

Run: `brew install xcodegen`
Expected: `xcodegen` on PATH (`xcodegen --version` prints a version).

- [ ] **Step 2: Write `ios/project.yml`**

```yaml
name: RsyncExplorer
options:
  bundleIdPrefix: com.joeltordjman
  deploymentTarget:
    iOS: "16.0"
packages:
  Citadel:
    url: https://github.com/orlandos-nl/Citadel.git
    from: 0.7.0
targets:
  RsyncExplorer:
    type: application
    platform: iOS
    sources: [RsyncExplorer]
    dependencies:
      - package: Citadel
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.joeltordjman.RsyncExplorer
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        INFOPLIST_KEY_CFBundleDisplayName: rsync explorer
        TARGETED_DEVICE_FAMILY: "1"
        SWIFT_VERSION: "5.9"
  RsyncExplorerTests:
    type: bundle.unit-test
    platform: iOS
    sources: [RsyncExplorerTests]
    dependencies:
      - target: RsyncExplorer
```

> NOTE on Citadel version: `from: 0.7.0` is a starting point. If `xcodegen`/resolve fails, run `git ls-remote --tags https://github.com/orlandos-nl/Citadel.git`, pick the latest stable tag, and update `from:`. MobileVLCKit is added in Task 14 (kept out of the initial bootstrap so Phase A builds with the lightest dependency set).

- [ ] **Step 3: Write the app entry point**

`ios/RsyncExplorer/App/RsyncExplorerApp.swift`:
```swift
import SwiftUI

@main
struct RsyncExplorerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
```

`ios/RsyncExplorer/App/RootView.swift`:
```swift
import SwiftUI

struct RootView: View {
    var body: some View {
        Text("rsync explorer")
            .font(.largeTitle)
    }
}

#Preview {
    RootView()
}
```

- [ ] **Step 4: Generate and open the project**

Run: `cd ios && xcodegen generate`
Expected: `Created project at .../ios/RsyncExplorer.xcodeproj`.

- [ ] **Step 5: Configure signing (one-time, Xcode GUI)**

Open `ios/RsyncExplorer.xcodeproj` in Xcode → select the `RsyncExplorer` target → **Signing & Capabilities** → check **Automatically manage signing** → set **Team** to your personal (free) Apple ID team. This cannot be scripted; document the chosen Team ID in a comment in `project.yml` so regeneration keeps it (`DEVELOPMENT_TEAM: <ID>` under `settings.base`).

- [ ] **Step 6: Build and run on a connected iPhone**

In Xcode: select your iPhone as the run destination, press Run. On the phone, trust the developer profile under Settings → General → VPN & Device Management.
Expected: app launches showing "rsync explorer".

- [ ] **Step 7: Add a `.gitignore` for iOS build artifacts**

Append to `ios/.gitignore`:
```
*.xcodeproj
.build/
DerivedData/
*.xcuserstate
```
(The project is regenerated from `project.yml`, so the `.xcodeproj` is a build artifact.)

- [ ] **Step 8: Commit**

```bash
git add ios/project.yml ios/RsyncExplorer/App ios/.gitignore
git commit -m "build(ios): bootstrap SwiftUI app via XcodeGen"
```

---

## Phase B — Pure logic (full TDD)

> All Phase B tasks are pure Swift, no network/UI. Run tests with:
> `cd ios && xcodegen generate && xcodebuild test -scheme RsyncExplorer -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:RsyncExplorerTests/<TestClass>`
> (Substitute any installed simulator name from `xcrun simctl list devices available`.)

### Task 2: `FileKind` classification

**Files:**
- Create: `ios/RsyncExplorer/Models/FileKind.swift`
- Test: `ios/RsyncExplorerTests/FileKindTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RsyncExplorer

final class FileKindTests: XCTestCase {
    func test_directory_is_folder() {
        XCTAssertEqual(FileKind.from(name: "anything", isDirectory: true), .folder)
    }
    func test_image_extensions() {
        for n in ["a.jpg", "B.JPEG", "c.png", "d.heic", "e.gif", "f.webp"] {
            XCTAssertEqual(FileKind.from(name: n, isDirectory: false), .image, n)
        }
    }
    func test_video_extensions() {
        for n in ["a.mp4", "B.MOV", "c.mkv", "d.avi", "e.webm", "f.m4v", "g.ts"] {
            XCTAssertEqual(FileKind.from(name: n, isDirectory: false), .video, n)
        }
    }
    func test_other_extensions() {
        for n in ["a.pdf", "b.txt", "noext", "c.zip"] {
            XCTAssertEqual(FileKind.from(name: n, isDirectory: false), .other, n)
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Expected: FAIL — `FileKind` not defined.

- [ ] **Step 3: Implement**

```swift
import Foundation

enum FileKind: Equatable {
    case folder, image, video, other

    private static let imageExt: Set<String> =
        ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff"]
    private static let videoExt: Set<String> =
        ["mp4", "mov", "m4v", "mkv", "avi", "webm", "ts", "flv", "wmv", "mpg", "mpeg"]

    static func from(name: String, isDirectory: Bool) -> FileKind {
        if isDirectory { return .folder }
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExt.contains(ext) { return .image }
        if videoExt.contains(ext) { return .video }
        return .other
    }
}
```

- [ ] **Step 4: Run to verify it passes** — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/RsyncExplorer/Models/FileKind.swift ios/RsyncExplorerTests/FileKindTests.swift
git commit -m "feat(ios): FileKind extension classification"
```

### Task 3: `RemoteEntry` model

**Files:**
- Create: `ios/RsyncExplorer/Models/RemoteEntry.swift`

- [ ] **Step 1: Implement (no test — plain data type, exercised by later tasks)**

```swift
import Foundation

struct RemoteEntry: Identifiable, Equatable {
    var id: String { path }
    let name: String
    let path: String          // absolute remote path
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date?
    var kind: FileKind { FileKind.from(name: name, isDirectory: isDirectory) }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/RsyncExplorer/Models/RemoteEntry.swift
git commit -m "feat(ios): RemoteEntry model"
```

### Task 4: `SnapshotResolver` (latest snapshot selection)

**Files:**
- Create: `ios/RsyncExplorer/Core/SnapshotResolver.swift`
- Test: `ios/RsyncExplorerTests/SnapshotResolverTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RsyncExplorer

final class SnapshotResolverTests: XCTestCase {
    private func dir(_ name: String, _ ts: TimeInterval) -> RemoteEntry {
        RemoteEntry(name: name, path: "/b/\(name)", isDirectory: true,
                    size: 0, modificationDate: Date(timeIntervalSince1970: ts))
    }
    func test_picks_newest_by_mtime() {
        let entries = [dir("2026-06-01", 100), dir("2026-06-20", 300), dir("2026-06-10", 200)]
        XCTAssertEqual(SnapshotResolver.latest(from: entries)?.name, "2026-06-20")
    }
    func test_mtime_tie_breaks_on_name_desc() {
        let entries = [dir("2026-06-19", 300), dir("2026-06-20", 300)]
        XCTAssertEqual(SnapshotResolver.latest(from: entries)?.name, "2026-06-20")
    }
    func test_ignores_files() {
        let file = RemoteEntry(name: "z.txt", path: "/b/z.txt", isDirectory: false,
                               size: 1, modificationDate: Date(timeIntervalSince1970: 999))
        XCTAssertEqual(SnapshotResolver.latest(from: [dir("snap", 1), file])?.name, "snap")
    }
    func test_empty_returns_nil() {
        XCTAssertNil(SnapshotResolver.latest(from: []))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — Expected: FAIL, `SnapshotResolver` undefined.

- [ ] **Step 3: Implement**

```swift
import Foundation

enum SnapshotResolver {
    /// Picks the newest snapshot directory: latest mtime, tie-broken by name descending.
    static func latest(from entries: [RemoteEntry]) -> RemoteEntry? {
        entries
            .filter { $0.isDirectory }
            .max { a, b in
                let ta = a.modificationDate ?? .distantPast
                let tb = b.modificationDate ?? .distantPast
                if ta != tb { return ta < tb }
                return a.name < b.name
            }
    }
}
```

- [ ] **Step 4: Run to verify it passes** — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/RsyncExplorer/Core/SnapshotResolver.swift ios/RsyncExplorerTests/SnapshotResolverTests.swift
git commit -m "feat(ios): latest-snapshot resolver"
```

### Task 5: `CacheKey`

**Files:**
- Create: `ios/RsyncExplorer/Core/CacheKey.swift`
- Test: `ios/RsyncExplorerTests/CacheKeyTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RsyncExplorer

final class CacheKeyTests: XCTestCase {
    func test_stable_for_same_inputs() {
        let a = CacheKey.make(path: "/b/x.jpg", size: 10, mtime: 1000)
        let b = CacheKey.make(path: "/b/x.jpg", size: 10, mtime: 1000)
        XCTAssertEqual(a, b)
    }
    func test_changes_when_mtime_changes() {
        let a = CacheKey.make(path: "/b/x.jpg", size: 10, mtime: 1000)
        let b = CacheKey.make(path: "/b/x.jpg", size: 10, mtime: 2000)
        XCTAssertNotEqual(a, b)
    }
    func test_is_filename_safe_hex() {
        let k = CacheKey.make(path: "/b/weird name?.jpg", size: 1, mtime: 1)
        XCTAssertTrue(k.allSatisfy { $0.isHexDigit })
    }
}
```

- [ ] **Step 2: Run to verify it fails** — Expected: FAIL.

- [ ] **Step 3: Implement**

```swift
import Foundation
import CryptoKit

enum CacheKey {
    static func make(path: String, size: Int64, mtime: TimeInterval) -> String {
        let seed = "\(path)|\(size)|\(Int(mtime))"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run to verify it passes** — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/RsyncExplorer/Core/CacheKey.swift ios/RsyncExplorerTests/CacheKeyTests.swift
git commit -m "feat(ios): deterministic cache key"
```

### Task 6: `INIParser`

**Files:**
- Create: `ios/RsyncExplorer/Core/INIParser.swift`
- Test: `ios/RsyncExplorerTests/INIParserTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run to verify it fails** — Expected: FAIL.

- [ ] **Step 3: Implement**

```swift
import Foundation

enum INIParser {
    /// Returns [sectionName: [key: value]]. Comments start with # or ;.
    static func parse(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var current: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                current = name
                result[name] = result[name] ?? [:]
            } else if let eq = line.firstIndex(of: "="), let section = current {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                result[section]?[key] = value
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Run to verify it passes** — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/RsyncExplorer/Core/INIParser.swift ios/RsyncExplorerTests/INIParserTests.swift
git commit -m "feat(ios): INI parser"
```

### Task 7: `ServerConfig` + `ConfigImporter`

**Files:**
- Create: `ios/RsyncExplorer/Models/ServerConfig.swift`
- Create: `ios/RsyncExplorer/Core/ConfigImporter.swift`
- Test: `ios/RsyncExplorerTests/ConfigImporterTests.swift`

- [ ] **Step 1: Write `ServerConfig.swift` (data type)**

```swift
import Foundation

enum AuthMethod: String, Codable { case ed25519Key, password }

struct ServerConfig: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    var remotePath: String
    var authMethod: AuthMethod
    /// Set only transiently during import; secrets are moved to Keychain by the caller.
    var importedKeyPath: String? = nil
}
```

- [ ] **Step 2: Write the failing test**

```swift
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
```

- [ ] **Step 3: Run to verify it fails** — Expected: FAIL.

- [ ] **Step 4: Implement `ConfigImporter.swift`**

```swift
import Foundation

enum ConfigImporter {
    /// Builds ServerConfigs from the `remote.*` sections of a config.ini. Local sections are ignored.
    static func servers(from text: String) -> [ServerConfig] {
        INIParser.parse(text).compactMap { (section, kv) -> ServerConfig? in
            guard section.hasPrefix("remote.") else { return nil }
            let name = String(section.dropFirst("remote.".count))
            guard let host = kv["host"], let user = kv["ssh_user"], let dest = kv["dest"]
            else { return nil }
            let hasKey = (kv["ssh_key"]?.isEmpty == false)
            return ServerConfig(
                name: name,
                host: host,
                port: Int(kv["port"] ?? "") ?? 22,
                username: user,
                remotePath: dest,
                authMethod: hasKey ? .ed25519Key : .password,
                importedKeyPath: hasKey ? kv["ssh_key"] : nil
            )
        }
        .sorted { $0.name < $1.name }
    }
}
```

- [ ] **Step 5: Run to verify it passes** — Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/RsyncExplorer/Models/ServerConfig.swift ios/RsyncExplorer/Core/ConfigImporter.swift ios/RsyncExplorerTests/ConfigImporterTests.swift
git commit -m "feat(ios): ServerConfig + config.ini importer"
```

### Task 8: `OpenSSHKey` (ed25519 private key import)

**Files:**
- Create: `ios/RsyncExplorer/Core/OpenSSHKey.swift`
- Test: `ios/RsyncExplorerTests/OpenSSHKeyTests.swift`

> Scope: **unencrypted** OpenSSH ed25519 keys (cipher `none`). Encrypted keys are out of scope for v1 — the onboarding UI will tell the user to use an unencrypted key or a password. This keeps the parser small and dependency-free.

- [ ] **Step 1: Generate a test fixture (one-time)**

Run:
```bash
ssh-keygen -t ed25519 -N "" -C "test" -f /tmp/rsx_test_key
ssh-keygen -y -f /tmp/rsx_test_key            # prints the public key; note the base64 blob
cat /tmp/rsx_test_key                          # the PEM to embed in the test
```
Embed the private-key PEM as `Self.fixturePEM` and the public-key base64 (the part after `ssh-ed25519 `) as `Self.expectedPubB64` in the test below.

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
import Crypto
@testable import RsyncExplorer

final class OpenSSHKeyTests: XCTestCase {
    // Paste from Step 1:
    static let fixturePEM = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    <paste full PEM here>
    -----END OPENSSH PRIVATE KEY-----
    """
    static let expectedPubB64 = "<paste base64 after 'ssh-ed25519 '>"

    func test_parses_ed25519_and_matches_public_key() throws {
        let key = try OpenSSHKey.ed25519PrivateKey(fromPEM: Self.fixturePEM)
        // OpenSSH wire public key = string "ssh-ed25519" + string(32-byte raw pub)
        let raw = key.publicKey.rawRepresentation
        var blob = Data()
        func sshString(_ d: Data) -> Data {
            var out = Data(); var len = UInt32(d.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }; out.append(d); return out
        }
        blob.append(sshString(Data("ssh-ed25519".utf8)))
        blob.append(sshString(raw))
        XCTAssertEqual(blob.base64EncodedString(), Self.expectedPubB64)
    }

    func test_rejects_encrypted_key() {
        let enc = "-----BEGIN OPENSSH PRIVATE KEY-----\nGARBAGE\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertThrowsError(try OpenSSHKey.ed25519PrivateKey(fromPEM: enc))
    }
}
```

- [ ] **Step 3: Run to verify it fails** — Expected: FAIL, `OpenSSHKey` undefined.

- [ ] **Step 4: Implement `OpenSSHKey.swift`**

```swift
import Foundation
import Crypto

enum OpenSSHKeyError: Error { case badFormat, encryptedUnsupported, notEd25519 }

enum OpenSSHKey {
    /// Parses an unencrypted OpenSSH ed25519 private key PEM into a Curve25519 signing key.
    static func ed25519PrivateKey(fromPEM pem: String) throws -> Curve25519.Signing.PrivateKey {
        let b64 = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let blob = Data(base64Encoded: b64) else { throw OpenSSHKeyError.badFormat }

        var r = ByteReader(blob)
        // magic: "openssh-key-v1\0"
        guard r.readBytes(15) == Data("openssh-key-v1\0".utf8) else { throw OpenSSHKeyError.badFormat }
        let cipher = try r.readSSHString()
        _ = try r.readSSHString()                       // kdfname
        _ = try r.readSSHString()                       // kdfoptions
        guard String(data: cipher, encoding: .utf8) == "none" else {
            throw OpenSSHKeyError.encryptedUnsupported
        }
        guard r.readUInt32() == 1 else { throw OpenSSHKeyError.badFormat }   // key count
        _ = try r.readSSHString()                       // public key blob
        let privSection = try r.readSSHString()          // private section (unencrypted)

        var p = ByteReader(privSection)
        _ = p.readUInt32(); _ = p.readUInt32()           // two checkints (must match; ignored)
        let keyType = try p.readSSHString()
        guard String(data: keyType, encoding: .utf8) == "ssh-ed25519" else {
            throw OpenSSHKeyError.notEd25519
        }
        _ = try p.readSSHString()                        // public key (32 bytes)
        let priv = try p.readSSHString()                 // 64 bytes: seed(32) + pub(32)
        guard priv.count == 64 else { throw OpenSSHKeyError.badFormat }
        let seed = priv.prefix(32)
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }
}

private struct ByteReader {
    private let data: Data
    private var offset: Int
    init(_ data: Data) { self.data = data; self.offset = data.startIndex }
    mutating func readBytes(_ n: Int) -> Data {
        let end = offset + n
        defer { offset = end }
        return data.subdata(in: offset..<min(end, data.endIndex))
    }
    mutating func readUInt32() -> UInt32 {
        let b = readBytes(4)
        return b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    mutating func readSSHString() throws -> Data {
        let len = Int(readUInt32())
        guard offset + len <= data.endIndex else { throw OpenSSHKeyError.badFormat }
        return readBytes(len)
    }
}
```

- [ ] **Step 5: Run to verify it passes** — Expected: PASS (public key derived from the parsed seed matches `ssh-keygen -y`).

- [ ] **Step 6: Commit**

```bash
git add ios/RsyncExplorer/Core/OpenSSHKey.swift ios/RsyncExplorerTests/OpenSSHKeyTests.swift
git commit -m "feat(ios): OpenSSH ed25519 private-key parser"
```

---

## Phase C — SFTP service (prove against the real NAS)

### Task 9: `SFTPService` protocol + `FakeSFTPService`

**Files:**
- Create: `ios/RsyncExplorer/SFTP/SFTPService.swift`
- Create: `ios/RsyncExplorer/SFTP/FakeSFTPService.swift`
- Test: `ios/RsyncExplorerTests/FakeSFTPServiceTests.swift`

- [ ] **Step 1: Write the protocol**

`ios/RsyncExplorer/SFTP/SFTPService.swift`:
```swift
import Foundation

protocol SFTPService {
    func connect() async throws
    func listDirectory(_ path: String) async throws -> [RemoteEntry]
    func resolveLatestSnapshot(under path: String) async throws -> String
    func download(_ path: String, to localURL: URL,
                  progress: @escaping (Double) -> Void) async throws
    func read(at path: String, offset: UInt64, length: UInt32) async throws -> Data
    func disconnect() async
}

extension SFTPService {
    /// Default snapshot resolution: list `path`, pick latest dir, fall back to `path` itself.
    func defaultResolveLatestSnapshot(under path: String) async throws -> String {
        let entries = try await listDirectory(path)
        return SnapshotResolver.latest(from: entries)?.path ?? path
    }
}
```

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
@testable import RsyncExplorer

final class FakeSFTPServiceTests: XCTestCase {
    func test_resolves_latest_snapshot_then_lists_it() async throws {
        let svc = FakeSFTPService.sample()
        try await svc.connect()
        let snap = try await svc.resolveLatestSnapshot(under: "/backup")
        XCTAssertEqual(snap, "/backup/2026-06-20")
        let entries = try await svc.listDirectory(snap)
        XCTAssertEqual(Set(entries.map(\.name)), ["Photos", "readme.txt"])
    }
}
```

- [ ] **Step 3: Run to verify it fails** — Expected: FAIL.

- [ ] **Step 4: Implement `FakeSFTPService.swift`**

```swift
import Foundation

final class FakeSFTPService: SFTPService {
    private let tree: [String: [RemoteEntry]]
    init(tree: [String: [RemoteEntry]]) { self.tree = tree }

    func connect() async throws {}
    func disconnect() async {}

    func listDirectory(_ path: String) async throws -> [RemoteEntry] {
        tree[path] ?? []
    }
    func resolveLatestSnapshot(under path: String) async throws -> String {
        try await defaultResolveLatestSnapshot(under: path)
    }
    func download(_ path: String, to localURL: URL,
                  progress: @escaping (Double) -> Void) async throws {
        progress(1.0)
        try Data().write(to: localURL)
    }
    func read(at path: String, offset: UInt64, length: UInt32) async throws -> Data { Data() }

    static func sample() -> FakeSFTPService {
        func d(_ n: String, _ p: String, _ ts: TimeInterval) -> RemoteEntry {
            RemoteEntry(name: n, path: p, isDirectory: true, size: 0,
                        modificationDate: Date(timeIntervalSince1970: ts))
        }
        func f(_ n: String, _ p: String) -> RemoteEntry {
            RemoteEntry(name: n, path: p, isDirectory: false, size: 12,
                        modificationDate: Date(timeIntervalSince1970: 1))
        }
        return FakeSFTPService(tree: [
            "/backup": [d("2026-06-01", "/backup/2026-06-01", 100),
                        d("2026-06-20", "/backup/2026-06-20", 300)],
            "/backup/2026-06-20": [d("Photos", "/backup/2026-06-20/Photos", 300),
                                   f("readme.txt", "/backup/2026-06-20/readme.txt")],
        ])
    }
}
```

- [ ] **Step 5: Run to verify it passes** — Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/RsyncExplorer/SFTP/SFTPService.swift ios/RsyncExplorer/SFTP/FakeSFTPService.swift ios/RsyncExplorerTests/FakeSFTPServiceTests.swift
git commit -m "feat(ios): SFTPService protocol + in-memory fake"
```

### Task 10: `CitadelSFTPService` (real impl) + live NAS proof

**Files:**
- Create: `ios/RsyncExplorer/SFTP/CitadelSFTPService.swift`

> This task is **manually verified against your real NAS** — there is no unit test for live SFTP. The fake (Task 9) covers the protocol contract.

- [ ] **Step 1: Implement `CitadelSFTPService.swift`**

```swift
import Foundation
import Citadel
import Crypto
import NIOCore

actor CitadelSFTPService: SFTPService {
    private let config: ServerConfig
    private let auth: SFTPAuth
    private let hostKeyStore: HostKeyStore
    private var client: SSHClient?
    private var sftp: SFTPClient?

    enum SFTPAuth { case password(String); case ed25519(Curve25519.Signing.PrivateKey) }

    init(config: ServerConfig, auth: SFTPAuth, hostKeyStore: HostKeyStore) {
        self.config = config; self.auth = auth; self.hostKeyStore = hostKeyStore
    }

    func connect() async throws {
        let method: SSHAuthenticationMethod
        switch auth {
        case .password(let p): method = .passwordBased(username: config.username, password: p)
        case .ed25519(let k): method = .ed25519(username: config.username, privateKey: k)
        }
        let client = try await SSHClient.connect(
            host: config.host,
            port: config.port,
            authenticationMethod: method,
            hostKeyValidator: .custom(TOFUHostKeyValidator(host: config.host, store: hostKeyStore)),
            reconnect: .never
        )
        self.client = client
        self.sftp = try await client.openSFTP()
    }

    func disconnect() async {
        try? await sftp?.close()
        try? await client?.close()
        sftp = nil; client = nil
    }

    func listDirectory(_ path: String) async throws -> [RemoteEntry] {
        guard let sftp else { throw SFTPError.notConnected }
        let items = try await sftp.listDirectory(atPath: path)
        // Citadel returns SFTPPathComponent values per directory chunk.
        return items.flatMap { $0.components }.compactMap { Self.entry(from: $0, parent: path) }
    }

    func resolveLatestSnapshot(under path: String) async throws -> String {
        try await defaultResolveLatestSnapshot(under: path)
    }

    func download(_ path: String, to localURL: URL,
                  progress: @escaping (Double) -> Void) async throws {
        guard let sftp else { throw SFTPError.notConnected }
        let file = try await sftp.openFile(filePath: path, flags: .read)
        defer { Task { try? await file.close() } }
        let attrs = try await file.readAttributes()
        let total = Int(attrs.size ?? 0)
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: localURL)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        let chunk: UInt32 = 256 * 1024
        while true {
            let data = try await file.read(from: offset, length: chunk)
            if data.readableBytes == 0 { break }
            let bytes = Data(data.readableBytesView)
            try handle.write(contentsOf: bytes)
            offset += UInt64(bytes.count)
            if total > 0 { progress(min(1.0, Double(offset) / Double(total))) }
        }
        progress(1.0)
    }

    func read(at path: String, offset: UInt64, length: UInt32) async throws -> Data {
        guard let sftp else { throw SFTPError.notConnected }
        let file = try await sftp.openFile(filePath: path, flags: .read)
        defer { Task { try? await file.close() } }
        let buf = try await file.read(from: offset, length: length)
        return Data(buf.readableBytesView)
    }

    private static func entry(from c: SFTPPathComponent, parent: String) -> RemoteEntry? {
        let name = c.filename
        if name == "." || name == ".." { return nil }
        let attrs = c.attributes
        let isDir = attrs.permissions.map { ($0 & 0o170000) == 0o040000 } ?? false
        let mtime = attrs.accessModificationTime?.modificationTime
        return RemoteEntry(
            name: name,
            path: parent.hasSuffix("/") ? parent + name : parent + "/" + name,
            isDirectory: isDir,
            size: Int64(attrs.size ?? 0),
            modificationDate: mtime
        )
    }
}

enum SFTPError: Error { case notConnected }
```

> NOTE: Citadel's exact type/property names (`SFTPPathComponent`, `.components`, `attributes.permissions`, `accessModificationTime`, `read(from:length:)`, `SSHAuthenticationMethod.passwordBased`) must be confirmed against the resolved Citadel version. After `xcodegen generate`, open the Citadel package in Xcode and adjust the mapping in `entry(from:)`, `download`, and `connect` to match the real API. Treat the build errors as the checklist.

- [ ] **Step 2: Implement `TOFUHostKeyValidator`** (in same file or `Security/HostKeyStore.swift`, finalized in Task 12 — for now use `.acceptAnything()` so you can prove auth):

Temporarily replace the `hostKeyValidator:` argument with `.acceptAnything()` to unblock the live test; swap to TOFU in Task 12.

- [ ] **Step 3: Write a temporary live-proof harness**

Add a throwaway button to `RootView` that constructs a `CitadelSFTPService` from your real NAS details (host/user + an unencrypted ed25519 key pasted in, or a password), calls `connect()`, then `resolveLatestSnapshot(under:)`, then `listDirectory`, and prints results with `print(...)`.

- [ ] **Step 4: Run on device and verify**

Run on the iPhone (must be on the same network as the NAS). Tap the button.
Expected (console): a successful connect, a resolved snapshot path, and a printed list of real folder names from your NAS. **If auth fails:** check key format (Task 8 handles only unencrypted ed25519) or fall back to password. **This is the Phase C gate** — do not proceed past Phase D until this prints real listings.

- [ ] **Step 5: Remove the throwaway harness, commit the service**

```bash
git add ios/RsyncExplorer/SFTP/CitadelSFTPService.swift
git commit -m "feat(ios): Citadel-backed SFTP service (live-verified)"
```

---

## Phase D — Video playback (prove MobileVLCKit)

### Task 11: Add MobileVLCKit and prove playback

**Files:**
- Modify: `ios/project.yml`

- [ ] **Step 1: Add MobileVLCKit to `project.yml`**

Try SPM first — add under `packages:`:
```yaml
  MobileVLCKit:
    url: https://code.videolan.org/videolan/VLCKit.git
    from: 4.0.0
```
and add `- package: MobileVLCKit` to the target `dependencies`. If VideoLAN's SPM endpoint does not resolve, fall back to CocoaPods: create `ios/Podfile` with `pod 'MobileVLCKit'`, run `pod install`, and open the generated `.xcworkspace` instead (update the run scheme accordingly).

> Spec open-Q #2: confirm the working distribution channel here before building UI on it.

- [ ] **Step 2: Regenerate and build** — `cd ios && xcodegen generate`; build in Xcode. Expected: links MobileVLCKit with no errors.

- [ ] **Step 3: Throwaway playback proof**

Add a temporary button to `RootView` that plays a known-good local sample (drag a small `.mkv` into the app bundle, or use a `file://` URL from the Documents dir) through a `VLCMediaPlayer` into a `UIView`. Confirm video renders and audio plays on device.
Expected: the clip plays. **This is the Phase D gate.**

- [ ] **Step 4: Remove the throwaway button, commit the dependency change**

```bash
git add ios/project.yml ios/Podfile* 2>/dev/null; git commit -m "build(ios): add MobileVLCKit for FFmpeg video playback"
```

---

## Phase E — Security storage

### Task 12: `CredentialStore` + `HostKeyStore` (Keychain)

**Files:**
- Create: `ios/RsyncExplorer/Security/CredentialStore.swift`
- Create: `ios/RsyncExplorer/Security/HostKeyStore.swift`
- Test: `ios/RsyncExplorerTests/HostKeyStoreTests.swift`

- [ ] **Step 1: Implement `CredentialStore.swift`** (Keychain generic-password wrapper)

```swift
import Foundation
import Security

struct CredentialStore {
    private let service = "com.joeltordjman.RsyncExplorer.credentials"

    func save(_ secret: Data, account: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = secret
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }
    func load(account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
}
enum KeychainError: Error { case status(OSStatus) }
```

- [ ] **Step 2: Write the failing test for `HostKeyStore` pin/compare logic**

```swift
import XCTest
@testable import RsyncExplorer

final class HostKeyStoreTests: XCTestCase {
    func test_first_use_trusts_and_persists() {
        let store = HostKeyStore(backing: InMemoryKVStore())
        let key = Data([1,2,3])
        XCTAssertEqual(store.evaluate(host: "nas", presentedKey: key), .trustedNew)
        XCTAssertEqual(store.evaluate(host: "nas", presentedKey: key), .trustedKnown)
    }
    func test_changed_key_is_flagged() {
        let store = HostKeyStore(backing: InMemoryKVStore())
        _ = store.evaluate(host: "nas", presentedKey: Data([1]))
        XCTAssertEqual(store.evaluate(host: "nas", presentedKey: Data([9])), .changed)
    }
}
```

- [ ] **Step 3: Run to verify it fails** — Expected: FAIL.

- [ ] **Step 4: Implement `HostKeyStore.swift`**

```swift
import Foundation

protocol KVStore { func get(_ k: String) -> Data?; func set(_ k: String, _ v: Data) }

final class InMemoryKVStore: KVStore {
    private var d: [String: Data] = [:]
    func get(_ k: String) -> Data? { d[k] }
    func set(_ k: String, _ v: Data) { d[k] = v }
}

struct HostKeyStore {
    enum Result: Equatable { case trustedNew, trustedKnown, changed }
    private let backing: KVStore
    init(backing: KVStore) { self.backing = backing }

    func evaluate(host: String, presentedKey: Data) -> Result {
        let k = "hostkey." + host
        guard let known = backing.get(k) else { backing.set(k, presentedKey); return .trustedNew }
        return known == presentedKey ? .trustedKnown : .changed
    }
}
```

- [ ] **Step 5: Run to verify it passes** — Expected: PASS.

- [ ] **Step 6: Provide a Keychain-backed `KVStore` for production use** (append to `HostKeyStore.swift`):

```swift
struct KeychainKVStore: KVStore {
    private let store = CredentialStore()
    func get(_ k: String) -> Data? { store.load(account: k) }
    func set(_ k: String, _ v: Data) { try? store.save(v, account: k) }
}
```

- [ ] **Step 7: Wire `TOFUHostKeyValidator`** into `CitadelSFTPService` (replace the temporary `.acceptAnything()` from Task 10): serialize the presented host key to `Data`, call `HostKeyStore.evaluate`, throw on `.changed`, otherwise accept. Confirm the validator hook signature against the resolved Citadel API.

- [ ] **Step 8: Commit**

```bash
git add ios/RsyncExplorer/Security ios/RsyncExplorerTests/HostKeyStoreTests.swift ios/RsyncExplorer/SFTP/CitadelSFTPService.swift
git commit -m "feat(ios): Keychain credential store + TOFU host-key pinning"
```

---

## Phase F — Browser UI

### Task 13: `OnboardingView` (enter / import connection)

**Files:**
- Create: `ios/RsyncExplorer/UI/OnboardingView.swift`
- Modify: `ios/RsyncExplorer/App/RootView.swift`

- [ ] **Step 1: Implement `OnboardingView`** — a `Form` capturing name, host, port, username, remote path, an auth picker (key/password), a secret field (paste key PEM or password), and a "Import config.ini" button using `.fileImporter`. On save: persist `ServerConfig` (Codable → `UserDefaults`) and the secret → `CredentialStore`.

```swift
import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    @State private var name = "nas"
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var remotePath = ""
    @State private var auth: AuthMethod = .ed25519Key
    @State private var secret = ""
    @State private var importing = false
    var onSaved: (ServerConfig) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                    TextField("Host", text: $host).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextField("Username", text: $username).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Remote backup path", text: $remotePath).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section("Auth") {
                    Picker("Method", selection: $auth) {
                        Text("ed25519 key").tag(AuthMethod.ed25519Key)
                        Text("Password").tag(AuthMethod.password)
                    }
                    SecureField(auth == .ed25519Key ? "Paste unencrypted key PEM" : "Password", text: $secret)
                }
                Button("Import config.ini") { importing = true }
                Button("Connect") { save() }.disabled(host.isEmpty || username.isEmpty)
            }
            .navigationTitle("Connect to NAS")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result,
                   let text = try? String(contentsOf: url),
                   let cfg = ConfigImporter.servers(from: text).first {
                    name = cfg.name; host = cfg.host; port = String(cfg.port)
                    username = cfg.username; remotePath = cfg.remotePath; auth = cfg.authMethod
                }
            }
        }
    }

    private func save() {
        var cfg = ServerConfig(name: name, host: host, port: Int(port) ?? 22,
                               username: username, remotePath: remotePath, authMethod: auth)
        cfg.importedKeyPath = nil
        if let data = try? JSONEncoder().encode(cfg) {
            UserDefaults.standard.set(data, forKey: "server")
        }
        try? CredentialStore().save(Data(secret.utf8), account: "secret." + cfg.id.uuidString)
        onSaved(cfg)
    }
}
```

- [ ] **Step 2: Manual verify** — run on simulator; fill the form or import a config.ini; confirm it dismisses to a placeholder. (No unit test — pure UI.)

- [ ] **Step 3: Commit**

```bash
git add ios/RsyncExplorer/UI/OnboardingView.swift ios/RsyncExplorer/App/RootView.swift
git commit -m "feat(ios): onboarding/connection screen"
```

### Task 14: `DirectoryView` + `DirectoryRow` (browse with the fake)

**Files:**
- Create: `ios/RsyncExplorer/UI/DirectoryView.swift`
- Create: `ios/RsyncExplorer/UI/DirectoryRow.swift`

- [ ] **Step 1: Implement `DirectoryView`** — loads `listDirectory(path)` into `@State`, renders a `List` of `DirectoryRow`, routes taps via `NavigationStack` path: folder pushes another `DirectoryView`; image/video/other open the media views (added in Phase H, stubbed now with `Text`). Pull-to-refresh re-lists.

```swift
import SwiftUI

struct DirectoryView: View {
    let service: SFTPService
    let path: String
    let title: String
    @State private var entries: [RemoteEntry] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(entries) { entry in
                switch entry.kind {
                case .folder:
                    NavigationLink(value: entry) { DirectoryRow(entry: entry, service: service) }
                default:
                    NavigationLink(value: entry) { DirectoryRow(entry: entry, service: service) }
                }
            }
        }
        .navigationTitle(title)
        .navigationDestination(for: RemoteEntry.self) { entry in
            destination(for: entry)
        }
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder private func destination(for entry: RemoteEntry) -> some View {
        switch entry.kind {
        case .folder: DirectoryView(service: service, path: entry.path, title: entry.name)
        case .image:  MediaCarouselView(service: service, images: entries.filter { $0.kind == .image }, start: entry)
        case .video:  VideoPlayerView(service: service, entry: entry)
        case .other:  QuickLookView(service: service, entry: entry)
        }
    }

    private func load() async {
        do { entries = try await service.listDirectory(path); error = nil }
        catch { self.error = "Couldn't list this folder. Pull to retry." }
    }
}

#Preview {
    NavigationStack {
        DirectoryView(service: FakeSFTPService.sample(),
                      path: "/backup/2026-06-20", title: "2026-06-20")
    }
}
```

- [ ] **Step 2: Implement `DirectoryRow`** — icon/thumbnail, name, size, date. Use a system icon now; swap to `ThumbnailService` in Task 16.

```swift
import SwiftUI

struct DirectoryRow: View {
    let entry: RemoteEntry
    let service: SFTPService

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 28)
            VStack(alignment: .leading) {
                Text(entry.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var icon: String {
        switch entry.kind { case .folder: "folder.fill"; case .image: "photo"
        case .video: "play.rectangle"; case .other: "doc" }
    }
    private var subtitle: String {
        entry.isDirectory ? "Folder"
            : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
    }
}
```

- [ ] **Step 3: Manual verify via Preview** — Xcode canvas shows the sample tree; tapping a folder pushes; image/video rows route to stubs. (Stub `MediaCarouselView`/`VideoPlayerView`/`QuickLookView` with `Text(entry.name)` until Phase H so this compiles.)

- [ ] **Step 4: Commit**

```bash
git add ios/RsyncExplorer/UI/DirectoryView.swift ios/RsyncExplorer/UI/DirectoryRow.swift
git commit -m "feat(ios): directory browser UI (fake-service preview)"
```

### Task 15: Wire `RootView` end-to-end (onboarding → real browse)

**Files:**
- Modify: `ios/RsyncExplorer/App/RootView.swift`

- [ ] **Step 1: Implement** — load `ServerConfig` from `UserDefaults`; if absent show `OnboardingView`; else build a `CitadelSFTPService` (secret from `CredentialStore`; if key, parse via `OpenSSHKey`), `connect()`, `resolveLatestSnapshot(under: cfg.remotePath)`, and present `DirectoryView` rooted there inside a `NavigationStack`. Show a spinner during connect and an error+retry on failure.

- [ ] **Step 2: Manual verify on device** — cold launch → onboarding → connect → lands on the latest snapshot showing real folders. (Phase C/D gates already proved the pieces.)

- [ ] **Step 3: Commit**

```bash
git add ios/RsyncExplorer/App/RootView.swift
git commit -m "feat(ios): wire onboarding to live SFTP browse"
```

---

## Phase G — File cache & thumbnails

### Task 16: `FileCache`

**Files:**
- Create: `ios/RsyncExplorer/Cache/FileCache.swift`

- [ ] **Step 1: Implement** — maps a `RemoteEntry` to a local URL in `Caches/files/<CacheKey>`; `localURL(for:)` returns the cached file if present; `fetch(_:via:progress:)` downloads via `SFTPService.download` into the cache and returns the URL. Size-cap eviction (delete oldest until under cap).

```swift
import Foundation

actor FileCache {
    private let root: URL
    init() {
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    private func url(for e: RemoteEntry) -> URL {
        let key = CacheKey.make(path: e.path, size: e.size,
                                mtime: e.modificationDate?.timeIntervalSince1970 ?? 0)
        return root.appendingPathComponent(key)
    }
    func cachedURL(for e: RemoteEntry) -> URL? {
        let u = url(for: e); return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    func fetch(_ e: RemoteEntry, via service: SFTPService,
               progress: @escaping (Double) -> Void) async throws -> URL {
        let u = url(for: e)
        if FileManager.default.fileExists(atPath: u.path) { progress(1.0); return u }
        let tmp = u.appendingPathExtension("part")
        try await service.download(e.path, to: tmp, progress: progress)
        try? FileManager.default.removeItem(at: u)
        try FileManager.default.moveItem(at: tmp, to: u)
        return u
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/RsyncExplorer/Cache/FileCache.swift
git commit -m "feat(ios): on-disk file cache with atomic download"
```

### Task 17: `ThumbnailService` + `ThumbnailCache`

**Files:**
- Create: `ios/RsyncExplorer/Cache/ThumbnailCache.swift`
- Create: `ios/RsyncExplorer/Cache/ThumbnailService.swift`
- Modify: `ios/RsyncExplorer/UI/DirectoryRow.swift`

- [ ] **Step 1: Implement `ThumbnailCache`** — stores small JPEGs in `Caches/thumbs/<CacheKey>.jpg`; `image(for:)`/`store(_:for:)`.

- [ ] **Step 2: Implement `ThumbnailService`**

```swift
import UIKit
import ImageIO
import MobileVLCKit

actor ThumbnailService {
    private let cache = ThumbnailCache()
    private let files: FileCache
    private let service: SFTPService
    init(files: FileCache, service: SFTPService) { self.files = files; self.service = service }

    func thumbnail(for e: RemoteEntry) async -> UIImage? {
        if let cached = cache.image(for: e) { return cached }
        let img: UIImage?
        switch e.kind {
        case .image: img = try? await imageThumb(e)
        case .video: img = try? await videoThumb(e)
        default: img = nil
        }
        if let img { cache.store(img, for: e) }
        return img
    }

    private func imageThumb(_ e: RemoteEntry) async throws -> UIImage? {
        let url = try await files.fetch(e, via: service) { _ in }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 200,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func videoThumb(_ e: RemoteEntry) async throws -> UIImage? {
        let url = try await files.fetch(e, via: service) { _ in }   // v1: download-first fallback
        return await withCheckedContinuation { cont in
            let media = VLCMedia(url: url)
            let t = VLCMediaThumbnailer(media: media, andDelegate: ThumbDelegate { cont.resume(returning: $0) })
            t.thumbnailWidth = 200; t.thumbnailHeight = 200
            t.fetchThumbnail()
        }
    }
}

private final class ThumbDelegate: NSObject, VLCMediaThumbnailerDelegate {
    let done: (UIImage?) -> Void
    init(_ done: @escaping (UIImage?) -> Void) { self.done = done }
    func mediaThumbnailerDidTimeOut(_ t: VLCMediaThumbnailer) { done(nil) }
    func mediaThumbnailer(_ t: VLCMediaThumbnailer, didFinishThumbnail image: CGImage) {
        done(UIImage(cgImage: image))
    }
}
```

> NOTE: confirm `VLCMediaThumbnailer` exists in the resolved MobileVLCKit build; if not, fall back to grabbing a frame via `VLCMediaPlayer` snapshot. The efficient ranged-read path (spec open-Q #3) can replace `files.fetch` later.

- [ ] **Step 3: Use thumbnails in `DirectoryRow`** — replace the system icon with an async-loaded `ThumbnailService` image (fallback to the icon while loading / when nil). Load in `.task`, cancel-safe.

- [ ] **Step 4: Manual verify on device** — a folder of photos/videos shows real thumbnails; second visit loads them instantly from cache.

- [ ] **Step 5: Commit**

```bash
git add ios/RsyncExplorer/Cache/ThumbnailCache.swift ios/RsyncExplorer/Cache/ThumbnailService.swift ios/RsyncExplorer/UI/DirectoryRow.swift
git commit -m "feat(ios): cached image + video thumbnails"
```

---

## Phase H — Media views

### Task 18: `ZoomableImageView` + `MediaCarouselView`

**Files:**
- Create: `ios/RsyncExplorer/UI/ZoomableImageView.swift`
- Create: `ios/RsyncExplorer/UI/MediaCarouselView.swift`

- [ ] **Step 1: Implement `ZoomableImageView`** — loads the full image via `FileCache`, displays in a pinch/double-tap zoomable container. For large images, render through a Metal-backed `CIContext` (`CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!)`) to keep zoom GPU-accelerated; downscale very large images to screen scale before display.

- [ ] **Step 2: Implement `MediaCarouselView`** — a paged `TabView` seeded with the folder's image entries, opened at `start`'s index; each page is a `ZoomableImageView`; prefetch ±1 neighbors via `FileCache`.

```swift
import SwiftUI

struct MediaCarouselView: View {
    let service: SFTPService
    let images: [RemoteEntry]
    let start: RemoteEntry
    @State private var index: Int = 0

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(images.enumerated()), id: \.element.id) { i, entry in
                ZoomableImageView(service: service, entry: entry).tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .background(.black)
        .ignoresSafeArea()
        .onAppear { index = images.firstIndex(of: start) ?? 0 }
        .navigationBarTitleDisplayMode(.inline)
    }
}
```

- [ ] **Step 3: Manual verify on device** — tap a photo → full-screen; swipe scrolls through all images in the folder; pinch zooms smoothly.

- [ ] **Step 4: Commit**

```bash
git add ios/RsyncExplorer/UI/ZoomableImageView.swift ios/RsyncExplorer/UI/MediaCarouselView.swift
git commit -m "feat(ios): zoomable image carousel"
```

### Task 19: `VideoPlayerView` (VLCKit) + `QuickLookView`

**Files:**
- Create: `ios/RsyncExplorer/UI/VideoPlayerView.swift`
- Create: `ios/RsyncExplorer/UI/QuickLookView.swift`

- [ ] **Step 1: Implement `VideoPlayerView`** — download via `FileCache` with a progress bar, then play the local URL through a `VLCMediaPlayer` wrapped in a `UIViewRepresentable`; basic play/pause + scrubber.

```swift
import SwiftUI
import MobileVLCKit

struct VideoPlayerView: View {
    let service: SFTPService
    let entry: RemoteEntry
    @State private var localURL: URL?
    @State private var progress: Double = 0
    private let cache = FileCache()

    var body: some View {
        Group {
            if let url = localURL { VLCPlayerContainer(url: url).ignoresSafeArea() }
            else { ProgressView(value: progress) { Text("Downloading…") }.padding() }
        }
        .task {
            localURL = try? await cache.fetch(entry, via: service) { p in
                Task { @MainActor in progress = p }
            }
        }
    }
}

struct VLCPlayerContainer: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> UIView {
        let v = UIView(); let player = VLCMediaPlayer()
        player.media = VLCMedia(url: url); player.drawable = v
        context.coordinator.player = player
        DispatchQueue.main.async { player.play() }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var player: VLCMediaPlayer? ; deinit { player?.stop() } }
}
```

- [ ] **Step 2: Implement `QuickLookView`** — download via `FileCache`, present a `QLPreviewController` (`UIViewControllerRepresentable`) on the local URL.

- [ ] **Step 3: Manual verify on device** — tap an MKV/AVI/AV1 clip → downloads, then plays with correct video+audio (proves the FFmpeg/VLCKit path on a non-AVFoundation codec); tap a PDF → QuickLook preview.

- [ ] **Step 4: Commit**

```bash
git add ios/RsyncExplorer/UI/VideoPlayerView.swift ios/RsyncExplorer/UI/QuickLookView.swift
git commit -m "feat(ios): VLCKit video player + QuickLook fallback"
```

---

## Phase I — Polish

### Task 20: Error states, reconnect, and disk guardrails

**Files:**
- Modify: `ios/RsyncExplorer/App/RootView.swift`, `ios/RsyncExplorer/UI/DirectoryView.swift`, `ios/RsyncExplorer/Cache/FileCache.swift`

- [ ] **Step 1: Implement** — friendly connect-failure screen with Retry; reconnect on app foreground (`scenePhase`); per-folder retry row (already stubbed); `FileCache` size-cap eviction + a "low disk" guard before large downloads; clean up `.part` files on launch.
- [ ] **Step 2: Manual verify** — airplane-mode launch shows the error+retry; turning Wi-Fi back on + Retry recovers; a changed host key shows the warning.
- [ ] **Step 3: Commit**

```bash
git add ios/RsyncExplorer
git commit -m "feat(ios): error handling, reconnect, disk guardrails"
```

### Task 21: README + run instructions

**Files:**
- Create: `ios/README.md`

- [ ] **Step 1: Document** — prerequisites (Xcode, XcodeGen, optional CocoaPods), `xcodegen generate`, signing with a free Apple ID, the 7-day re-install caveat, and that the phone must reach the NAS (same LAN or VPN). Note the unencrypted-ed25519-or-password key constraint.
- [ ] **Step 2: Commit**

```bash
git add ios/README.md
git commit -m "docs(ios): build & sideload instructions"
```

---

## Self-review notes (coverage vs spec)

- Use case (browse + carousel + video): Tasks 14, 18, 19. ✓
- Latest snapshot only: Task 4 + Task 10 `resolveLatestSnapshot`. ✓
- SFTP via Citadel, ed25519 + password: Tasks 8, 10. ✓
- FFmpeg/VLCKit (AVC→AV1, all containers, HW+SW, Metal): Tasks 11, 19. ✓
- Thumbnail cache: Task 17. ✓
- Keychain secrets + TOFU host key: Task 12. ✓
- File cache: Task 16. ✓
- Sideload (XcodeGen, free Apple ID, iOS 16): Tasks 1, 21. ✓
- Out-of-scope items (restore, timeline, streaming, multi-server) intentionally absent. ✓

**Known verifications carried into execution** (from spec open-questions, surfaced at the relevant tasks): Citadel API names & ranged reads (Task 10/17), MobileVLCKit distribution & thumbnailer API (Tasks 11/17), snapshot heuristic vs real naming (Task 10 live check). These are flagged inline as "confirm against resolved version" rather than assumed.
