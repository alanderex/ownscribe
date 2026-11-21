import Foundation

/// Reads a meeting's summary text from whichever format the CLI wrote.
enum SummaryFile {
    /// The summary's names, in the order the CLI looks for them.
    static let names = ["summary.md", "summary.json"]

    /// summary.md as written; summary.json holds `{"summary": "..."}`, and showing
    /// the raw JSON would put braces and escapes on screen.
    static func text(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if url.pathExtension.lowercased() == "json" {
            struct Document: Decodable { let summary: String }
            return (try? JSONDecoder().decode(Document.self, from: data))?.summary
        }
        return String(data: data, encoding: .utf8)
    }

    /// The summary of the meeting in `folder`, or nil when there is none.
    static func text(inFolder folder: URL) -> String? {
        for name in names {
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return text(at: url) }
        }
        return nil
    }
}
