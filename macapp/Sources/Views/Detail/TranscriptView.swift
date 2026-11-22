import SwiftUI

/// The transcript as turns: who spoke, when, and what was said, one row per line.
///
/// With a playable recording a line plays from its start when clicked, or with Space
/// when focused. While speakers can be edited, a line's context menu moves the line
/// or its whole turn to another speaker; the move shows in the draft's colors until
/// it is saved, when the turns regroup.
struct TranscriptView: View {
    let document: MeetingDocument
    let draft: SpeakerDraft
    let playingLine: Int?
    /// The speaker picked in the inspector, whose lines stand out.
    let highlighted: String?
    let play: ((MeetingDocument.Segment) -> Void)?
    /// nil while speakers cannot be edited (a job owns the folder, or an older CLI).
    let move: (([Int], String) -> Void)?
    /// Asks for a new speaker's name, then moves these lines to it.
    let moveToNewSpeaker: (([Int]) -> Void)?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(document.turns) { turn in
                TurnView(
                    turn: turn,
                    draft: draft,
                    playingLine: playingLine,
                    highlighted: highlighted,
                    play: play,
                    move: move,
                    moveToNewSpeaker: moveToNewSpeaker
                )
                .id(turn.ordinal)
            }
        }
    }
}

private struct TurnView: View {
    let turn: MeetingDocument.Turn
    let draft: SpeakerDraft
    let playingLine: Int?
    let highlighted: String?
    let play: ((MeetingDocument.Segment) -> Void)?
    let move: (([Int], String) -> Void)?
    let moveToNewSpeaker: (([Int]) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(SpeakerColors.color(for: turn.speaker, among: draft.speakers))
                .frame(width: isPlaying ? 5 : 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                header
                if turn.segments.isEmpty {
                    // An older CLI sends no lines: the turn is one block, without moves.
                    Text(turn.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(turn.segments) { segment in
                        LineView(
                            segment: segment,
                            turn: turn,
                            draft: draft,
                            isPlaying: playingLine == segment.index,
                            isHighlighted: highlighted != nil && draft.speaker(ofLine: segment.index) == highlighted,
                            play: play.map { action in { action(segment) } },
                            move: move,
                            moveToNewSpeaker: moveToNewSpeaker
                        )
                    }
                }
            }
        }
    }

    private var isPlaying: Bool {
        guard let playingLine else { return false }
        return turn.segments.contains { $0.index == playingLine }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // The name is always written out: color alone never identifies a speaker.
            if let speaker = turn.speaker {
                Text(draft.name(for: speaker)).font(.subheadline.weight(.semibold))
            }
            Text(ClockText.duration(turn.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct LineView: View {
    let segment: MeetingDocument.Segment
    let turn: MeetingDocument.Turn
    let draft: SpeakerDraft
    let isPlaying: Bool
    let isHighlighted: Bool
    let play: (() -> Void)?
    let move: (([Int], String) -> Void)?
    let moveToNewSpeaker: (([Int]) -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let target = movedTo {
                // The line's new speaker, until saving regroups the turns.
                Label(draft.name(for: target), systemImage: "arrow.turn.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SpeakerColors.color(for: target, among: draft.speakers))
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
            }
            Text(segment.text)
                .foregroundStyle(isPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isHighlighted ? AnyShapeStyle(.selection.opacity(0.2)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 4)
        )
        .contentShape(Rectangle())
        // Simultaneous, so selecting the line's text still works.
        .simultaneousGesture(TapGesture().onEnded { play?() })
        .focusable()
        .onKeyPress(.space) {
            guard let play else { return .ignored }
            play()
            return .handled
        }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: "Play from here") { play?() }
        .help(play == nil ? "" : "Click to play from \(ClockText.duration(segment.start))")
    }

    private var movedTo: String? {
        draft.isMoved(segment.index) ? draft.speaker(ofLine: segment.index) : nil
    }

    @ViewBuilder
    private var menu: some View {
        if let move, let moveToNewSpeaker {
            Menu("Move Line to") {
                speakerButtons(lines: [segment.index], current: draft.speaker(ofLine: segment.index), move: move)
                Divider()
                Button("New Speaker…") { moveToNewSpeaker([segment.index]) }
            }
            if turn.segments.count > 1 {
                let lines = turn.segments.map(\.index)
                Menu("Move Turn to") {
                    speakerButtons(lines: lines, current: turn.speaker, move: move)
                    Divider()
                    Button("New Speaker…") { moveToNewSpeaker(lines) }
                }
            }
        }
        if let play {
            Button("Play from Here", action: play)
        }
    }

    private func speakerButtons(lines: [Int], current: String?, move: @escaping ([Int], String) -> Void) -> some View {
        ForEach(draft.speakers, id: \.self) { speaker in
            Button {
                move(lines, speaker)
            } label: {
                if speaker == current {
                    Label(draft.name(for: speaker), systemImage: "checkmark")
                } else {
                    Text(draft.name(for: speaker))
                }
            }
        }
    }

    private var accessibilityText: String {
        let who = draft.speaker(ofLine: segment.index).map(draft.name(for:))
        let when = "at \(ClockText.duration(segment.start))"
        if let who { return "\(who), \(when): \(segment.text)" }
        return "\(when): \(segment.text)"
    }
}

/// A stable color per speaker: the order speakers first appear in the meeting, then
/// speakers created by moving lines. Merging in a draft never shifts the others.
enum SpeakerColors {
    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]

    static func color(for speaker: String?, among speakers: [String]) -> Color {
        guard let speaker, let index = speakers.firstIndex(of: speaker) else {
            return .secondary.opacity(0.4)
        }
        return palette[index % palette.count]
    }
}
