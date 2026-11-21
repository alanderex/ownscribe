import SwiftUI

/// The menu-bar symbol: what the app is doing, most pressing first.
struct MenuBarIcon: View {
    let engine: Engine
    let recorder: Recorder
    let jobs: Jobs

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        if recorder.isRecording { return "record.circle.fill" }
        if jobs.isRunning { return "hourglass" }
        if engine.isInstalling { return "arrow.down.circle" }
        if case .failed = jobs.state { return "exclamationmark.circle" }
        if engine.setupFailure != nil || engine.permissionFailure != nil { return "exclamationmark.circle" }
        return "waveform"
    }
}
