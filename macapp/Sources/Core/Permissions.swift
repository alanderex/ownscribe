import AVFoundation
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
    static func prime(mic: Bool) async {
        await Task.detached { _ = ensureScreenRecording() }.value
        if mic { await ensureMicrophone() }
    }
}
