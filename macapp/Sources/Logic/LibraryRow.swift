import Foundation

/// One meeting folder as `ownscribe show --list --json` describes it.
struct LibraryRow: Decodable, Identifiable, Hashable {
    struct Status: Decodable, Hashable {
        /// "present" or "missing".
        let transcript: String
        /// "present", "missing" or "disabled".
        let summary: String
        /// The recording, found by the CLI (it knows output.audio_dir); nil when none is kept.
        let audio: String?
        /// Whether original-name copies exist, i.e. speakers were renamed.
        let orig: Bool

        var hasTranscript: Bool { transcript == "present" }
        var hasSummary: Bool { summary == "present" }
    }

    let path: String
    /// `YYYY-MM-DD` from the folder name, when it has one.
    let nameDay: String?
    /// The folder's creation time, ISO 8601 with offset.
    let created: String?
    let title: String
    let duration: Double?
    let speakerCount: Int
    let status: Status

    /// Meetings are keyed by folder path.
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    /// Shown in the Library: the folder holds a transcript or a summary. Folders with
    /// only a recording, or crash leftovers, are not finished meetings.
    var isMeeting: Bool { status.hasTranscript || status.hasSummary }

    enum CodingKeys: String, CodingKey {
        case path, created, title, duration, status
        case nameDay = "name_day"
        case speakerCount = "speaker_count"
    }
}

/// The whole `show --list --json` document.
struct LibraryListing: Decodable {
    /// The only schema this app understands. A newer CLI that changes a field's
    /// meaning bumps it, and the app must not misread the rows.
    static let supportedSchema = 1

    enum Failure: Error, Equatable {
        case unsupportedSchema(Int)
    }

    let schema: Int
    let meetings: [LibraryRow]

    static func decode(_ data: Data) throws -> [LibraryRow] {
        let listing = try JSONDecoder().decode(LibraryListing.self, from: data)
        guard listing.schema == supportedSchema else { throw Failure.unsupportedSchema(listing.schema) }
        return listing.meetings
    }
}
