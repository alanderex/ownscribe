import AVFoundation
import Observation

/// Plays a meeting's recording from a transcript line.
@MainActor
@Observable
final class TurnPlayer {
    /// The line playing now (its segment index), for the transcript to mark.
    private(set) var playingLine: Int?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var loadedURL: URL?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func play(_ url: URL, from seconds: Double, line: Int) {
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
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        playingLine = line
    }

    func stop() {
        player?.pause()
        player = nil
        loadedURL = nil
        playingLine = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}
