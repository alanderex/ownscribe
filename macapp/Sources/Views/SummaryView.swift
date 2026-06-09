import SwiftUI

/// Shown after a meeting finishes (or when a recent one is opened): the summary,
/// optional speaker naming (when diarized), and Copy / Reveal / New actions.
struct SummaryView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        Text(rendered)
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Render inline markdown where possible, otherwise fall back to plain text.
    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: app.summaryText, options: options) {
            return attributed
        }
        return AttributedString(app.summaryText)
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
