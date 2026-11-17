import DaybookCore
import Foundation

/// How much of a conversation one pass of a local summary model may read (docs/model-runtime.md, "Summarization"):
/// the catalog's per-model limits (engine options), each under what the model's usable window holds. A limit the
/// catalog doesn't set follows the window alone, so a model is given as much as fits.
///
/// The built-in summary models keep the sizes they were measured at as their limits. The only comparison of longer
/// reads (Gemma 4 26B A4B, docs/validation.md, 2026-10-31) found them worse: the weekly read whole, commitments in
/// one pass, lost a topic and kept 31 of its 38 commitments against 36 in parts of 5,400 tokens, and the three-hour
/// meeting's commitments in two parts of 24,000 tokens kept 60 of 66 against all 66. No other model was measured
/// above these sizes, so each keeps them until it is.
public struct SummaryReadLimits: Equatable, Sendable {
    /// The longest conversation the final pass reads whole (`wholeReadTokens`).
    public var wholeRead: Int?
    /// The most one extraction pass reads of a longer conversation (`partTokens`).
    public var part: Int?
    /// The most evidence the final pass reads (`evidenceTokens`).
    public var evidence: Int?
    /// The most one commitments pass reads (`commitmentPartTokens`).
    public var commitmentPart: Int?

    public init(wholeRead: Int? = nil, part: Int? = nil, evidence: Int? = nil, commitmentPart: Int? = nil) {
        self.wholeRead = wholeRead; self.part = part; self.evidence = evidence; self.commitmentPart = commitmentPart
    }

    /// From a variant's engine options: "wholeReadTokens", "partTokens", "evidenceTokens", "commitmentPartTokens".
    public init(engineOptions: [String: String]) {
        func value(_ key: String) -> Int? { engineOptions[key].flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil } }
        self.init(wholeRead: value("wholeReadTokens"), part: value("partTokens"), evidence: value("evidenceTokens"),
                  commitmentPart: value("commitmentPartTokens"))
    }

    /// The most any pass may write with a known window: 16,384 tokens, or less where the catalog says (`outputTokens`).
    public static let defaultOutput = 16_384
    /// Room in a pass's prompt for everything but what it reads: the instructions, the prompt's own words, the
    /// template's instructions, the vocabulary, and the notes that travel with every part. A pass is checked exactly
    /// against the window before it runs; this only sizes what it reads.
    public static let promptAllowance = 4_096

    /// What one pass may read in a window of `window` tokens: the window less room for its reply (a quarter of the
    /// window, at most `output`) and for its instructions (`promptAllowance`). Never negative.
    public static func room(window: Int, output: Int = defaultOutput) -> Int {
        max(0, window - min(output, window / 4) - promptAllowance)
    }

    /// The longest conversation read whole in a window of `window` tokens under these limits.
    public func wholeRead(window: Int, output: Int = SummaryReadLimits.defaultOutput) -> Int {
        let room = Self.room(window: window, output: output)
        return min(wholeRead ?? room, room)
    }
}

extension CatalogModel {
    /// What one pass of this model may read (`SummaryReadLimits`).
    public var summaryReadLimits: SummaryReadLimits { SummaryReadLimits(engineOptions: engineOptions) }
}
