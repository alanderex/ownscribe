import Foundation

/// One meeting folder as `ownscribe show --list --json` describes it.
struct LibraryRow: Decodable, Identifiable, Hashable {
    struct Status: Decodable, Hashable {
        /// Whether a process holds the folder's lock. `unknown` on a volume where locks
        /// cannot be read: such a folder stays in the Library and editable.
        enum Busy: Hashable {
            case free, busy, unknown
        }

        /// "present" or "missing".
        let transcript: String
        /// "present", "missing" or "disabled".
        let summary: String
        /// The recording, found by the CLI (it knows output.audio_dir); nil when none is kept.
        let audio: String?
        /// Whether copies from before a speaker edit exist, so Restore can put them back.
        let orig: Bool
        let busy: Busy
        /// The process holding the folder's lock, when one does.
        let holderPid: Int?
        /// The summary was written before speakers were moved.
        let summaryStale: Bool

        var hasTranscript: Bool { transcript == "present" }
        var hasSummary: Bool { summary == "present" }

        enum CodingKeys: String, CodingKey {
            case transcript, summary, audio, orig, busy
            case holderPid = "holder_pid"
            case summaryStale = "summary_stale"
        }

        init(
            transcript: String, summary: String, audio: String?, orig: Bool,
            busy: Busy = .free, holderPid: Int? = nil, summaryStale: Bool = false
        ) {
            self.transcript = transcript
            self.summary = summary
            self.audio = audio
            self.orig = orig
            self.busy = busy
            self.holderPid = holderPid
            self.summaryStale = summaryStale
        }

        /// Fields added after schema 1 shipped are optional, so a row from an older CLI
        /// still decodes: free, not stale.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            transcript = try c.decode(String.self, forKey: .transcript)
            summary = try c.decode(String.self, forKey: .summary)
            audio = try c.decodeIfPresent(String.self, forKey: .audio)
            orig = try c.decode(Bool.self, forKey: .orig)
            holderPid = try c.decodeIfPresent(Int.self, forKey: .holderPid)
            summaryStale = try c.decodeIfPresent(Bool.self, forKey: .summaryStale) ?? false
            if !c.contains(.busy) {
                busy = .free
            } else if let flag = try? c.decode(Bool.self, forKey: .busy) {
                busy = flag ? .busy : .free
            } else {
                let word = try c.decode(String.self, forKey: .busy)
                guard word == "unknown" else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .busy, in: c, debugDescription: "busy is true, false or \"unknown\", not \(word)")
                }
                busy = .unknown
            }
        }
    }

    let path: String
    /// `YYYY-MM-DD` from the folder name, when it has one.
    let nameDay: String?
    /// The folder's creation time, ISO 8601 with offset.
    let created: String?
    let title: String
    let duration: Double?
    let speakerCount: Int
    /// The meeting's speaker labels, named or not: names offered when naming speakers.
    let speakers: [String]
    let status: Status

    /// Meetings are keyed by folder path.
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    /// Shown in the Library: the folder holds a transcript or a summary. Folders with
    /// only a recording, or crash leftovers, are not finished meetings.
    var isMeeting: Bool { status.hasTranscript || status.hasSummary }

    enum CodingKeys: String, CodingKey {
        case path, created, title, duration, status, speakers
        case nameDay = "name_day"
        case speakerCount = "speaker_count"
    }

    init(
        path: String, nameDay: String?, created: String?, title: String, duration: Double?,
        speakerCount: Int, speakers: [String] = [], status: Status
    ) {
        self.path = path
        self.nameDay = nameDay
        self.created = created
        self.title = title
        self.duration = duration
        self.speakerCount = speakerCount
        self.speakers = speakers
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        nameDay = try c.decodeIfPresent(String.self, forKey: .nameDay)
        created = try c.decodeIfPresent(String.self, forKey: .created)
        title = try c.decode(String.self, forKey: .title)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        speakerCount = try c.decode(Int.self, forKey: .speakerCount)
        speakers = try c.decodeIfPresent([String].self, forKey: .speakers) ?? []
        status = try c.decode(Status.self, forKey: .status)
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
