import DaybookCore
import Foundation

/// Where a cloud summary came from (docs/cloud.md, "Provenance"), as its `ProcessingSettings` record it: the model's
/// provenance names the provider (family) and the provider's model ID (variant), with engine "cloud", so
/// `variantKey` and the summary's `modelID` read "anthropic/claude-sonnet-5-5"; the parameters keep the effort,
/// the tokens in and out, the estimated cost in USD, and the device that sent it.
public struct CloudProvenance: Equatable, Sendable {
    public static let engine = "cloud"

    public var provider: CloudProvider
    /// The provider's model ID: "claude-sonnet-5-5".
    public var model: String
    /// "Claude Sonnet 5.5".
    public var name: String
    public var effort: CloudEffort
    public var inputTokens: Int
    public var outputTokens: Int
    /// In USD, from the price in force; nil when the model had no price.
    public var estimatedCost: Double?
    public var priceIsEstimated: Bool
    /// The device that sent the conversation: "Vlad's MacBook Pro".
    public var sentBy: String?

    public init(provider: CloudProvider, model: String, name: String, effort: CloudEffort, inputTokens: Int, outputTokens: Int,
                estimatedCost: Double?, priceIsEstimated: Bool = false, sentBy: String? = nil) {
        self.provider = provider; self.model = model; self.name = name; self.effort = effort; self.inputTokens = inputTokens
        self.outputTokens = outputTokens; self.estimatedCost = estimatedCost; self.priceIsEstimated = priceIsEstimated; self.sentBy = sentBy
    }

    /// "anthropic/claude-sonnet-5-5": the summary's `modelID`.
    public var modelID: String { "\(provider.rawValue)/\(model)" }

    public var modelProvenance: ModelProvenance {
        ModelProvenance(family: provider.rawValue, variant: model, revision: "", engine: Self.engine,
                        engineVersion: provider == .anthropic ? "Messages API \(CloudClient.anthropicVersion)" : "Responses API", name: name)
    }

    public var parameters: [String: String] {
        var values = ["cloudProvider": provider.rawValue, "cloudModel": model, "effort": effort.rawValue,
                      "inputTokens": String(inputTokens), "outputTokens": String(outputTokens)]
        if let estimatedCost { values["estimatedCostUSD"] = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), estimatedCost) }
        if priceIsEstimated { values["priceIsEstimated"] = "true" }
        if let sentBy { values["sentBy"] = sentBy }
        return values
    }

    /// The cloud provenance a summary's settings record; nil for a summary made on a device.
    public init?(_ settings: ProcessingSettings?) {
        guard let settings, let model = settings.model, model.engine == Self.engine, let provider = CloudProvider(rawValue: model.family) else { return nil }
        let parameters = settings.parameters
        self.init(provider: provider, model: model.variant, name: model.name ?? model.variant,
                  effort: parameters["effort"].flatMap(CloudEffort.init(rawValue:)) ?? .medium,
                  inputTokens: parameters["inputTokens"].flatMap(Int.init) ?? 0, outputTokens: parameters["outputTokens"].flatMap(Int.init) ?? 0,
                  estimatedCost: parameters["estimatedCostUSD"].flatMap(Double.init), priceIsEstimated: parameters["priceIsEstimated"] == "true",
                  sentBy: parameters["sentBy"])
    }

    /// "Summarized with Claude Sonnet 5.5".
    public var label: String { "Summarized with \(name)" }
}

extension MeetingSummary {
    /// Where this summary was made, when it was a cloud model.
    public var cloudProvenance: CloudProvenance? { CloudProvenance(processingSettings) }
}

/// Dollar amounts for estimates: "$0.09", "under $0.01".
public enum CloudCost {
    public static func format(_ dollars: Double) -> String {
        if dollars < 0.005 { return "under $0.01" }
        if dollars < 10 { return String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), dollars) }
        return String(format: "$%.0f", locale: Locale(identifier: "en_US_POSIX"), dollars)
    }

    /// "About $0.09 an hour", "Under $0.01 an hour".
    public static func perHour(_ dollars: Double?) -> String? {
        guard let dollars else { return nil }
        let amount = format(dollars)
        return amount.hasPrefix("under") ? "Under \(amount.dropFirst(6)) an hour" : "About \(amount) an hour"
    }
}
