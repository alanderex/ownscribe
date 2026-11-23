import AppKit
import SwiftUI

/// One meeting: header, then its summary or its transcript.
struct MeetingDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        var id: String { rawValue }
    }

    @Environment(Engine.self) private var engine
    @Environment(Library.self) private var library
    @Environment(Jobs.self) private var jobs
    @Environment(SpeakerEditor.self) private var editor
    let row: LibraryRow

    @State private var summary: String?
    @State private var document: MeetingDocument?
    @State private var documentFailure: String?
    @State private var loadedPath: String?
    /// nil until chosen: the summary when there is one, the transcript otherwise.
    @State private var chosenTab: Tab?
    @State private var player = TurnPlayer()
    @SceneStorage("speakerInspectorShown") private var inspectorShown = false
    /// The speaker picked in the inspector: their lines are highlighted.
    @State private var selectedSpeaker: String?
    @State private var isSaving = false
    @State private var saveProblem: String?
    /// Lines waiting for a name typed for "New Speaker…".
    @State private var newSpeakerLines: [Int]?
    @State private var newSpeakerName = ""
    @State private var showsSummarize = false

    var body: some View {
        // The header, the tags and the tab row stay in view; only the summary or the
        // transcript scrolls under them.
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    MeetingHeader(
                        row: row, language: document?.language,
                        day: library.calendar.day(of: row), time: library.calendar.time(of: row),
                        // An older CLI has no `title`.
                        titleEditable: !engine.isDegraded,
                        titleReadOnlyReason: isProcessing ? Library.titleBusyMessage : nil
                    )
                    // An older CLI has no tags.
                    if !engine.isDegraded {
                        MeetingTagsView(row: row, readOnlyReason: isProcessing ? Library.tagsBusyMessage : nil)
                    }
                }
                tabBar
                summaryFailure
            }
            .readingMeasure()
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch tab {
                        case .summary: summaryBody
                        case .transcript: transcriptBody
                        }
                    }
                    .readingMeasure()
                    .padding(28)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedSpeaker) { _, speaker in
                    guard let speaker, let turn = firstTurn(of: speaker) else { return }
                    chosenTab = .transcript
                    withAnimation { proxy.scrollTo(turn, anchor: .top) }
                }
            }
        }
        .inspector(isPresented: $inspectorShown) { inspector }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    inspectorShown.toggle()
                } label: {
                    Label("Speakers", systemImage: "person.2")
                }
                .help("Show or hide the speakers (⌥⌘I)")
            }
        }
        .focusedSceneValue(\.speakerInspectorShown, $inspectorShown)
        .task(id: row) {
            // Leaving a meeting saves its draft; a refusal keeps it for when the
            // meeting is opened again.
            let otherMeeting = loadedPath != row.path
            if otherMeeting, let previous = loadedPath {
                saveInBackground(previous)
            }
            player.stop()
            if otherMeeting {
                selectedSpeaker = nil
                saveProblem = nil
            }
            await load()
        }
        .onDisappear {
            player.stop()
            saveInBackground(row.path)
        }
        .onChange(of: jobs.ownedFolder) { previous, current in
            // A summary run on this meeting ended: show what it wrote. The row may look
            // the same before and after, so the reload cannot wait for it to change.
            if previous == row.path, current == nil {
                Task { await load() }
            }
        }
        .sheet(isPresented: $showsSummarize) {
            SummarizeSheet(
                meetingTitle: row.title, hasSummary: row.status.hasSummary,
                request: initialSummaryRequest
            ) { request in
                chosenTab = .summary
                jobs.resummarize(folder: row.path, request: request)
            }
        }
        .alert("New Speaker", isPresented: newSpeakerPrompt) {
            TextField("Name", text: $newSpeakerName)
            Button("Move") { moveToTypedSpeaker() }
            Button("Cancel", role: .cancel) { newSpeakerLines = nil }
        } message: {
            Text("The lines move to this speaker when the speaker edits are saved.")
        }
    }

    /// Whether speakers can be edited: never while a job works on the folder, and only
    /// with a CLI that numbers the transcript's lines.
    private var canEdit: Bool {
        guard let document, document.revision != nil, !engine.isDegraded else { return false }
        return readOnlyReason == nil
    }

    /// A process works on the meeting's folder: one of the app's jobs, or another
    /// process holding its lock. A folder whose lock state is unknown (a volume without
    /// lock support) does not count, so it stays editable.
    private var isProcessing: Bool {
        row.status.busy == .busy || jobs.ownedFolder == row.path
    }

    /// Why the speakers cannot be edited now.
    private var readOnlyReason: String? {
        if isProcessing {
            return "Processing… Speakers can be edited when this meeting is done."
        }
        if document?.revision == nil {
            return "Editing speakers needs the updated ownscribe engine."
        }
        return nil
    }

    @ViewBuilder
    private var inspector: some View {
        if let document, !engine.isDegraded, !document.turns.isEmpty {
            SpeakerInspector(
                document: document,
                draft: editor.draft(for: row.path, document: document),
                readOnlyReason: readOnlyReason,
                knownNames: library.knownSpeakerNames,
                selectedSpeaker: $selectedSpeaker,
                rename: { label, name in
                    editor.update(row.path, document: document) { $0.rename(label, to: name) }
                },
                save: { Task { await save() } },
                discard: {
                    editor.discard(row.path)
                    saveProblem = nil
                },
                isSaving: isSaving,
                problem: saveProblem,
                restore: document.status.orig ? { Task { await restore() } } : nil,
                playSample: playback.url == nil ? nil : { label in playSample(of: label) },
                sampleUnavailable: playback.unavailableReason
            )
        } else {
            ContentUnavailableView(
                "No Speakers", systemImage: "person.2.slash",
                description: Text(engine.isDegraded
                    ? "Speaker editing returns after the update."
                    : "This meeting has no transcript to take speakers from.")
            )
        }
    }

    /// A speaker's longest turn, at most eight seconds of it.
    private func playSample(of label: String) {
        guard let url = playback.url, let document,
              let stats = document.speakers.first(where: { $0.label == label }),
              let turn = document.turns.first(where: { $0.ordinal == stats.longestTurn })
        else { return }
        let line = turn.segments.first?.index ?? -1
        player.play(url, from: turn.start, line: line, until: min(turn.end, turn.start + 8))
    }

    /// The first turn with a line by `speaker` in the draft.
    private func firstTurn(of speaker: String) -> Int? {
        guard let document else { return nil }
        let draft = editor.draft(for: row.path, document: document)
        return document.turns.first { turn in
            turn.segments.isEmpty
                ? turn.speaker == speaker
                : turn.segments.contains { draft.speaker(ofLine: $0.index) == speaker }
        }?.ordinal
    }

    private func save() async {
        isSaving = true
        saveProblem = nil
        defer { isSaving = false }
        switch await editor.save(row.path, with: engine.cli) {
        case .saved:
            await load()
            library.refresh()
        case .busy(let message), .failed(let message):
            saveProblem = message
        case .transcriptChanged:
            await load()
            if let document { editor.carryNames(row.path, to: document) }
            saveProblem = "The transcript changed since it was shown. The names are kept; move the lines again."
        }
    }

    private func restore() async {
        isSaving = true
        saveProblem = nil
        defer { isSaving = false }
        if let problem = await editor.revert(row.path, with: engine.cli) {
            saveProblem = problem
            return
        }
        await load()
        library.refresh()
    }

    private func saveInBackground(_ path: String) {
        guard editor.hasEdits(path) else { return }
        Task {
            if await editor.save(path, with: engine.cli) == .saved { library.refresh() }
        }
    }

    private var newSpeakerPrompt: Binding<Bool> {
        Binding(get: { newSpeakerLines != nil }, set: { if !$0 { newSpeakerLines = nil } })
    }

    private func moveToTypedSpeaker() {
        defer { newSpeakerLines = nil }
        guard let lines = newSpeakerLines, let document else { return }
        let target = editor.draft(for: row.path, document: document).target(forTypedName: newSpeakerName)
        guard !target.isEmpty else { return }
        editor.update(row.path, document: document) { $0.move(lines: lines, to: target) }
    }

    /// The CLI's word on the recording: the fresh document's when loaded.
    private var playback: Playback {
        Playback(audioPath: document?.status.audio ?? row.status.audio)
    }

    private var tab: Tab {
        // An older CLI has no `show`, so there is no transcript view to switch to.
        if engine.isDegraded { return .summary }
        return chosenTab ?? (summary == nil && row.status.hasTranscript && loadedPath == row.path ? .transcript : .summary)
    }

    @ViewBuilder
    private var tabBar: some View {
        if engine.isDegraded {
            Text("The transcript view returns after the update.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            tabPicker
        }
    }

    private var tabPicker: some View {
        HStack {
            Picker("Show", selection: Binding(get: { tab }, set: { chosenTab = $0 })) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            summarizeButton
            if tab == .transcript, player.playingLine != nil {
                Button {
                    player.stop()
                } label: {
                    Label("Stop Playback", systemImage: "stop.fill")
                }
            }
            if tab == .transcript, let document, !document.turns.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document.plainText, forType: .string)
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
            }
        }
    }

    /// Writes the summary with instructions, a template and a model (SummarizeSheet).
    /// Needs a transcript, and a CLI new enough to take instructions.
    @ViewBuilder
    private var summarizeButton: some View {
        if !engine.isDegraded, row.status.hasTranscript {
            if jobs.ownedFolder == row.path {
                ProgressView().controlSize(.small)
                Text("Summarizing…").foregroundStyle(.secondary)
            } else {
                Button {
                    showsSummarize = true
                } label: {
                    Label(row.status.hasSummary ? "Re-summarize…" : "Summarize…", systemImage: "text.badge.star")
                }
                .disabled(jobs.isRunning || isProcessing)
                .help(jobs.isRunning || isProcessing
                      ? "Available when the current recording or job is done."
                      : "Write the summary with your own instructions, template and model")
            }
        }
    }

    /// Why the summary run on this meeting failed, in the pinned area so it shows on
    /// either tab, until dismissed or another run starts.
    @ViewBuilder
    private var summaryFailure: some View {
        if case .failed(let message) = jobs.state, jobs.failedFolder == row.path {
            VStack(alignment: .leading, spacing: 8) {
                Label("The summary could not be written", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Summarize…") { showsSummarize = true }
                    Button("Dismiss", action: jobs.dismissFailure)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// The meeting's last request, else Settings' backend, model and template.
    private var initialSummaryRequest: SummaryRequest {
        let settings = engine.config.summarization
        return SummaryRequest.initial(
            recorded: document?.summaryRequest, backend: settings.backend,
            model: settings.model, template: settings.template
        )
    }

    @ViewBuilder
    private var summaryBody: some View {
        if let summary {
            if !engine.isDegraded, document?.status.summaryStale ?? row.status.summaryStale {
                staleSummaryBanner
            }
            RenderedMarkdown(text: summary, style: .document)
                .textSelection(.enabled)
        } else if loadedPath == row.path {
            Text(row.status.summary == "disabled"
                 ? "No summary: summarization is turned off in Settings."
                 : "No summary for this meeting.")
                .foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// A summary written before speakers were moved may credit the wrong person.
    private var staleSummaryBanner: some View {
        HStack(spacing: 10) {
            Label("Speakers changed after this summary was written.", systemImage: "exclamationmark.bubble")
            Spacer()
            if jobs.ownedFolder == row.path {
                ProgressView().controlSize(.small)
                Text("Summarizing…").foregroundStyle(.secondary)
            } else {
                Button("Re-summarize…") { showsSummarize = true }
                    .disabled(jobs.isRunning || isProcessing)
                    .help(jobs.isRunning ? "Available when the current recording or job is done." : "")
            }
        }
        .font(.callout)
        .padding(10)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if let document {
            if document.turns.isEmpty {
                Text("No transcript for this meeting.")
                    .foregroundStyle(.secondary)
            } else {
                if let reason = playback.unavailableReason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                TranscriptView(
                    document: document,
                    draft: editor.draft(for: row.path, document: document),
                    playingLine: player.playingLine,
                    highlighted: selectedSpeaker,
                    play: playAction,
                    move: canEdit ? { lines, target in
                        editor.update(row.path, document: document) { $0.move(lines: lines, to: target) }
                    } : nil,
                    moveToNewSpeaker: canEdit ? { lines in
                        newSpeakerName = ""
                        newSpeakerLines = lines
                    } : nil
                )
            }
        } else if let documentFailure {
            Label(documentFailure, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// nil when the recording cannot be played, so lines offer no playback at all.
    private var playAction: ((MeetingDocument.Segment) -> Void)? {
        guard let url = playback.url else { return nil }
        return { segment in player.play(url, from: segment.start, line: segment.index) }
    }

    private func load() async {
        let folder = row.url
        let firstLoad = loadedPath != row.path
        async let summaryText = Task.detached { SummaryFile.text(inFolder: folder) }.value
        if engine.isDegraded {
            document = nil
            documentFailure = nil
        } else {
            do {
                document = try await engine.cli.show(folder)
                documentFailure = nil
            } catch {
                document = nil
                documentFailure = Self.describe(error)
            }
        }
        summary = await summaryText
        loadedPath = row.path
        // Speakers nobody named yet: the inspector opens to name them, once per visit,
        // so a refresh never reopens what the user closed.
        if firstLoad, let document, canEdit, !document.unnamedSpeakers.isEmpty {
            inspectorShown = true
        }
    }

    private static func describe(_ error: Error) -> String {
        if case CLIError.command(_, let message) = error { return "Couldn't read the transcript: \(message)" }
        return "Couldn't read the transcript: \(error)"
    }
}

private extension View {
    /// A readable measure: long lines at window width are hard to follow.
    func readingMeasure() -> some View {
        frame(maxWidth: 720, alignment: .leading)
    }
}

/// The meeting's title and facts. The title can be renamed in place: the pencil or a
/// double-click opens it for editing, Return saves it with `ownscribe title`, Esc
/// leaves it as it was.
struct MeetingHeader: View {
    @Environment(Library.self) private var library
    let row: LibraryRow
    let language: String?
    let day: Date?
    let time: Date?
    /// Whether this CLI can rename meetings at all.
    let titleEditable: Bool
    /// Why the title cannot change now (a job works on the meeting); nil when it can.
    let titleReadOnlyReason: String?

    @State private var isEditing = false
    @State private var draft = ""
    @State private var isSaving = false
    @State private var problem: String?
    /// The title just saved, shown until the library lists it.
    @State private var savedTitle: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditing {
                TextField("Title", text: $draft)
                    .font(.largeTitle.weight(.semibold))
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .disabled(isSaving)
                    .onSubmit(save)
                    .onExitCommand { isEditing = false }
                    .task { fieldFocused = true }
                    .accessibilityLabel("Meeting title")
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(savedTitle ?? row.title)
                        .font(.largeTitle.weight(.semibold))
                        .onTapGesture(count: 2) { if canRename { startEditing() } }
                    if titleEditable {
                        Button(action: startEditing) {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canRename)
                        .help(titleReadOnlyReason ?? "Rename this meeting")
                        .accessibilityLabel("Rename meeting")
                    }
                }
            }
            if isSaving {
                ProgressView().controlSize(.small)
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(facts)
                .foregroundStyle(.secondary)
        }
        .onChange(of: row.path) {
            isEditing = false
            problem = nil
            savedTitle = nil
        }
        .onChange(of: row.title) { savedTitle = nil }
    }

    private var canRename: Bool { titleEditable && titleReadOnlyReason == nil && !isSaving }

    private func startEditing() {
        draft = row.title
        problem = nil
        isEditing = true
    }

    /// An unchanged or empty title just closes the field; a refusal keeps it open.
    private func save() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != row.title else {
            isEditing = false
            return
        }
        isSaving = true
        Task {
            problem = await library.setTitle(of: row, to: title)
            isSaving = false
            if problem == nil {
                savedTitle = title
                isEditing = false
            }
        }
    }

    private var facts: String {
        var parts: [String] = []
        if let day, day != .distantPast {
            parts.append(time?.formatted(date: .abbreviated, time: .shortened)
                ?? day.formatted(date: .abbreviated, time: .omitted))
        }
        if let duration = row.duration { parts.append(ClockText.duration(duration)) }
        if let language { parts.append(language) }
        if row.speakerCount > 0 { parts.append(row.speakerCount == 1 ? "1 speaker" : "\(row.speakerCount) speakers") }
        return parts.joined(separator: " · ")
    }
}
