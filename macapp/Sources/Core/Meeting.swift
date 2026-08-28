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

    /// Folder name -> display title, for both layouts:
    ///   `260609-q2-sales-review`          -> `Q2 Sales Review`   (current)
    ///   `260609-standup_1630`             -> `Standup`           (collision suffix)
    ///   `260609-budget-2026`              -> `Budget 2026`       (title ending in digits)
    ///   `260609-1053`                     -> `260609-1053`       (untitled)
    ///   `2026-06-09_1053_q2-sales-review` -> `Q2 Sales Review`   (pre-YYMMDD, still on disk)
    static func prettyTitle(_ name: String) -> String {
        // Legacy: date_time_slug (three underscore-separated parts).
        let underscored = name.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        if underscored.count == 3, !underscored[2].isEmpty {
            return underscored[2].replacingOccurrences(of: "-", with: " ").capitalized
        }

        // Current: YYMMDD-<slug>, with an optional _HHMM collision suffix. A slug never
        // contains "_" (slugify strips it), so the suffix is unambiguous — unlike a
        // trailing "-1630", which "Budget 2026" would also produce.
        var body = name
        if let sep = body.lastIndex(of: "_") {
            let suffix = body[body.index(after: sep)...]
            if suffix.count == 4, suffix.allSatisfy(\.isNumber) {
                body = String(body[body.startIndex..<sep])
            }
        }

        var parts = body.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0].count == 6, parts[0].allSatisfy(\.isNumber) else {
            return name
        }
        parts.removeFirst()
        // Untitled run: the remainder is just HHMM, so there is no title to show.
        // `260609-2026` is genuinely ambiguous — an untitled run at 20:26 and a meeting
        // titled "2026" produce the same name — and untitled runs are far more common,
        // so it is read as a timestamp.
        if parts.count == 1, parts[0].count == 4, parts[0].allSatisfy(\.isNumber) {
            return name
        }
        return parts.joined(separator: " ").capitalized
    }
}
