import Foundation
import Observation

/// Each meeting's unsaved speaker edits, kept while the user moves between meetings.
@MainActor
@Observable
final class SpeakerEditor {
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
}
