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

    private static let projectDirKey = "projectDirectory"

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.projectDirKey)
        let dir = stored.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: NSHomeDirectory())
        cli = OwnscribeCLI(projectDirectory: dir)
        if !cli.isConfigured { phase = .needsSetup }
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

    // MARK: Lifecycle

    func bootstrap() async {
        if didBootstrap { return }
        didBootstrap = true
        guard cli.isConfigured else { phase = .needsSetup; return }
        await reloadConfig()
        refreshRecents()
    }

    func reloadConfig() async {
        do {
            let cfg = try await cli.loadConfig()
            config = cfg
            captureMic = cfg.audio.mic
            model = cfg.transcription.model
            language = cfg.transcription.language.isEmpty ? "auto" : cfg.transcription.language
            template = cfg.summarization.template.isEmpty ? "meeting" : cfg.summarization.template
            speakerCount = cfg.diarization.minSpeakers
            if phase == .needsSetup { phase = .idle }
        } catch {
            phase = .failed("Couldn't read ownscribe config: \(error)")
        }
    }

    func setProjectDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.projectDirKey)
        cli.projectDirectory = url
        Task {
            if cli.isConfigured {
                await reloadConfig()
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
        if language != "auto" { flags += ["--language", language] }
        flags += ["--template", template]
        if diarizationEnabled && speakerCount > 0 {
            flags += ["--speakers", String(speakerCount)]
        }
        return flags
    }

    func startRecording() {
        guard cli.isConfigured else { phase = .needsSetup; return }
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

    private func handlePipelineExit(_ result: CommandResult) {
        timer?.invalidate(); timer = nil
        running = nil

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
        if let summaryURL = meeting.summaryURL,
           let text = try? String(contentsOf: summaryURL, encoding: .utf8) {
            summaryText = text
        } else if let transcriptURL = meeting.transcriptURL,
                  let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            summaryText = "_(No summary — showing transcript.)_\n\n" + text
        } else {
            summaryText = "_(No summary or transcript found.)_"
        }
        if config.diarization.enabled, let transcript = meeting.transcriptURL {
            Task { detectedSpeakers = await cli.listSpeakers(transcript) }
        }
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

    /// Persist a single config value, then reload so the UI reflects it.
    func updateConfig(_ key: String, _ value: String) {
        Task {
            let result = await cli.setConfig(key, value)
            if result.ok { await reloadConfig() }
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
