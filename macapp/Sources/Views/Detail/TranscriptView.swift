import SwiftUI

/// The transcript as turns: who spoke, when, and what was said.
struct TranscriptView: View {
    let document: MeetingDocument

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(document.turns) { turn in
                TurnView(turn: turn, color: SpeakerColors.color(for: turn.speaker, in: document))
            }
        }
    }
}

private struct TurnView: View {
    let turn: MeetingDocument.Turn
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    // The name is always written out: color alone never identifies a speaker.
                    if let speaker = turn.speaker {
                        Text(speaker).font(.subheadline.weight(.semibold))
                    }
                    Text(ClockText.duration(turn.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(turn.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .focusable()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let when = "at \(ClockText.duration(turn.start))"
        if let speaker = turn.speaker { return "\(speaker), \(when): \(turn.text)" }
        return "\(when): \(turn.text)"
    }
}

/// A stable color per speaker: the order speakers first appear in the meeting.
enum SpeakerColors {
    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]

    static func color(for speaker: String?, in document: MeetingDocument) -> Color {
        guard let speaker, let index = document.speakers.firstIndex(where: { $0.label == speaker }) else {
            return .secondary.opacity(0.4)
        }
        return palette[index % palette.count]
    }
}
