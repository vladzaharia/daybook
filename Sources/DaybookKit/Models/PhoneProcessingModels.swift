import Foundation

/// How much processing an iPhone takes on, from its memory (docs/models.md, "iPhone processing"). The
/// catalog's `initialSelection` lists an iPhone's processing models per tier (`platformTiers`, under
/// "iOS"); a Mac's tiers (`DeviceTier`) put every iPhone in `compact`.
public enum PhoneTier: String, CaseIterable, Codable, Sendable {
    /// 4 GB: iPhone 11 to 13.
    case small
    /// 6 GB: iPhone 12 Pro to 15.
    case medium
    /// 8 GB: iPhone 15 Pro, 16, and 17.
    case standard
    /// 12 GB and more: iPhone 17 Pro and Air, 18 Pro, and Duo.
    case large

    /// iPhones report a little less than their marketed memory (an 8 GB phone, about 7.5 GiB).
    public init(physicalMemory: UInt64) {
        let gib = Double(physicalMemory) / 1_073_741_824
        switch gib {
        case ..<4.5: self = .small
        case ..<6.5: self = .medium
        case ..<9.5: self = .standard
        default: self = .large
        }
    }

    public static var current: PhoneTier { PhoneTier(physicalMemory: ProcessInfo.processInfo.physicalMemory) }
}

/// The models an iPhone processes its own recordings with (docs/models.md, "iPhone processing"): per
/// role, the person's choice, else the catalog's first runnable default for the iPhone's tier
/// (`initialSelection`'s iOS lists). Summaries also need the model to fit in the memory iOS lets the
/// app use (`fits`). The live roles are `LiveModelChoices`' and stay separate.
public enum PhoneProcessingModels {
    /// The roles an iPhone processes with, in the order Settings lists them.
    public static let roles: [ModelRole] = [.transcription, .diarization, .speakerEmbedding, .summarization]

    /// Room the app itself needs beside a model's peak: its own memory, audio buffers, and the
    /// language model's buffer cache (256 MB).
    public static let headroomGB = 1.0

    /// The catalog's choices for `role` on an iPhone of `tier`, best first. With `engines`, only those
    /// this build can run on an iPhone.
    public static func defaults(for role: ModelRole, tier: PhoneTier, catalog: ModelCatalog = .builtIn,
                                engines: [ModelEngineDescriptor]? = nil, appVersion: ModelVersion? = ModelVersion.app) -> [String] {
        let keys = catalog.initialSelection?.choices(for: role, platform: .iOS, platformTier: tier.rawValue) ?? []
        return runnable(keys, role: role, catalog: catalog, engines: engines, appVersion: appVersion)
    }

    /// Every model the catalog lists for `role` on any iPhone, best first: what Settings offers.
    public static func options(for role: ModelRole, catalog: ModelCatalog = .builtIn, engines: [ModelEngineDescriptor]? = nil,
                               appVersion: ModelVersion? = ModelVersion.app) -> [String] {
        var keys: [String] = []
        for tier in PhoneTier.allCases.reversed() {
            for key in catalog.initialSelection?.choices(for: role, platform: .iOS, platformTier: tier.rawValue) ?? [] where !keys.contains(key) {
                keys.append(key)
            }
        }
        return runnable(keys, role: role, catalog: catalog, engines: engines, appVersion: appVersion)
    }

    /// The model `role` uses on this iPhone: the stored choice when the catalog knows it for that role
    /// and this build can run it, else the first default. A summary model also has to fit in
    /// `memoryLimit` (bytes), the most iOS lets the app use; nil when nothing fits.
    public static func choice(for role: ModelRole, selections: ModelSelections, tier: PhoneTier, memoryLimit: UInt64,
                              catalog: ModelCatalog = .builtIn, engines: [ModelEngineDescriptor]? = nil,
                              appVersion: ModelVersion? = ModelVersion.app) -> String? {
        func usable(_ key: String) -> Bool {
            guard let model = catalog.model(key), model.serves(role) else { return false }
            if let engines, !model.availability(engines: engines, appVersion: appVersion, platform: .iOS).isAvailable { return false }
            return role != .summarization || fits(model, memoryLimit: memoryLimit)
        }
        if let stored = selections[role], let key = catalog.model(stored)?.key, usable(key) { return key }
        return defaults(for: role, tier: tier, catalog: catalog, engines: engines, appVersion: appVersion).first(where: usable)
    }

    /// Whether `model` runs within `memoryLimit` bytes: its measured peak (`capabilities.memoryGB`,
    /// else its download), with `headroomGB` for the app.
    public static func fits(_ model: CatalogModel, memoryLimit: UInt64) -> Bool {
        let peak = model.capabilities.memoryGB ?? Double(model.approximateBytes) / 1e9
        return (peak + headroomGB) * 1e9 <= Double(memoryLimit)
    }

    private static func runnable(_ keys: [String], role: ModelRole, catalog: ModelCatalog, engines: [ModelEngineDescriptor]?,
                                 appVersion: ModelVersion?) -> [String] {
        keys.compactMap { key in
            guard let model = catalog.model(key), model.serves(role) else { return nil }
            if let engines, !model.availability(engines: engines, appVersion: appVersion, platform: .iOS).isAvailable { return nil }
            return model.key
        }
    }
}

/// The most memory iOS lets one app use before it ends it: what a local summary has to fit in. On a
/// device the app reads it as it runs (`os_proc_available_memory` plus what it uses already); this is
/// the estimate for when it can't (the simulator, tests, Settings before anything is measured).
public enum AppMemoryLimit {
    /// A little under half the phone's memory, and about seven tenths with the Increased Memory Limit
    /// entitlement (`com.apple.developer.kernel.increased-memory-limit`), from published figures; a
    /// device's own reading replaces it.
    public static func estimate(physicalMemory: UInt64, increasedLimit: Bool) -> UInt64 {
        UInt64(Double(physicalMemory) * (increasedLimit ? 0.7 : 0.45))
    }
}
