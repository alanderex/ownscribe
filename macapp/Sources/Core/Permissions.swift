import AVFoundation
import AppKit
import CoreGraphics

/// Prime the privacy grants *from the app process* so macOS attributes the
/// consent prompt to Ownscribe.app (the signed bundle the user launched) rather
/// than to the downloaded `ownscribe-audio` helper that actually opens the
/// devices. The child then inherits the app's grant as the responsible process.
enum Permissions {
    /// Microphone consent (only needed when mixing in the mic). Returns whether
    /// access is granted — a `.denied` status used to be ignored, so a meeting could
    /// record with a silent or missing mic track and only reveal it afterwards.
    @discardableResult
    static func ensureMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:  // .denied, .restricted
            return false
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
    static func prime(mic: Bool) async -> Grants {
        let screen = await Task.detached { ensureScreenRecording() }.value
        // Not requested when the mic is off, and then not a blocker either.
        let microphone = mic ? await ensureMicrophone() : true
        return Grants(screenRecording: screen, microphone: microphone)
    }

    struct Grants {
        let screenRecording: Bool
        let microphone: Bool
    }

    /// True once the user has granted Screen Recording; never prompts.
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Open a privacy pane directly — these settings are several levels deep and
    /// the app cannot grant them itself.
    static func openScreenRecordingSettings() {
        open("Privacy_ScreenCapture")
    }

    static func openMicrophoneSettings() {
        open("Privacy_Microphone")
    }

    private static func open(_ anchor: String) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
