import AppKit
import Foundation
import Observation

/// Meetings on disk: every folder as `show --list` describes it, which of them
/// finished unopened, and their summaries for search.
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
            if engine.isDegraded {
                await listFoldersPlainly()
            } else {
                await listWithShow()
            }
            isListing = false
            if listAgain {
                listAgain = false
                listRows()
            }
        }
    }

    private func listWithShow() async {
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
    }

    /// On a CLI too old for `show`: the folders MeetingLoader finds, newest change
    /// first, with no duration, speakers or audio.
    private func listFoldersPlainly() async {
        let folder = MeetingLoader.outputDir(engine.config)
        let meetings = await Task.detached { MeetingLoader.load(from: folder) }.value
        rows = meetings.map(Self.plainRow)
        listFailure = nil
        await indexSummaries()
    }

    private static func plainRow(_ meeting: Meeting) -> LibraryRow {
        LibraryRow(
            path: meeting.url.path, nameDay: nil,
            created: ISO8601DateFormatter().string(from: meeting.date),
            title: meeting.title, duration: nil, speakerCount: 0,
            status: .init(
                transcript: meeting.transcriptURL == nil ? "missing" : "present",
                summary: meeting.summaryURL == nil ? "missing" : "present",
                audio: nil, orig: false
            )
        )
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

    func markUnseen(_ path: String) {
        unseen.insert(path)
    }

    /// The meeting was opened, in the window or the menu.
    func markSeen(_ path: String) {
        unseen.remove(path)
    }

    /// Names given to speakers anywhere in the library, offered when naming speakers.
    var knownSpeakerNames: [String] { LibraryRow.speakerNames(in: rows) }

    /// The newest meetings, for the menu.
    func recentRows(_ count: Int) -> [LibraryRow] {
        Array(calendar.sections(rows).lazy.flatMap(\.rows).prefix(count))
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
}
