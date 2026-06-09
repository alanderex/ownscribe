import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case needsSetup
        case idle
        case recording
        case processing
        case done
        case failed(String)
    }

    // MARK: Published state
    @Published var phase: Phase = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var config = OwnscribeConfig()

    // Quick-bar selections (per-run), seeded from config on load.
    @Published var captureMic = false
    @Published var model = "base"
    @Published var language = "auto"        // "auto" or a language code
    @Published var template = "meeting"
    @Published var speakerCount = 0          // 0 = auto-detect

    // Results / naming
    @Published var currentMeeting: Meeting?
    @Published var summaryText = ""
    @Published var detectedSpeakers: [String] = []
    @Published var speakersNamed = false
    @Published var recentMeetings: [Meeting] = []

    let availableModels = ["tiny", "base", "small", "medium", "large-v3"]
    let availableLanguages: [(label: String, code: String)] = [
        ("Auto", "auto"), ("German", "de"), ("English", "en"),
        ("French", "fr"), ("Spanish", "es"),
    ]
    let availableTemplates = ["meeting", "lecture", "brief"]

    private(set) var cli: OwnscribeCLI
    private var running: RunningProcess?
    private var timer: Timer?
    private var startDate: Date?
    private var didBootstrap = false
    private var cancelled = false
    private var configWrite: Task<Void, Never> = Task {}

    private static let projectDirKey = "projectDirectory"

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.projectDirKey)
        let dir = stored.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: NSHomeDirectory())
        cli = OwnscribeCLI(projectDirectory: dir)
        if !cli.isConfigured { phase = .needsSetup }

        // Never let the spawned pipeline outlive the app: signal it on quit so
        // it stops recording (releasing the mic / CoreAudio tap) on the way out.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, so we're already on the main actor;
            // run synchronously so the child is signaled before the app exits.
            MainActor.assumeIsolated {
                self?.running?.interrupt()
            }
        }
    }

    var diarizationEnabled: Bool { config.diarization.enabled }

    var menuBarSymbol: String {
        switch phase {
        case .recording: return "record.circle.fill"
        case .processing: return "hourglass"
        case .needsSetup, .failed: return "exclamationmark.circle"
        default: return "waveform"
        }
    }

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
        guard cli.isConfigured else { phase = .needsSetup; return }
        await reloadConfig(seedQuickBar: true)
        refreshRecents()
    }

    func reloadConfig(seedQuickBar seed: Bool = false) async {
        do {
            config = try await cli.loadConfig()
            if seed { seedQuickBarFromConfig() }
            if phase == .needsSetup { phase = .idle }
        } catch {
            phase = .failed("Couldn't read ownscribe config: \(error)")
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

    func setProjectDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.projectDirKey)
        cli.projectDirectory = url
        Task {
            if cli.isConfigured {
                await reloadConfig(seedQuickBar: true)
                refreshRecents()
            } else {
                phase = .needsSetup
            }
        }
    }

    // MARK: Recording

    private func pipelineFlags() -> [String] {
        var flags: [String] = [captureMic ? "--mic" : "--no-mic"]
        flags += ["--model", model]
        // Always send language so the quick bar is authoritative: "" forces
        // auto-detect even when config has a default language.
        flags += ["--language", language == "auto" ? "" : language]
        flags += ["--template", template]
        // The GUI owns Stop; disable silence auto-stop so the pipeline can't
        // start transcribing while the UI still shows "Recording".
        flags += ["--silence-timeout", "0"]
        if diarizationEnabled && speakerCount > 0 {
            flags += ["--speakers", String(speakerCount)]
        }
        return flags
    }

    func startRecording() {
        guard cli.isConfigured else { phase = .needsSetup; return }
        cancelled = false
        Task {
            await Permissions.prime(mic: captureMic)
            beginRecording()
        }
    }

    private func beginRecording() {
        phase = .recording
        elapsed = 0
        startDate = Date()
        summaryText = ""
        currentMeeting = nil
        detectedSpeakers = []
        speakersNamed = false

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        running = cli.launchPipeline(flags: pipelineFlags()) { [weak self] result in
            Task { @MainActor in self?.handlePipelineExit(result) }
        }
    }

    private func tick() {
        guard let startDate else { return }
        elapsed = Date().timeIntervalSince(startDate)
    }

    func stopRecording() {
        guard phase == .recording else { return }
        phase = .processing
        timer?.invalidate(); timer = nil
        running?.interrupt()   // SIGINT → stop recording, continue pipeline
    }

    /// Abort an in-flight transcription/summarization (recording already ended,
    /// so no audio devices are held).
    func cancelProcessing() {
        guard phase == .processing else { return }
        cancelled = true
        running?.terminate()
        running = nil
        timer?.invalidate(); timer = nil
        phase = .idle
    }

    private func handlePipelineExit(_ result: CommandResult) {
        timer?.invalidate(); timer = nil
        running = nil
        if cancelled { cancelled = false; return }

        guard result.ok else {
            phase = .failed(Self.firstMeaningfulLine(result.stderr)
                ?? "Recording failed (exit \(result.exitCode)).")
            return
        }

        // The pipeline may rename its folder with a generated slug, so resolve
        // the meeting by newest-folder rather than parsing a (possibly stale) path.
        guard let meeting = MeetingLoader.mostRecent(in: MeetingLoader.outputDir(config)) else {
            phase = .failed("Finished, but no meeting folder was found in \(config.output.dir).")
            return
        }
        showMeeting(meeting)
        phase = .done
        refreshRecents()
    }

    // MARK: Meetings & speakers

    func showMeeting(_ meeting: Meeting) {
        currentMeeting = meeting
        detectedSpeakers = []
        speakersNamed = false
        summaryText = ""

        let summaryURL = meeting.summaryURL
        let transcriptURL = meeting.transcriptURL
        Task {
            summaryText = await Self.readMeetingText(summaryURL: summaryURL, transcriptURL: transcriptURL)
        }
        if config.diarization.enabled, let transcript = transcriptURL {
            Task { detectedSpeakers = await cli.listSpeakers(transcript) }
        }
    }

    /// Read summary (or transcript fallback) off the main actor.
    private static func readMeetingText(summaryURL: URL?, transcriptURL: URL?) async -> String {
        await Task.detached {
            if let url = summaryURL, let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
            if let url = transcriptURL, let text = try? String(contentsOf: url, encoding: .utf8) {
                return "_(No summary — showing transcript.)_\n\n" + text
            }
            return "_(No summary or transcript found.)_"
        }.value
    }

    func open(_ meeting: Meeting) {
        showMeeting(meeting)
        phase = .done
    }

    func applySpeakerNames(_ mapping: [String: String]) {
        guard let transcript = currentMeeting?.transcriptURL else { return }
        let cleaned = mapping.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !cleaned.isEmpty else { speakersNamed = true; return }
        Task {
            _ = await cli.renameSpeakers(transcript, mapping: cleaned)
            detectedSpeakers = await cli.listSpeakers(transcript)
            speakersNamed = true
        }
    }

    func refreshRecents() {
        recentMeetings = Array(MeetingLoader.load(from: MeetingLoader.outputDir(config)).prefix(8))
    }

    func backToIdle() {
        phase = .idle
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

    // MARK: Helpers

    func revealInFinder(_ meeting: Meeting) {
        NSWorkspace.shared.activateFileViewerSelecting([meeting.url])
    }

    func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summaryText, forType: .string)
    }

    static func firstMeaningfulLine(_ text: String) -> String? {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
