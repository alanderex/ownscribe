import XCTest
@testable import Logic

final class SummaryRequestTests: XCTestCase {
    private let recorded = SummaryRequest(backend: "omlx", model: "gemma", template: "brief", instructions: "In German.")

    func testDecodesTheRequestBehindTheSummary() throws {
        let json = #"""
        {"schema": 1, "title": "T", "language": null, "duration": null, "turns": [], "speakers": [],
         "summary_request": {"backend": "omlx", "model": "gemma", "template": "brief", "instructions": "In German."},
         "status": {"transcript": "present", "summary": "present", "audio": null, "orig": false}}
        """#
        XCTAssertEqual(try MeetingDocument.decode(Data(json.utf8)).summaryRequest, recorded)
    }

    func testAnOlderCLIReportsNone() throws {
        let json = #"""
        {"schema": 1, "title": "T", "language": null, "duration": null, "turns": [], "speakers": [],
         "status": {"transcript": "present", "summary": "present", "audio": null, "orig": false}}
        """#
        XCTAssertNil(try MeetingDocument.decode(Data(json.utf8)).summaryRequest)
    }

    func testStartsFromSettingsWithoutARecordedRequest() {
        XCTAssertEqual(
            SummaryRequest.initial(recorded: nil, backend: "omlx", model: "qwen", template: ""),
            SummaryRequest(backend: "omlx", model: "qwen", template: "meeting", instructions: "")
        )
    }

    func testStartsFromTheLastRequest() {
        XCTAssertEqual(SummaryRequest.initial(recorded: recorded, backend: "omlx", model: "qwen", template: ""), recorded)
    }

    func testAModelFromAnotherBackendGivesWayToSettings() {
        XCTAssertEqual(
            SummaryRequest.initial(recorded: recorded, backend: "local", model: "phi-4-mini", template: "meeting"),
            SummaryRequest(backend: "local", model: "phi-4-mini", template: "brief", instructions: "In German.")
        )
    }

    func testResumeArguments() {
        XCTAssertEqual(
            recorded.resumeArguments(folder: "/n/a"),
            ["resume", "/n/a", "--resummarize", "--template", "brief", "--summary-model", "gemma",
             "--instructions", "In German."]
        )
        var plain = recorded
        plain.instructions = "  \n"
        XCTAssertFalse(plain.resumeArguments(folder: "/n/a").contains("--instructions"))
    }

    func testCustomTemplatesFollowTheBuiltIns() {
        XCTAssertEqual(
            SummaryRequest.templates(custom: ["standup", "brief", "Board"]),
            ["meeting", "lecture", "brief", "Board", "standup"]
        )
    }
}
