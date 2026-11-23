import Foundation

/// One meeting as `ownscribe show DIR --json` describes it.
struct MeetingDocument: Decodable, Equatable {
    struct Turn: Decodable, Identifiable, Equatable {
        let ordinal: Int
        /// The speaker label, or nil without diarization.
        let speaker: String?
        let start: Double
        let end: Double
        let text: String
        /// The turn's lines, each numbered as `edit-speakers --assign` names it.
        let segments: [Segment]

        var id: Int { ordinal }

        enum CodingKeys: String, CodingKey {
            case ordinal, speaker, start, end, text, segments
        }

        init(ordinal: Int, speaker: String?, start: Double, end: Double, text: String, segments: [Segment] = []) {
            self.ordinal = ordinal
            self.speaker = speaker
            self.start = start
            self.end = end
            self.text = text
            self.segments = segments
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ordinal = try c.decode(Int.self, forKey: .ordinal)
            speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
            start = try c.decode(Double.self, forKey: .start)
            end = try c.decode(Double.self, forKey: .end)
            text = try c.decode(String.self, forKey: .text)
            segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        }
    }

    /// One timestamped line of a turn.
    struct Segment: Decodable, Identifiable, Equatable {
        /// The segment's index in the transcript; what a line move names.
        let index: Int
        let start: Double
        let end: Double
        let text: String

        var id: Int { index }
    }

    struct Speaker: Decodable, Equatable {
        let label: String
        let turns: Int
        /// Approximate for markdown transcripts: a turn ends where the next begins.
        let seconds: Double
        let longestTurn: Int

        enum CodingKeys: String, CodingKey {
            case label, turns, seconds
            case longestTurn = "longest_turn"
        }
    }

    let schema: Int
    let title: String
    let language: String?
    let duration: Double?
    /// sha256 of the transcript file; a line move passes it back so it never applies
    /// to a transcript that changed since.
    let revision: String?
    /// False when a line move would also rewrite the transcript's layout.
    let standardLayout: Bool?
    let turns: [Turn]
    let speakers: [Speaker]
    let status: LibraryRow.Status
    /// What the current summary was written with; nil from an older CLI or for a
    /// summary from before it was recorded.
    let summaryRequest: SummaryRequest?

    enum CodingKeys: String, CodingKey {
        case schema, title, language, duration, revision, turns, speakers, status
        case standardLayout = "standard_layout"
        case summaryRequest = "summary_request"
    }

    static func decode(_ data: Data) throws -> MeetingDocument {
        let document = try JSONDecoder().decode(MeetingDocument.self, from: data)
        guard document.schema == LibraryListing.supportedSchema else {
            throw LibraryListing.Failure.unsupportedSchema(document.schema)
        }
        return document
    }

    /// Labels diarization assigned that nobody has named yet.
    var unnamedSpeakers: [String] {
        speakers.map(\.label).filter(Self.isUnnamedLabel)
    }

    /// `SPEAKER_00` and the like, as pyannote writes them.
    static func isUnnamedLabel(_ label: String) -> Bool {
        guard label.hasPrefix("SPEAKER_") else { return false }
        let number = label.dropFirst("SPEAKER_".count)
        return !number.isEmpty && number.allSatisfy(\.isASCIIDigit)
    }

    /// The transcript as plain text for the clipboard: a paragraph per turn, headed
    /// by the speaker and time, or `[time] text` lines without diarization.
    var plainText: String {
        if speakers.isEmpty {
            return turns.map { "[\(ClockText.duration($0.start))] \($0.text)" }.joined(separator: "\n") + "\n"
        }
        return turns.map { turn in
            let who = turn.speaker ?? "Unknown"
            return "\(who) (\(ClockText.duration(turn.start)))\n\(turn.text)"
        }.joined(separator: "\n\n") + "\n"
    }
}
