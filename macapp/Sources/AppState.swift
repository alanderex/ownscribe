import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case installing
        case idle
        case recording
        case processing
        case done
        case failed(String)
    }

    /// One row of the pipeline checklist, mirroring the CLI's own steps. Populated
    /// from the "steps" event so the UI never has to know the pipeline's shape.
    struct PipelineStep: Identifiable, Equatable {
        enum State: Equatable { case pending, running, done, failed }

        let key: String
        let label: String
        let indent: Int
        var state: State = .pending
        /// 0...1 when the step reports determinate progress; nil = indeterminate.
        var fraction: Double?
        var detail: String?

        var id: String { key }
    }

    // MARK: Published state
    @Published var phase: Phase = .idle
    @Published var elapsed: TimeInterval = 0
    /// Live pipeline checklist, driven by the CLI's progress events.
    @Published var steps: [PipelineStep] = []
    @Published var activeStepKey: String?
    /// True when the last recording ended by silence auto-stop rather than Stop.
    @Published var autoStopped = false
    @Published var config = OwnscribeConfig()

    // Quick-bar selections (per-run), seeded from config on load.
    @Published var captureMic = false
    @Published var model = "base"
    @Published var language = "auto"        // "auto" or a language code
    @Published var template = "meeting"
    @Published var speakerCount = 0          // 0 = auto-detect
    /// Optional name for this meeting; becomes the output folder name.
    @Published var meetingTitle = ""

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

    init() {
        cli = OwnscribeCLI()
        if !cli.isInstalled { phase = .installing }

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
        case .installing: return "arrow.down.circle"
        case .failed: return "exclamationmark.circle"
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
        guard cli.isInstalled else { await install(); return }
        await reloadConfig(seedQuickBar: true)
        refreshRecents()
    }

    /// First-run: install the managed ownscribe environment with uv, then load config.
    func install() async {
        phase = .installing
        let result = await cli.install()
        guard result.ok, cli.isInstalled else {
            phase = .failed("Couldn't set up ownscribe.\n"
                + (Self.firstMeaningfulLine(result.stderr) ?? "Install failed — is `uv` installed?"))
            return
        }
        await reloadConfig(seedQuickBar: true)
        refreshRecents()
        if phase == .installing { phase = .idle }
    }

    func reloadConfig(seedQuickBar seed: Bool = false) async {
        do {
            config = try await cli.loadConfig()
            if seed { seedQuickBarFromConfig() }
            if phase == .installing { phase = .idle }
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

    // MARK: Recording

    private func pipelineFlags() -> [String] {
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
        return flags
    }

    func startRecording() {
        guard cli.isInstalled else { Task { await install() }; return }
        cancelled = false
        Task {
            await Permissions.prime(mic: captureMic)
            beginRecording()
        }
    }

    private func beginRecording() {
        // Read the flags before clearing per-run state below — pipelineFlags()
        // consumes meetingTitle.
        let flags = pipelineFlags()

        phase = .recording
        elapsed = 0
        startDate = Date()
        summaryText = ""
        currentMeeting = nil
        detectedSpeakers = []
        speakersNamed = false
        steps = []
        activeStepKey = nil
        autoStopped = false
        // Consumed by this run: keeping it would silently name the next meeting
        // the same and force a collision suffix.
        meetingTitle = ""

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        running = cli.launchPipeline(
            flags: flags,
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handleProgressEvent(event) }
            }
        ) { [weak self] result in
            Task { @MainActor in self?.handlePipelineExit(result) }
        }
    }

    /// Fold one NDJSON progress event from the CLI into the UI state.
    /// Events arrive off the main thread and are hopped onto the main actor by the
    /// caller, so this runs isolated.
    private func handleProgressEvent(_ event: ProgressEvent) {
        switch event.event {
        case "recording_stopped":
            // Capture is over and transcription is starting. Reaching this without the
            // user pressing Stop means silence auto-stop fired — which the app used to
            // make impossible by forcing --silence-timeout 0, because without this
            // event it could not tell "still recording" from "transcribing".
            guard phase == .recording else { return }
            phase = .processing
            timer?.invalidate(); timer = nil
            autoStopped = event.reason == "silence_timeout"

        case "steps":
            steps = (event.steps ?? []).map {
                PipelineStep(key: $0.key, label: $0.label, indent: $0.indent)
            }

        case "begin":
            activeStepKey = event.key
            updateStep(event.key) { $0.state = .running; $0.fraction = nil; $0.detail = nil }

        case "progress":
            updateStep(event.key) { $0.fraction = event.fraction }

        case "detail":
            updateStep(event.key) { $0.detail = event.text }

        case "complete":
            updateStep(event.key) { $0.state = .done; $0.fraction = nil; $0.detail = nil }

        case "failed":
            updateStep(event.key) { $0.state = .failed; $0.fraction = nil }

        default:
            break  // forward-compatible: unknown events from a newer CLI are ignored
        }
    }

    private func updateStep(_ key: String?, _ mutate: (inout PipelineStep) -> Void) {
        guard let key, let idx = steps.firstIndex(where: { $0.key == key }) else { return }
        mutate(&steps[idx])
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

    /// Pick the line most likely to explain a failure out of captured stderr.
    ///
    /// Progress events share stderr with diagnostics, so they must be dropped here or
    /// the user is shown `{"ownscribe_progress":1,...}` instead of the error — the
    /// first line of a failing run is now always an event.
    ///
    /// For a Python traceback the useful line is the last one (the exception), not the
    /// first (`Traceback (most recent call last):`), so that case is handled explicitly.
    static func firstMeaningfulLine(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isProgressEventLine($0) }

        guard !lines.isEmpty else { return nil }
        if lines.contains(where: { $0.hasPrefix("Traceback (most recent call last)") }) {
            // The exception type and message are on the final line of a traceback.
            return lines.last
        }
        return lines.first
    }

    /// Cheap discriminator check — avoids a full JSON decode per stderr line.
    private static func isProgressEventLine(_ line: String) -> Bool {
        line.hasPrefix("{") && line.contains("\"ownscribe_progress\"")
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
