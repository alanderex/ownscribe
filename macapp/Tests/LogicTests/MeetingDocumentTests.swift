import XCTest
@testable import Logic

final class MeetingDocumentTests: XCTestCase {
    private let diarized = #"""
    {"schema": 1, "title": "Budget Review", "language": "en", "duration": 40.0,
     "turns": [
       {"ordinal": 0, "speaker": "SPEAKER_00", "start": 0.0, "end": 8.0, "text": "Welcome everyone."},
       {"ordinal": 1, "speaker": "Anna", "start": 8.0, "end": 10.0, "text": "Sounds good."}],
     "speakers": [
       {"label": "SPEAKER_00", "turns": 1, "seconds": 8.0, "longest_turn": 0},
       {"label": "Anna", "turns": 1, "seconds": 2.0, "longest_turn": 1}],
     "status": {"transcript": "present", "summary": "missing", "audio": null, "orig": false}}
    """#

    func testDecodesShowOutput() throws {
        let document = try MeetingDocument.decode(Data(diarized.utf8))
        XCTAssertEqual(document.language, "en")
        XCTAssertEqual(document.turns.map(\.speaker), ["SPEAKER_00", "Anna"])
        XCTAssertEqual(document.speakers.first?.longestTurn, 0)
        XCTAssertNil(document.status.audio)
    }

    func testUnnamedSpeakers() throws {
        let document = try MeetingDocument.decode(Data(diarized.utf8))
        XCTAssertEqual(document.unnamedSpeakers, ["SPEAKER_00"])
        XCTAssertFalse(MeetingDocument.isUnnamedLabel("SPEAKER_"))
        XCTAssertFalse(MeetingDocument.isUnnamedLabel("SPEAKER_X1"))
        XCTAssertTrue(MeetingDocument.isUnnamedLabel("SPEAKER_10"))
    }

    func testPlainTextWithSpeakers() throws {
        let document = try MeetingDocument.decode(Data(diarized.utf8))
        XCTAssertEqual(document.plainText, "SPEAKER_00 (0:00)\nWelcome everyone.\n\nAnna (0:08)\nSounds good.\n")
    }

    func testPlainTextWithoutSpeakers() throws {
        let json = #"""
        {"schema": 1, "title": "T", "language": null, "duration": null,
         "turns": [{"ordinal": 0, "speaker": null, "start": 3723.0, "end": 3730.0, "text": "Still going."}],
         "speakers": [], "status": {"transcript": "present", "summary": "disabled", "audio": null, "orig": false}}
        """#
        XCTAssertEqual(try MeetingDocument.decode(Data(json.utf8)).plainText, "[1:02:03] Still going.\n")
    }

    func testDecodesLinesRevisionAndLayout() throws {
        let json = #"""
        {"schema": 1, "title": "T", "language": "en", "duration": 4.0,
         "revision": "abc123", "standard_layout": false,
         "turns": [{"ordinal": 0, "speaker": "A", "start": 0.0, "end": 4.0, "text": "One. Two.",
                    "segments": [{"index": 0, "start": 0.0, "end": 2.0, "text": "One."},
                                 {"index": 2, "start": 2.0, "end": 4.0, "text": "Two."}]}],
         "speakers": [{"label": "A", "turns": 1, "seconds": 4.0, "longest_turn": 0}],
         "status": {"transcript": "present", "summary": "present", "audio": null, "orig": true,
                    "busy": false, "holder_pid": null, "summary_stale": true}}
        """#
        let document = try MeetingDocument.decode(Data(json.utf8))
        XCTAssertEqual(document.revision, "abc123")
        XCTAssertEqual(document.standardLayout, false)
        XCTAssertEqual(document.turns[0].segments.map(\.index), [0, 2])
        XCTAssertEqual(document.turns[0].segments[1].text, "Two.")
        XCTAssertTrue(document.status.summaryStale)
        XCTAssertEqual(document.status.busy, .free)
    }

    func testAnOlderDocumentDecodesWithoutTheNewFields() throws {
        let document = try MeetingDocument.decode(Data(diarized.utf8))
        XCTAssertNil(document.revision)
        XCTAssertNil(document.standardLayout)
        XCTAssertEqual(document.turns[0].segments, [])
        XCTAssertEqual(document.status.busy, .free)
        XCTAssertFalse(document.status.summaryStale)
    }

    func testBusyIsTrueFalseOrUnknown() throws {
        func busy(_ value: String) throws -> LibraryRow.Status.Busy {
            let json = #"{"transcript": "present", "summary": "missing", "audio": null, "orig": false, "busy": "# + value + #", "holder_pid": 42}"#
            return try JSONDecoder().decode(LibraryRow.Status.self, from: Data(json.utf8)).busy
        }
        XCTAssertEqual(try busy("true"), .busy)
        XCTAssertEqual(try busy("false"), .free)
        XCTAssertEqual(try busy(#""unknown""#), .unknown)
        XCTAssertThrowsError(try busy(#""maybe""#))
    }

    func testRefusesAnUnknownSchema() {
        let json = diarized.replacingOccurrences(of: #""schema": 1"#, with: #""schema": 2"#)
        XCTAssertThrowsError(try MeetingDocument.decode(Data(json.utf8)))
    }
}
