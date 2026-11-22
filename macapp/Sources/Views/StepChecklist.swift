import SwiftUI

/// The recording timer. Its own view so the once-a-second change redraws only
/// this text.
struct ElapsedText: View {
    @Environment(Recorder.self) private var recorder
    var font: Font = .body

    var body: some View {
        Text(Recorder.formatElapsed(recorder.elapsed))
            .font(font)
            .monospacedDigit()
    }
}

/// The CLI's pipeline steps, as the progress events report them.
struct StepChecklist: View {
    let steps: [PipelineStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps) { step in
                StepRow(step: step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One checklist row: status glyph, label, and a determinate bar when the step
/// reports a fraction.
private struct StepRow: View {
    let step: PipelineStep

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                glyph
                    .frame(width: 14)
                Text(step.label)
                    .font(.callout)
                    .foregroundStyle(step.state == .pending ? .secondary : .primary)
                Spacer(minLength: 0)
                if let fraction = step.fraction {
                    Text("\(Int(fraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if step.state == .running, let fraction = step.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            }
            if step.state == .running, let detail = step.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.leading, CGFloat(step.indent) * 16)
    }

    @ViewBuilder
    private var glyph: some View {
        switch step.state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            // A step with no fraction (diarization, summarization) still needs to look
            // alive, so fall back to a spinner rather than a static glyph.
            if step.fraction == nil {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.tint)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
