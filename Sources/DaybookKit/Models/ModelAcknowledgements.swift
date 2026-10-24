import Foundation

/// One line of Settings › About › Acknowledgements: a model family under one license.
public struct ModelAcknowledgement: Identifiable, Equatable, Sendable {
    /// "qwen2.5|Qwen-Research"
    public var id: String
    /// "Qwen 2.5"
    public var title: String
    public var maker: String?
    /// The variants covered: "Qwen 2.5 · 1.5B", "Qwen 2.5 · 7B".
    public var models: [String]
    public var licenseName: String
    public var licenseURL: String
    /// The credit the license requires, verbatim from the manifest.
    public var attribution: String?
    public var allowsCommercialUse: Bool
    /// True for models the person added.
    public var addedByYou: Bool

    /// "Non-commercial" where the terms don't allow commercial use.
    public var label: String? { allowsCommercialUse ? nil : "Non-commercial" }
}

/// Builds the acknowledgements list from the manifests, so a new model's credit appears with its entry.
public enum ModelAcknowledgements {
    /// One entry per family and license, alphabetical by family. `only` limits it to some variant keys
    /// (for example, the installed ones); nil lists every model in the catalog.
    public static func list(from catalog: ModelCatalog, only keys: Set<String>? = nil) -> [ModelAcknowledgement] {
        var entries: [ModelAcknowledgement] = []
        for model in catalog.models where keys?.contains(model.key) ?? true {
            let license = model.license ?? ModelLicense(name: "License not stated", url: model.homepage ?? "", allowsCommercialUse: false)
            let id = "\(model.familyID)|\(license.id ?? license.name)"
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].models.append(model.name)
                entries[index].addedByYou = entries[index].addedByYou && model.origin == .addedByYou
            } else {
                entries.append(ModelAcknowledgement(
                    id: id, title: model.familyName, maker: model.maker, models: [model.name], licenseName: license.name,
                    licenseURL: license.url, attribution: license.attribution, allowsCommercialUse: license.allowsCommercialUse,
                    addedByYou: model.origin == .addedByYou))
            }
        }
        // Stable, so a family's licenses keep catalog order.
        return entries.enumerated().sorted { a, b in
            let order = a.element.title.localizedCaseInsensitiveCompare(b.element.title)
            return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
        }.map(\.element)
    }

    /// The list as plain text, for an About window or a notices file.
    public static func text(from catalog: ModelCatalog, only keys: Set<String>? = nil) -> String {
        list(from: catalog, only: keys).map { entry in
            var lines = ["\(entry.title) — \(entry.models.joined(separator: ", "))",
                         "\(entry.licenseName)\(entry.label.map { " (\($0))" } ?? ""): \(entry.licenseURL)"]
            if let attribution = entry.attribution { lines.append(attribution) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
