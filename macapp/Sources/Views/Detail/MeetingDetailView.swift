import SwiftUI

/// One meeting: header and summary.
struct MeetingDetailView: View {
    @Environment(Library.self) private var library
    let row: LibraryRow
    @State private var summary: String?
    @State private var loadedPath: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MeetingHeader(row: row, day: library.calendar.day(of: row), time: library.calendar.time(of: row))
                Divider()
                summaryBody
            }
            // A readable measure: long lines at window width are hard to follow.
            .frame(maxWidth: 720, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .task(id: row) { await load() }
    }

    @ViewBuilder
    private var summaryBody: some View {
        if let summary {
            RenderedMarkdown(text: summary, style: .document)
                .textSelection(.enabled)
        } else if loadedPath == row.path {
            Text(missingSummaryText)
                .foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var missingSummaryText: String {
        switch row.status.summary {
        case "disabled": return "No summary: summarization is turned off in Settings."
        default: return "No summary for this meeting."
        }
    }

    private func load() async {
        let folder = row.url
        let text = await Task.detached { SummaryFile.text(inFolder: folder) }.value
        summary = text
        loadedPath = row.path
    }
}

struct MeetingHeader: View {
    let row: LibraryRow
    let day: Date?
    let time: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.title)
                .font(.largeTitle.weight(.semibold))
                .textSelection(.enabled)
            Text(facts)
                .foregroundStyle(.secondary)
        }
    }

    private var facts: String {
        var parts: [String] = []
        if let day, day != .distantPast {
            parts.append(time?.formatted(date: .abbreviated, time: .shortened)
                ?? day.formatted(date: .abbreviated, time: .omitted))
        }
        if let duration = row.duration { parts.append(ClockText.duration(duration)) }
        if row.speakerCount > 0 { parts.append(row.speakerCount == 1 ? "1 speaker" : "\(row.speakerCount) speakers") }
        return parts.joined(separator: " · ")
    }
}
