import AppKit
import Foundation
import Observation

/// The installed CLI and what it is told: install and upgrade, config.toml through
/// `ownscribe config`, the per-run choices seeded from it, and the privacy grants a
/// recording needs.
@MainActor
@Observable
final class Engine {
    /// An upgrade the app wants but has not made. Until it is made the app runs on
    /// the CLI it has: recording works, but nothing newer than that CLI does.
    enum Upgrade: Equatable {
        case none
        /// A process still runs from the environment; reinstalling under it could
        /// break it, so the upgrade waits.
        case pending
        /// The install failed; uv leaves the old CLI runnable when that happens.
        case failed(String)
    }

    /// A privacy grant that is missing, found when a recording was about to start.
    enum PermissionFailure: Equatable {
        case screenRecording
        case microphone

        var message: String {
            switch self {
            case .screenRecording:
                return """
                    Ownscribe needs Screen Recording permission to capture system audio.

                    Enable it for this app in System Settings › Privacy & Security › \
                    Screen Recording, then quit and reopen Ownscribe — macOS only applies a \
                    new grant after a relaunch.
                    """
            case .microphone:
                return """
                    Ownscribe needs Microphone permission to record you alongside system audio.

                    Enable it for this app in System Settings › Privacy & Security › \
                    Microphone, then try again — or switch Capture to "System only".
                    """
            }
        }

        /// The pane is several levels deep in System Settings and the app cannot grant
        /// this itself, so the UI offers the shortcut rather than prose.
        func openSettings() {
            switch self {
            case .screenRecording: Permissions.openScreenRecordingSettings()
            case .microphone: Permissions.openMicrophoneSettings()
            }
        }
    }

    /// True while the managed CLI is being installed or upgraded.
    private(set) var isInstalling: Bool
    private(set) var upgrade: Upgrade = .none
    /// Why setup or reading the config failed, until the user dismisses it.
    var setupFailure: String?
    var permissionFailure: PermissionFailure?
    private(set) var config = OwnscribeConfig()

    // Quick-bar selections (per-run), seeded from config on load.
    var captureMic = false
    var model = "base"
    var language = "auto"        // "auto" or a language code
    var template = "meeting"
    var speakerCount = 0          // 0 = auto-detect
    /// Optional name for this meeting; becomes the output folder name.
    var meetingTitle = ""

    let availableModels = ["tiny", "base", "small", "medium", "large-v3"]
    let availableLanguages: [(label: String, code: String)] = [
        ("Auto", "auto"), ("German", "de"), ("English", "en"),
        ("French", "fr"), ("Spanish", "es"),
    ]
    let availableTemplates = ["meeting", "lecture", "brief"]

    let cli = OwnscribeCLI()
    /// Called after every successful config load: at setup, and after a Settings
    /// change, which may have moved the output folder.
    @ObservationIgnored var onConfigLoaded: (() -> Void)?
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var configWrite: Task<Void, Never> = Task {}
    @ObservationIgnored private var pendingCheck: Timer?

    init() {
        isInstalling = !cli.isInstalled
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.upgradeIfPending() }
        }
    }

    /// Running on an older CLI than this app expects: `show` and the transcript
    /// view may not exist there.
    var isDegraded: Bool { upgrade != .none }

    var diarizationEnabled: Bool { config.diarization.enabled }

    // Picker option lists that tolerate a configured value outside the presets.
    var modelOptions: [String] {
        availableModels.contains(model) ? availableModels : availableModels + [model]
    }

    var languageOptions: [(label: String, code: String)] {
        if availableLanguages.contains(where: { $0.code == language }) { return availableLanguages }
        return availableLanguages + [(language, language)]
    }

    var templateOptions: [String] {
        availableTemplates.contains(template) ? availableTemplates : availableTemplates + [template]
    }

    // MARK: Lifecycle

    func bootstrap() async {
        if didBootstrap { return }
        didBootstrap = true
        guard cli.isInstalled else { await install(); return }
        // A newer app bundle expects a newer CLI. Without this the managed venv
        // stayed on whatever it first installed, so every Python-side fix shipped
        // in a new .app silently never reached the user.
        if cli.needsUpgrade {
            await upgradeWhenIdle()
            if isDegraded { await reloadConfig(seedQuickBar: true) }
            return
        }
        await reloadConfig(seedQuickBar: true)
    }

    /// First-run setup, and the upgrade path when the app expects a newer CLI.
    func install() async {
        let hadCLI = cli.isInstalled
        isInstalling = true
        let result = await cli.install()
        guard result.ok, cli.isInstalled else {
            isInstalling = false
            let reason = FailureText.firstMeaningfulLine(result.stderr) ?? "Install failed — is `uv` installed?"
            if hadCLI && cli.isInstalled {
                // The old CLI still runs, so keep recording on it rather than stopping.
                setUpgrade(.failed(reason))
                await reloadConfig(seedQuickBar: true)
            } else {
                setupFailure = "Couldn't set up ownscribe.\n" + reason
            }
            return
        }
        setUpgrade(.none)
        await reloadConfig(seedQuickBar: true)
        isInstalling = false
    }

    /// Retry a failed upgrade, or try a pending one now.
    func retryUpgrade() {
        Task { await upgradeWhenIdle() }
    }

    /// Called when a job ends, on activation and every minute while waiting.
    func upgradeIfPending() {
        guard upgrade == .pending else { return }
        Task { await upgradeWhenIdle() }
    }

    /// Upgrade unless something still runs from the environment. That includes a
    /// job an earlier app session left running, which the app never launched.
    private func upgradeWhenIdle() async {
        guard cli.isInstalled, cli.needsUpgrade, !isInstalling else { return }
        if await environmentInUse() {
            setUpgrade(.pending)
            return
        }
        await install()
    }

    private func environmentInUse() async -> Bool {
        let ps = await CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"), args: ["-axww", "-o", "args="], cwd: nil
        )
        // If ps cannot run, nothing is known to be safe: wait.
        guard ps.ok else { return true }
        return VenvProcesses.anyUsing(script: cli.scriptPath, psOutput: ps.stdout)
    }

    private func setUpgrade(_ state: Upgrade) {
        upgrade = state
        pendingCheck?.invalidate()
        pendingCheck = nil
        if state == .pending {
            pendingCheck = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.upgradeIfPending() }
            }
        }
    }

    func reloadConfig(seedQuickBar seed: Bool = false) async {
        do {
            config = try await cli.loadConfig()
            if seed { seedQuickBarFromConfig() }
            isInstalling = false
            onConfigLoaded?()
        } catch {
            setupFailure = "Couldn't read ownscribe config: \(error)"
        }
    }

    private func seedQuickBarFromConfig() {
        captureMic = config.audio.mic
        model = config.transcription.model
        language = config.transcription.language.isEmpty ? "auto" : config.transcription.language
        template = config.summarization.template.isEmpty ? "meeting" : config.summarization.template
        // The quick bar only models an exact count; show Auto for a real range.
        speakerCount = config.diarization.minSpeakers == config.diarization.maxSpeakers
            ? config.diarization.minSpeakers : 0
    }

    /// CLI flags for one recording, from the quick bar. Consumes the meeting title:
    /// keeping it would silently name the next meeting the same and force a
    /// collision suffix.
    func takeRecordingFlags() -> [String] {
        var flags: [String] = [captureMic ? "--mic" : "--no-mic"]
        flags += ["--model", model]
        // Always send language so the quick bar is authoritative: "" forces
        // auto-detect even when config has a default language.
        flags += ["--language", language == "auto" ? "" : language]
        flags += ["--template", template]
        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { flags += ["--title", title] }
        // Honour the user's Settings value. This used to be forced to 0 because an
        // auto-stop would leave the UI showing "Recording" for the rest of the run —
        // the app had no way to see capture end. It now watches for the CLI's
        // recording_stopped event, so the preference can be respected.
        flags += ["--silence-timeout", String(config.audio.silenceTimeout)]
        if diarizationEnabled && speakerCount > 0 {
            flags += ["--speakers", String(speakerCount)]
        }
        meetingTitle = ""
        return flags
    }

    // MARK: Settings

    /// Persist a single config value, then reload. Writes are serialized so two
    /// rapid edits (e.g. a held Stepper) can't race tomlkit and corrupt the file.
    func updateConfig(_ key: String, _ value: String) {
        let previous = configWrite
        configWrite = Task { [weak self] in
            _ = await previous.value
            guard let self else { return }
            let result = await self.cli.setConfig(key, value)
            if result.ok { await self.reloadConfig() }
        }
    }
}
