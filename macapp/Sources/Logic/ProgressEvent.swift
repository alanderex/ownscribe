import Foundation

/// One progress event from the CLI (OWNSCRIBE_PROGRESS_EVENTS=1), decoded from a
/// single NDJSON line on stderr. Field presence varies by `event`, so everything
/// past the discriminator is optional.
struct ProgressEvent: Decodable, Equatable {
    struct Step: Decodable, Equatable {
        let key: String
        let label: String
        let indent: Int
    }

    let event: String
    let key: String?
    let label: String?
    let indent: Int?
    let fraction: Double?
    let text: String?
    let steps: [Step]?
    let ok: Bool?
    let reason: String?
    /// recording_started: the meeting folder this run owns.
    /// meeting_saved: where the meeting ended up, after any title rename.
    let folder: String?
    /// meeting_saved: "ok", "failed", "unavailable" or "disabled".
    let summary: String?

    /// Discriminator written by ownscribe.progress; absent on ordinary stderr.
    let ownscribeProgress: Int

    enum CodingKeys: String, CodingKey {
        case event, key, label, indent, fraction, text, steps, ok, reason, folder, summary
        case ownscribeProgress = "ownscribe_progress"
    }

    /// Decode one stderr line, or nil for anything that is not an event.
    ///
    /// Ordinary stderr (torch/pyannote warnings) is not JSON, and JSON without the
    /// discriminator is not ours; both failing to decode is the expected case.
    static func decode(line: String) -> ProgressEvent? {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ProgressEvent.self, from: data)
    }

    /// The last meeting_saved event in a finished run's captured stderr, or nil.
    ///
    /// Events and the process exit reach the app on separate hops, so the exit
    /// handler cannot rely on the event having been handled already; the full
    /// stderr it is given always contains it.
    static func lastMeetingSaved(in stderr: String) -> ProgressEvent? {
        stderr.split(whereSeparator: \.isNewline).reversed().lazy
            .compactMap { decode(line: String($0)) }
            .first { $0.event == "meeting_saved" }
    }
}
