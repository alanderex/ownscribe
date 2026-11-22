import XCTest
@testable import Logic

final class LibraryTests: XCTestCase {
    private let berlin: LibraryCalendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return LibraryCalendar(calendar: calendar)
    }()

    private func row(
        _ name: String, day: String?, created: String?,
        transcript: String = "present", summary: String = "present"
    ) -> LibraryRow {
        LibraryRow(
            path: "/n/\(name)", nameDay: day, created: created, title: name, duration: 60,
            speakerCount: 2,
            status: .init(transcript: transcript, summary: summary, audio: nil, orig: false)
        )
    }

    private func components(_ date: Date) -> DateComponents {
        berlin.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    func testDecodesShowListOutput() throws {
        let json = #"""
        {"schema": 1, "meetings": [{"path": "/Users/a/ownscribe/261120-iwr-uni-hd", "name_day": "2026-11-20",
          "created": "2026-11-20T09:59:39+01:00", "title": "Iwr Uni Hd", "duration": 2401.0, "speaker_count": 3,
          "status": {"transcript": "present", "summary": "disabled", "audio": "/Users/a/ownscribe/261120-iwr-uni-hd/recording.wav", "orig": false}}]}
        """#
        let rows = try LibraryListing.decode(Data(json.utf8)).meetings
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "/Users/a/ownscribe/261120-iwr-uni-hd")
        XCTAssertEqual(rows[0].speakerCount, 3)
        XCTAssertEqual(rows[0].status.audio, "/Users/a/ownscribe/261120-iwr-uni-hd/recording.wav")
        XCTAssertTrue(rows[0].isMeeting)
        XCTAssertFalse(rows[0].status.hasSummary)
        XCTAssertEqual(rows[0].tags, [], "a CLI without tags lists none")
    }

    func testDecodesTagsOfRowsAndLibrary() throws {
        let json = #"""
        {"schema": 1, "meetings": [{"path": "/n/a", "name_day": null, "created": null, "title": "A",
          "duration": null, "speaker_count": 0, "tags": ["ClientX", "Q4"],
          "status": {"transcript": "present", "summary": "present", "audio": null, "orig": false}}],
         "tags": [{"name": "ClientX", "count": 2}, {"name": "Q4", "count": 1}]}
        """#
        let listing = try LibraryListing.decode(Data(json.utf8))
        XCTAssertEqual(listing.meetings[0].tags, ["ClientX", "Q4"])
        XCTAssertEqual(listing.tags, [LibraryTag(name: "ClientX", count: 2), LibraryTag(name: "Q4", count: 1)])
    }

    func testDecodesSpeakerNamesAndBusyFolders() throws {
        let json = #"""
        {"schema": 1, "meetings": [{"path": "/n/a", "name_day": null, "created": null, "title": "A",
          "duration": null, "speaker_count": 2, "speakers": ["Anna", "SPEAKER_01"],
          "status": {"transcript": "present", "summary": "present", "audio": null, "orig": false,
                     "busy": true, "holder_pid": 4711, "summary_stale": false}}]}
        """#
        let listing = try LibraryListing.decode(Data(json.utf8))
        XCTAssertEqual(listing.tags, [], "a CLI without tags lists none")
        let rows = listing.meetings
        XCTAssertEqual(rows[0].speakers, ["Anna", "SPEAKER_01"])
        XCTAssertEqual(rows[0].status.busy, .busy)
        XCTAssertEqual(rows[0].status.holderPid, 4711)
    }

    func testSpeakerNamesAreTheNamedSpeakersOfTheWholeLibrary() {
        func meeting(_ speakers: [String]) -> LibraryRow {
            LibraryRow(
                path: "/n/\(speakers.joined())", nameDay: nil, created: nil, title: "T", duration: nil,
                speakerCount: speakers.count, speakers: speakers,
                status: .init(transcript: "present", summary: "present", audio: nil, orig: false)
            )
        }
        let rows = [meeting(["Ben", "SPEAKER_00"]), meeting(["anna", "Ben", "Unknown"]), meeting([])]
        XCTAssertEqual(LibraryRow.speakerNames(in: rows), ["anna", "Ben"])
    }

    func testRefusesAnUnknownSchema() {
        let json = #"{"schema": 2, "meetings": []}"#
        XCTAssertThrowsError(try LibraryListing.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? LibraryListing.Failure, .unsupportedSchema(2))
        }
    }

    func testNameDayWinsOverCreation() throws {
        // A folder copied on the 28th still belongs to the 16th.
        let copied = row("2026-06-16-su-screener", day: "2026-06-16", created: "2026-06-28T11:30:55+02:00")
        let day = try XCTUnwrap(berlin.day(of: copied))
        XCTAssertEqual(components(day).day, 16)
        XCTAssertNil(berlin.time(of: copied), "a creation time on another day is not the meeting's time")
    }

    func testCreationTimeShownOnTheSameDay() throws {
        let titled = row("261120-iwr-uni-hd", day: "2026-11-20", created: "2026-11-20T09:59:39+01:00")
        let time = try XCTUnwrap(berlin.time(of: titled))
        XCTAssertEqual(components(time).hour, 9)
        XCTAssertEqual(components(time).minute, 59)
    }

    func testNameWithoutDateFallsBackToCreation() throws {
        let undated = row("notes", day: nil, created: "2026-11-21T23:30:00+01:00")
        XCTAssertEqual(components(try XCTUnwrap(berlin.day(of: undated))).day, 21)
    }

    func testSectionsNewestDayFirstNewestFirstWithin() {
        let rows = [
            row("a", day: "2026-11-19", created: "2026-11-19T10:00:00+01:00"),
            row("b", day: "2026-11-20", created: "2026-11-20T09:00:00+01:00"),
            row("c", day: "2026-11-20", created: "2026-11-20T15:00:00+01:00"),
        ]
        let sections = berlin.sections(rows)
        XCTAssertEqual(sections.map { $0.rows.map(\.title) }, [["c", "b"], ["a"]])
    }

    func testSectionsLeaveOutUnfinishedAndJobOwnedFolders() {
        let rows = [
            row("done", day: "2026-11-20", created: nil),
            row("audio-only", day: "2026-11-20", created: nil, transcript: "missing", summary: "missing"),
            row("recording-now", day: "2026-11-20", created: nil, transcript: "missing", summary: "disabled"),
            row("summary-only", day: "2026-11-20", created: nil, transcript: "missing", summary: "present"),
            row("running", day: "2026-11-20", created: nil),
        ]
        let sections = berlin.sections(rows, excluding: ["/n/running"])
        XCTAssertEqual(Set(sections.flatMap { $0.rows.map(\.title) }), ["done", "summary-only"])
    }

    func testSectionsLeaveOutBusyFoldersButNotUnknownOnes() {
        func meeting(_ name: String, _ busy: LibraryRow.Status.Busy) -> LibraryRow {
            LibraryRow(
                path: "/n/\(name)", nameDay: "2026-11-20", created: nil, title: name, duration: nil,
                speakerCount: 0,
                status: .init(transcript: "present", summary: "present", audio: nil, orig: false, busy: busy)
            )
        }
        let rows = [meeting("free", .free), meeting("held", .busy), meeting("no-locks", .unknown)]
        XCTAssertEqual(Set(berlin.sections(rows).flatMap { $0.rows.map(\.title) }), ["free", "no-locks"])
    }

    func testUndatedRowsGoLast() {
        let rows = [row("x", day: nil, created: nil), row("y", day: "2026-01-01", created: nil)]
        XCTAssertEqual(berlin.sections(rows).map(\.day.description).last, Date.distantPast.description)
    }
}
