import XCTest
@testable import RsyncExplorer

final class FileKindTests: XCTestCase {
    func test_directory_is_folder() {
        XCTAssertEqual(FileKind.from(name: "anything", isDirectory: true), .folder)
    }
    func test_image_extensions() {
        for n in ["a.jpg", "B.JPEG", "c.png", "d.heic", "e.gif", "f.webp", "g.avif"] {
            XCTAssertEqual(FileKind.from(name: n, isDirectory: false), .image, n)
        }
    }
    func test_video_extensions() {
        for n in ["a.mp4", "B.MOV", "c.mkv", "d.avi", "e.webm", "f.m4v", "g.ts",
                  "h.vob", "i.m2ts", "j.3gp", "k.flv", "l.ogv"] {
            XCTAssertEqual(FileKind.from(name: n, isDirectory: false), .video, n)
        }
    }
    func test_audio_extensions() {
        for n in ["a.mp3", "B.FLAC", "c.aac", "d.m4a", "e.wav", "f.ogg", "g.opus", "h.wma"] {
            XCTAssertEqual(FileKind.from(name: n, isDirectory: false), .audio, n)
        }
    }
    func test_other_extensions() {
        for n in ["a.pdf", "b.txt", "noext", "c.zip"] {
            XCTAssertEqual(FileKind.from(name: n, isDirectory: false), .other, n)
        }
    }
    func test_isMedia() {
        XCTAssertTrue(FileKind.image.isMedia)
        XCTAssertTrue(FileKind.video.isMedia)
        XCTAssertTrue(FileKind.audio.isMedia)
        XCTAssertFalse(FileKind.folder.isMedia)
        XCTAssertFalse(FileKind.other.isMedia)
    }
}
