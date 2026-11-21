import Foundation

/// The app's state objects, created once and shared by every scene.
@MainActor
final class AppModel {
    let engine: Engine
    let library: Library
    let jobs: Jobs
    let recorder: Recorder
    let windows: WindowCoordinator

    init() {
        engine = Engine()
        library = Library(engine: engine)
        jobs = Jobs(engine: engine, library: library)
        recorder = Recorder(engine: engine, jobs: jobs)
        windows = WindowCoordinator()
        engine.onConfigLoaded = { [weak library] in library?.refresh() }
        // Here and not in the popover's .task: MenuBarExtra builds its content only
        // when the menu is first opened, so setup, an upgrade and loading the
        // config used to wait for that first click.
        Task { await engine.bootstrap() }
    }
}
