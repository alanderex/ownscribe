import SwiftUI

/// Per-run controls. Seeded from config defaults; changes apply to the next
/// recording only (passed as CLI flags), they do not rewrite config.toml.
struct QuickBarView: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        @Bindable var engine = engine
        VStack(alignment: .leading, spacing: 10) {
            row("Title") {
                TextField("Optional", text: $engine.meetingTitle)
                    .textFieldStyle(.roundedBorder)
                    .help("Names the output folder YYMMDD-your-title. "
                          + "Left blank, the summary supplies a title.")
            }

            row("Capture") {
                Picker("", selection: $engine.captureMic) {
                    Text("System only").tag(false)
                    Text("System + Mic").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            row("Model") {
                Picker("", selection: $engine.model) {
                    ForEach(engine.modelOptions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }

            row("Language") {
                Picker("", selection: $engine.language) {
                    ForEach(engine.languageOptions, id: \.code) { lang in
                        Text(lang.label).tag(lang.code)
                    }
                }
                .labelsHidden()
            }

            row("Template") {
                Picker("", selection: $engine.template) {
                    ForEach(engine.templateOptions, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden()
            }

            if engine.diarizationEnabled {
                row("Speakers") {
                    Picker("", selection: $engine.speakerCount) {
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
