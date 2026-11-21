import XCTest
@testable import Logic

final class PlaybackTests: XCTestCase {
    func testPlayableFormats() {
        for ext in ["wav", "mp3", "m4a", "flac", "mp4", "m4v", "mov", "WAV"] {
            let playback = Playback(audioPath: "/a/b/recording.\(ext)")
            XCTAssertEqual(playback.url, URL(fileURLWithPath: "/a/b/recording.\(ext)"), ext)
            XCTAssertNil(playback.unavailableReason, ext)
        }
    }

    func testUnsupportedFormat() {
        XCTAssertEqual(Playback(audioPath: "/a/call.ogg").unavailableReason, "Playback not available for .ogg")
        XCTAssertNil(Playback(audioPath: "/a/call.mkv").url)
    }

    func testNoRecording() {
        XCTAssertEqual(Playback(audioPath: nil), .noRecording)
        XCTAssertEqual(Playback(audioPath: nil).unavailableReason, "No recording kept · playback unavailable")
    }
}
