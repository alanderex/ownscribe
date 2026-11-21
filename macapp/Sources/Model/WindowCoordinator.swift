import AppKit
import Observation
import SwiftUI

enum WindowID {
    static let main = "main"
    static let settings = "settings"
}

/// Opens the app's windows from a menu-bar app, and keeps the Dock icon only while
/// one is open.
///
/// An accessory app's window opens behind whatever app is in front, so opening goes
/// through the regular policy first and then activates. Checked on macOS 27: with
/// another app frontmost, the window comes up key and the app frontmost.
@MainActor
@Observable
final class WindowCoordinator {
    init() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowWillClose(closing) }
        }
    }

    func open(_ id: String, with openWindow: OpenWindowAction) {
        Task {
            NSApp.setActivationPolicy(.regular)
            // Activating in the same turn as the policy change leaves the app behind
            // the frontmost one; a short pause lets the change take effect.
            try? await Task.sleep(nanoseconds: 100_000_000)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: id)
        }
    }

    /// Back to a menu-bar-only app once no window of ours is left. Deferred so the
    /// closing window is gone when the others are counted.
    private func windowWillClose(_ closing: NSWindow?) {
        guard let closing, Self.isAppWindow(closing) else { return }
        DispatchQueue.main.async {
            let open = NSApp.windows.filter { $0 !== closing && $0.isVisible && Self.isAppWindow($0) }
            if open.isEmpty { NSApp.setActivationPolicy(.accessory) }
        }
    }

    /// The main window and Settings: titled windows. The status item and the
    /// MenuBarExtra panel are neither titled nor ordinary windows.
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel)
    }
}
