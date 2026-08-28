import SwiftUI

/// Shown while recording (timer + Stop) and while processing (spinner).
struct StatusView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 18) {
            switch app.phase {
            case .recording:
                recording
            default:
                processing
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var recording: some View {
        VStack(spacing: 16) {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)

            Text(AppState.formatElapsed(app.elapsed))
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .monospacedDigit()

            Text(app.captureMic ? "Capturing system audio + mic" : "Capturing system audio")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: app.stopRecording) {
                Label("Stop & Transcribe", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
        }
    }

    private var processing: some View {
        VStack(spacing: 10) {
            if app.autoStopped {
                Label("Stopped after silence", systemImage: "moon.zzz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if app.steps.isEmpty {
                // No events yet — the CLI is still starting up, or is an older build
                // without OWNSCRIBE_PROGRESS_EVENTS support.
                ProgressView().controlSize(.large)
                Text("Transcribing & summarizing…").font(.callout)
                Text("This can take a little while on the first run\nwhile models download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(app.steps) { step in
                        StepRow(step: step)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(role: .destructive, action: app.cancelProcessing) {
                Text("Cancel")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

/// One checklist row: status glyph, label, and a determinate bar when the step
/// reports a fraction.
private struct StepRow: View {
    let step: AppState.PipelineStep

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
