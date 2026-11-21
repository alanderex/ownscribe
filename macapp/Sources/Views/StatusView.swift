import SwiftUI

/// Shown while recording (timer + Stop) and while processing (spinner).
struct StatusView: View {
    @Environment(Engine.self) private var engine
    @Environment(Recorder.self) private var recorder
    @Environment(Jobs.self) private var jobs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            if recorder.isRecording {
                recording
            } else {
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
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)

            ElapsedText(font: .system(size: 34, weight: .semibold, design: .monospaced))

            Text(engine.captureMic ? "Capturing system audio + mic" : "Capturing system audio")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: recorder.stop) {
                Label("Stop Recording", systemImage: "stop.circle")
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
            if jobs.autoStopped {
                Label("Stopped after silence", systemImage: "moon.zzz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if recorder.phase == .finalizing {
                ProgressView().controlSize(.large)
                Text("Finalizing…").font(.callout)
                Text("Merging the recorded tracks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if jobs.steps.isEmpty {
                // No events yet — the CLI is still starting up, or is an older build
                // without OWNSCRIBE_PROGRESS_EVENTS support.
                ProgressView().controlSize(.large)
                Text("Transcribing & summarizing…").font(.callout)
                Text("This can take a little while on the first run\nwhile models download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                StepChecklist(steps: jobs.steps)
            }
            // Not while finalizing: SIGTERM during the track merge loses the recording.
            if recorder.phase != .finalizing {
                Button(role: .destructive, action: jobs.cancel) {
                    Text("Cancel")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
