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
    @Environment(Jobs.self) private var jobs
    @State private var selection: SidebarItem?
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("mainWindow.sidebarVisible") private var sidebarVisible = true

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(selection: $selection, query: query)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            DetailPane(selection: selection)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                RecorderToolbarButton()
            }
            ToolbarItem(placement: .primaryAction) {
                TextField("Search titles and summaries", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .focused($searchFocused)
                    .onExitCommand { query = ""; searchFocused = false }
                    .accessibilityLabel("Search meetings")
            }
        }
        .focusedSceneValue(\.focusSearch, FocusSearchAction { searchFocused = true })
        .onChange(of: jobs.lastFinished) { _, finished in
            guard let finished else { return }
            // Completion never takes the selection away from something else: the
            // finished meeting opens only in place of nothing, or of its own run.
            switch selection {
            case nil, .activeRun?: selection = .meeting(finished.folder)
            default: break
            }
        }
        .onChange(of: selection) { _, selected in
            if case .meeting(let path)? = selected { library.markSeen(path) }
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
            } else if library.isListing {
                ProgressView()
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

/// Lets the Find menu command (⌘F) focus the window's search field. macOS 14 has
/// no API to focus a `.searchable` field, so the field is a plain TextField.
struct FocusSearchAction {
    let focus: () -> Void
}

private struct FocusSearchKey: FocusedValueKey {
    typealias Value = FocusSearchAction
}

extension FocusedValues {
    var focusSearch: FocusSearchAction? {
        get { self[FocusSearchKey.self] }
        set { self[FocusSearchKey.self] = newValue }
    }
}

struct LibraryCommands: Commands {
    @FocusedValue(\.focusSearch) private var focusSearch

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") { focusSearch?.focus() }
                .keyboardShortcut("f")
                .disabled(focusSearch == nil)
        }
    }
}
