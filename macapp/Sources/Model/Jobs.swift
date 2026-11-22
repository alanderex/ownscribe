import AppKit
import Foundation
import Observation

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

/// The ownscribe process for a meeting and what it reports: its steps, how it
/// ended, and the meeting it produced.
@MainActor
@Observable
final class Jobs {
    enum State: Equatable {
        case idle
        case running
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Live pipeline checklist, driven by the CLI's progress events.
    private(set) var steps: [PipelineStep] = []
    private(set) var activeStepKey: String?
    /// True when the last recording ended by silence auto-stop rather than Stop.
    private(set) var autoStopped = false
    /// The meeting folder the running process writes, from recording_started. The
    /// library leaves it out until the run is over.
    private(set) var ownedFolder: String?
    /// The last run that finished, and where its meeting ended up.
    private(set) var lastFinished: FinishedRun?
    /// The meeting whose summary run failed, while that failure is shown: the
    /// meeting says why, not only the sidebar.
    private(set) var failedFolder: String?

    struct FinishedRun: Equatable {
        let run: Int
        let folder: String
    }

    /// Called when the run stops capturing audio: recording_stopped, an exit, or Cancel.
    @ObservationIgnored var onCaptureEnded: (() -> Void)?
    /// Called when the process is gone: it exited or was cancelled.
    @ObservationIgnored var onRunEnded: (() -> Void)?

    private let engine: Engine
    private let library: Library
    @ObservationIgnored private var running: RunningProcess?
    /// Identifies the current pipeline launch. A single `cancelled` Bool could not
    /// distinguish a stale callback from the live run: cancel set it, then a new
    /// recording cleared it, and the SIGTERM'd process's onExit — still in
    /// flight — was then applied to the *new* recording, invalidating its timer,
    /// dropping its process handle (so Stop could no longer signal it) and flipping
    /// the app to failed while capture continued headless.
    @ObservationIgnored private var runToken = 0
    /// What the current run is, for how it ends.
    @ObservationIgnored private var kind: Kind = .recording

    private enum Kind {
        /// Record, transcribe, summarize: a new meeting the user has not seen.
        case recording
        /// Write an existing meeting's summary again; the user is looking at it.
        case resummarizing
    }

    init(engine: Engine, library: Library) {
        self.engine = engine
        self.library = library

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

    var isRunning: Bool { state == .running }

    /// Start the record → transcribe → summarize process.
    func launchRecording(flags: [String]) {
        launch(arguments: flags, kind: .recording, folder: nil)
    }

    /// Write a meeting's summary (again) from its transcript with the template, model
    /// and instructions in `request` (`resume DIR --resummarize`). The folder counts as
    /// owned until it is done.
    func resummarize(folder: String, request: SummaryRequest) {
        guard state != .running else { return }
        launch(arguments: request.resumeArguments(folder: folder), kind: .resummarizing, folder: folder)
    }

    private func launch(arguments: [String], kind: Kind, folder: String?) {
        steps = []
        activeStepKey = nil
        autoStopped = false
        ownedFolder = folder
        failedFolder = nil
        self.kind = kind
        state = .running
        runToken &+= 1
        let token = runToken
        running = engine.cli.launchPipeline(
            flags: arguments,
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handleProgressEvent(token, event) }
            }
        ) { [weak self] result in
            Task { @MainActor in self?.handleExit(token, result) }
        }
    }

    /// SIGINT: stop recording, then let the process transcribe and summarize.
    func interrupt() {
        running?.interrupt()
    }

    /// Abort an in-flight transcription/summarization (recording already ended,
    /// so no audio devices are held).
    func cancel() {
        guard state == .running else { return }
        // Retire this launch: any onExit still in flight for it becomes a no-op.
        runToken &+= 1
        running?.terminate()
        running = nil
        ownedFolder = nil
        state = .idle
        onCaptureEnded?()
        onRunEnded?()
    }

    func dismissFailure() {
        if case .failed = state { state = .idle }
        failedFolder = nil
    }

    /// Fold one NDJSON progress event from the CLI into the UI state.
    /// Events arrive off the main thread and are hopped onto the main actor by the
    /// caller, so this runs isolated.
    private func handleProgressEvent(_ token: Int, _ event: ProgressEvent) {
        guard token == runToken else { return }
        switch event.event {
        case "recording_started":
            ownedFolder = event.folder

        case "recording_stopped":
            // Capture is over and transcription is starting. Reaching this without the
            // user pressing Stop means silence auto-stop fired — which the app used to
            // make impossible by forcing --silence-timeout 0, because without this
            // event it could not tell "still recording" from "transcribing".
            autoStopped = event.reason == "silence_timeout"
            onCaptureEnded?()

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

    private func handleExit(_ token: Int, _ result: CommandResult) {
        // Ignore a callback from a launch that has been cancelled or superseded;
        // acting on it would tear down whatever is running now.
        guard token == runToken else { return }
        running = nil
        let folder = ownedFolder
        ownedFolder = nil
        onCaptureEnded?()
        defer { onRunEnded?() }

        guard result.ok else {
            let what = kind == .recording ? "Recording" : "Summarizing"
            state = .failed(FailureText.firstMeaningfulLine(result.stderr)
                ?? "\(what) failed (exit \(result.exitCode)).")
            if kind == .resummarizing { failedFolder = folder }
            return
        }
        // The user asked for this summary on the meeting in front of them: no badge,
        // no change of selection, only the new summary.
        guard kind == .recording else {
            state = .idle
            library.refresh()
            return
        }

        // meeting_saved names the folder after any title rename. A CLI too old to
        // send it leaves only a guess: the newest folder in the output directory.
        let meeting: Meeting?
        if let folder = ProgressEvent.lastMeetingSaved(in: result.stderr)?.folder {
            meeting = MeetingLoader.meeting(at: URL(fileURLWithPath: folder))
        } else {
            meeting = MeetingLoader.mostRecent(in: MeetingLoader.outputDir(engine.config))
        }
        guard let meeting else {
            state = .failed("Finished, but no meeting folder was found in \(engine.config.output.dir).")
            return
        }
        state = .idle
        library.markUnseen(meeting.url.path)
        lastFinished = FinishedRun(run: token, folder: meeting.url.path)
        library.refresh()
    }
}
