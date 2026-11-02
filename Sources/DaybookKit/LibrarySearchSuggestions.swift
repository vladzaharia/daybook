import DaybookCore
import Foundation

/// What the library's search field suggests as tokens, the same on the Mac and the iPhone: tags and the people
/// conversations name, never "Me" or an unnamed "Speaker 2", never a token already chosen.
public enum LibrarySearchSuggestions {
    /// The suggestions for what's typed. Nothing typed: every tag, then every person. After "#": the tags that
    /// start with what follows it. Otherwise: the tags and people whose names start with what's typed.
    public static func tokens(for text: String, tags: [String], meetings: [Meeting], chosen: [SearchToken] = []) -> [SearchToken] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        func starts(_ name: String, with prefix: some StringProtocol) -> Bool {
            prefix.isEmpty || name.range(of: prefix, options: options) != nil
        }
        let suggested: [SearchToken]
        if typed.hasPrefix("#") {
            let prefix = typed.dropFirst()
            suggested = tags.filter { starts($0, with: prefix) }.map(SearchToken.tag)
        } else {
            suggested = tags.filter { starts($0, with: typed) }.map(SearchToken.tag)
                + people(in: meetings).filter { starts($0, with: typed) }.map(SearchToken.speaker)
        }
        return suggested.filter { token in !chosen.contains { $0.matches(token) } }
    }

    /// "#launch " typed whole, with the space after it, becomes that tag's token (in the library's spelling).
    public static func promotedTag(in text: String, tags: [String]) -> SearchToken? {
        guard text.hasPrefix("#"), text.hasSuffix(" ") else { return nil }
        let typed = text.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, let tag = tags.first(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) else { return nil }
        return .tag(tag)
    }

    /// The people conversations name, once each, in name order: not "Me" (this device's own microphone) and not a
    /// speaker nobody has named yet.
    public static func people(in meetings: [Meeting]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for name in meetings.lazy.flatMap({ $0.speakers.map(\.name) }) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPerson(trimmed), seen.insert(trimmed.lowercased()).inserted else { continue }
            names.append(trimmed)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A name worth suggesting: not empty, not "Me", not "Speaker 2" (as the byline leaves them out, `peopleLine`).
    static func isPerson(_ name: String) -> Bool {
        guard !name.isEmpty, name.caseInsensitiveCompare("Me") != .orderedSame else { return false }
        return !name.hasPrefix("Speaker ")
    }
}

extension SearchToken {
    /// The same token whatever its case: a tag or person chosen once isn't suggested again.
    func matches(_ other: SearchToken) -> Bool {
        switch (self, other) {
        case (.tag(let a), .tag(let b)), (.speaker(let a), .speaker(let b)): return a.caseInsensitiveCompare(b) == .orderedSame
        default: return false
        }
    }
}
