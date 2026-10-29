import Foundation

/// Which live models a device uses (docs/models.md, "Live models"): per live role, the person's
/// choice, else the catalog's first runnable default for this platform and tier
/// (`ModelCatalog.liveSelection`). Live models are optional downloads; without them, live captions
/// use the system's speech recognizer as before, and never make a transcript either way.
public enum LiveModelChoices {
    /// The catalog's choices for `role` on `platform` and `tier`, best first. With `engines`, only
    /// those this build can run there.
    public static func defaults(for role: ModelRole, platform: ModelPlatform = .current, tier: DeviceTier = .current,
                                catalog: ModelCatalog = .builtIn, engines: [ModelEngineDescriptor]? = nil,
                                appVersion: ModelVersion? = ModelVersion.app) -> [String] {
        let keys = catalog.liveSelection?.choices(for: role, tier: tier.rawValue, platform: platform) ?? []
        return keys.filter { key in
            guard let model = catalog.model(key), model.serves(role) else { return false }
            guard let engines else { return true }
            return model.availability(engines: engines, appVersion: appVersion, platform: platform).isAvailable
        }
    }

    /// The model `role` uses: the stored selection when the catalog knows it for that role, else the
    /// first default. Nil when the catalog names nothing this build can run.
    public static func choice(for role: ModelRole, selections: ModelSelections, platform: ModelPlatform = .current,
                              tier: DeviceTier = .current, catalog: ModelCatalog = .builtIn,
                              engines: [ModelEngineDescriptor]? = nil, appVersion: ModelVersion? = ModelVersion.app) -> String? {
        if let stored = selections[role], let model = catalog.model(stored), model.serves(role) {
            if let engines, !model.availability(engines: engines, appVersion: appVersion, platform: platform).isAvailable {
                // A stored choice this build can't run falls through to the defaults.
            } else {
                return model.key
            }
        }
        return defaults(for: role, platform: platform, tier: tier, catalog: catalog, engines: engines, appVersion: appVersion).first
    }

    /// Fills each live role the selections don't name with its default, leaving every other role as
    /// it is: what a device starts with, so Settings shows the live models it would use.
    public static func addingDefaults(to selections: ModelSelections, platform: ModelPlatform = .current,
                                      tier: DeviceTier = .current, catalog: ModelCatalog = .builtIn,
                                      engines: [ModelEngineDescriptor]? = nil) -> ModelSelections {
        var result = selections
        for role in ModelRole.live where result[role] == nil {
            result[role] = defaults(for: role, platform: platform, tier: tier, catalog: catalog, engines: engines).first
        }
        return result
    }

    /// Whether this device has the memory a model suggests (`recommendedMemoryGB`), so a phone with
    /// too little never loads it during a recording.
    public static func fitsMemory(_ model: CatalogModel, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        // iPhones report a little less than their marketed memory (an 8 GB phone, about 7.5 GiB).
        Double(physicalMemory) / 1_073_741_824 + 0.75 >= Double(model.recommendedMemoryGB)
    }
}
