import SwiftUI

/// Per-run controls. Seeded from config defaults; changes apply to the next
/// recording only (passed as CLI flags), they do not rewrite config.toml.
struct QuickBarView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Capture") {
                Picker("", selection: $app.captureMic) {
                    Text("System only").tag(false)
                    Text("System + Mic").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            row("Model") {
                Picker("", selection: $app.model) {
                    ForEach(app.availableModels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }

            row("Language") {
                Picker("", selection: $app.language) {
                    ForEach(app.availableLanguages, id: \.code) { lang in
                        Text(lang.label).tag(lang.code)
                    }
                }
                .labelsHidden()
            }

            row("Template") {
                Picker("", selection: $app.template) {
                    ForEach(app.availableTemplates, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden()
            }

            if app.diarizationEnabled {
                row("Speakers") {
                    Picker("", selection: $app.speakerCount) {
                        Text("Auto").tag(0)
                        ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ control: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            control()
        }
    }
}
