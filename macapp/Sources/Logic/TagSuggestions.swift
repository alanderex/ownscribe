import Foundation

/// What "+ Tag" offers while a tag is typed: the library's tags the meeting does not
/// have yet, those starting with the typed text first, then those containing it, each
/// group in the library's order (by name).
enum TagSuggestions {
    static func suggest(_ typed: String, from library: [LibraryTag], excluding meetingTags: [String]) -> [String] {
        let have = Set(meetingTags)
        let candidates = library.map(\.name).filter { !have.contains($0) }
        let needle = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return candidates }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let starting = candidates.filter { $0.range(of: needle, options: options.union(.anchored)) != nil }
        let containing = candidates.filter { name in
            !starting.contains(name) && name.range(of: needle, options: options) != nil
        }
        return starting + containing
    }
}
