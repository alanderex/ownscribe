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
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Transcribing & summarizing…")
                .font(.callout)
            Text("This can take a little while on the first run\nwhile models download.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
