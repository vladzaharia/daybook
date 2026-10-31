import DaybookCore
import Foundation

/// Commitments that restate an earlier one in other words. A meeting's recap goes over most of what was
/// agreed ("Complete the storage spike" after "Spike storage for iOS and report back next Thursday"), and
/// the transcript parts' overlap repeats a few, so a three-hour meeting listed 129 actions for its 66
/// commitments (docs/validation.md, 2026-10-31). A later commitment with the same owner (or no owner,
/// like the earlier one) whose task is mostly the earlier task's distinctive words is the same
/// commitment, and the earlier wording, from when it was made, is kept; so is one that sums up several
/// earlier ones ("Complete account deletion, refund status, and the kill switches"). Words count by how
/// few of the meeting's commitments use them, so a verb, a platform, or a number the tasks share ("fix",
/// "iOS", "five") never makes two of them one.
enum RestatedCommitments {
    /// How much of the shorter task's weight two commitments must share to be one.
    static let threshold = 0.6
    /// How much of a commitment's weight earlier ones must cover together, each sharing two of its words, for
    /// it to sum them up. On the three-hour meeting, the two that did came to 0.88 and 1; the closest
    /// commitment that didn't, 0.53.
    static let summingUp = 0.75

    /// A verified commitment and where its quote is in the transcript.
    struct Item {
        var action: ActionItem
        /// The passage the quote starts in.
        var passage: Int
        /// The quote's place in the transcript's words.
        var quote: Range<Int>
    }

    /// `items` in the order they were said, less restatements. Two commitments quoted from different words of
    /// one passage are told apart however alike they read: listed side by side ("the storage spike, and
    /// Bugnet in five point seven"), neither restates the other.
    static func removing(from items: [Item]) -> [ActionItem] {
        let ordered = items.enumerated().sorted { ($0.element.passage, $0.offset) < ($1.element.passage, $1.offset) }.map(\.element)
        let words = ordered.map { Self.words($0.action.text) }
        var counts: [String: Int] = [:]
        for set in words { for word in set { counts[word, default: 0] += 1 } }
        let weight = { (word: String) in log(Double(ordered.count + 1) / Double(counts[word] ?? 1)) }
        let total = { (set: Set<String>) in set.reduce(0) { $0 + weight($1) } }
        var kept: [Int] = []
        for index in ordered.indices {
            let owner = owners(ordered[index].action.owner)
            let earlier = kept.filter { earlier in
                owners(ordered[earlier].action.owner) == owner
                    && (ordered[earlier].passage != ordered[index].passage || ordered[earlier].quote.overlaps(ordered[index].quote))
            }
            let restates = earlier.contains { earlier in
                let shared = total(words[index].intersection(words[earlier]))
                return shared > 0 && shared >= threshold * min(total(words[index]), total(words[earlier]))
            }
            let summed = earlier.filter { words[$0].intersection(words[index]).count >= 2 }
            let covered = summed.reduce(into: Set<String>()) { $0.formUnion(words[$1].intersection(words[index])) }
            let sumsUp = summed.count >= 2 && total(covered) >= summingUp * total(words[index])
            if !restates && !sumsUp { kept.append(index) }
        }
        return kept.map { ordered[$0].action }
    }

    /// The people an owner names ("Hana and Diego"), so the same pair in another order is the same owner.
    static func owners(_ owner: String?) -> Set<String> {
        Set((owner ?? "").lowercased().components(separatedBy: CharacterSet(charactersIn: ",&"))
            .flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// A task's distinctive words: lowercased, numbers as digits ("five point six" and "5.6" alike), common
    /// endings removed ("flags", "flag"), without the words any task has (articles, "complete", dates).
    static func words(_ task: String) -> Set<String> {
        var tokens: [String] = [], current = ""
        let characters = Array(task.lowercased().replacingOccurrences(of: "\u{2019}", with: "'"))
        for (index, character) in characters.enumerated() {
            if character.isLetter || character.isNumber { current.append(character); continue }
            // A decimal point between digits stays ("5.6"); a possessive goes ("Paylane's").
            if character == ".", current.last?.isNumber == true, index + 1 < characters.count, characters[index + 1].isNumber {
                current.append(character); continue
            }
            if !current.isEmpty { tokens.append(current); current = "" }
        }
        if !current.isEmpty { tokens.append(current) }
        var result = Set<String>(), index = 0
        while index < tokens.count {
            var token = tokens[index]
            if var number = numbers[token] {
                if index + 2 < tokens.count, tokens[index + 1] == "point", let fraction = numbers[tokens[index + 2]] {
                    number += "." + fraction; index += 2
                }
                token = number
            } else if let digits = token.range(of: #"^\d+(?=(?:st|nd|rd|th)$)"#, options: .regularExpression) {
                token = String(token[digits])
            }
            index += 1
            guard !ignored.contains(token) else { continue }
            result.insert(stem(token))
        }
        return result
    }

    private static func stem(_ word: String) -> String {
        for suffix in ["ations", "ation", "ings", "ing", "ions", "ion", "ers", "er", "ies", "es", "ed", "s"]
        where word.hasSuffix(suffix) && word.count - suffix.count >= 4 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    private static let numbers: [String: String] = {
        var table: [String: String] = [:]
        let cardinals = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty"
        for (value, word) in cardinals.split(separator: " ").enumerated() { table[String(word)] = String(value) }
        let ordinals = "first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth twentieth"
        for (value, word) in ordinals.split(separator: " ").enumerated() { table[String(word)] = String(value + 1) }
        for (word, value) in ["thirty": "30", "thirtieth": "30", "forty": "40", "fifty": "50", "hundred": "100"] { table[word] = value }
        return table
    }()

    /// Words that say nothing about which task it is: grammar, what any task does ("complete", "handle"),
    /// and when.
    private static let ignored = Set("""
    a an the to for of and or in on at by with from into about as it its that this these those their there then than so
    be is are was were been will would can could should may might must do does did done i ll m s t d re ve we you your our my
    me us he she they them his her him who what which when where how
    complete completing finish handle address conduct perform manage make get take prepare work also just still all any each
    every both same up out off over before after until once per today tomorrow tonight morning afternoon evening week weeks
    month months day days year sprint end next last soon
    monday tuesday wednesday thursday friday saturday sunday january february march april may june july august september
    october november december
    """.split(whereSeparator: \.isWhitespace).map(String.init))
}
