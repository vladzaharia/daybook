import DaybookCore
import Foundation

/// A model a provider's own list says the person's key can reach, as the provider describes it.
public struct CloudListedModel: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String?
    public var maxInputTokens: Int?
    public var maxOutputTokens: Int?
    /// The efforts the provider says it takes (Anthropic's capabilities); nil when it doesn't say.
    public var efforts: [String]?

    public init(id: String, displayName: String? = nil, maxInputTokens: Int? = nil, maxOutputTokens: Int? = nil, efforts: [String]? = nil) {
        self.id = id; self.displayName = displayName; self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens; self.efforts = efforts
    }
}

/// A cloud model Daybook offers: what the interface shares (`CloudModel`), and what a request and an
/// estimate need besides.
public struct CloudOffer: Equatable, Identifiable, Sendable {
    public var model: CloudModel
    public var id: String { model.id }
    public var price: CloudPrice?
    /// What the model takes of Low, Medium, and High, in that order.
    public var efforts: [CloudEffort]
    public var maxOutputTokens: Int
    public var structuredOutputs: Bool
    public var refusalFallback: Bool
    /// 0–100 on the local summary models' scale; nil when unmeasured (docs/cloud.md, "Summary quality").
    public var summaryQuality: Int?

    public init(model: CloudModel, price: CloudPrice?, efforts: [CloudEffort] = CloudEffort.allCases, maxOutputTokens: Int = 32_000,
                structuredOutputs: Bool = true, refusalFallback: Bool = false, summaryQuality: Int? = nil) {
        self.model = model; self.price = price; self.efforts = efforts; self.maxOutputTokens = maxOutputTokens
        self.structuredOutputs = structuredOutputs; self.refusalFallback = refusalFallback; self.summaryQuality = summaryQuality
    }

    /// `wanted`, or the nearest effort the model takes: medium, then high, then low.
    public func effort(_ wanted: CloudEffort) -> CloudEffort {
        if efforts.contains(wanted) { return wanted }
        return [.medium, .high, .low].first { efforts.contains($0) } ?? .medium
    }

    /// The estimated cost of summarizing `minutes` of conversation at `effort`, in USD; nil without a price.
    public func estimatedCost(minutes: Double, effort: CloudEffort, catalog: CloudCatalog = .builtIn) -> Double? {
        guard let price else { return nil }
        return price.cost(inputTokens: catalog.expectedInputTokens(provider: model.provider, minutes: minutes),
                          outputTokens: catalog.expectedOutputTokens(model.id, provider: model.provider, minutes: minutes, effort: self.effort(effort)))
    }
}

extension CloudCatalog {
    /// The models offered, from what each provider lists for the person's keys: a model the catalog measured,
    /// or a newer version of a known family (and a "-pro" variant of either), priced by `prices`. A newer
    /// version OpenRouter doesn't list takes its family's newest price, marked estimated; a model with no price
    /// either way isn't offered, nor is an older version of a family, or a dated snapshot when its alias is listed.
    /// In tier order (Best, Balanced, Economy), then rank: the catalog's, then newer versions first, then price.
    public func offers(listings: [CloudProvider: [CloudListedModel]], prices: CloudPriceBook) -> [CloudOffer] {
        var offers: [(offer: CloudOffer, version: [Int], measured: Bool)] = []
        for (provider, listed) in listings {
            let ids = Set(listed.map(\.id))
            for entry in listed {
                guard let name = name(entry.id, provider: provider) else { continue }
                if name.date != nil, ids.contains(name.alias) { continue }
                let known = model(entry.id, provider: provider) ?? (name.date != nil ? model(name.alias, provider: provider) : nil)
                let latest = latest(in: name.family)
                if known == nil, let latest {
                    let newer = Self.isNewer(name.version, than: latest.version)
                    let sameAsMeasured = name.version == latest.version && name.isPro
                    guard newer || sameAsMeasured else { continue }
                }
                let listing = prices[name.openRouterID]
                var price = listing?.price
                var estimated = false
                if price == nil, let latest, let latestName = self.name(latest.model.id, provider: provider) {
                    price = prices[latestName.openRouterID]?.price
                    estimated = price != nil
                }
                guard let price else { continue }
                let efforts = (entry.efforts ?? listing?.efforts).map { offered in CloudEffort.allCases.filter { offered.contains($0.rawValue) } }
                let model = CloudModel(provider: provider, id: entry.id, name: known?.name ?? listing?.name ?? name.displayName,
                                       tier: known?.tier ?? name.family.tier, inputPrice: price.input, outputPrice: price.output,
                                       priceIsEstimated: estimated, contextTokens: entry.maxInputTokens ?? listing?.contextLength,
                                       rank: known?.rank ?? 0)
                let offer = CloudOffer(model: model, price: price, efforts: efforts.flatMap { $0.isEmpty ? nil : $0 } ?? CloudEffort.allCases,
                                       maxOutputTokens: entry.maxOutputTokens ?? listing?.maxOutputTokens ?? 32_000,
                                       structuredOutputs: listing?.structuredOutputs ?? true, refusalFallback: known?.refusalFallback ?? false,
                                       summaryQuality: known?.summaryQuality)
                offers.append((offer, name.version, known != nil))
            }
        }
        // Unmeasured models rank after the measured ones in their tier: newer first, then the cheaper.
        var ranked: [CloudOffer] = []
        for tier in CloudTier.allCases {
            let inTier = offers.filter { $0.offer.model.tier == tier }
            let measured = inTier.filter(\.measured).map(\.offer).sorted { ($0.model.rank, $0.id) < ($1.model.rank, $1.id) }
            let others = inTier.filter { !$0.measured }.sorted { a, b in
                if a.version != b.version { return Self.isNewer(a.version, than: b.version) }
                let pa = a.offer.price?.input ?? 0, pb = b.offer.price?.input ?? 0
                return pa != pb ? pa < pb : a.offer.id < b.offer.id
            }.map(\.offer)
            let base = (measured.map(\.model.rank).max() ?? 0) + 1
            ranked += measured + others.enumerated().map { index, offer in
                var offer = offer
                offer.model.rank = base + index
                return offer
            }
        }
        return ranked
    }
}

extension Array where Element == CloudOffer {
    /// The tier's recommendation: its best-ranked model.
    public func recommended(_ tier: CloudTier) -> CloudOffer? {
        filter { $0.model.tier == tier }.min { $0.model.rank < $1.model.rank }
    }

    /// The model `preferences` choose: the chosen model while a key reaches it, else the tier's recommendation,
    /// else the nearest tier's (Balanced, then Economy, then Best). Nil when nothing is offered.
    public func resolve(_ preferences: CloudSummaryPreferences) -> CloudOffer? {
        if let id = preferences.model, let chosen = first(where: { $0.id == id }) { return chosen }
        let order = [preferences.tier] + [CloudTier.balanced, .economy, .best].filter { $0 != preferences.tier }
        return order.lazy.compactMap { recommended($0) }.first
    }

    public func offer(_ id: String, provider: CloudProvider? = nil) -> CloudOffer? {
        first { $0.id == id && (provider == nil || $0.model.provider == provider) }
    }
}

extension CloudSummaryPreferences {
    static let defaultsKey = "cloudSummaryPreferences"

    /// This device's preferences (never synced).
    public static func load(from defaults: UserDefaults) -> CloudSummaryPreferences {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(CloudSummaryPreferences.self, from: $0) } ?? CloudSummaryPreferences()
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}
