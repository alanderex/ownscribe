import SwiftUI

/// Recent meetings read from the configured output directory.
struct RecentView: View {
    @Environment(Library.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(library.recentMeetings) { meeting in
                Button { library.show(meeting) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: meeting.hasSummary ? "doc.text.fill" : "doc.text")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(meeting.title)
                                .font(.callout)
                                .lineLimit(1)
                            Text(meeting.date, format: .dateTime.month().day().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
