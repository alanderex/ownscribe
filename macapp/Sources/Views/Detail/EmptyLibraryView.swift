import SwiftUI

/// No meetings yet: say so, and offer the one thing to do about it.
struct EmptyLibraryView: View {
    @Environment(Recorder.self) private var recorder
    @Environment(Jobs.self) private var jobs

    var body: some View {
        ContentUnavailableView {
            Label("No meetings yet", systemImage: "waveform")
        } description: {
            Text("Recorded meetings appear here with their transcript and summary.")
        } actions: {
            Button("Record", action: recorder.start)
                .buttonStyle(.borderedProminent)
                .disabled(recorder.isRecording || jobs.isRunning)
        }
    }
}
