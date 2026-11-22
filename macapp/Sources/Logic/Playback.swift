import Foundation

/// Whether a meeting's recording can be played from a transcript turn.
enum Playback: Equatable {
    case playable(URL)
    /// A recording exists in a format AVFoundation cannot play or seek.
    case unsupported(fileExtension: String)
    /// The CLI found no recording (keep_recording off, or it was deleted).
    case noRecording

    /// Formats AVFoundation plays and seeks. Checked on macOS 27: flac plays; ogg
    /// reports itself playable but has no duration and cannot seek; webm and mkv do
    /// not open.
    static let playableExtensions: Set<String> = ["wav", "mp3", "m4a", "flac", "mp4", "m4v", "mov"]

    /// `audioPath` is the status the CLI reports; the app never looks for audio
    /// itself, because output.audio_dir can put it outside the meeting folder.
    init(audioPath: String?) {
        guard let audioPath else { self = .noRecording; return }
        let url = URL(fileURLWithPath: audioPath)
        let ext = url.pathExtension.lowercased()
        self = Self.playableExtensions.contains(ext) ? .playable(url) : .unsupported(fileExtension: ext)
    }

    var url: URL? {
        if case .playable(let url) = self { return url }
        return nil
    }

    /// What to say when turns cannot be played; nil when they can.
    var unavailableReason: String? {
        switch self {
        case .playable: return nil
        case .unsupported(let ext): return "Playback not available for .\(ext)"
        case .noRecording: return "No recording kept · playback unavailable"
        }
    }
}
