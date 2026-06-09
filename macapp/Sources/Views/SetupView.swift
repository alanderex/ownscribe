import AppKit
import SwiftUI

/// First-run prompt: point the app at the ownscribe project folder so it can
/// find `.venv/bin/ownscribe`.
struct SetupView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Set up ownscribe", systemImage: "folder.badge.gearshape")
                .font(.headline)

            Text("""
            Choose your ownscribe project folder — the one that contains \
            `.venv/bin/ownscribe` (created by `uv sync`).
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button("Choose Folder…") { chooseFolder() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Select the ownscribe project directory"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            app.setProjectDirectory(url)
        }
    }
}
