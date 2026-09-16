import Foundation
import ServiceManagement

/// Registers the app as its own login item.
///
/// Startup used to depend on the user dragging the bundle into System Settings ›
/// Login Items. Such an entry is keyed to the bundle's path and code signature, so
/// a major OS upgrade can drop it — which is exactly what happened on macOS 27, and
/// the app had no way to notice or repair it.
///
/// `SMAppService.mainApp` instead lets the app register itself. The entry then
/// belongs to the app, appears under Login Items & Extensions as the app rather
/// than a remembered path, and can be toggled from inside Settings.
///
/// Two caveats worth knowing:
/// - The bundle should live somewhere stable (normally /Applications). Registering
///   from a build directory records that path, and moving the app afterwards
///   leaves a stale entry.
/// - An ad-hoc signature gives the bundle no stable identity, so registration can
///   be rejected or silently dropped on the next upgrade. Use the local signing
///   certificate (macapp/make-signing-cert.sh), which build-app.sh prefers.
enum LaunchAtLogin {
    enum State: Equatable {
        case on
        case off
        /// Registered, but the user still has to approve it in System Settings.
        /// macOS shows a prompt once; if it is dismissed the entry sits here.
        case needsApproval
        /// The service could not be found — usually an unsigned or relocated bundle.
        case unavailable
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .off
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    static var isEnabled: Bool { state == .on }

    /// Register or unregister. Throws so the caller can show why it failed rather
    /// than leaving a toggle that silently springs back.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Open the pane where a pending registration is approved.
    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// True when the bundle is somewhere a login item can reliably point at.
    /// A login item registered from a build directory breaks as soon as the app
    /// is copied into /Applications, which is the normal next step.
    static var isInStableLocation: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
            || Bundle.main.bundleURL.path.contains("/Applications/")
    }
}
