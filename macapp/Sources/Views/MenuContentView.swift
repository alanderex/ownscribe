import SwiftUI

/// Root of the menu-bar popover. Switches content on the app phase.
struct MenuContentView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(12)
            }
            // A definite height is required: inside a self-sizing MenuBarExtra(.window)
            // popover the system proposes no height, so a maxHeight-only ScrollView
            // collapses to zero and the content disappears (header/footer still show).
            .frame(height: 420)
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .foregroundStyle(.tint)
            Text("ownscribe")
                .font(.headline)
            Spacer()
            statusBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch app.phase {
        case .recording:
            Label("Recording", systemImage: "record.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .processing:
            Label("Processing", systemImage: "hourglass")
                .foregroundStyle(.secondary)
                .font(.caption)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch app.phase {
        case .installing:
            InstallingView()
        case .idle:
            IdleView()
        case .recording, .processing:
            StatusView()
        case .done:
            SummaryView()
        case .failed(let message):
            FailedView(message: message)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .disabled(!app.cli.isInstalled)

            Spacer()

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Idle: quick-bar + record button + recent meetings.
private struct IdleView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            QuickBarView()

            Button(action: app.startRecording) {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if !app.recentMeetings.isEmpty {
                RecentView()
            }
        }
    }
}

private struct FailedView: View {
    @EnvironmentObject var app: AppState
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Back") { app.backToIdle() }
                .buttonStyle(.bordered)
        }
    }
}
