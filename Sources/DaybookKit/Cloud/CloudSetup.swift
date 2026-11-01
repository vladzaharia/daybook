import DaybookCore
import Foundation
import Observation

/// Settings › Cloud on both apps (docs/cloud.md, "Settings"): each provider's key (added after a check, replaced,
/// removed), the models the keys reach, and this device's preferences: tier, Recommended or a model, effort, when
/// to use the cloud, and the countdown. Preferences are this device's own (UserDefaults, never synced); keys are in
/// iCloud Keychain (`KeychainCloudKeyStore`).
@MainActor
@Observable
public final class CloudSetup {
    /// What checking a key came to.
    public enum Check: Equatable, Sendable {
        case checking
        case works
        case failed(message: String, details: String)
    }

    /// Each provider's key, masked, for the providers that have one.
    public private(set) var keys: [CloudProvider: String] = [:] {
        didSet { if keys != oldValue { onChange?() } }
    }
    public private(set) var checks: [CloudProvider: Check] = [:]
    public private(set) var offers: [CloudOffer] = [] {
        didSet { if offers != oldValue { onChange?() } }
    }
    public private(set) var isRefreshing = false
    /// This device's preferences, and the one place they're read and written (UserDefaults, `cloudSummaryPreferences`).
    public var preferences: CloudSummaryPreferences {
        didSet {
            guard preferences != oldValue else { return }
            preferences.save(to: defaults)
            onChange?()
        }
    }
    /// What a summary may use changed: a key, the models offered, or the preferences. Each app's summary placement
    /// follows it, so a countdown reacts at once (docs/multipoint.md, "Where summaries run").
    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored public let directory: CloudDirectory
    @ObservationIgnored private let store: any CloudKeyStore
    @ObservationIgnored private let defaults: UserDefaults
    /// Off for the Settings demos, which must never reach a provider: refreshing only reads what's kept.
    @ObservationIgnored public var fetches = true

    public init(keys: any CloudKeyStore = KeychainCloudKeyStore.system, client: CloudClient = CloudClient(), defaults: UserDefaults = .standard,
                catalog: CloudCatalog = .builtIn) {
        store = keys
        self.defaults = defaults
        directory = CloudDirectory(catalog: catalog, keys: keys, client: client, defaults: defaults)
        preferences = CloudSummaryPreferences.load(from: defaults)
        reloadKeys()
    }

    /// Whether any key is set: until then, nothing about the cloud is offered.
    public var isSetUp: Bool { !keys.isEmpty }

    /// Asks the providers and OpenRouter again (when Settings opens, or on request).
    public func refresh() async {
        reloadKeys()
        guard isSetUp else { offers = []; return }
        isRefreshing = true
        offers = fetches ? await directory.offers(refresh: true) : await directory.currentOffers()
        isRefreshing = false
    }

    /// Reads the keys again, and the models kept for them, before a summary is placed. No provider is asked, except
    /// once for a key this device has never listed (one added on another device, which iCloud Keychain brought here).
    public func reload() async {
        reloadKeys()
        guard isSetUp else {
            if !offers.isEmpty { offers = [] }
            return
        }
        var unlisted = false
        for provider in CloudProvider.allCases where keys[provider] != nil {
            if await directory.listing(provider) == nil { unlisted = true }
        }
        let current = fetches && unlisted ? await directory.offers() : await directory.currentOffers()
        if current != offers { offers = current }
    }

    /// Checks `text` as a key with the provider's model list and keeps it only when the provider accepts it.
    @discardableResult
    public func addKey(_ text: String, for provider: CloudProvider) async -> Bool {
        guard let key = CloudAPIKey(text) else {
            checks[provider] = .failed(message: "Paste the whole key, with nothing around it.", details: "")
            return false
        }
        checks[provider] = .checking
        do {
            if fetches { _ = try await directory.check(key, for: provider) }
            try store.store(key, for: provider)
        } catch let error as CloudError {
            checks[provider] = .failed(message: error.message, details: error.details)
            return false
        } catch {
            checks[provider] = .failed(message: "The keychain couldn’t keep the key.", details: error.localizedDescription)
            return false
        }
        checks[provider] = .works
        reloadKeys()
        offers = fetches ? await directory.offers() : await directory.currentOffers()
        return true
    }

    public func removeKey(for provider: CloudProvider) async {
        do {
            try store.removeKey(for: provider)
            checks[provider] = nil
        } catch {
            checks[provider] = .failed(message: "The keychain couldn’t remove the key.", details: error.localizedDescription)
        }
        reloadKeys()
        await directory.forget(provider)
        offers = await directory.currentOffers()
    }

    /// Forgets a check's outcome (the key field was edited, or the sheet closed).
    public func clearCheck(for provider: CloudProvider) {
        if checks[provider] != .checking { checks[provider] = nil }
    }

    public func offers(in tier: CloudTier) -> [CloudOffer] { offers.filter { $0.model.tier == tier } }

    /// The model the preferences resolve to now.
    public var resolved: CloudOffer? { isSetUp ? offers.resolve(preferences) : nil }

    /// The chosen model, while a key reaches it; nil for Recommended.
    public var chosenModel: CloudModel.ID? {
        get { preferences.model.flatMap { id in offers.contains { $0.id == id } ? id : nil } }
        set { preferences.model = newValue }
    }

    /// Choosing a tier goes back to its recommendation.
    public func choose(_ tier: CloudTier) {
        preferences.tier = tier
        preferences.model = nil
    }

    /// The estimated cost of an hour of conversation with `offer`, at the preferred effort.
    public func costPerHour(_ offer: CloudOffer) -> Double? {
        offer.estimatedCost(minutes: 60, effort: preferences.effort, catalog: directory.catalog)
    }

    /// The efforts the resolved model takes.
    public var efforts: [CloudEffort] { resolved?.efforts ?? CloudEffort.allCases }

    private func reloadKeys() {
        var masked: [CloudProvider: String] = [:]
        for provider in CloudProvider.allCases {
            if let key = (try? store.key(for: provider)) ?? nil { masked[provider] = key.masked }
        }
        if masked != keys { keys = masked }
    }

    /// A line for Settings' list: "Claude Sonnet 5.5", "Never", or "Off" with no key.
    public var summary: String {
        guard isSetUp else { return "Off" }
        if preferences.policy == .never { return "Never" }
        return resolved?.model.name ?? "No models"
    }
}

extension CloudSetup {
    /// Settings as it looks with keys and models, for screenshots and previews: an in-memory key per provider in
    /// `providers`, their lists from the catalog, and the bundled prices. It never reaches a provider or the keychain.
    public static func demo(providers: [CloudProvider], preferences: CloudSummaryPreferences = .init(), defaults: UserDefaults,
                            checks: [CloudProvider: Check] = [:]) -> CloudSetup {
        let store = MemoryCloudKeyStore(Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
            CloudAPIKey(provider == .anthropic ? "sk-ant-api03-demoDEMOdemoDEMOdemo-gDAA" : "sk-proj-demoDEMOdemoDEMOdemoDEMO-x9Qa").map { (provider, $0) }
        }))
        let listings = Dictionary(uniqueKeysWithValues: providers.map { provider in
            (provider.rawValue, CloudDirectory.Listing(fetchedAt: Date(), models: CloudCatalog.builtIn.models.filter { $0.provider == provider }.map {
                CloudListedModel(id: $0.id, displayName: $0.name)
            }))
        })
        defaults.set(try? JSONEncoder().encode(listings), forKey: CloudDirectory.listingsKey)
        defaults.removeObject(forKey: CloudDirectory.pricesKey)
        preferences.save(to: defaults)
        let setup = CloudSetup(keys: store, client: CloudClient(endpoints: CloudEndpoints(base: URL(string: "https://invalid.invalid")!)), defaults: defaults)
        setup.fetches = false
        setup.checks = checks
        setup.offers = CloudCatalog.builtIn.offers(listings: listings.reduce(into: [:]) { result, entry in
            if let provider = CloudProvider(rawValue: entry.key) { result[provider] = entry.value.models }
        }, prices: .snapshot)
        return setup
    }
}
