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

            // Each tab is a Form, which scrolls itself on macOS. Don't nest it in a
            // ScrollView — that clips the lower rows (e.g. the config-path row).
            Group {
                switch tab {
                case .general: GeneralTab()
                case .transcription: TranscriptionTab()
                case .summarization: SummarizationTab()
                case .speakers: DiarizationTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 560, height: 480)
    }
}

// MARK: - Tabs

private struct GeneralTab: View {
    @Environment(Engine.self) private var engine

    private static let configURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ownscribe/config.toml")

    var body: some View {
        Form {
            LaunchAtLoginRow()
            Divider()
            Picker("Default capture", selection: engine.boolBinding(\.audio.mic, key: "audio.mic")) {
                Text("System only").tag(false)
                Text("System + Mic").tag(true)
            }
            Picker("Source picker", selection: engine.stringBinding(\.audio.captureMode, key: "audio.capture_mode")) {
                Text("Show picker each time").tag("picker")
                Text("Capture all system audio").tag("all")
            }
            Stepper(
                "Silence auto-stop: \(engine.config.audio.silenceTimeout)s",
                value: engine.intBinding(\.audio.silenceTimeout, key: "audio.silence_timeout"),
                in: 0...3600, step: 30
            )
            Divider()
            HStack {
                ConfigTextField(title: "Output folder", key: "output.dir", keyPath: \.output.dir)
                Button("Choose…") { chooseOutputFolder() }
            }
            Toggle("Keep WAV recordings", isOn: engine.boolBinding(\.output.keepRecording, key: "output.keep_recording"))
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
            engine.updateConfig("output.dir", url.path)
        }
    }
}

private struct TranscriptionTab: View {
    @Environment(Engine.self) private var engine

    private var modelOptions: [String] {
        let current = engine.config.transcription.model
        return engine.availableModels.contains(current) ? engine.availableModels : engine.availableModels + [current]
    }

    /// Language presets minus the "auto" pseudo-entry; include the configured
    /// code if it isn't one of the presets so the picker never shows blank.
    private var languageOptions: [(label: String, code: String)] {
        var options = Array(engine.availableLanguages.dropFirst())
        let current = engine.config.transcription.language
        if !current.isEmpty && !options.contains(where: { $0.code == current }) {
            options.append((current, current))
        }
        return options
    }

    var body: some View {
        Form {
            Picker("Default model", selection: engine.stringBinding(\.transcription.model, key: "transcription.model")) {
                ForEach(modelOptions, id: \.self) { Text($0).tag($0) }
            }
            Picker("Default language", selection: engine.stringBinding(\.transcription.language, key: "transcription.language")) {
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
    @Environment(Engine.self) private var engine

    private var backend: String { engine.config.summarization.backend }
    private var enabled: Bool { engine.config.summarization.enabled }
    /// Backends whose server lists its models (`ownscribe models`) and may want a key.
    private var listsModels: Bool { backend == "omlx" || backend == "openai" }

    var body: some View {
        Form {
            Toggle("Summarize after transcription",
                   isOn: engine.boolBinding(\.summarization.enabled, key: "summarization.enabled"))
            if enabled {
                Picker("Backend", selection: engine.stringBinding(\.summarization.backend, key: "summarization.backend")) {
                    Text("Local (built-in)").tag("local")
                    Text("oMLX").tag("omlx")
                    Text("Ollama").tag("ollama")
                    Text("OpenAI-compatible").tag("openai")
                }
                if listsModels {
                    ServerModelPicker(
                        selection: engine.stringBinding(\.summarization.model, key: "summarization.model")
                    ) {
                        ConfigTextField(title: "Model", key: "summarization.model", keyPath: \.summarization.model)
                    }
                } else {
                    ConfigTextField(
                        title: "Model", key: "summarization.model", keyPath: \.summarization.model,
                        help: backend == "local" ? "A GGUF model. MLX models run through oMLX." : nil
                    )
                }
                if backend != "local" {
                    ConfigTextField(
                        title: "Host", key: "summarization.host", keyPath: \.summarization.host,
                        help: "Leave empty for the backend's default."
                    )
                }
                if listsModels {
                    ConfigTextField(
                        title: "API key", key: "summarization.api_key", keyPath: \.summarization.apiKey,
                        secure: true, help: backend == "omlx" ? "oMLX requires one." : "If the server requires one."
                    )
                }
                Picker("Template", selection: templateBinding) {
                    ForEach(engine.availableTemplates, id: \.self) { Text($0.capitalized).tag($0) }
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
            get: { engine.config.summarization.template.isEmpty ? "meeting" : engine.config.summarization.template },
            set: { engine.updateConfig("summarization.template", $0) }
        )
    }
}

private struct DiarizationTab: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        Form {
            Toggle("Enable speaker diarization", isOn: engine.boolBinding(\.diarization.enabled, key: "diarization.enabled"))
            ConfigTextField(
                title: "HF token", key: "diarization.hf_token", keyPath: \.diarization.hfToken,
                secure: true, help: "Set once. Needed for pyannote speaker diarization."
            )
            Picker("Device", selection: engine.stringBinding(\.diarization.device, key: "diarization.device")) {
                Text("Auto").tag("auto")
                Text("GPU (MPS)").tag("mps")
                Text("CPU").tag("cpu")
            }
        }
    }
}

// MARK: - Reusable text field (commit on Enter or the Set button)

private struct ConfigTextField: View {
    @Environment(Engine.self) private var engine
    let title: String
    let key: String
    let keyPath: WritableKeyPath<OwnscribeConfig, String>
    var secure = false
    var help: String? = nil
    @State private var draft = ""

    /// True when a value for this secret is stored. `config get` blanks the value
    /// itself, so presence is reported separately.
    private var secretIsSet: Bool { engine.config.secretsSet?[key] == true }

    private var effectiveHelp: String? {
        // Secrets come back redacted (blank), so say whether one is stored — otherwise
        // the field going empty after a save is indistinguishable from a failed save.
        if secure {
            let state = secretIsSet
                ? "Saved. Leave blank to keep it, or type a new value to replace it."
                : "Not set."
            return [help, state].compactMap { $0 }.joined(separator: " ")
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
        .onAppear { draft = engine.config[keyPath: keyPath] }
        .onChange(of: engine.config[keyPath: keyPath]) { _, newValue in draft = newValue }
    }

    private func commit() {
        // Never overwrite a stored secret with a blank (the field starts blank
        // because `config get` redacts secrets).
        if secure && draft.isEmpty { return }
        engine.updateConfig(key, draft)
    }
}

// MARK: - Config bindings (each set persists via `config set` + reload)

extension Engine {
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

/// "Launch at login", backed by SMAppService so the app owns its own login item.
///
/// The state is re-read on appear rather than cached: the entry can be removed
/// outside the app — in System Settings, or by an OS upgrade, which is how it was
/// lost on macOS 27 — and a toggle that kept showing "on" would be lying.
private struct LaunchAtLoginRow: View {
    @State private var state: LaunchAtLogin.State = .off
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at login", isOn: Binding(
                get: { state == .on },
                set: { setEnabled($0) }
            ))
            .disabled(state == .unavailable)

            if let failure {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if state == .needsApproval {
                HStack(spacing: 6) {
                    Text("Waiting for approval in System Settings.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Open") { LaunchAtLogin.openSettings() }
                        .buttonStyle(.link)
                        .font(.caption2)
                }
            } else if state == .unavailable {
                Text("Unavailable — move Ownscribe to /Applications and sign it with "
                     + "make-signing-cert.sh, then reopen.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !LaunchAtLogin.isInStableLocation {
                // Registering from a build directory records that path, so the entry
                // breaks the moment the app is copied into /Applications.
                Text("Running from outside /Applications — a login item registered "
                     + "here will break when the app is moved.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { state = LaunchAtLogin.state }
    }

    private func setEnabled(_ on: Bool) {
        failure = nil
        do {
            try LaunchAtLogin.setEnabled(on)
        } catch {
            failure = "Couldn't \(on ? "enable" : "disable") it: \(error.localizedDescription)"
        }
        // Re-read rather than assume: register() can land in .requiresApproval.
        state = LaunchAtLogin.state
    }
}
