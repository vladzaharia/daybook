import DaybookCore
import Foundation

/// What Daybook knows about cloud models before asking anyone (docs/cloud.md, "The catalog"): the family
/// rules that place a model ID in a tier, and, for the models measured on our own prompt, their rank within
/// the tier, a summary quality on the scale the local summary models use, and how many tokens they write.
/// Prices aren't here: they come from OpenRouter's list (`CloudPriceBook`), with a bundled snapshot when
/// it can't be reached. The built-in catalog is `Resources/CloudCatalog.json`.
public struct CloudCatalog: Codable, Equatable, Sendable {
    /// What a provider's tokenizer and replies measure on our prompt.
    public struct Provider: Codable, Equatable, Sendable {
        public var name: String
        /// Tokens of transcript per minute of conversation.
        public var inputTokensPerMinute: Double
        /// For estimating a prompt's tokens without the provider's tokenizer.
        public var charactersPerToken: Double
        /// Characters of reply per output token (reasoning included), for progress while a reply streams.
        public var visibleCharactersPerOutputToken: Double
        /// For a model with no measurements of its own or its family's: tokens written per minute of conversation.
        public var outputTokensPerMinute: Double
    }

    /// A family of model IDs: `prefix` + a version + `suffix` ("claude-sonnet-" "5-5", "gpt-" "6.1" "-sol"),
    /// optionally a "-pro" variant and a dated snapshot. A model that matches no family isn't offered.
    public struct Family: Codable, Equatable, Sendable {
        public var provider: CloudProvider
        public var prefix: String
        public var suffix: String
        public var tier: CloudTier
        /// "Claude Sonnet {version}": the name of a model the catalog doesn't list.
        public var name: String

        public var key: String { "\(provider.rawValue):\(prefix)*\(suffix)" }
    }

    /// A model measured on our prompt (docs/validation.md, 2026-10-31).
    public struct Model: Codable, Equatable, Sendable {
        public var provider: CloudProvider
        public var id: String
        public var name: String
        public var tier: CloudTier
        /// Lower is better, within the tier: measured quality, then price.
        public var rank: Int
        /// 0–100, on the scale the local summary models use (docs/cloud.md, "Summary quality"); nil when unmeasured.
        public var summaryQuality: Int?
        /// Anthropic's server-side fallback on a refusal (`fallbacks: "default"`).
        public var refusalFallback: Bool?
        /// Output tokens (reasoning included) for a conversation of so many minutes, at medium effort:
        /// `[[minutes, tokens], …]`, in order.
        public var outputTokens: [[Double]]?
        /// Output at low and high effort, against medium, measured on an hour.
        public var effortScale: [String: Double]?
    }

    public var version: Int
    public var measured: String
    public var providers: [String: Provider]
    public var families: [Family]
    public var models: [Model]
    /// Our prompt's own characters, without the conversation: instructions, rules, and the notes check.
    public var promptCharacters: Double?

    public static let builtIn: CloudCatalog = {
        guard let url = Bundle.module.url(forResource: "CloudCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(CloudCatalog.self, from: data) else {
            assertionFailure("The built-in cloud catalog couldn't be read.")
            return CloudCatalog(version: 0, measured: "", providers: [:], families: [], models: [])
        }
        return catalog
    }()

    public func provider(_ provider: CloudProvider) -> Provider {
        providers[provider.rawValue] ?? Provider(name: provider.rawValue.capitalized, inputTokensPerMinute: 300, charactersPerToken: 3,
                                                   visibleCharactersPerOutputToken: 3, outputTokensPerMinute: 150)
    }

    public func model(_ id: String, provider: CloudProvider) -> Model? {
        models.first { $0.provider == provider && $0.id == id }
    }

    // MARK: Names

    /// A model ID read by the family rules.
    public struct Name: Equatable, Sendable {
        public var family: Family
        /// "5-5" → [5, 5]; "6.1" → [6, 1].
        public var version: [Int]
        public var isPro: Bool
        /// A dated snapshot's date ("20251001", "2026-09-29"); nil for an alias.
        public var date: String?

        /// The ID without its date: what a dated snapshot is a snapshot of.
        public var alias: String {
            let separator = family.provider == .anthropic ? "-" : "."
            return family.prefix + version.map(String.init).joined(separator: separator) + family.suffix + (isPro ? "-pro" : "")
        }

        /// OpenRouter's ID for it: "anthropic/claude-sonnet-5.5", "openai/gpt-6.1-sol".
        public var openRouterID: String {
            "\(family.provider.rawValue)/\(family.prefix)\(version.map(String.init).joined(separator: "."))\(family.suffix)\(isPro ? "-pro" : "")"
        }

        /// "Claude Sonnet 5.5", "GPT-6.1 Sol Pro".
        public var displayName: String {
            family.name.replacingOccurrences(of: "{version}", with: version.map(String.init).joined(separator: ".")) + (isPro ? " Pro" : "")
        }
    }

    /// The family `id` belongs to, with its version; nil when no family rule matches (not offered).
    public func name(_ id: String, provider: CloudProvider) -> Name? {
        guard !id.contains(":") else { return nil }   // OpenRouter's ":batch" and the like
        var rest = id
        var date: String?
        if let range = rest.range(of: #"-(\d{8}|\d{4}-\d{2}-\d{2})$"#, options: .regularExpression) {
            date = String(rest[range].dropFirst())
            rest.removeSubrange(range)
        }
        for family in families where family.provider == provider && rest.hasPrefix(family.prefix) {
            var middle = String(rest.dropFirst(family.prefix.count))
            var isPro = false
            if middle.hasSuffix(family.suffix + "-pro") {
                isPro = true
                middle.removeLast(family.suffix.count + 4)
            } else if family.suffix.isEmpty || middle.hasSuffix(family.suffix) {
                middle.removeLast(family.suffix.count)
            } else {
                continue
            }
            guard let version = Self.version(middle) else { continue }
            return Name(family: family, version: version, isPro: isPro, date: date)
        }
        return nil
    }

    /// "5-5" or "6.1" as numbers; nil for anything else ("mini", "4o", a date).
    static func version(_ text: String) -> [Int]? {
        let parts = text.split(omittingEmptySubsequences: false) { $0 == "." || $0 == "-" }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        return numbers.count == parts.count ? numbers : nil
    }

    static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The newest version the catalog lists in `family` (its "-pro" variants aside), and that model.
    func latest(in family: Family) -> (version: [Int], model: Model)? {
        models.compactMap { model -> ([Int], Model)? in
            guard let name = name(model.id, provider: model.provider), name.family == family, !name.isPro else { return nil }
            return (name.version, model)
        }.max { Self.isNewer($1.0, than: $0.0) }.map { (version: $0.0, model: $0.1) }
    }

    // MARK: Estimates

    /// The measurements that stand for `id`: its own, else its family's newest model's.
    func measurement(for id: String, provider: CloudProvider) -> Model? {
        if let model = model(id, provider: provider), model.outputTokens != nil { return model }
        guard let name = name(id, provider: provider), let latest = latest(in: name.family), latest.model.outputTokens != nil else { return nil }
        return latest.model
    }

    /// How many tokens `id` is expected to write (reasoning included) for a conversation of `minutes` at `effort`:
    /// between measured lengths, in proportion; shorter, along the shortest stretch; longer, at the longest
    /// conversation's rate per minute.
    public func expectedOutputTokens(_ id: String, provider: CloudProvider, minutes: Double, effort: CloudEffort) -> Int {
        let minutes = max(0, minutes)
        let tokens: Double
        if let measured = measurement(for: id, provider: provider), let points = measured.outputTokens?.filter({ $0.count == 2 }), points.count >= 2 {
            if let last = points.last, minutes > last[0] {
                tokens = last[1] * minutes / max(1, last[0])
            } else {
                let upper = max(1, points.firstIndex { $0[0] >= minutes } ?? 1), lower = upper - 1
                let (x0, y0, x1, y1) = (points[lower][0], points[lower][1], points[upper][0], points[upper][1])
                tokens = x1 == x0 ? y1 : y0 + (y1 - y0) * (minutes - x0) / (x1 - x0)
            }
            let scale = effort == .medium ? 1 : measured.effortScale?[effort.rawValue] ?? (effort == .high ? 1.6 : 0.9)
            return max(500, Int((tokens * scale).rounded()))
        }
        let scale = effort == .high ? 1.6 : effort == .low ? 0.9 : 1
        return max(500, Int((self.provider(provider).outputTokensPerMinute * minutes * scale).rounded()))
    }

    /// The prompt's tokens for a conversation of `minutes`: the transcript and our instructions.
    public func expectedInputTokens(provider: CloudProvider, minutes: Double) -> Int {
        let measured = self.provider(provider)
        return Int((measured.inputTokensPerMinute * max(0, minutes) + (promptCharacters ?? 7_000) / measured.charactersPerToken).rounded())
    }

    /// A text's tokens, estimated from its length.
    public func estimatedTokens(_ text: String, provider: CloudProvider) -> Int {
        Int((Double(text.count) / self.provider(provider).charactersPerToken).rounded(.up))
    }
}
