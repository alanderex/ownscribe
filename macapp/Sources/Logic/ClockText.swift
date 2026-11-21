import Foundation

enum ClockText {
    /// A meeting's length: `42:10`, or `1:02:03` from an hour on.
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
