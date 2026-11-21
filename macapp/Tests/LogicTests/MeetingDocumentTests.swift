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

    func testRefusesAnUnknownSchema() {
        let json = diarized.replacingOccurrences(of: #""schema": 1"#, with: #""schema": 2"#)
        XCTAssertThrowsError(try MeetingDocument.decode(Data(json.utf8)))
    }
}
