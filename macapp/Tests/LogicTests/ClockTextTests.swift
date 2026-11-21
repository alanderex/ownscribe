import XCTest
@testable import Logic

final class ClockTextTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual(ClockText.duration(0), "0:00")
        XCTAssertEqual(ClockText.duration(2530), "42:10")
        XCTAssertEqual(ClockText.duration(3723), "1:02:03")
        XCTAssertEqual(ClockText.duration(59.6), "1:00")
    }
}
