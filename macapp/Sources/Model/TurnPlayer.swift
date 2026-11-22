import AVFoundation
import Observation

/// Plays a meeting's recording from a transcript turn.
@MainActor
@Observable
final class TurnPlayer {
    /// The turn playing now, for the transcript to mark.
    private(set) var playingTurn: Int?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var loadedURL: URL?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func play(_ url: URL, from seconds: Double, turn: Int) {
        if loadedURL != url {
            stop()
            let item = AVPlayerItem(url: url)
            player = AVPlayer(playerItem: item)
            loadedURL = url
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.playingTurn = nil }
            }
        }
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        playingTurn = turn
    }

    func stop() {
        player?.pause()
        player = nil
        loadedURL = nil
        playingTurn = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}
