import XCTest
@testable import Logic

final class ProgressEventTests: XCTestCase {
    func testRecordingStartedCarriesTheFolder() throws {
        let line = #"{"ownscribe_progress": 1, "event": "recording_started", "silence_timeout": 300, "folder": "/Users/a/ownscribe/261121-1405"}"#
        let event = try XCTUnwrap(ProgressEvent.decode(line: line))
        XCTAssertEqual(event.event, "recording_started")
        XCTAssertEqual(event.folder, "/Users/a/ownscribe/261121-1405")
    }

    func testMeetingSavedCarriesFolderAndSummary() throws {
        let line = #"{"ownscribe_progress": 1, "event": "meeting_saved", "folder": "/n/261121-q2-review", "summary": "unavailable"}"#
        let event = try XCTUnwrap(ProgressEvent.decode(line: line))
        XCTAssertEqual(event.folder, "/n/261121-q2-review")
        XCTAssertEqual(event.summary, "unavailable")
    }

    func testOrdinaryStderrIsNotAnEvent() {
        XCTAssertNil(ProgressEvent.decode(line: "UserWarning: torchaudio._backend is deprecated"))
        XCTAssertNil(ProgressEvent.decode(line: #"{"unrelated": true}"#))
        XCTAssertNil(ProgressEvent.decode(line: #"{"ownscribe_progress": 1, "event": "#))
        XCTAssertNil(ProgressEvent.decode(line: ""))
    }

    func testStepsDecode() throws {
        let line = #"{"ownscribe_progress": 1, "event": "steps", "steps": [{"key": "transcribing", "label": "Transcribing", "indent": 0}]}"#
        let event = try XCTUnwrap(ProgressEvent.decode(line: line))
        XCTAssertEqual(event.steps, [.init(key: "transcribing", label: "Transcribing", indent: 0)])
    }

    func testLastMeetingSavedIsFoundAmongNoise() {
        let stderr = """
            UserWarning: something noisy
            {"ownscribe_progress": 1, "event": "recording_started", "folder": "/n/261121-1405"}
            {"ownscribe_progress": 1, "event": "meeting_saved", "folder": "/n/first", "summary": "ok"}
            Traceback-free trailing noise
            {"ownscribe_progress": 1, "event": "meeting_saved", "folder": "/n/261121-q2-review", "summary": "ok"}
            """
        XCTAssertEqual(ProgressEvent.lastMeetingSaved(in: stderr)?.folder, "/n/261121-q2-review")
    }

    func testNoMeetingSavedFromAnOlderCLI() {
        let stderr = #"{"ownscribe_progress": 1, "event": "recording_stopped", "reason": "user"}"#
        XCTAssertNil(ProgressEvent.lastMeetingSaved(in: stderr))
    }
}
