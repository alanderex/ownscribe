import XCTest
@testable import Logic

final class LibrarySearchTests: XCTestCase {
    private let row = LibraryRow(
        path: "/n/261120-q2-sales-review", nameDay: "2026-11-20", created: nil, title: "Q2 Sales Review",
        duration: nil, speakerCount: 0,
        status: .init(transcript: "present", summary: "present", audio: nil, orig: false)
    )

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(LibrarySearch.matches(row, query: "  ", summary: nil))
    }

    func testTitleCaseInsensitive() {
        XCTAssertTrue(LibrarySearch.matches(row, query: "sales", summary: nil))
        XCTAssertFalse(LibrarySearch.matches(row, query: "budget", summary: nil))
    }

    func testSummaryText() {
        XCTAssertTrue(LibrarySearch.matches(row, query: "DEADLINE", summary: "The deadline moves to Friday."))
        XCTAssertFalse(LibrarySearch.matches(row, query: "hiring", summary: "The deadline moves to Friday."))
    }
}
