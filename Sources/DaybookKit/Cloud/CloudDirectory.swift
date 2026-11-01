import DaybookCore
import Foundation

/// Which cloud models the person's keys reach, and what they cost (docs/cloud.md, "Discovery"). Each provider's
/// list is asked for with its key and kept with the time it was fetched, until Settings opens or a refresh is
/// asked for; OpenRouter's prices are fetched once there's a key and kept for a day, over the bundled snapshot.
/// Nothing is fetched while no key is set, and a provider's list goes when its key does.
public actor CloudDirectory {
    /// One provider's list, as last fetched.
    public struct Listing: Codable, Equatable, Sendable {
        public var fetchedAt: Date
        public var models: [CloudListedModel]
    }

    public nonisolated let catalog: CloudCatalog
    public nonisolated let keys: any CloudKeyStore
    public nonisolated let client: CloudClient
    private nonisolated(unsafe) let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var listings: [CloudProvider: Listing]
    private var livePrices: CloudPriceBook?
    /// How long OpenRouter's prices are kept.
    static let priceLifetime: TimeInterval = 24 * 60 * 60
    static let listingsKey = "cloudModelListings"
    static let pricesKey = "cloudModelPrices"

    public init(catalog: CloudCatalog = .builtIn, keys: any CloudKeyStore, client: CloudClient = CloudClient(),
                defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.catalog = catalog
        self.keys = keys
        self.client = client
        self.defaults = defaults
        self.now = now
        listings = (defaults.data(forKey: Self.listingsKey).flatMap { try? JSONDecoder().decode([String: Listing].self, from: $0) } ?? [:])
            .reduce(into: [:]) { result, entry in if let provider = CloudProvider(rawValue: entry.key) { result[provider] = entry.value } }
        livePrices = defaults.data(forKey: Self.pricesKey).flatMap { try? JSONDecoder().decode(CloudPriceBook.self, from: $0) }
    }

    /// The models offered now (`CloudCatalog.offers`). With `refresh`, or for a provider never listed, each provider
    /// with a key is asked again first; a list that can't be fetched keeps the last one.
    public func offers(refresh: Bool = false) async -> [CloudOffer] {
        let providers = keys.providersWithKeys()
        for provider in CloudProvider.allCases where !providers.contains(provider) && listings[provider] != nil { forget(provider) }
        guard !providers.isEmpty else { return [] }
        for provider in providers where refresh || listings[provider] == nil {
            guard let key = try? keys.key(for: provider) else { continue }
            if let models = try? await client.models(provider, key: key) { remember(models, for: provider) }
        }
        await refreshPrices(force: refresh)
        return currentOffers()
    }

    /// The offers from what's kept, without asking anyone.
    public func currentOffers() -> [CloudOffer] {
        let providers = Set(keys.providersWithKeys())
        return catalog.offers(listings: listings.filter { providers.contains($0.key) }.mapValues(\.models), prices: prices)
    }

    /// The model `preferences` resolve to (`Array.resolve`).
    public func resolve(_ preferences: CloudSummaryPreferences, refresh: Bool = false) async -> CloudOffer? {
        await offers(refresh: refresh).resolve(preferences)
    }

    /// Checks `key` with the provider's model list, which it then keeps: "This key works", or why not. The key
    /// isn't stored here.
    public func check(_ key: CloudAPIKey, for provider: CloudProvider) async throws -> [CloudListedModel] {
        let models = try await client.models(provider, key: key)
        remember(models, for: provider)
        return models
    }

    /// Drops a provider's list (its key is gone).
    public func forget(_ provider: CloudProvider) {
        listings[provider] = nil
        save()
    }

    public func listing(_ provider: CloudProvider) -> Listing? { listings[provider] }

    /// OpenRouter's prices over the bundled snapshot.
    public var prices: CloudPriceBook { livePrices.map { $0.merged(over: .snapshot) } ?? .snapshot }

    /// Fetches OpenRouter's list when there's a key and the last is over a day old (or `force`). A failure keeps
    /// what there was.
    public func refreshPrices(force: Bool = false) async {
        guard !keys.providersWithKeys().isEmpty else { return }
        if !force, let fetched = livePrices?.fetchedAt, now().timeIntervalSince(fetched) < Self.priceLifetime { return }
        guard let book = try? await client.openRouterPrices(fetchedAt: now()), !book.models.isEmpty else { return }
        livePrices = book
        defaults.set(try? JSONEncoder().encode(book), forKey: Self.pricesKey)
    }

    func remember(_ models: [CloudListedModel], for provider: CloudProvider) {
        listings[provider] = Listing(fetchedAt: now(), models: models)
        save()
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: listings.map { ($0.key.rawValue, $0.value) })
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.listingsKey)
    }
}
