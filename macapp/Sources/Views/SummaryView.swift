import SwiftUI

/// Shown after a meeting finishes (or when a recent one is opened): the summary,
/// optional speaker naming (when diarized), and Copy / Reveal / New actions.
struct SummaryView: View {
    @Environment(Library.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button { library.closeMeeting() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .font(.callout)
                Spacer()
            }

            if let meeting = library.currentMeeting {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(2)
            }

            if !library.detectedSpeakers.isEmpty && !library.speakersNamed {
                SpeakerNamingView(
                    labels: library.detectedSpeakers,
                    apply: library.applySpeakerNames,
                    skip: { library.speakersNamed = true }
                )
                Divider()
            }

            summaryBody

            actions
        }
    }

    private var summaryBody: some View {
        RenderedMarkdown(text: library.summaryText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack {
            Button { library.copySummary() } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            if let meeting = library.currentMeeting {
                Button { library.revealInFinder(meeting) } label: {
                    Label("Reveal", systemImage: "folder")
                }
            }
            Spacer()
            Button { library.closeMeeting() } label: {
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
    /// Compact for the 340 pt popover; document for reading in the window.
    enum Style { case compact, document }

    let text: String
    var style: Style = .compact

    var body: some View {
        VStack(alignment: .leading, spacing: style == .document ? 8 : 4) {
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
            Text(inline(String(line.dropFirst(4)))).font(style == .document ? .headline : .subheadline).bold()
        } else if line.hasPrefix("## ") {
            Text(inline(String(line.dropFirst(3)))).font(style == .document ? .title3.bold() : .headline)
        } else if line.hasPrefix("# ") {
            Text(inline(String(line.dropFirst(2)))).font(style == .document ? .title2 : .title3).bold()
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(inline(String(line.dropFirst(2))))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(bodyFont)
        } else if line.isEmpty {
            Spacer().frame(height: 2)
        } else {
            Text(inline(line)).font(bodyFont)
        }
    }

    private var bodyFont: Font { style == .document ? .body : .callout }

    private func inline(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string)) ?? AttributedString(string)
    }
}
