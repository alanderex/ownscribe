import AVFoundation
import Observation

/// Plays a meeting's recording from a transcript line, or a short sample of a speaker.
@MainActor
@Observable
final class TurnPlayer {
    /// The line playing now (its segment index), for the transcript to mark.
    private(set) var playingLine: Int?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var loadedURL: URL?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var stopObserver: Any?

    /// Plays from `seconds`; with `until`, pauses there (a speaker sample).
    func play(_ url: URL, from seconds: Double, line: Int, until end: Double? = nil) {
        if loadedURL != url {
            stop()
            let item = AVPlayerItem(url: url)
            player = AVPlayer(playerItem: item)
            loadedURL = url
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.playingLine = nil }
            }
        }
        guard let player else { return }
        removeStopObserver()
        if let end, end > seconds {
            let at = NSValue(time: CMTime(seconds: end, preferredTimescale: 600))
            stopObserver = player.addBoundaryTimeObserver(forTimes: [at], queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.pauseAtSampleEnd() }
            }
        }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        playingLine = line
    }

    private func pauseAtSampleEnd() {
        player?.pause()
        playingLine = nil
        removeStopObserver()
    }

    private func removeStopObserver() {
        if let stopObserver { player?.removeTimeObserver(stopObserver) }
        stopObserver = nil
    }

    func stop() {
        removeStopObserver()
        player?.pause()
        player = nil
        loadedURL = nil
        playingLine = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}
