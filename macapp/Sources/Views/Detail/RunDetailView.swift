import SwiftUI

/// The recording or job in progress: its timer or step checklist, and the way to
/// stop it.
struct RunDetailView: View {
    @Environment(Recorder.self) private var recorder
    @Environment(Jobs.self) private var jobs

    var body: some View {
        Group {
            if recorder.isRecording {
                recording
            } else if recorder.phase == .finalizing {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Finalizing…").font(.title3)
                    Text("Merging the recorded tracks.").foregroundStyle(.secondary)
                }
            } else if jobs.isRunning {
                processing
            } else if case .failed(let message) = jobs.state {
                failed(message)
            } else {
                ContentUnavailableView("Nothing in progress", systemImage: "checkmark.circle")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recording: some View {
        VStack(spacing: 18) {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            ElapsedText(font: .system(size: 40, weight: .semibold, design: .monospaced))
            Button(role: .destructive, action: recorder.stop) {
                Label("Stop Recording", systemImage: "stop.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
        }
    }

    private var processing: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Processing").font(.title2.weight(.semibold))
            if jobs.autoStopped {
                Label("Recording stopped after silence", systemImage: "moon.zzz")
                    .foregroundStyle(.secondary)
            }
            if jobs.steps.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting…").foregroundStyle(.secondary)
                }
            } else {
                StepChecklist(steps: jobs.steps)
            }
            Button("Cancel", role: .destructive, action: jobs.cancel)
        }
        .frame(maxWidth: 420)
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Dismiss", action: jobs.dismissFailure)
        }
        .frame(maxWidth: 480)
    }
}
