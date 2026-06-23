import XCTest
@testable import RsyncExplorer

final class LRCParserTests: XCTestCase {
    func test_synced_basic() {
        let lines = LRCParser.parse("[00:12.34]Hello\n[00:15.00]World")
        XCTAssertEqual(lines.map(\.text), ["Hello", "World"])
        XCTAssertEqual(lines[0].time ?? -1, 12.34, accuracy: 0.001)
        XCTAssertEqual(lines[1].time ?? -1, 15.0, accuracy: 0.001)
    }

    func test_multiple_timestamps_on_one_line() {
        let lines = LRCParser.parse("[00:01.00][00:03.00]Repeat")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(Set(lines.map(\.text)), ["Repeat"])
        XCTAssertEqual(lines[0].time ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(lines[1].time ?? -1, 3.0, accuracy: 0.001)
    }

    func test_skips_id_tags() {
        let lines = LRCParser.parse("[ar:Artist]\n[ti:Title]\n[00:01.00]Line")
        XCTAssertEqual(lines.map(\.text), ["Line"])
    }

    func test_unsynced_plain_text() {
        let lines = LRCParser.parse("Just text\nMore text")
        XCTAssertEqual(lines.map(\.text), ["Just text", "More text"])
        XCTAssertNil(lines[0].time)
    }

    func test_offset_applied() {
        let lines = LRCParser.parse("[offset:+500]\n[00:10.00]Late")
        XCTAssertEqual(lines[0].time ?? -1, 9.5, accuracy: 0.001)
    }
}
