import XCTest
@testable import Logic

final class SummaryFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testMarkdownAsWritten() throws {
        try "# Meeting Summary\n\nWe agreed.\n".write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SummaryFile.text(inFolder: folder), "# Meeting Summary\n\nWe agreed.\n")
    }

    func testJSONGivesTheSummaryValue() throws {
        let json = "{\"summary\": \"## Decisions\\n- Ship it\"}"
        try json.write(to: folder.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SummaryFile.text(inFolder: folder), "## Decisions\n- Ship it")
    }

    func testNoSummary() {
        XCTAssertNil(SummaryFile.text(inFolder: folder))
    }
}
