import AppKit
import SwiftUI

/// The menu-bar symbol: recording first, then processing, then idle. An idle icon
/// carries a dot while a finished meeting has not been opened.
struct MenuBarIcon: View {
    let engine: Engine
    let recorder: Recorder
    let jobs: Jobs
    let library: Library

    var body: some View {
        if showsDot {
            Image(nsImage: Self.dotted)
                .accessibilityLabel("Ownscribe, a meeting is ready")
        } else {
            Image(systemName: symbol)
        }
    }

    private var showsDot: Bool {
        symbol == "waveform" && !library.unseen.isEmpty
    }

    private var symbol: String {
        if recorder.isRecording { return "record.circle.fill" }
        if recorder.phase == .finalizing || jobs.isRunning { return "hourglass" }
        if engine.isInstalling { return "arrow.down.circle" }
        if case .failed = jobs.state { return "exclamationmark.circle" }
        if engine.setupFailure != nil || engine.permissionFailure != nil { return "exclamationmark.circle" }
        return "waveform"
    }

    /// The idle waveform with a dot at its top right. A template image, so the menu
    /// bar tints it like every other item; the dot is a shape, not a color.
    private static let dotted: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return NSImage() }
        let dot: CGFloat = 6
        let size = NSSize(width: base.size.width + dot / 2, height: base.size.height)
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: 0, width: base.size.width, height: base.size.height))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - dot, y: rect.maxY - dot, width: dot, height: dot)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
