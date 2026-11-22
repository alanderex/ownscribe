import Foundation

/// Unsaved speaker edits for one meeting: names typed for speakers and lines moved to
/// other speakers. The transcript previews them; one `edit-speakers` call saves them.
///
/// Moves name their target by label (as loaded, or a new speaker's name), never by a
/// typed name, so renaming a speaker after moving lines to it keeps those lines with it.
/// Turns are not regrouped here: the CLI writes the transcript and the app reloads it.
struct SpeakerDraft: Equatable {
    /// The meeting's speaker labels as loaded, in order of first appearance.
    let labels: [String]
    /// The transcript revision the draft was made against; saving passes it back.
    let revision: String?
    /// Each line's speaker as loaded, by segment index.
    private let loadedSpeaker: [Int: String?]

    /// Names typed for speakers, by label. A label not in here keeps its name.
    private(set) var names: [String: String] = [:]
    /// Lines moved to another speaker: segment index → label or new speaker.
    private(set) var moves: [Int: String] = [:]
    /// Speakers that exist only because a line was moved to them, in order of creation.
    private(set) var newSpeakers: [String] = []

    init(document: MeetingDocument) {
        labels = document.speakers.map(\.label)
        revision = document.revision
        var loaded: [Int: String?] = [:]
        for turn in document.turns {
            for segment in turn.segments {
                loaded[segment.index] = turn.speaker
            }
        }
        loadedSpeaker = loaded
    }

    var isEmpty: Bool { names.isEmpty && moves.isEmpty }

    /// Every speaker the editor lists: loaded labels, then new speakers.
    var speakers: [String] { labels + newSpeakers }

    // MARK: Names

    /// The name shown for a speaker: what was typed, or the label itself.
    func name(for label: String) -> String {
        names[label] ?? label
    }

    /// Types a name for a speaker. An empty name, or the label itself, clears it.
    mutating func rename(_ label: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == label {
            names[label] = nil
        } else {
            names[label] = trimmed
        }
    }

    /// Speakers that will end up with the same name, so saving merges them, keyed by that name.
    var merges: [String: [String]] {
        Dictionary(grouping: speakers, by: name(for:)).filter { $0.value.count > 1 }
    }

    // MARK: Moves

    /// The speaker a line belongs to in the draft (a label or new speaker, before renames).
    func speaker(ofLine index: Int) -> String? {
        if let moved = moves[index] { return moved }
        return loadedSpeaker[index].flatMap { $0 }
    }

    func isMoved(_ index: Int) -> Bool {
        moves[index] != nil
    }

    /// Moves lines to a speaker. A line moved back to its loaded speaker is no longer moved.
    mutating func move(lines indices: [Int], to target: String) {
        for index in indices {
            if loadedSpeaker[index] == target {
                moves[index] = nil
            } else {
                moves[index] = target
            }
        }
        if !labels.contains(target), !newSpeakers.contains(target), moves.values.contains(target) {
            newSpeakers.append(target)
        }
        dropUnusedNewSpeakers()
    }

    /// The speaker a name typed for "New Speaker…" means: the speaker already shown
    /// under that name, if any, otherwise a new one by that name.
    func target(forTypedName name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return speakers.first { self.name(for: $0) == trimmed } ?? trimmed
    }

    private mutating func dropUnusedNewSpeakers() {
        let used = Set(moves.values)
        for speaker in newSpeakers where !used.contains(speaker) {
            names[speaker] = nil
        }
        newSpeakers.removeAll { !used.contains($0) }
    }

    // MARK: Saving

    /// The `edit-speakers` arguments after the folder path: moves, then renames, then the
    /// revision, which the CLI checks so the line numbers cannot apply to a changed file.
    var arguments: [String] {
        var args: [String] = []
        for (index, target) in moves.sorted(by: { $0.key < $1.key }) {
            args += ["--assign", "\(index)=\(target)"]
        }
        for label in speakers {
            if let name = names[label] {
                args += ["--map", "\(label)=\(name)"]
            }
        }
        if let revision {
            args += ["--revision", revision]
        }
        return args
    }

    /// This draft's names on a draft of the reloaded meeting, for a transcript that
    /// changed underneath it: the moves no longer apply, names of speakers still there do.
    func names(appliedTo fresh: SpeakerDraft) -> SpeakerDraft {
        var draft = fresh
        for (label, name) in names where fresh.labels.contains(label) {
            draft.names[label] = name
        }
        return draft
    }
}
