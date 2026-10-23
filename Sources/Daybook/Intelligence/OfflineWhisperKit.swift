import Foundation
import NaturalLanguage
import WhisperKit
import Hub
import Tokenizers

/// WhisperKit's default tokenizer loader may fall back to a network download even
/// when `download: false`. This override only reads the explicitly installed files.
final class OfflineWhisperKit: WhisperKit {
    override func loadTokenizerIfNeeded() async throws {
        guard tokenizer == nil else { return }
        guard let folder = tokenizerFolder, let logits = textDecoder.logitsSize else {
            throw LocalIntelligenceError.invalidTokenizer("model metadata")
        }
        // 51,864 is Whisper's English-only vocabulary. The catalog currently
        // ships multilingual vocabularies (51,865, or 51,866 for large v3).
        textDecoder.isModelMultilingual = logits != 51_864
        let local = try await AutoTokenizer.from(modelFolder: folder, hubApi: HubApi(useOfflineMode: true))
        tokenizer = try OfflineWhisperTokenizer(local)
    }
}

/// An adapter around swift-transformers' local tokenizer. The required special
/// tokens come from the installed vocabulary rather than guessed model offsets.
private final class OfflineWhisperTokenizer: WhisperTokenizer {
    let tokenizer: any Tokenizer
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(_ tokenizer: any Tokenizer) throws {
        self.tokenizer = tokenizer
        func required(_ token: String) throws -> Int {
            guard let value = tokenizer.convertTokenToId(token) else {
                throw LocalIntelligenceError.invalidTokenizer(token)
            }
            return value
        }
        specialTokens = try SpecialTokens(
            endToken: required("<|endoftext|>"), englishToken: required("<|en|>"),
            noSpeechToken: required("<|nospeech|>"), noTimestampsToken: required("<|notimestamps|>"),
            specialTokenBegin: required("<|endoftext|>"), startOfPreviousToken: required("<|startofprev|>"),
            startOfTranscriptToken: required("<|startoftranscript|>"), timeTokenBegin: required("<|0.00|>"),
            transcribeToken: required("<|transcribe|>"), translateToken: required("<|translate|>"),
            whitespaceToken: tokenizer.encode(text: " ").first ?? 220)
        allLanguageTokens = Set(Constants.languages.values.compactMap { tokenizer.convertTokenToId("<|\($0)|>") })
    }

    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(decode(tokens: tokenIds.filter { $0 < specialTokens.specialTokenBegin }))
        let noSpaces = ["zh", "ja", "th", "lo", "my", "yue"].contains(recognizer.dominantLanguage?.rawValue ?? "")
        var words: [String] = [], groups: [[Int]] = [], pending: [Int] = []
        for token in tokenIds {
            pending.append(token)
            let piece = decode(tokens: pending)
            // BPE may split a Unicode scalar over multiple tokens. Wait until it
            // decodes to a complete scalar before assigning a word boundary.
            if piece.contains("\u{fffd}") && pending.count < 8 { continue }
            let punctuation = !piece.trimmingCharacters(in: .whitespaces).isEmpty &&
                piece.trimmingCharacters(in: .whitespaces).unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
            let special = pending.first.map { $0 >= specialTokens.specialTokenBegin } ?? false
            if noSpaces || special || piece.first?.isWhitespace == true || punctuation || words.isEmpty {
                words.append(piece); groups.append(pending)
            } else {
                words[words.count - 1] += piece; groups[groups.count - 1] += pending
            }
            pending = []
        }
        if !pending.isEmpty { words.append(decode(tokens: pending)); groups.append(pending) }
        return (words, groups)
    }
}
