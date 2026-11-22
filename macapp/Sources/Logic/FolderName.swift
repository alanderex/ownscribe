import Foundation

/// What a meeting folder's name says about the meeting.
///
/// The CLI's `folder_title` (src/ownscribe/show.py) applies the same rules and
/// both are tested against the same cases. The app needs its own copy for when
/// it runs an older CLI that has no `show`.
enum FolderName {
    /// Folder name -> display title, for both layouts:
    ///   `260609-q2-sales-review`          -> `Q2 Sales Review`   (current)
    ///   `260609-standup_1630`             -> `Standup`           (collision suffix)
    ///   `260609-budget-2026`              -> `Budget 2026`       (title ending in digits)
    ///   `260609-1053`                     -> `260609-1053`       (untitled)
    ///   `2026-06-09_1053_q2-sales-review` -> `Q2 Sales Review`   (pre-YYMMDD, still on disk)
    static func title(_ name: String) -> String {
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
            if suffix.count == 4, suffix.allSatisfy(\.isASCIIDigit) {
                body = String(body[body.startIndex..<sep])
            }
        }

        var parts = body.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0].count == 6, parts[0].allSatisfy(\.isASCIIDigit) else {
            return name
        }
        parts.removeFirst()
        // Untitled run: the remainder is just a time — HHMM, or HHMMSS when a second
        // run claimed the same minute. Without the 6-digit case the raw digits showed
        // up as the meeting's title in Recents.
        //
        // `260609-2026` is genuinely ambiguous — an untitled run at 20:26 and a meeting
        // titled "2026" produce the same name — and untitled runs are far more common,
        // so it is read as a timestamp.
        if parts.count == 1, parts[0].count == 4 || parts[0].count == 6,
           parts[0].allSatisfy(\.isASCIIDigit) {
            return name
        }
        return parts.joined(separator: " ").capitalized
    }
}

extension Character {
    /// 0-9 only. `isNumber` also accepts other scripts' digits and fractions,
    /// which the CLI never writes into a folder name.
    var isASCIIDigit: Bool { isASCII && isWholeNumber }
}
