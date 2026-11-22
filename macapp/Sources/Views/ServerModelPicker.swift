import SwiftUI

/// A summarization model picked from what the omlx or openai server lists
/// (`ownscribe models --json`), asked again when the backend or host changes and on
/// Refresh. When the list cannot be had (server not running, key refused) the CLI's
/// reason shows above `field`, where the model can still be typed.
struct ServerModelPicker<Field: View>: View {
    @Environment(Engine.self) private var engine
    @Binding var selection: String
    @ViewBuilder var field: () -> Field

    @State private var models: [String] = []
    @State private var problem: String?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if models.isEmpty {
                    field()
                } else {
                    Picker("Model", selection: $selection) {
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                    }
                }
                Button {
                    Task { await load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .disabled(isLoading)
                .help("List the server's models again")
            }
            if engine.config.summarization.backend == "omlx", !models.isEmpty, !models.contains(selection) {
                Text("oMLX does not serve “\(selection)”. Pick one of its models.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        // Asks again when the backend or its address changes.
        .task(id: "\(engine.config.summarization.backend) \(engine.config.summarization.host)") { await load() }
    }

    /// The served models, plus the selected one when the server lacks it, so the
    /// picker never shows a blank selection.
    private var options: [String] {
        selection.isEmpty || models.contains(selection) ? models : models + [selection]
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            models = try await engine.cli.models()
            problem = nil
        } catch CLIError.command(_, let message) {
            models = []
            problem = message
        } catch {
            models = []
            problem = "Couldn't list the server's models: \(error)"
        }
    }
}
