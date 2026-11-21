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

        var id: Int { ordinal }
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
    let turns: [Turn]
    let speakers: [Speaker]
    let status: LibraryRow.Status

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
