import XCTest
@testable import Logic

final class SpeakerDraftTests: XCTestCase {
    /// SPEAKER_00 speaks lines 0–2, SPEAKER_01 line 3.
    private let document: MeetingDocument = {
        let json = #"""
        {"schema": 1, "title": "T", "language": "en", "duration": 4.0, "revision": "rev1", "standard_layout": true,
         "turns": [
           {"ordinal": 0, "speaker": "SPEAKER_00", "start": 0, "end": 3, "text": "One. Two. Three.",
            "segments": [{"index": 0, "start": 0, "end": 1, "text": "One."},
                         {"index": 1, "start": 1, "end": 2, "text": "Two."},
                         {"index": 2, "start": 2, "end": 3, "text": "Three."}]},
           {"ordinal": 1, "speaker": "SPEAKER_01", "start": 3, "end": 4, "text": "Four.",
            "segments": [{"index": 3, "start": 3, "end": 4, "text": "Four."}]}],
         "speakers": [{"label": "SPEAKER_00", "turns": 1, "seconds": 3, "longest_turn": 0},
                      {"label": "SPEAKER_01", "turns": 1, "seconds": 1, "longest_turn": 1}],
         "status": {"transcript": "present", "summary": "present", "audio": null, "orig": false}}
        """#
        return try! MeetingDocument.decode(Data(json.utf8))
    }()

    func testStartsEmpty() {
        let draft = SpeakerDraft(document: document)
        XCTAssertTrue(draft.isEmpty)
        XCTAssertEqual(draft.speakers, ["SPEAKER_00", "SPEAKER_01"])
        XCTAssertEqual(draft.arguments, ["--revision", "rev1"])
    }

    func testRenamingAndClearingAName() {
        var draft = SpeakerDraft(document: document)
        draft.rename("SPEAKER_00", to: "  Anna ")
        XCTAssertEqual(draft.name(for: "SPEAKER_00"), "Anna")
        draft.rename("SPEAKER_00", to: "")
        XCTAssertEqual(draft.name(for: "SPEAKER_00"), "SPEAKER_00")
        XCTAssertTrue(draft.isEmpty)
    }

    func testOneNameOnTwoSpeakersMergesThem() {
        var draft = SpeakerDraft(document: document)
        draft.rename("SPEAKER_00", to: "Anna")
        draft.rename("SPEAKER_01", to: "Anna")
        XCTAssertEqual(draft.merges, ["Anna": ["SPEAKER_00", "SPEAKER_01"]])
    }

    func testMovingALine() {
        var draft = SpeakerDraft(document: document)
        draft.move(lines: [1], to: "SPEAKER_01")
        XCTAssertEqual(draft.speaker(ofLine: 1), "SPEAKER_01")
        XCTAssertTrue(draft.isMoved(1))
        XCTAssertEqual(draft.speaker(ofLine: 0), "SPEAKER_00")
        XCTAssertFalse(draft.isMoved(0))
    }

    func testMovingALineBackUndoesTheMove() {
        var draft = SpeakerDraft(document: document)
        draft.move(lines: [1], to: "SPEAKER_01")
        draft.move(lines: [1], to: "SPEAKER_00")
        XCTAssertTrue(draft.isEmpty)
    }

    func testMovingToANewSpeakerListsItUntilNoLineIsLeft() {
        var draft = SpeakerDraft(document: document)
        draft.move(lines: [0], to: "Carla")
        XCTAssertEqual(draft.speakers, ["SPEAKER_00", "SPEAKER_01", "Carla"])
        draft.rename("Carla", to: "Carla M.")
        draft.move(lines: [0], to: "SPEAKER_00")
        XCTAssertEqual(draft.speakers, ["SPEAKER_00", "SPEAKER_01"])
        XCTAssertTrue(draft.isEmpty, "the name of a speaker that no longer exists goes too")
    }

    func testATypedNameMeansTheSpeakerShownUnderIt() {
        var draft = SpeakerDraft(document: document)
        draft.rename("SPEAKER_01", to: "Ben")
        XCTAssertEqual(draft.target(forTypedName: " Ben "), "SPEAKER_01")
        XCTAssertEqual(draft.target(forTypedName: "Carla"), "Carla")
    }

    func testArgumentsMoveThenRenameThenGuardTheRevision() {
        var draft = SpeakerDraft(document: document)
        draft.move(lines: [2, 0], to: "SPEAKER_01")
        draft.rename("SPEAKER_01", to: "Ben")
        draft.move(lines: [3], to: "Carla")
        XCTAssertEqual(draft.arguments, [
            "--assign", "0=SPEAKER_01", "--assign", "2=SPEAKER_01", "--assign", "3=Carla",
            "--map", "SPEAKER_01=Ben",
            "--revision", "rev1",
        ])
    }

    func testNamesCarryOverToAReloadedMeetingWithoutTheMoves() {
        var draft = SpeakerDraft(document: document)
        draft.rename("SPEAKER_00", to: "Anna")
        draft.rename("Gone", to: "Nobody")
        draft.move(lines: [1], to: "SPEAKER_01")
        let carried = draft.names(appliedTo: SpeakerDraft(document: document))
        XCTAssertEqual(carried.name(for: "SPEAKER_00"), "Anna")
        XCTAssertFalse(carried.isMoved(1))
        XCTAssertEqual(carried.arguments, ["--map", "SPEAKER_00=Anna", "--revision", "rev1"])
    }
}
