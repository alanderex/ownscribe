import SwiftUI

/// The latest meetings; each opens in the window.
struct RecentView: View {
    @Environment(Library.self) private var library
    @Environment(WindowCoordinator.self) private var windows
    @Environment(\.openWindow) private var openWindow
    let rows: [LibraryRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(rows) { row in
                Button {
                    library.markSeen(row.path)
                    windows.open(meeting: row.path, with: openWindow)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: row.status.hasSummary ? "doc.text.fill" : "doc.text")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title)
                                .font(.callout)
                                .lineLimit(1)
                            Text(when(row))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if library.unseen.contains(row.path) {
                            Circle().fill(.tint).frame(width: 6, height: 6)
                                .accessibilityLabel("new")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func when(_ row: LibraryRow) -> String {
        if let time = library.calendar.time(of: row) {
            return time.formatted(.dateTime.month().day().hour().minute())
        }
        guard let day = library.calendar.day(of: row), day != .distantPast else { return "" }
        return day.formatted(.dateTime.month().day())
    }
}
