import AppKit
import Foundation
import Observation

/// Meetings on disk: every folder as `show --list` describes it, the popover's
/// recent list, and the meeting the popover is showing, with its summary text and
/// speaker labels.
@MainActor
@Observable
final class Library {
    /// Every meeting folder, from `ownscribe show --list --json`.
    private(set) var rows: [LibraryRow] = []
    /// Why the last listing failed, while it keeps failing.
    private(set) var listFailure: String?
    /// Summary text by folder path, for the search field.
    private(set) var summaries: [String: String] = [:]
    /// True while `show --list` runs.
    private(set) var isListing = false
    /// Meetings that finished but have not been opened yet, by folder path.
    private(set) var unseen: Set<String> = []
    let calendar = LibraryCalendar()

    private(set) var recentMeetings: [Meeting] = []
    private(set) var currentMeeting: Meeting?
    private(set) var summaryText = ""
    private(set) var detectedSpeakers: [String] = []
    var speakersNamed = false

    private let engine: Engine
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var listAgain = false

    init(engine: Engine) {
        self.engine = engine
        // Folders can change while the app is in the background (Finder, a terminal
        // run); look again whenever the user comes back.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Reload everything listed from disk.
    func refresh() {
        refreshRecents()
        listRows()
        watchOutputFolder()
    }

    /// One `show --list` at a time; a request that arrives meanwhile runs once
    /// the current one is done, so a burst of changes costs at most two runs.
    private func listRows() {
        guard engine.cli.isInstalled else { return }
        if isListing { listAgain = true; return }
        isListing = true
        Task {
            let result = await engine.cli.run(["show", "--list", "--json"])
            if result.ok {
                let data = Data(result.stdout.utf8)
                do {
                    rows = try await Task.detached { try LibraryListing.decode(data) }.value
                    listFailure = nil
                    await indexSummaries()
                } catch {
                    listFailure = "Couldn't read the meeting list: \(error)"
                }
            } else {
                listFailure = FailureText.firstMeaningfulLine(result.stderr)
                    ?? "Listing meetings failed (exit \(result.exitCode))."
            }
            isListing = false
            if listAgain {
                listAgain = false
                listRows()
            }
        }
    }

    /// Read every summary off the main actor so search never touches the disk.
    private func indexSummaries() async {
        let folders = rows.filter(\.status.hasSummary).map(\.url)
        summaries = await Task.detached {
            var index: [String: String] = [:]
            for folder in folders {
                if let text = SummaryFile.text(inFolder: folder) { index[folder.path] = text }
            }
            return index
        }.value
    }

    private func watchOutputFolder() {
        let folder = MeetingLoader.outputDir(engine.config)
        guard watcher?.url != folder else { return }
        watcher = DirectoryWatcher(url: folder) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func show(_ meeting: Meeting) {
        currentMeeting = meeting
        detectedSpeakers = []
        speakersNamed = false
        summaryText = ""

        let summaryURL = meeting.summaryURL
        let transcriptURL = meeting.transcriptURL
        Task {
            summaryText = await Self.readMeetingText(summaryURL: summaryURL, transcriptURL: transcriptURL)
        }
        if engine.config.diarization.enabled, let transcript = transcriptURL {
            Task { detectedSpeakers = await engine.cli.listSpeakers(transcript) }
        }
    }

    func markUnseen(_ path: String) {
        unseen.insert(path)
    }

    /// The meeting was opened, in the window or the menu.
    func markSeen(_ path: String) {
        unseen.remove(path)
    }

    func closeMeeting() {
        currentMeeting = nil
        summaryText = ""
        detectedSpeakers = []
        speakersNamed = false
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

    func applySpeakerNames(_ mapping: [String: String]) {
        guard let transcript = currentMeeting?.transcriptURL else { return }
        let cleaned = mapping.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !cleaned.isEmpty else { speakersNamed = true; return }
        Task {
            _ = await engine.cli.renameSpeakers(transcript, mapping: cleaned)
            detectedSpeakers = await engine.cli.listSpeakers(transcript)
            speakersNamed = true
        }
    }

    func refreshRecents() {
        recentMeetings = Array(MeetingLoader.load(from: MeetingLoader.outputDir(engine.config)).prefix(8))
    }

    func revealInFinder(_ meeting: Meeting) {
        NSWorkspace.shared.activateFileViewerSelecting([meeting.url])
    }

    func revealInFinder(_ row: LibraryRow) {
        NSWorkspace.shared.activateFileViewerSelecting([row.url])
    }

    /// Copies the summary's text (summary.json's value, not its JSON).
    func copySummary(of row: LibraryRow) {
        let folder = row.url
        Task {
            guard let text = await Task.detached(operation: { SummaryFile.text(inFolder: folder) }).value else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Moves the meeting folder to the Trash, where it can still be put back. A
    /// recording kept in a separate output.audio_dir stays where it is.
    func moveToTrash(_ row: LibraryRow) throws {
        try FileManager.default.trashItem(at: row.url, resultingItemURL: nil)
        rows.removeAll { $0.path == row.path }
        refresh()
    }

    func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summaryText, forType: .string)
    }
}
