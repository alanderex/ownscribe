import SwiftUI

/// First-run: ownscribe isn't installed yet, so the app is setting up its own managed
/// environment (a venv under Application Support, populated with `uv`). Shown while
/// `AppState.install()` runs.
struct InstallingView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Setting up Ownscribe", systemImage: "arrow.down.circle")
                .font(.headline)

            Text("""
            Installing the transcription engine on first launch. This is a one-time \
            download (up to a couple of GB) and can take a few minutes — you can leave \
            this open.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Working…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
