import Foundation
import Observation

/// Capture: starting a recording, its elapsed time, and Stop.
///
/// The recording runs inside the meeting's ownscribe process, which Jobs owns;
/// this object is the part of that run the recorder controls show.
@MainActor
@Observable
final class Recorder {
    enum Phase: Equatable {
        case idle
        case recording
        /// Stop was pressed; the helper is merging the tracks, which can take up to
        /// 30 s, until the CLI reports recording_stopped.
        case finalizing
    }

    private(set) var phase: Phase = .idle
    /// Read only by leaf views: it changes every second.
    private(set) var elapsed: TimeInterval = 0

    private let engine: Engine
    private let jobs: Jobs
    private let library: Library
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startDate: Date?

    init(engine: Engine, jobs: Jobs, library: Library) {
        self.engine = engine
        self.jobs = jobs
        self.library = library
        jobs.onCaptureEnded = { [weak self] in self?.captureEnded() }
    }

    var isRecording: Bool { phase == .recording }

    func start() {
        guard engine.cli.isInstalled else { Task { await engine.install() }; return }
        Task {
            // Refuse to start without Screen Recording rather than recording silence:
            // ScreenCaptureKit fails with -3801 and the user finds out minutes later
            // via an empty transcript. The first request also always returns false —
            // macOS only applies a fresh grant after a relaunch — so say so plainly.
            let grants = await Permissions.prime(mic: engine.captureMic)
            guard grants.screenRecording else {
                engine.permissionFailure = .screenRecording
                return
            }
            // Same reasoning as Screen Recording: starting anyway produces a meeting
            // with a silent or missing mic track, discovered only afterwards.
            guard grants.microphone else {
                engine.permissionFailure = .microphone
                return
            }
            begin()
        }
    }

    private func begin() {
        let flags = engine.takeRecordingFlags()
        library.closeMeeting()
        phase = .recording
        elapsed = 0
        startDate = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        jobs.launchRecording(flags: flags)
    }

    func stop() {
        guard phase == .recording else { return }
        phase = .finalizing
        timer?.invalidate()
        timer = nil
        jobs.interrupt()   // SIGINT → stop recording, continue pipeline
    }

    private func captureEnded() {
        phase = .idle
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let startDate else { return }
        elapsed = Date().timeIntervalSince(startDate)
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
