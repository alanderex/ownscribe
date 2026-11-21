import SwiftUI

/// Root of the menu-bar popover: the recorder. Shows the most pressing state:
/// setup, a failure, a running recording or job, or the idle recorder. Meetings
/// open in the window.
struct MenuContentView: View {
    @Environment(Engine.self) private var engine
    @Environment(Recorder.self) private var recorder
    @Environment(Jobs.self) private var jobs
    @Environment(Library.self) private var library
    @Environment(WindowCoordinator.self) private var windows
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DegradedBanner()
                    content
                }
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
        if recorder.isRecording {
            Label("Recording", systemImage: "record.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        } else if jobs.isRunning {
            Label("Processing", systemImage: "hourglass")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var content: some View {
        if engine.isInstalling {
            InstallingView()
        } else if let message = engine.setupFailure {
            FailedView(message: message, permission: nil)
        } else if let permission = engine.permissionFailure {
            FailedView(message: permission.message, permission: permission)
        } else if recorder.phase != .idle || jobs.isRunning {
            StatusView()
        } else if case .failed(let message) = jobs.state {
            FailedView(message: message, permission: nil)
        } else {
            IdleView()
        }
    }

    private var footer: some View {
        HStack {
            Button {
                windows.open(WindowID.main, with: openWindow)
            } label: {
                Label("Open Ownscribe", systemImage: "macwindow")
            }
            .buttonStyle(.borderless)

            Button {
                windows.open(WindowID.settings, with: openWindow)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .disabled(!engine.cli.isInstalled)

            Spacer()

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Idle: a finished meeting waiting to be opened, Record, the options for the next
/// recording (collapsed), and the latest meetings.
private struct IdleView: View {
    @Environment(Recorder.self) private var recorder
    @Environment(Jobs.self) private var jobs
    @Environment(Library.self) private var library
    @Environment(WindowCoordinator.self) private var windows
    @Environment(\.openWindow) private var openWindow
    @AppStorage("popover.optionsExpanded") private var optionsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let ready = readyFolder {
                ReadyBanner(path: ready, title: title(of: ready)) {
                    library.markSeen(ready)
                    windows.open(meeting: ready, with: openWindow)
                }
            }

            Button(action: recorder.start) {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            DisclosureGroup("Options", isExpanded: $optionsExpanded) {
                QuickBarView()
                    .padding(.top, 8)
            }

            let recent = library.recentRows(5)
            if !recent.isEmpty {
                RecentView(rows: recent)
            }
        }
    }

    /// The meeting the last run produced, until it is opened.
    private var readyFolder: String? {
        guard let folder = jobs.lastFinished?.folder, library.unseen.contains(folder) else { return nil }
        return folder
    }

    private func title(of path: String) -> String {
        library.rows.first { $0.path == path }?.title
            ?? FolderName.title(URL(fileURLWithPath: path).lastPathComponent)
    }
}

/// "Ready · Open": a run finished while the user was elsewhere. Nothing takes
/// focus by itself; this, the row badge and the icon's dot say so instead.
private struct ReadyBanner: View {
    let path: String
    let title: String
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ready").font(.caption).foregroundStyle(.secondary)
                Text(title).font(.callout).lineLimit(1)
            }
            Spacer()
            Button("Open", action: open)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ready: \(title)")
        .accessibilityAction(named: "Open", open)
    }
}

private struct FailedView: View {
    @Environment(Engine.self) private var engine
    @Environment(Jobs.self) private var jobs
    let message: String
    let permission: Engine.PermissionFailure?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                permission != nil ? "Permission needed" : "Something went wrong",
                systemImage: permission != nil
                    ? "lock.shield" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let permission {
                    Button("Open Settings") { permission.openSettings() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Back") {
                    engine.setupFailure = nil
                    engine.permissionFailure = nil
                    jobs.dismissFailure()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
