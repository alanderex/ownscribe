import Foundation

/// Picks the line most likely to explain a failure out of a command's captured stderr.
enum FailureText {
    /// Progress events share stderr with diagnostics, so they must be dropped here or
    /// the user is shown `{"ownscribe_progress":1,...}` instead of the error — the
    /// first line of a failing run is now always an event.
    ///
    /// For a Python traceback the useful line is the last one (the exception), not the
    /// first (`Traceback (most recent call last):`), so that case is handled explicitly.
    static func firstMeaningfulLine(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isProgressEventLine($0) }

        guard !lines.isEmpty else { return nil }
        if lines.contains(where: { $0.hasPrefix("Traceback (most recent call last)") }) {
            // The exception type and message are on the final line of a traceback.
            return lines.last
        }
        // A torch/pyannote import prints deprecation warnings long before anything
        // fails, so "first line" was usually library noise rather than the error.
        // Prefer the first line that isn't recognisable noise; fall back to the
        // first line rather than nothing, since an unrecognised error still helps.
        return lines.first(where: { !isLibraryNoise($0) }) ?? lines.first
    }

    private static func isLibraryNoise(_ line: String) -> Bool {
        let noise = [
            "Warning:", "warnings.warn", "FutureWarning", "UserWarning",
            "DeprecationWarning", "TqdmWarning", "torchaudio", "pkg_resources",
        ]
        // Click's own messages start "Error:"/"Usage:" and must never be filtered.
        if line.hasPrefix("Error:") || line.hasPrefix("Usage:") { return false }
        return noise.contains { line.contains($0) }
    }

    /// Cheap discriminator check — avoids a full JSON decode per stderr line.
    private static func isProgressEventLine(_ line: String) -> Bool {
        line.hasPrefix("{") && line.contains("\"ownscribe_progress\"")
    }
}
