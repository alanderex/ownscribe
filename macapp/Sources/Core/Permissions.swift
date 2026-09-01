import AVFoundation
import AppKit
import CoreGraphics

/// Prime the privacy grants *from the app process* so macOS attributes the
/// consent prompt to Ownscribe.app (the signed bundle the user launched) rather
/// than to the downloaded `ownscribe-audio` helper that actually opens the
/// devices. The child then inherits the app's grant as the responsible process.
enum Permissions {
    /// Microphone consent (only needed when mixing in the mic).
    static func ensureMicrophone() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    /// Screen Recording consent (required to capture system audio). Returns
    /// whether access is currently granted; the first call shows the prompt.
    @discardableResult
    static func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    /// Prime both grants before recording. Runs the (potentially prompting)
    /// screen-recording check off the main thread.
    ///
    /// Returns whether screen recording is granted. The result must not be discarded:
    /// without it the pipeline starts anyway and ScreenCaptureKit fails with -3801
    /// ("user has declined TCC for capturing apps, windows, displays"), which reaches
    /// the user only as an empty transcript minutes later.
    static func prime(mic: Bool) async -> Bool {
        let granted = await Task.detached { ensureScreenRecording() }.value
        if mic { await ensureMicrophone() }
        return granted
    }

    /// True once the user has granted Screen Recording; never prompts.
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Open the Screen Recording pane directly — the setting is several levels deep
    /// and the app cannot grant it itself.
    static func openScreenRecordingSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
