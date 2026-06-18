import AppKit
import SwiftUI

/// Setup configuration (rarely changed). Every control writes through
/// `ownscribe config set`, so config.toml stays the single source of truth and
/// stays in sync with the CLI. Per-run choices live in the quick bar instead.
///
/// Uses an explicit segmented tab bar rather than `TabView`: on macOS 26 a plain
/// TabView collapses these into a "Navigation Tab Bar" overflow menu instead of
/// showing tabs.
struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var tab: Tab = .general

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case transcription = "Transcription"
        case summarization = "Summarization"
        case speakers = "Speakers"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            ScrollView {
                Group {
                    switch tab {
                    case .general: GeneralTab()
                    case .transcription: TranscriptionTab()
                    case .summarization: SummarizationTab()
                    case .speakers: DiarizationTab()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 440)
    }
}

// MARK: - Tabs

private struct GeneralTab: View {
    @EnvironmentObject var app: AppState

    private static let configURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ownscribe/config.toml")

    var body: some View {
        Form {
            Picker("Default capture", selection: app.boolBinding(\.audio.mic, key: "audio.mic")) {
                Text("System only").tag(false)
                Text("System + Mic").tag(true)
            }
            Picker("Source picker", selection: app.stringBinding(\.audio.captureMode, key: "audio.capture_mode")) {
                Text("Show picker each time").tag("picker")
                Text("Capture all system audio").tag("all")
            }
            Stepper(
                "Silence auto-stop: \(app.config.audio.silenceTimeout)s",
                value: app.intBinding(\.audio.silenceTimeout, key: "audio.silence_timeout"),
                in: 0...3600, step: 30
            )
            Divider()
            HStack {
                ConfigTextField(title: "Output folder", key: "output.dir", keyPath: \.output.dir)
                Button("Choose…") { chooseOutputFolder() }
            }
            Toggle("Keep WAV recordings", isOn: app.boolBinding(\.output.keepRecording, key: "output.keep_recording"))
            Divider()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Config file").font(.caption).foregroundStyle(.secondary)
                    Text("~/.config/ownscribe/config.toml")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([Self.configURL])
                }
            }
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            app.updateConfig("output.dir", url.path)
        }
    }
}

private struct TranscriptionTab: View {
    @EnvironmentObject var app: AppState

    private var modelOptions: [String] {
        let current = app.config.transcription.model
        return app.availableModels.contains(current) ? app.availableModels : app.availableModels + [current]
    }

    /// Language presets minus the "auto" pseudo-entry; include the configured
    /// code if it isn't one of the presets so the picker never shows blank.
    private var languageOptions: [(label: String, code: String)] {
        var options = Array(app.availableLanguages.dropFirst())
        let current = app.config.transcription.language
        if !current.isEmpty && !options.contains(where: { $0.code == current }) {
            options.append((current, current))
        }
        return options
    }

    var body: some View {
        Form {
            Picker("Default model", selection: app.stringBinding(\.transcription.model, key: "transcription.model")) {
                ForEach(modelOptions, id: \.self) { Text($0).tag($0) }
            }
            Picker("Default language", selection: app.stringBinding(\.transcription.language, key: "transcription.language")) {
                Text("Auto-detect").tag("")
                ForEach(languageOptions, id: \.code) { lang in
                    Text(lang.label).tag(lang.code)
                }
            }
            Text("These are defaults; change them per meeting from the menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SummarizationTab: View {
    @EnvironmentObject var app: AppState

    private var backend: String { app.config.summarization.backend }
    private var enabled: Bool { app.config.summarization.enabled }

    var body: some View {
        Form {
            Toggle("Summarize after transcription",
                   isOn: app.boolBinding(\.summarization.enabled, key: "summarization.enabled"))
            if enabled {
                Picker("Backend", selection: app.stringBinding(\.summarization.backend, key: "summarization.backend")) {
                    Text("Local (built-in)").tag("local")
                    Text("Ollama").tag("ollama")
                    Text("OpenAI-compatible").tag("openai")
                }
                ConfigTextField(title: "Model", key: "summarization.model", keyPath: \.summarization.model)
                if backend != "local" {
                    ConfigTextField(
                        title: "Host", key: "summarization.host", keyPath: \.summarization.host,
                        help: "e.g. http://127.0.0.1:8000/v1"
                    )
                }
                if backend == "openai" {
                    ConfigTextField(
                        title: "API key", key: "summarization.api_key", keyPath: \.summarization.apiKey,
                        secure: true, help: "Required by servers like oMLX."
                    )
                }
                Picker("Template", selection: templateBinding) {
                    ForEach(app.availableTemplates, id: \.self) { Text($0.capitalized).tag($0) }
                }
            } else {
                Text("Recordings will be transcribed only — no summary is generated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// config stores "" to mean the default template; present that as "meeting".
    private var templateBinding: Binding<String> {
        Binding(
            get: { app.config.summarization.template.isEmpty ? "meeting" : app.config.summarization.template },
            set: { app.updateConfig("summarization.template", $0) }
        )
    }
}

private struct DiarizationTab: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Form {
            Toggle("Enable speaker diarization", isOn: app.boolBinding(\.diarization.enabled, key: "diarization.enabled"))
            ConfigTextField(
                title: "HF token", key: "diarization.hf_token", keyPath: \.diarization.hfToken,
                secure: true, help: "Set once. Needed for pyannote speaker diarization."
            )
            Picker("Device", selection: app.stringBinding(\.diarization.device, key: "diarization.device")) {
                Text("Auto").tag("auto")
                Text("GPU (MPS)").tag("mps")
                Text("CPU").tag("cpu")
            }
        }
    }
}

// MARK: - Reusable text field (commit on Enter or the Set button)

private struct ConfigTextField: View {
    @EnvironmentObject var app: AppState
    let title: String
    let key: String
    let keyPath: WritableKeyPath<OwnscribeConfig, String>
    var secure = false
    var help: String? = nil
    @State private var draft = ""

    private var effectiveHelp: String? {
        // Secrets come back redacted (blank), so make the keep-existing behavior explicit.
        if secure {
            return [help, "Leave blank to keep the saved value."].compactMap { $0 }.joined(separator: " ")
        }
        return help
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Group {
                    if secure {
                        SecureField(title, text: $draft)
                    } else {
                        TextField(title, text: $draft)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
                Button("Set", action: commit)
                    .buttonStyle(.bordered)
            }
            if let effectiveHelp {
                Text(effectiveHelp)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { draft = app.config[keyPath: keyPath] }
        .onChange(of: app.config[keyPath: keyPath]) { _, newValue in draft = newValue }
    }

    private func commit() {
        // Never overwrite a stored secret with a blank (the field starts blank
        // because `config get` redacts secrets).
        if secure && draft.isEmpty { return }
        app.updateConfig(key, draft)
    }
}

// MARK: - Config bindings (each set persists via `config set` + reload)

extension AppState {
    func stringBinding(_ keyPath: WritableKeyPath<OwnscribeConfig, String>, key: String) -> Binding<String> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { self.updateConfig(key, $0) }
        )
    }

    func boolBinding(_ keyPath: WritableKeyPath<OwnscribeConfig, Bool>, key: String) -> Binding<Bool> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { self.updateConfig(key, $0 ? "true" : "false") }
        )
    }

    func intBinding(_ keyPath: WritableKeyPath<OwnscribeConfig, Int>, key: String) -> Binding<Int> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { self.updateConfig(key, String($0)) }
        )
    }
}
