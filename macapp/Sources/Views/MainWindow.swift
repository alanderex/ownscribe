import SwiftUI

/// What the sidebar can select. Meetings are keyed by folder path.
enum SidebarItem: Hashable {
    case activeRun
    case meeting(String)
}

/// The workspace: the library and the run in progress in the sidebar, the
/// selected item in the detail pane.
struct MainWindow: View {
    @Environment(Library.self) private var library
    @State private var selection: SidebarItem?
    @AppStorage("mainWindow.sidebarVisible") private var sidebarVisible = true

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            DetailPane(selection: selection)
        }
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = $0 != .detailOnly }
        )
    }
}

private struct DetailPane: View {
    @Environment(Library.self) private var library
    let selection: SidebarItem?

    var body: some View {
        switch selection {
        case .activeRun:
            RunDetailView()
        case .meeting(let path):
            if let row = library.rows.first(where: { $0.path == path }) {
                MeetingDetailView(row: row)
            } else {
                ContentUnavailableView(
                    "Meeting not found", systemImage: "questionmark.folder",
                    description: Text("Its folder was moved or deleted.")
                )
            }
        case nil:
            if library.rows.contains(where: \.isMeeting) {
                ContentUnavailableView("Select a meeting", systemImage: "waveform")
            } else {
                EmptyLibraryView()
            }
        }
    }
}
