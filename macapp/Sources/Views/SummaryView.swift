import SwiftUI

/// Shown after a meeting finishes (or when a recent one is opened): the summary,
/// optional speaker naming (when diarized), and Copy / Reveal / New actions.
struct SummaryView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button { app.backToIdle() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .font(.callout)
                Spacer()
            }

            if let meeting = app.currentMeeting {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(2)
            }

            if !app.detectedSpeakers.isEmpty && !app.speakersNamed {
                SpeakerNamingView(labels: app.detectedSpeakers)
                Divider()
            }

            summaryBody

            actions
        }
    }

    private var summaryBody: some View {
        RenderedMarkdown(text: app.summaryText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack {
            Button { app.copySummary() } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            if let meeting = app.currentMeeting {
                Button { app.revealInFinder(meeting) } label: {
                    Label("Reveal", systemImage: "folder")
                }
            }
            Spacer()
            Button { app.backToIdle() } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .buttonStyle(.bordered)
        .font(.callout)
    }
}

/// Lightweight block-level markdown renderer: headings become bold/sized text
/// and `-`/`*` lines become bullets, with inline emphasis parsed per line.
/// (SwiftUI's Text drops block styling from AttributedString, which left raw
/// `##` / `-` visible — this renders them properly.)
struct RenderedMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
    }

    private var lines: [String] {
        text.components(separatedBy: "\n")
    }

    @ViewBuilder
    private func lineView(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("### ") {
            Text(inline(String(line.dropFirst(4)))).font(.subheadline).bold()
        } else if line.hasPrefix("## ") {
            Text(inline(String(line.dropFirst(3)))).font(.headline)
        } else if line.hasPrefix("# ") {
            Text(inline(String(line.dropFirst(2)))).font(.title3).bold()
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(inline(String(line.dropFirst(2))))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        } else if line.isEmpty {
            Spacer().frame(height: 2)
        } else {
            Text(inline(line)).font(.callout)
        }
    }

    private func inline(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string)) ?? AttributedString(string)
    }
}
