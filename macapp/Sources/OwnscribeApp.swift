import AppKit
import SwiftUI

/// Chooses the App type for this system.
///
/// The main window must not open at launch. On macOS 15+ the scene says so with
/// `.defaultLaunchBehavior(.suppressed)`. That modifier cannot be applied
/// conditionally inside one scene list (SceneBuilder accepts a bare `if #available`
/// with no else branch), so each case gets its own App type. The compiler check
/// keeps the macOS 14 SDK, which lacks the modifier, building.
@main
enum OwnscribeMain {
    static func main() {
        #if compiler(>=6.0)
        if #available(macOS 15, *) {
            OwnscribeApp15.main()
            return
        }
        #endif
        AppDelegate.closesMainWindowAtLaunch = true
        OwnscribeApp.main()
    }
}

/// macOS 14, or a build without the macOS 15 SDK: the delegate closes a main window
/// SwiftUI presents at launch. Checked on macOS 27 by forcing a launch-time window;
/// macOS 14 itself has not been observed.
struct OwnscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarScene(model: model)
        MainWindowScene(model: model)
        SettingsScene(model: model)
    }
}

#if compiler(>=6.0)
@available(macOS 15, *)
struct OwnscribeApp15: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarScene(model: model)
        MainWindowScene(model: model)
            .defaultLaunchBehavior(.suppressed)
        SettingsScene(model: model)
    }
}
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set when the running App type cannot suppress the main window itself.
    @MainActor static var closesMainWindowAtLaunch = false

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Self.closesMainWindowAtLaunch else { return }
        // SwiftUI has created the window by now, and its content has not appeared.
        for window in NSApp.windows
        where window.isVisible && window.identifier?.rawValue.hasPrefix(WindowID.main) == true {
            window.close()
        }
    }

    /// A menu-bar app keeps running with no window open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct MenuBarScene: Scene {
    let model: AppModel

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .modelEnvironment(model)
        } label: {
            MenuBarIcon(engine: model.engine, recorder: model.recorder, jobs: model.jobs)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MainWindowScene: Scene {
    let model: AppModel

    var body: some Scene {
        Window("Ownscribe", id: WindowID.main) {
            MainWindow()
                .modelEnvironment(model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            LibraryCommands()
            RecordingCommands(recorder: model.recorder, jobs: model.jobs)
        }
    }
}

struct SettingsScene: Scene {
    let model: AppModel

    var body: some Scene {
        Window("Ownscribe Settings", id: WindowID.settings) {
            SettingsView()
                .environment(model.engine)
        }
        .windowResizability(.contentSize)
    }
}

extension View {
    /// Every state object, for views anywhere in a scene.
    func modelEnvironment(_ model: AppModel) -> some View {
        environment(model.engine)
            .environment(model.recorder)
            .environment(model.jobs)
            .environment(model.library)
            .environment(model.windows)
    }
}
