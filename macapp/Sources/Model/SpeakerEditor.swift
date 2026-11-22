import Foundation
import Observation

/// Each meeting's unsaved speaker edits, kept while the user moves between meetings,
/// and saving them with `ownscribe edit-speakers`.
@MainActor
@Observable
final class SpeakerEditor {
    enum SaveOutcome: Equatable {
        case saved
        /// Another process works on the folder; the draft is kept for later.
        case busy(String)
        /// The transcript changed since the draft was made, so its line numbers no
        /// longer hold. Reload, then carryNames(_:to:).
        case transcriptChanged
        case failed(String)
    }

    // edit-speakers' exit code for a changed transcript (src/ownscribe/speaker_edits.py).
    private static let transcriptChangedExit: Int32 = 65

    /// Drafts with edits in them, by meeting folder path.
    private(set) var drafts: [String: SpeakerDraft] = [:]

    /// The meeting's draft: the one in progress, or a fresh one from the loaded
    /// document. An untouched draft made against another revision is replaced, so it
    /// always matches the transcript on screen.
    func draft(for path: String, document: MeetingDocument) -> SpeakerDraft {
        if let draft = drafts[path], !draft.isEmpty {
            return draft
        }
        return SpeakerDraft(document: document)
    }

    func hasEdits(_ path: String) -> Bool {
        drafts[path].map { !$0.isEmpty } ?? false
    }

    func update(_ path: String, document: MeetingDocument, _ change: (inout SpeakerDraft) -> Void) {
        var draft = draft(for: path, document: document)
        change(&draft)
        drafts[path] = draft.isEmpty ? nil : draft
    }

    func discard(_ path: String) {
        drafts[path] = nil
    }

    /// Saves the meeting's draft in one `edit-speakers` call. The draft is dropped only
    /// once saved; on any refusal it stays for another attempt.
    func save(_ path: String, with cli: OwnscribeCLI) async -> SaveOutcome {
        guard let draft = drafts[path], !draft.isEmpty else { return .saved }
        let result = await cli.editSpeakers(URL(fileURLWithPath: path), arguments: draft.arguments)
        if result.ok {
            drafts[path] = nil
            return .saved
        }
        let message = FailureText.firstMeaningfulLine(result.stderr)
            ?? "Saving the speakers failed (exit \(result.exitCode))."
        switch result.exitCode {
        case OwnscribeCLI.busyExitCode: return .busy(message)
        case Self.transcriptChangedExit: return .transcriptChanged
        default: return .failed(message)
        }
    }

    /// After the transcript changed underneath a draft: its names stay, on a draft of
    /// the reloaded meeting; its moves are dropped.
    func carryNames(_ path: String, to document: MeetingDocument) {
        guard let draft = drafts[path] else { return }
        let carried = draft.names(appliedTo: SpeakerDraft(document: document))
        drafts[path] = carried.isEmpty ? nil : carried
    }

    /// Puts back the transcript and summary as they were before the first speaker
    /// edit (`edit-speakers --revert`) and drops any draft. Returns the problem, if any.
    func revert(_ path: String, with cli: OwnscribeCLI) async -> String? {
        let result = await cli.editSpeakers(URL(fileURLWithPath: path), arguments: ["--revert"])
        guard result.ok else {
            return FailureText.firstMeaningfulLine(result.stderr) ?? "Restoring failed (exit \(result.exitCode))."
        }
        drafts[path] = nil
        return nil
    }
}
