import SwiftUI

/// The window's recorder: Record (with its options while idle), a red Stop with
/// the elapsed time while recording, and Finalizing… until the CLI confirms the
/// recording ended.
struct RecorderToolbarButton: View {
    @Environment(Recorder.self) private var recorder
    @Environment(Jobs.self) private var jobs
    @State private var showingOptions = false

    var body: some View {
        switch recorder.phase {
        case .recording:
            Button(action: recorder.stop) {
                Label { StopTitle() } icon: { Image(systemName: "stop.circle.fill") }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("Stop Recording")
        case .finalizing:
            Button {} label: {
                Label("Finalizing…", systemImage: "hourglass")
            }
            .disabled(true)
        case .idle:
            HStack(spacing: 2) {
                Button(action: recorder.start) {
                    Label("Record", systemImage: "record.circle")
                }
                .help(jobs.isRunning ? "Wait until the current meeting has been processed." : "Start recording")
                Button {
                    showingOptions.toggle()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .accessibilityLabel("Recording options")
                .help("Options for the next recording")
                // Options are fixed once a recording starts, so they are offered only here.
                .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
                    QuickBarView()
                        .padding(14)
                        .frame(width: 320)
                }
            }
            .disabled(jobs.isRunning)
        }
    }
}

/// "Stop 12:40", in its own view so the per-second tick redraws only this label.
private struct StopTitle: View {
    @Environment(Recorder.self) private var recorder

    var body: some View {
        Text("Stop \(Recorder.formatElapsed(recorder.elapsed))")
            .monospacedDigit()
    }
}

/// Record and Stop in the menu bar's Recording menu.
struct RecordingCommands: Commands {
    let recorder: Recorder
    let jobs: Jobs

    var body: some Commands {
        CommandMenu("Recording") {
            if recorder.isRecording {
                Button("Stop Recording", action: recorder.stop)
            } else {
                Button("Record", action: recorder.start)
                    .disabled(recorder.phase == .finalizing || jobs.isRunning)
            }
        }
    }
}
