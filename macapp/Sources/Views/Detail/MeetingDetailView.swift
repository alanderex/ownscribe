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
    let row: LibraryRow

    @State private var summary: String?
    @State private var document: MeetingDocument?
    @State private var documentFailure: String?
    @State private var loadedPath: String?
    /// nil until chosen: the summary when there is one, the transcript otherwise.
    @State private var chosenTab: Tab?
    @State private var namingSkipped: Set<String> = []
    @State private var player = TurnPlayer()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MeetingHeader(
                    row: row, language: document?.language,
                    day: library.calendar.day(of: row), time: library.calendar.time(of: row)
                )
                tabBar
                Divider()
                switch tab {
                case .summary: summaryBody
                case .transcript: transcriptBody
                }
            }
            // A readable measure: long lines at window width are hard to follow.
            .frame(maxWidth: 720, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .task(id: row) {
            player.stop()
            await load()
        }
        .onDisappear { player.stop() }
    }

    /// The CLI's word on the recording: the fresh document's when loaded.
    private var playback: Playback {
        Playback(audioPath: document?.status.audio ?? row.status.audio)
    }

    private var tab: Tab {
        chosenTab ?? (summary == nil && row.status.hasTranscript && loadedPath == row.path ? .transcript : .summary)
    }

    private var tabBar: some View {
        HStack {
            Picker("Show", selection: Binding(get: { tab }, set: { chosenTab = $0 })) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if tab == .transcript, player.playingTurn != nil {
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

    @ViewBuilder
    private var summaryBody: some View {
        if let summary {
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

    @ViewBuilder
    private var transcriptBody: some View {
        if let document {
            let unnamed = document.unnamedSpeakers
            if !unnamed.isEmpty && !namingSkipped.contains(row.path) {
                SpeakerNamingView(
                    labels: document.speakers.map(\.label),
                    apply: { names in Task { await rename(names) } },
                    skip: { namingSkipped.insert(row.path) }
                )
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            if document.turns.isEmpty {
                Text("No transcript for this meeting.")
                    .foregroundStyle(.secondary)
            } else {
                if let reason = playback.unavailableReason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                TranscriptView(document: document, playingTurn: player.playingTurn, play: playAction)
            }
        } else if let documentFailure {
            Label(documentFailure, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// nil when the recording cannot be played, so turns offer no playback at all.
    private var playAction: ((MeetingDocument.Turn) -> Void)? {
        guard let url = playback.url else { return nil }
        return { turn in player.play(url, from: turn.start, turn: turn.ordinal) }
    }

    private func load() async {
        let folder = row.url
        async let summaryText = Task.detached { SummaryFile.text(inFolder: folder) }.value
        do {
            document = try await engine.cli.show(folder)
            documentFailure = nil
        } catch {
            document = nil
            documentFailure = Self.describe(error)
        }
        summary = await summaryText
        loadedPath = row.path
    }

    /// Rename in every transcript file the folder has, so `show` (which prefers
    /// transcript.json) and the markdown agree.
    private func rename(_ names: [String: String]) async {
        let mapping = names.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !mapping.isEmpty else { namingSkipped.insert(row.path); return }
        for name in ["transcript.json", "transcript.md"] {
            let url = row.url.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                await engine.cli.renameSpeakers(url, mapping: mapping)
            }
        }
        await load()
        library.refresh()
    }

    private static func describe(_ error: Error) -> String {
        if case CLIError.command(_, let message) = error { return "Couldn't read the transcript: \(message)" }
        return "Couldn't read the transcript: \(error)"
    }
}

struct MeetingHeader: View {
    let row: LibraryRow
    let language: String?
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
        if let language { parts.append(language) }
        if row.speakerCount > 0 { parts.append(row.speakerCount == 1 ? "1 speaker" : "\(row.speakerCount) speakers") }
        return parts.joined(separator: " · ")
    }
}
