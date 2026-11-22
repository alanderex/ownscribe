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

    func testNoSelectedTagMatchesEverything() {
        XCTAssertTrue(LibraryTagFilter.matches(row, selected: []))
    }

    func testAnySelectedTagMatches() {
        let tagged = LibraryRow(
            path: "/n/a", nameDay: nil, created: nil, title: "A", duration: nil, speakerCount: 0,
            tags: ["ClientX", "Q4"],
            status: .init(transcript: "present", summary: "present", audio: nil, orig: false)
        )
        XCTAssertTrue(LibraryTagFilter.matches(tagged, selected: ["Q4", "Hiring"]))
        XCTAssertFalse(LibraryTagFilter.matches(tagged, selected: ["Hiring"]))
        XCTAssertFalse(LibraryTagFilter.matches(row, selected: ["ClientX"]), "an untagged meeting has none of them")
    }

    func testSelectionSurvivesStorage() {
        let selected: Set<String> = ["ClientX", "Q4 review", "Über uns"]
        XCTAssertEqual(LibraryTagFilter.decode(LibraryTagFilter.encode(selected)), selected)
        XCTAssertEqual(LibraryTagFilter.decode(""), [])
    }
}
