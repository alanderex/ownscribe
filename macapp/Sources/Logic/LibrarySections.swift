import Foundation

/// Meetings of one day, newest first.
struct DaySection: Identifiable, Equatable {
    /// Start of the day; `Date.distantPast` for meetings with no date at all.
    let day: Date
    let rows: [LibraryRow]

    var id: Date { day }
}

/// How the Library orders, dates and filters rows.
///
/// The day comes from the folder name first. Creation time only stands in for a
/// name without a date, and orders rows within a day: copying a folder resets it,
/// and a titled folder has no time in its name.
struct LibraryCalendar {
    var calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Start of the meeting's day: the name day, else the creation day.
    func day(of row: LibraryRow) -> Date? {
        if let nameDay = row.nameDay, let day = parseDay(nameDay) { return day }
        return created(row).map { calendar.startOfDay(for: $0) }
    }

    func created(_ row: LibraryRow) -> Date? {
        guard let created = row.created else { return nil }
        return Self.isoParser.date(from: created)
    }

    /// The time to show for a row: its creation time, but only when that falls on
    /// the meeting's day. A copied folder was created later, and its time would lie.
    func time(of row: LibraryRow) -> Date? {
        guard let created = created(row), let day = day(of: row),
              calendar.isDate(created, inSameDayAs: day) else { return nil }
        return created
    }

    /// Meetings grouped by day, newest day first, newest first within a day.
    /// `excluding` holds folder paths a running job still owns.
    func sections(_ rows: [LibraryRow], excluding: Set<String> = []) -> [DaySection] {
        var byDay: [Date: [LibraryRow]] = [:]
        for row in rows where row.isMeeting && !excluding.contains(row.path) {
            byDay[day(of: row) ?? .distantPast, default: []].append(row)
        }
        return byDay.keys.sorted(by: >).map { day in
            DaySection(day: day, rows: byDay[day]!.sorted(by: newerFirst))
        }
    }

    private func newerFirst(_ a: LibraryRow, _ b: LibraryRow) -> Bool {
        switch (created(a), created(b)) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.path > b.path
        }
    }

    private func parseDay(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static let isoParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// The toolbar search: a case-insensitive substring of the title or the summary.
/// Transcript text is not searched.
enum LibrarySearch {
    static func matches(_ row: LibraryRow, query: String, summary: String?) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if row.title.localizedCaseInsensitiveContains(needle) { return true }
        return summary?.localizedCaseInsensitiveContains(needle) ?? false
    }
}
