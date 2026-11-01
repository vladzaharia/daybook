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
    public private(set) var keys: [CloudProvider: String] = [:]
    public private(set) var checks: [CloudProvider: Check] = [:]
    public private(set) var offers: [CloudOffer] = []
    public private(set) var isRefreshing = false
    public var preferences: CloudSummaryPreferences {
        didSet { if preferences != oldValue { preferences.save(to: defaults) } }
    }

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
        try? store.removeKey(for: provider)
        checks[provider] = nil
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
    /// `providers` and their lists from the bundled snapshot. It never reaches a provider.
    public static func demo(providers: [CloudProvider], preferences: CloudSummaryPreferences = .init(), defaults: UserDefaults,
                            check: [CloudProvider: Check] = [:]) async -> CloudSetup {
        let store = MemoryCloudKeyStore(Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
            CloudAPIKey(provider == .anthropic ? "sk-ant-api03-demoDEMOdemoDEMOdemo-gDAA" : "sk-proj-demoDEMOdemoDEMOdemoDEMO-x9Qa").map { (provider, $0) }
        }))
        defaults.removeObject(forKey: CloudDirectory.listingsKey)
        defaults.removeObject(forKey: CloudDirectory.pricesKey)
        preferences.save(to: defaults)
        let setup = CloudSetup(keys: store, client: CloudClient(endpoints: CloudEndpoints(base: URL(string: "https://invalid.invalid")!)), defaults: defaults)
        setup.fetches = false
        for provider in providers {
            await setup.directory.seed(CloudCatalog.builtIn.models.filter { $0.provider == provider }.map {
                CloudListedModel(id: $0.id, displayName: $0.name)
            }, for: provider)
        }
        setup.checks = check
        await setup.refresh()
        return setup
    }
}

extension CloudDirectory {
    /// Keeps `models` as the provider's list, as a fetch would: for demos.
    public func seed(_ models: [CloudListedModel], for provider: CloudProvider) {
        remember(models, for: provider)
    }
}
