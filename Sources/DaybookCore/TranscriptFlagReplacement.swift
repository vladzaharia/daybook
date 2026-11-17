import Foundation

// Taking a flag's alternative reading (`TranscriptFlagMark.replacing(in:)`): the passage with the earlier reading in
// place of the flagged words, or the words taken out, and the text around them left well formed: no doubled
// punctuation, no empty brackets, a sentence still starting with a capital.

extension TranscriptFlagMark {
    /// The passage with the alternative reading in place of the flagged words. Nil without an alternative, when the
    /// passage doesn't hold the words there any more, or when nothing would be left of it.
    public func replacing(in text: String) -> String? {
        guard let alternative = alternativeWords,
              let range = Range(NSRange(location: range.lowerBound, length: range.count), in: text) else { return nil }
        let flagged = String(text[range])
        var before = String(text[..<range.lowerBound]), after = String(text[range.upperBound...])
        // A symbol that belongs to the flagged words and sits against them ("$" of "$20", "%" of "20%") goes with them
        // when the earlier reading already has it ("$20", or "twenty percent" for "%"); else it stays with its number.
        while let last = before.last, Self.belongsToWord(last), Self.carries(alternative, last) { before.removeLast() }
        while let first = after.first, Self.belongsToWord(first), Self.carries(alternative, first) { after.removeFirst() }
        // The flagged words began a sentence, with a capital: whatever now begins it gets one too.
        let capitalises = flagged.first(where: \.isLetter)?.isUppercase == true && Self.endsSentence(before)
        guard alternative.isEmpty else {
            var words = Self.respelled(alternative, over: flagged, atSentenceStart: Self.endsSentence(before))
            if capitalises { words = Self.capitalised(words) }
            return before + words + after
        }
        let joined = Self.takenOut(before: before, after: after, capitalises: capitalises)
        return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : joined
    }

    /// Whether a sentence ends where `text` does (or `text` is empty).
    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace }) else { return true }
        return ".?!…".contains(last)
    }

    /// A symbol that is part of how a number or word is written, not punctuation round it: currency, "%", "°", and the like.
    static func belongsToWord(_ character: Character) -> Bool {
        "%‰°#&+@±×".contains(character)
            || character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .currencySymbol }
    }

    /// The words that say a symbol aloud, as an earlier reading may write them instead of it.
    private static let spoken: [Character: Set<String>] = [
        "%": ["percent", "percentage"], "‰": ["permille"], "°": ["degree", "degrees"], "¢": ["cent", "cents"],
        "$": ["dollar", "dollars", "usd"], "€": ["euro", "euros", "eur"], "£": ["pound", "pounds", "gbp"], "¥": ["yen", "jpy"],
    ]

    /// Whether `reading` already says `symbol`: it holds it, or the word for it.
    private static func carries(_ reading: String, _ symbol: Character) -> Bool {
        reading.contains(symbol) || reading.split(whereSeparator: \.isWhitespace).contains { spoken[symbol]?.contains(TranscriptFlags.wordKey($0)) == true }
    }

    /// `reading` without the sentence punctuation, quotes, and brackets at its ends (the passage keeps its own) and the
    /// spaces round it; the symbols that belong to its words stay ("$20", "20%"). Empty where it has no words.
    static func edgesTrimmed(_ reading: String) -> String {
        var trimmed = Substring(reading)
        func strips(_ character: Character) -> Bool { character.isWhitespace || ((character.isPunctuation || character.isSymbol) && !belongsToWord(character)) }
        while let first = trimmed.first, strips(first) { trimmed.removeFirst() }
        while let last = trimmed.last, strips(last) { trimmed.removeLast() }
        return TranscriptFlags.core(of: trimmed) == nil ? "" : String(trimmed)
    }

    private static func capitalised(_ text: String) -> String {
        guard let index = text.firstIndex(where: \.isLetter), text[index].isLowercase else { return text }
        return text.replacingCharacters(in: index...index, with: text[index].uppercased())
    }

    /// The alternative's words, each that the flagged words also hold written as the passage writes it (its case and
    /// spelling are the passage's own, not the earlier transcript's). A word that began the sentence keeps the earlier
    /// reading's writing when it no longer does, where its capital was only the sentence's.
    private static func respelled(_ alternative: String, over flagged: String, atSentenceStart: Bool) -> String {
        let own = flagged.split(whereSeparator: \.isWhitespace).map(String.init)
        var next = 0
        let pieces = alternative.split(whereSeparator: \.isWhitespace).enumerated().map { position, piece -> String in
            let key = TranscriptFlags.wordKey(piece)
            guard !key.isEmpty, let match = own.indices.dropFirst(next).first(where: { TranscriptFlags.wordKey(own[$0]) == key }),
                  let core = TranscriptFlags.core(of: own[match]), let inner = TranscriptFlags.core(of: piece) else { return String(piece) }
            next = match + 1
            if match == 0 && atSentenceStart && position != 0 { return String(piece) }
            return String(piece[..<inner.lowerBound]) + own[match][core] + String(piece[inner.upperBound...])
        }
        return pieces.joined(separator: " ")
    }

    private static let openers = Set("([{“‘«\"")
    private static let closers = Set(")]}”’»\"")

    private static func isMark(_ character: Character) -> Bool { character.isPunctuation || character.isSymbol }

    /// How much a mark holds a sentence together when two meet: opening and closing marks and the ends of sentences
    /// stay, a comma goes first.
    private static func weight(_ character: Character) -> Int {
        if openers.contains(character) || closers.contains(character) { return 100 }
        if ".?!…".contains(character) { return 80 }
        if ";:".contains(character) { return 60 }
        if "—–-".contains(character) { return 50 }
        if character == "," { return 40 }
        return 30
    }

    /// `before` and `after` joined where words were taken out between them: the marks the words carried on either side
    /// become one (or none), brackets and quotes round them go with them, and nothing dangles at either end.
    private static func takenOut(before: String, after: String, capitalises: Bool) -> String {
        var before = before, after = after
        while before.last?.isWhitespace == true { before.removeLast() }
        while after.first?.isWhitespace == true { after.removeFirst() }
        var lead = String(before.reversed().prefix(while: isMark).reversed()), trail = String(after.prefix(while: isMark))
        if let opener = lead.last, let closer = trail.first, openers.contains(opener), closers.contains(closer),
           opener == "\"" ? closer == "\"" : pair(opener) == closer {
            // "(really)" and "“really”": nothing is left to hold.
            before.removeLast(); after.removeFirst()
            lead.removeLast(); trail.removeFirst()
        }
        var mark = ""
        switch (lead.last, trail.first) {
        case (nil, nil): break
        case let (last?, nil): mark = openers.contains(last) || weight(last) >= 80 ? lead : ""
        case let (nil, first?): mark = weight(first) >= 80 ? trail : ""
        case let (last?, first?): mark = openers.contains(last) || weight(first) <= weight(last) ? lead : trail
        }
        let left = String(before.dropLast(lead.count)), right = String(after.dropFirst(trail.count))
        let leftIsEmpty = left.allSatisfy(\.isWhitespace), rightIsEmpty = right.allSatisfy(\.isWhitespace)
        // Nothing dangles: a comma or dash with nothing after it, a mark that opens nothing at the start of the text.
        if let last = mark.last, !openers.contains(last), leftIsEmpty || (weight(last) < 80 && rightIsEmpty) { mark = "" }
        else if rightIsEmpty, let last = mark.last, openers.contains(last) { mark = "" }
        let next = capitalises ? capitalised(right.trimmingCharacters(in: .whitespaces)) : right.trimmingCharacters(in: .whitespaces)
        if mark.isEmpty {
            let kept = left.trimmingCharacters(in: .whitespaces)
            return kept + (kept.isEmpty || next.isEmpty ? "" : " ") + next
        }
        // Spaced as it was: "Okay — fine" stays, "Okay—fine" stays.
        let spaced = trail.isEmpty || right.first?.isWhitespace == true
        return left + mark + (spaced && !next.isEmpty && !openers.contains(mark.last!) ? " " : "") + next
    }

    private static func pair(_ opener: Character) -> Character {
        switch opener {
        case "(": return ")"
        case "[": return "]"
        case "{": return "}"
        case "“": return "”"
        case "‘": return "’"
        case "«": return "»"
        default: return opener
        }
    }
}
