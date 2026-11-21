import SwiftUI

@main
struct OwnscribeApp: App {
    @State private var engine: Engine
    @State private var library: Library
    @State private var jobs: Jobs
    @State private var recorder: Recorder

    init() {
        let engine = Engine()
        let library = Library(engine: engine)
        let jobs = Jobs(engine: engine, library: library)
        let recorder = Recorder(engine: engine, jobs: jobs, library: library)
        engine.onReady = { [weak library] in library?.refreshRecents() }
        _engine = State(initialValue: engine)
        _library = State(initialValue: library)
        _jobs = State(initialValue: jobs)
        _recorder = State(initialValue: recorder)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(engine)
                .environment(recorder)
                .environment(jobs)
                .environment(library)
                .task { await engine.bootstrap() }
        } label: {
            MenuBarIcon(engine: engine, recorder: recorder, jobs: jobs)
        }
        .menuBarExtraStyle(.window)

        Window("Ownscribe Settings", id: "settings") {
            SettingsView()
                .environment(engine)
        }
        .windowResizability(.contentSize)
    }
}
