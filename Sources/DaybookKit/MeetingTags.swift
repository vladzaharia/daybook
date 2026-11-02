import DaybookCore
import Foundation

/// How both apps take in a typed tag, so "client, beta" makes the same two tags on the Mac and the iPhone (and
/// syncs as them): the text splits at commas, each part is trimmed with its runs of spaces made one and a leading
/// "#" dropped, and a tag already there (whatever its case) isn't added twice.
public enum TagInput {
    /// The tags typed `text` makes, in the order typed, without empty parts or repeats.
    public static func tags(in text: String) -> [String] {
        adding(text, to: [])
    }

    /// `tags` with the ones typed in `text` after them.
    public static func adding(_ text: String, to tags: [String]) -> [String] {
        var result = tags
        var seen = Set(tags.map(key))
        for part in text.split(separator: ",", omittingEmptySubsequences: true) {
            let tag = normalized(String(part))
            guard !tag.isEmpty, seen.insert(key(tag)).inserted else { continue }
            result.append(tag)
        }
        return result
    }

    /// One tag as typed: trimmed, one space between words, no leading "#".
    public static func normalized(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while words.hasPrefix("#") { words.removeFirst() }
        return words.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func key(_ tag: String) -> String { tag.lowercased() }
}

extension Meeting {
    /// Its tags with those typed in `text` added (`TagInput`).
    public func tags(adding text: String) -> [String] { TagInput.adding(text, to: tags ?? []) }

    /// Its tags without `tag`.
    public func tags(removing tag: String) -> [String] { (tags ?? []).filter { $0 != tag } }
}
