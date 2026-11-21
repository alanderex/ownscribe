import SwiftUI

struct SidebarView: View {
    @Environment(Library.self) private var library
    @Environment(Recorder.self) private var recorder
    @Environment(Jobs.self) private var jobs
    @Binding var selection: SidebarItem?
    let query: String
    @State private var trashFailure: String?

    var body: some View {
        List(selection: $selection) {
            if hasActiveRun {
                Section("In progress") {
                    ActiveRunRow()
                        .tag(SidebarItem.activeRun)
                }
            }
            Section("Library") {
                if sections.isEmpty && !query.isEmpty {
                    Text("No titles or summaries match “\(query)”.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sections) { section in
                    Text(DayTitle.text(for: section.day, calendar: library.calendar.calendar))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.rows) { row in
                        LibraryRowView(
                            row: row, time: library.calendar.time(of: row),
                            isNew: library.unseen.contains(row.path)
                        )
                        .tag(SidebarItem.meeting(row.path))
                            .contextMenu { menu(for: row) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .alert("Couldn't move to Trash", isPresented: Binding(
            get: { trashFailure != nil }, set: { if !$0 { trashFailure = nil } }
        )) {
            Button("OK") { trashFailure = nil }
        } message: {
            Text(trashFailure ?? "")
        }
    }

    @ViewBuilder
    private func menu(for row: LibraryRow) -> some View {
        Button("Reveal in Finder") { library.revealInFinder(row) }
        Button("Copy Summary") { library.copySummary(of: row) }
            .disabled(!row.status.hasSummary)
        Divider()
        Button("Move to Trash") {
            do {
                try library.moveToTrash(row)
                if selection == .meeting(row.path) { selection = nil }
            } catch {
                trashFailure = error.localizedDescription
            }
        }
    }

    private var sections: [DaySection] {
        let matching = library.rows.filter {
            LibrarySearch.matches($0, query: query, summary: library.summaries[$0.path])
        }
        return library.calendar.sections(matching, excluding: Set([jobs.ownedFolder].compactMap { $0 }))
    }

    private var hasActiveRun: Bool {
        if recorder.phase != .idle || jobs.isRunning { return true }
        if case .failed = jobs.state { return true }
        return false
    }
}

/// The single recording or job of Phase 1, with what it is doing now.
private struct ActiveRunRow: View {
    @Environment(Recorder.self) private var recorder
    @Environment(Jobs.self) private var jobs

    var body: some View {
        if recorder.isRecording {
            HStack {
                Label("Recording", systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                Spacer()
                ElapsedText(font: .caption)
                    .foregroundStyle(.secondary)
            }
        } else if recorder.phase == .finalizing {
            Label("Finalizing…", systemImage: "hourglass")
        } else if jobs.isRunning {
            VStack(alignment: .leading, spacing: 2) {
                Label("Processing", systemImage: "hourglass")
                if let label = activeStepLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var activeStepLabel: String? {
        jobs.steps.first { $0.key == jobs.activeStepKey }?.label
    }
}

struct LibraryRowView: View {
    let row: LibraryRow
    let time: Date?
    /// Finished since it was last opened.
    var isNew = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if isNew {
                Circle()
                    .fill(.tint)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .lineLimit(1)
                if !caption.isEmpty {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if row.speakerCount > 0 {
                Label("\(row.speakerCount)", systemImage: "person.2")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("\(row.speakerCount) speakers")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var caption: String {
        [time?.formatted(date: .omitted, time: .shortened), row.duration.map(ClockText.duration)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var accessibilityText: String {
        var parts = [row.title]
        if isNew { parts.append("new") }
        if let time { parts.append(time.formatted(date: .omitted, time: .shortened)) }
        if let duration = row.duration { parts.append(Duration.seconds(duration).formatted(.units(width: .wide))) }
        if row.speakerCount > 0 { parts.append("\(row.speakerCount) speakers") }
        return parts.joined(separator: ", ")
    }
}

enum DayTitle {
    /// "Today", "Yesterday", "Wednesday, 18 November", with the year when not this year.
    static func text(for day: Date, calendar: Calendar) -> String {
        if day == .distantPast { return "No date" }
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: Date())
        let style = Date.FormatStyle(date: .complete, time: .omitted)
        return sameYear ? day.formatted(.dateTime.weekday(.wide).day().month(.wide)) : day.formatted(style)
    }
}
