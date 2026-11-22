import SwiftUI

/// One meeting's speakers: name them, say two are the same person, and save or discard
/// the draft, which also holds the lines moved in the transcript.
struct SpeakerInspector: View {
    let document: MeetingDocument
    let draft: SpeakerDraft
    /// Why the speakers cannot be edited right now, or nil.
    let readOnlyReason: String?
    /// Names used in the library, offered while typing.
    let knownNames: [String]
    @Binding var selectedSpeaker: String?
    let rename: (String, String) -> Void
    let save: () -> Void
    let discard: () -> Void
    let isSaving: Bool
    /// The last save's problem, shown until the next attempt.
    let problem: String?
    /// Puts back the files from before the first speaker edit; nil when there are none.
    let restore: (() -> Void)?
    /// Plays a few seconds of a speaker; nil without a playable recording.
    let playSample: ((String) -> Void)?
    /// Why there is no sample to hear, when there is none.
    let sampleUnavailable: String?

    @FocusState private var focusedSpeaker: String?
    @State private var confirmingRestore = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Speakers").font(.headline)
                if let readOnlyReason {
                    Label(readOnlyReason, systemImage: "lock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if playSample == nil, let sampleUnavailable {
                    Text(sampleUnavailable)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(draft.speakers, id: \.self) { speaker in
                    row(for: speaker)
                }
                footer
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        // Naming someone starts with hearing them.
        .onChange(of: focusedSpeaker) { _, speaker in
            if let speaker, hasSample(speaker) { playSample?(speaker) }
        }
    }

    private func row(for speaker: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(SpeakerColors.color(for: speaker, among: draft.speakers))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                TextField(MeetingDocument.isUnnamedLabel(speaker) ? speaker : "Name", text: nameBinding(speaker))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedSpeaker, equals: speaker)
                    .onSubmit { focusedSpeaker = nextSpeaker(after: speaker) }
                    .disabled(readOnlyReason != nil)
                    .accessibilityLabel("Name for \(speaker)")
                suggestions(for: speaker)
                if let playSample, hasSample(speaker) {
                    Button {
                        playSample(speaker)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Play a few seconds of this speaker")
                    .accessibilityLabel("Play a sample of \(draft.name(for: speaker))")
                }
            }
            HStack(spacing: 8) {
                Text(facts(for: speaker))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                samePersonMenu(for: speaker)
            }
            if let others = mergedWith(speaker) {
                Label("Same person as \(others)", systemImage: "arrow.triangle.merge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(
            selectedSpeaker == speaker ? AnyShapeStyle(.selection.opacity(0.25)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedSpeaker = selectedSpeaker == speaker ? nil : speaker }
        .accessibilityAddTraits(selectedSpeaker == speaker ? .isSelected : [])
        .accessibilityAction(named: "Show their lines") { selectedSpeaker = speaker }
    }

    /// The field shows a typed name, or a name the speaker already has; an unnamed
    /// label shows its placeholder instead.
    private func nameBinding(_ speaker: String) -> Binding<String> {
        Binding(
            get: {
                let name = draft.name(for: speaker)
                return name == speaker && MeetingDocument.isUnnamedLabel(speaker) ? "" : name
            },
            set: { rename(speaker, $0) }
        )
    }

    /// Speakers from the transcript have a longest turn to sample; new ones do not yet.
    private func hasSample(_ speaker: String) -> Bool {
        document.speakers.contains { $0.label == speaker }
    }

    private func nextSpeaker(after speaker: String) -> String? {
        guard let index = draft.speakers.firstIndex(of: speaker), index + 1 < draft.speakers.count else { return nil }
        return draft.speakers[index + 1]
    }

    @ViewBuilder
    private func suggestions(for speaker: String) -> some View {
        let typed = nameBinding(speaker).wrappedValue
        let matches = knownNames.filter { typed.isEmpty || $0.localizedStandardContains(typed) }.prefix(12)
        if readOnlyReason == nil && !matches.isEmpty {
            Menu {
                ForEach(Array(matches), id: \.self) { name in
                    Button(name) { rename(speaker, name) }
                }
            } label: {
                Image(systemName: "person.crop.circle.badge.questionmark")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Names used in other meetings")
            .accessibilityLabel("Names used before")
        }
    }

    private func samePersonMenu(for speaker: String) -> some View {
        Menu("Same person as…") {
            ForEach(draft.speakers.filter { $0 != speaker }, id: \.self) { other in
                Button(draft.name(for: other)) { rename(speaker, draft.name(for: other)) }
            }
        }
        .menuStyle(.borderlessButton)
        .font(.caption)
        .fixedSize()
        .disabled(readOnlyReason != nil || draft.speakers.count < 2)
    }

    private func mergedWith(_ speaker: String) -> String? {
        guard let group = draft.merges[draft.name(for: speaker)] else { return nil }
        let others = group.filter { $0 != speaker }
        return others.isEmpty ? nil : others.joined(separator: ", ")
    }

    private func facts(for speaker: String) -> String {
        guard let stats = document.speakers.first(where: { $0.label == speaker }) else {
            return "New speaker"
        }
        let total = document.speakers.reduce(0) { $0 + $1.seconds }
        let turns = stats.turns == 1 ? "1 turn" : "\(stats.turns) turns"
        guard total > 0 else { return turns }
        // Approximate for markdown transcripts, which keep no end times.
        return "\(turns) · ~\(Int((stats.seconds / total * 100).rounded()))%"
    }

    @ViewBuilder
    private var footer: some View {
        if !draft.moves.isEmpty, document.standardLayout == false {
            Text("Saving also tidies this transcript's layout. Restore Original Names brings the original back.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
        }
        if !draft.isEmpty {
            HStack {
                Button("Discard", role: .destructive, action: discard)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("Save", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .disabled(isSaving || readOnlyReason != nil)
        } else if let restore {
            Button("Restore Original Names…") { confirmingRestore = true }
                .disabled(isSaving || readOnlyReason != nil)
                .confirmationDialog(
                    "Restore the transcript and summary as they were before the first speaker edit?",
                    isPresented: $confirmingRestore
                ) {
                    Button("Restore", role: .destructive, action: restore)
                } message: {
                    Text("Every rename, merge and moved line since then is undone.")
                }
        }
    }
}

/// Toggles the speaker inspector from the View menu (⌥⌘I).
struct InspectorCommands: Commands {
    @FocusedBinding(\.speakerInspectorShown) private var shown

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(shown == true ? "Hide Speakers" : "Show Speakers") { shown?.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(shown == nil)
        }
    }
}

private struct SpeakerInspectorShownKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var speakerInspectorShown: Binding<Bool>? {
        get { self[SpeakerInspectorShownKey.self] }
        set { self[SpeakerInspectorShownKey.self] = newValue }
    }
}
