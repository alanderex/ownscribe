import Foundation

/// A processed meeting on disk (a folder under the output directory).
struct Meeting: Identifiable, Hashable {
    let id: String          // directory name (unique)
    let url: URL            // the meeting folder
    let title: String       // human title derived from the folder name
    let date: Date
    let summaryURL: URL?
    let transcriptURL: URL?

    var hasSummary: Bool { summaryURL != nil }
}

enum MeetingLoader {
    /// Expand the configured output directory (handles a leading `~`).
    static func outputDir(_ config: OwnscribeConfig) -> URL {
        URL(fileURLWithPath: NSString(string: config.output.dir).expandingTildeInPath)
    }

    /// All meeting folders under `dir`, newest first.
    static func load(from dir: URL) -> [Meeting] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var meetings: [Meeting] = []
        for url in entries {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true else { continue }
            if let meeting = meeting(at: url, modified: values?.contentModificationDate) {
                meetings.append(meeting)
            }
        }
        return meetings.sorted { $0.date > $1.date }
    }

    /// The newest meeting folder under `dir`, or nil. Used to resolve the folder
    /// a just-finished pipeline produced (its name may include a generated slug).
    static func mostRecent(in dir: URL) -> Meeting? {
        load(from: dir).first
    }

    /// Build a `Meeting` from a folder, or nil if it holds no transcript/summary.
    static func meeting(at dir: URL, modified: Date? = nil) -> Meeting? {
        let fm = FileManager.default
        func firstExisting(_ names: [String]) -> URL? {
            for name in names {
                let candidate = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
            return nil
        }
        let summary = firstExisting(["summary.md", "summary.json"])
        let transcript = firstExisting(["transcript.md", "transcript.json"])
        guard summary != nil || transcript != nil else { return nil }

        let date = modified
            ?? (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? Date.distantPast
        return Meeting(
            id: dir.lastPathComponent,
            url: dir,
            title: prettyTitle(dir.lastPathComponent),
            date: date,
            summaryURL: summary,
            transcriptURL: transcript
        )
    }

    /// `2026-06-09_1053_q2-sales-review` -> `Q2 Sales Review`.
    static func prettyTitle(_ name: String) -> String {
        let parts = name.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count == 3, !parts[2].isEmpty {
            return parts[2].replacingOccurrences(of: "-", with: " ").capitalized
        }
        return name
    }
}
