import XCTest
import CoreGraphics
@testable import RsyncExplorer

final class ScrubberTests: XCTestCase {
    func test_fraction_maps_x_to_0_1() {
        XCTAssertEqual(Scrubber.fraction(forX: 0, width: 200), 0, accuracy: 0.0001)
        XCTAssertEqual(Scrubber.fraction(forX: 100, width: 200), 0.5, accuracy: 0.0001)
        XCTAssertEqual(Scrubber.fraction(forX: 200, width: 200), 1, accuracy: 0.0001)
    }

    func test_fraction_clamps_outside_the_bar() {
        XCTAssertEqual(Scrubber.fraction(forX: -40, width: 200), 0, accuracy: 0.0001)
        XCTAssertEqual(Scrubber.fraction(forX: 999, width: 200), 1, accuracy: 0.0001)
    }

    func test_fraction_zero_width_is_safe() {
        XCTAssertEqual(Scrubber.fraction(forX: 50, width: 0), 0)
    }
}
