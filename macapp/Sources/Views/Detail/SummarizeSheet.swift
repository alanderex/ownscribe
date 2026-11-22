import SwiftUI

/// Asks how to write a meeting's summary: the user's own instructions, a template and
/// a model, on the backend from Settings. It opens with what made the current summary
/// (or Settings' choices), and ⌘↩ starts it.
struct SummarizeSheet: View {
    @Environment(Engine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let meetingTitle: String
    let hasSummary: Bool
    @State var request: SummaryRequest
    let start: (SummaryRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(hasSummary ? "Re-summarize" : "Summarize") “\(meetingTitle)”")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions")
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: $request.instructions)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 110)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    .overlay(alignment: .topLeading) {
                        if request.instructions.isEmpty {
                            Text("Optional, e.g. “Focus on the budget decisions. Write in German.”")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Instructions for the summary")
            }
            Form {
                Picker("Template", selection: $request.template) {
                    ForEach(templates, id: \.self) { Text($0.capitalized).tag($0) }
                }
                if listsModels {
                    ServerModelPicker(selection: $request.model) {
                        TextField("Model", text: $request.model)
                    }
                } else {
                    TextField("Model", text: $request.model)
                }
            }
            .formStyle(.columns)
            Text("Uses \(backendName), as set in Settings › Summarization. The meeting keeps its folder and title.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(hasSummary ? "Re-summarize" : "Summarize") {
                    start(request)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("⌘↩")
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var listsModels: Bool { request.backend == "omlx" || request.backend == "openai" }

    /// The templates on offer, plus the requested one should config.toml have lost it.
    private var templates: [String] {
        let available = engine.availableTemplates
        return available.contains(request.template) ? available : available + [request.template]
    }

    private var backendName: String {
        switch request.backend {
        case "omlx": return "oMLX"
        case "ollama": return "Ollama"
        case "openai": return "the OpenAI-compatible server"
        case "local": return "the built-in local model"
        default: return request.backend
        }
    }
}
