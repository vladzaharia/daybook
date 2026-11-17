import Foundation

// How two recognizers write the same words ("OK" and "okay", "20" and "twenty", "Dr." and "Doctor", "3rd" and "third",
// an "uh" one heard and the other left out) so a difference of writing is not a disagreement about what was said.
// Only English is known here, and only where a run says it is English: the rules are word lists, and a word such as
// "um" is a filler in English and an article in Portuguese. For any other language, or none, the words are left as they
// are (`TranscriptFlags.flags(for:)`).

enum TranscriptWordStyle {
    /// Whether `language` (a transcript's, as its recognizer reported it) is English.
    static func isEnglish(_ language: String?) -> Bool {
        guard let language = language?.lowercased(), !language.isEmpty else { return false }
        return language == "en" || language == "english" || language.hasPrefix("en-") || language.hasPrefix("en_")
    }

    /// Whether two runs of one recording are in English: at least one says so and neither says it is another language.
    static func isEnglish(_ a: TrackTranscript, _ b: TrackTranscript) -> Bool {
        let languages = [a.language, b.language].compactMap { $0 }.filter { !$0.isEmpty }
        return !languages.isEmpty && languages.allSatisfy { isEnglish($0) }
    }

    private static let fillers: Set<String> = ["uh", "um", "uhm", "umm", "uhh", "er", "erm", "hmm", "hm", "mm", "mhm", "mmhmm"]

    static func isFiller(_ key: String) -> Bool { fillers.contains(key) }

    private static let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                                "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let ordinals = ["zeroth", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth",
                                   "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth",
                                   "seventeenth", "eighteenth", "nineteenth"]
    private static let tensOrdinals = ["twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth"]

    /// Number words and ordinals as digits: "twenty" and "20" are one key, so are "third" and "3rd" and "3".
    private static let numbers: [String: String] = {
        var table: [String: String] = [:]
        for (value, word) in units.enumerated() { table[word] = String(value) }
        for (value, word) in ordinals.enumerated() { table[word] = String(value) }
        for (index, word) in tens.enumerated() { table[word] = String((index + 2) * 10) }
        for (index, word) in tensOrdinals.enumerated() { table[word] = String((index + 2) * 10) }
        return table
    }()

    private static let abbreviations = ["dr": "doctor", "mr": "mister", "mrs": "missus", "vs": "versus", "prof": "professor",
                                        "etc": "etcetera", "jr": "junior", "sr": "senior", "ok": "okay"]

    /// A tens word and a units word that read as one number when said one after the other ("twenty" "one" is 21).
    static func joins(_ tens: String, _ unit: String) -> String? {
        guard let ten = Self.tens.firstIndex(of: tens), let digit = Self.units.firstIndex(of: unit), (1...9).contains(digit) else { return nil }
        return String((ten + 2) * 10 + digit)
    }

    /// A word's key as the two runs are compared: written one way whatever the recognizer chose. English only.
    static func key(_ key: String) -> String {
        if let number = numbers[key] { return number }
        if let abbreviation = abbreviations[key] { return abbreviation }
        // "3rd", "21st": the digits.
        for suffix in ["st", "nd", "rd", "th"] where key.hasSuffix(suffix) {
            let digits = key.dropLast(2)
            if !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) { return String(digits) }
        }
        // "twentyone" (written "twenty-one"), "twentyfirst".
        for ten in tens where key.hasPrefix(ten) && key.count > ten.count {
            let rest = String(key.dropFirst(ten.count))
            if let value = joins(ten, rest) { return value }
            if let ordinal = ordinals.firstIndex(of: rest), (1...9).contains(ordinal), let base = joins(ten, units[ordinal]) { return base }
        }
        return key
    }
}
