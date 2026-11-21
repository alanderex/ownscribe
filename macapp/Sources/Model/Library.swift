import AppKit
import Foundation
import Observation

/// Meetings on disk: the recent list and the one being looked at, with its
/// summary text and speaker labels.
@MainActor
@Observable
final class Library {
    private(set) var recentMeetings: [Meeting] = []
    private(set) var currentMeeting: Meeting?
    private(set) var summaryText = ""
    private(set) var detectedSpeakers: [String] = []
    var speakersNamed = false

    private let engine: Engine

    init(engine: Engine) {
        self.engine = engine
    }

    func show(_ meeting: Meeting) {
        currentMeeting = meeting
        detectedSpeakers = []
        speakersNamed = false
        summaryText = ""

        let summaryURL = meeting.summaryURL
        let transcriptURL = meeting.transcriptURL
        Task {
            summaryText = await Self.readMeetingText(summaryURL: summaryURL, transcriptURL: transcriptURL)
        }
        if engine.config.diarization.enabled, let transcript = transcriptURL {
            Task { detectedSpeakers = await engine.cli.listSpeakers(transcript) }
        }
    }

    func closeMeeting() {
        currentMeeting = nil
        summaryText = ""
        detectedSpeakers = []
        speakersNamed = false
    }

    /// Read summary (or transcript fallback) off the main actor.
    private static func readMeetingText(summaryURL: URL?, transcriptURL: URL?) async -> String {
        await Task.detached {
            if let url = summaryURL, let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
            if let url = transcriptURL, let text = try? String(contentsOf: url, encoding: .utf8) {
                return "_(No summary — showing transcript.)_\n\n" + text
            }
            return "_(No summary or transcript found.)_"
        }.value
    }

    func applySpeakerNames(_ mapping: [String: String]) {
        guard let transcript = currentMeeting?.transcriptURL else { return }
        let cleaned = mapping.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !cleaned.isEmpty else { speakersNamed = true; return }
        Task {
            _ = await engine.cli.renameSpeakers(transcript, mapping: cleaned)
            detectedSpeakers = await engine.cli.listSpeakers(transcript)
            speakersNamed = true
        }
    }

    func refreshRecents() {
        recentMeetings = Array(MeetingLoader.load(from: MeetingLoader.outputDir(engine.config)).prefix(8))
    }

    func revealInFinder(_ meeting: Meeting) {
        NSWorkspace.shared.activateFileViewerSelecting([meeting.url])
    }

    func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summaryText, forType: .string)
    }
}
