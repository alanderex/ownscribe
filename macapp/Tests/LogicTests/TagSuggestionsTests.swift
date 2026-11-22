import XCTest
@testable import Logic

final class TagSuggestionsTests: XCTestCase {
    private let library = [
        LibraryTag(name: "ClientX", count: 3), LibraryTag(name: "Hiring", count: 1),
        LibraryTag(name: "Q4 Review", count: 2), LibraryTag(name: "Über uns", count: 1),
    ]

    func testNothingTypedOffersEveryTagTheMeetingLacks() {
        XCTAssertEqual(TagSuggestions.suggest(" ", from: library, excluding: ["Hiring"]), ["ClientX", "Q4 Review", "Über uns"])
    }

    func testTagsStartingWithTheTextComeFirst() {
        let lib = [LibraryTag(name: "Backlog", count: 1), LibraryTag(name: "Log review", count: 1)]
        XCTAssertEqual(TagSuggestions.suggest("log", from: lib, excluding: []), ["Log review", "Backlog"])
    }

    func testMatchingIgnoresCaseAndAccents() {
        XCTAssertEqual(TagSuggestions.suggest("CLIENT", from: library, excluding: []), ["ClientX"])
        XCTAssertEqual(TagSuggestions.suggest("uber", from: library, excluding: []), ["Über uns"])
    }

    func testATagTheMeetingHasIsNotOffered() {
        XCTAssertEqual(TagSuggestions.suggest("client", from: library, excluding: ["ClientX"]), [])
    }
}
