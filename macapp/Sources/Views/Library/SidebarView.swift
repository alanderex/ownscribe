import SwiftUI

struct SidebarView: View {
    @Environment(Library.self) private var library
    @Environment(Recorder.self) private var recorder
    @Environment(Jobs.self) private var jobs
    @Binding var selection: SidebarItem?
    let query: String
    @State private var trashFailure: String?
    /// The tags the Library is filtered by, one per line (see LibraryTagFilter).
    @SceneStorage("libraryTagFilter") private var storedTagFilter = ""
    @AppStorage("sidebar.tagsExpanded") private var tagsExpanded = true

    var body: some View {
        List(selection: $selection) {
            if hasActiveRun {
                Section("In progress") {
                    ActiveRunRow()
                        .tag(SidebarItem.activeRun)
                }
            }
            if !library.tags.isEmpty {
                Section(isExpanded: $tagsExpanded) {
                    ForEach(library.tags) { tag in
                        // A button, not a selectable row: picking a tag never changes
                        // which meeting is open.
                        TagFilterRow(tag: tag, isSelected: activeTags.contains(tag.name)) {
                            toggle(tag.name)
                        }
                    }
                } header: {
                    HStack {
                        Text("Tags")
                        Spacer()
                        if !activeTags.isEmpty {
                            Button("Clear") { selectedTags = [] }
                                .buttonStyle(.link)
                                .font(.caption)
                                .help("Show meetings with any tag or none")
                        }
                    }
                }
            }
            Section("Library") {
                if let failure = library.listFailure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if sections.isEmpty, let message = noMatchMessage {
                    Text(message)
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
        .onChange(of: library.tags) { _, tags in
            // A tag that no meeting has any more leaves the filter, so it is not
            // selected again should a tag of that name come back.
            let remaining = selectedTags.intersection(tags.map(\.name))
            if remaining != selectedTags { selectedTags = remaining }
        }
        .safeAreaInset(edge: .top) {
            DegradedBanner()
                .padding(.horizontal, 10)
        }
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
        let tags = activeTags
        let matching = library.rows.filter {
            LibraryTagFilter.matches($0, selected: tags)
                && LibrarySearch.matches($0, query: query, summary: library.summaries[$0.path])
        }
        return library.calendar.sections(matching, excluding: Set([jobs.ownedFolder].compactMap { $0 }))
    }

    private var selectedTags: Set<String> {
        get { LibraryTagFilter.decode(storedTagFilter) }
        nonmutating set { storedTagFilter = LibraryTagFilter.encode(newValue) }
    }

    /// The selected tags the library still has. A stored selection never hides
    /// meetings behind a tag that is gone, with no Tags section left to clear it.
    private var activeTags: Set<String> {
        selectedTags.intersection(library.tags.map(\.name))
    }

    private func toggle(_ tag: String) {
        var tags = activeTags
        if tags.remove(tag) == nil { tags.insert(tag) }
        selectedTags = tags
    }

    /// Why the Library is empty while a filter or search is on.
    private var noMatchMessage: String? {
        let tagged = activeTags.count == 1 ? "No meetings with this tag" : "No meetings with these tags"
        switch (activeTags.isEmpty, query.isEmpty) {
        case (true, true): return nil
        case (true, false): return "No titles or summaries match “\(query)”."
        case (false, true): return tagged + "."
        case (false, false): return tagged + " match “\(query)”."
        }
    }

    private var hasActiveRun: Bool {
        if recorder.phase != .idle || jobs.isRunning { return true }
        if case .failed = jobs.state { return true }
        return false
    }
}

/// A tag in the sidebar: picking it shows only meetings with it (or with any other
/// picked tag).
private struct TagFilterRow: View {
    let tag: LibraryTag
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                Text(tag.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(tag.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tag.name), \(tag.count == 1 ? "1 meeting" : "\(tag.count) meetings")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(isSelected ? "Stop showing only meetings tagged \(tag.name)" : "Show meetings tagged \(tag.name)")
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
