import Foundation

/// A note's first recording-relative timestamp survives later wording changes.
/// Nil means the text originated outside an active recording.
public struct TimedNote: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var time: TimeInterval?
    public var text: String

    public init(id: UUID = UUID(), time: TimeInterval? = nil, text: String) {
        self.id = id
        self.time = time.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.text = text
    }
}

public enum NoteTimeline {
    /// Reconciles nonempty, newline-separated paragraphs without stamping existing
    /// pre-meeting notes when recording begins. A new paragraph receives captureTime
    /// only when supplied by an active recorder; editing never changes its anchor.
    public static func reconcile(previous: [TimedNote], text: String, captureTime: TimeInterval?) -> [TimedNote] {
        let paragraphs = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let timestamp = captureTime.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        guard !previous.isEmpty else { return paragraphs.map { TimedNote(time: timestamp, text: $0) } }
        guard !paragraphs.isEmpty else { return [] }

        // Moving a line break must not invent a new timestamp for existing text.
        let oldNormalized = previous.map { normalized($0.text) }
        let newNormalized = paragraphs.map(normalized)
        if oldNormalized.joined(separator: " ") == newNormalized.joined(separator: " ") {
            var oldRanges: [Range<Int>] = []
            var position = 0
            for value in oldNormalized {
                oldRanges.append(position..<(position + value.count))
                position += value.count + 1
            }
            var used = Set<UUID>()
            position = 0
            return paragraphs.enumerated().map { index, paragraph in
                let range = position..<(position + newNormalized[index].count)
                position = range.upperBound + 1
                let origin = oldRanges.firstIndex(where: { $0.overlaps(range) }) ?? min(index, previous.count - 1)
                let note = previous[origin]
                let id = used.insert(note.id).inserted ? note.id : UUID()
                return TimedNote(id: id, time: note.time, text: paragraph)
            }
        }

        // Most keystrokes change one paragraph. Strip exact edges before diffing
        // so long notes don't incur a full quadratic comparison on every keypress.
        var prefix = 0
        while prefix < min(previous.count, paragraphs.count), previous[prefix].text == paragraphs[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(previous.count, paragraphs.count) - prefix,
              previous[previous.count - 1 - suffix].text == paragraphs[paragraphs.count - 1 - suffix] { suffix += 1 }

        let oldMiddle = Array(previous[prefix..<(previous.count - suffix)])
        let newMiddle = Array(paragraphs[prefix..<(paragraphs.count - suffix)])
        let mapping = align(oldMiddle.map(\.text), newMiddle)
        let middle = newMiddle.enumerated().map { index, paragraph in
            if let oldIndex = mapping[index] {
                let old = oldMiddle[oldIndex]
                return TimedNote(id: old.id, time: old.time, text: paragraph)
            }
            return TimedNote(time: timestamp, text: paragraph)
        }
        return Array(previous.prefix(prefix)) + middle + Array(previous.suffix(suffix))
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        let left = Array(lhs.lowercased()), right = Array(rhs.lowercased())
        let length = max(left.count, right.count)
        guard length > 0 else { return 1 }
        var prefix = 0
        while prefix < min(left.count, right.count), left[prefix] == right[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(left.count, right.count) - prefix,
              left[left.count - suffix - 1] == right[right.count - suffix - 1] { suffix += 1 }
        let a = Set(lhs.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let b = Set(rhs.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let words = a.isEmpty || b.isEmpty ? 0 : 2 * Double(a.intersection(b).count) / Double(a.count + b.count)
        return max(Double(prefix + suffix) / Double(length), words)
    }

    /// Maps new paragraph indices to old ones. Replacement is cheaper than delete
    /// plus insert, so editing an entire paragraph retains its original timestamp.
    private static func align(_ old: [String], _ new: [String]) -> [Int?] {
        guard !old.isEmpty else { return Array(repeating: nil, count: new.count) }
        guard !new.isEmpty else { return [] }
        // Bound work for a very large paste. Exact paragraphs retain their anchors;
        // unmatched replacements pair in order rather than freezing the editor.
        if old.count * new.count > 40_000 {
            var available: [String: [Int]] = [:]
            for (index, text) in old.enumerated() { available[text, default: []].append(index) }
            var used = Set<Int>()
            var output: [Int?] = new.map { text in
                guard let index = available[text]?.first else { return nil }
                available[text]?.removeFirst(); used.insert(index)
                return index
            }
            var remaining = old.indices.filter { !used.contains($0) }.makeIterator()
            for index in output.indices where output[index] == nil { output[index] = remaining.next() }
            return output
        }
        let width = new.count + 1
        var costs = Array(repeating: 0.0, count: (old.count + 1) * width)
        var steps = Array(repeating: UInt8(0), count: costs.count)
        for index in 1...old.count { costs[index * width] = Double(index); steps[index * width] = 1 }
        for index in 1...new.count { costs[index] = Double(index); steps[index] = 2 }
        for oldIndex in 1...old.count {
            for newIndex in 1...new.count {
                let position = oldIndex * width + newIndex
                let replace = costs[(oldIndex - 1) * width + newIndex - 1] + 1 - similarity(old[oldIndex - 1], new[newIndex - 1])
                let remove = costs[(oldIndex - 1) * width + newIndex] + 1
                let insert = costs[oldIndex * width + newIndex - 1] + 1
                costs[position] = replace
                if remove < costs[position] { costs[position] = remove; steps[position] = 1 }
                if insert < costs[position] { costs[position] = insert; steps[position] = 2 }
            }
        }
        var mapping = Array<Int?>(repeating: nil, count: new.count)
        var i = old.count, j = new.count
        while i > 0 || j > 0 {
            switch steps[i * width + j] {
            case 1: i -= 1
            case 2: j -= 1
            default: mapping[j - 1] = i - 1; i -= 1; j -= 1
            }
        }
        return mapping
    }
}
