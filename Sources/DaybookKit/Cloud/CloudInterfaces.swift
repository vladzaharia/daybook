import DaybookCore
import Foundation

/// A cloud provider the person can add a key for.
public enum CloudProvider: String, Codable, CaseIterable, Sendable { case anthropic, openai }

/// How capable and costly a cloud model is, for people: chosen by tier, mapped to models.
public enum CloudTier: String, Codable, CaseIterable, Sendable { case best, balanced, economy }

/// A cloud model the person's keys can reach, with what the catalog knows about it.
public struct CloudModel: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var provider: CloudProvider
    public var id: String                    // the provider's model ID, e.g. "claude-sonnet-5-5"
    public var name: String                  // "Claude Sonnet 5.5"
    public var tier: CloudTier
    public var inputPrice: Double?           // USD per 1M input tokens; nil if unknown
    public var outputPrice: Double?
    public var priceIsEstimated: Bool
    public var contextTokens: Int?
    public var rank: Int                     // lower is better within a tier
    public init(provider: CloudProvider, id: String, name: String, tier: CloudTier, inputPrice: Double?, outputPrice: Double?,
                priceIsEstimated: Bool, contextTokens: Int?, rank: Int) {
        self.provider = provider; self.id = id; self.name = name; self.tier = tier; self.inputPrice = inputPrice
        self.outputPrice = outputPrice; self.priceIsEstimated = priceIsEstimated; self.contextTokens = contextTokens; self.rank = rank
    }
}

public enum CloudEffort: String, Codable, CaseIterable, Sendable { case low, medium, high }

/// How the person wants summaries placed (Settings).
public struct CloudSummaryPreferences: Codable, Equatable, Sendable {
    public enum Policy: String, Codable, Sendable { case ask, always, never }
    public var policy: Policy = .ask
    public var countdownSeconds: Int = 15            // 15 or 30
    public var tier: CloudTier = .balanced
    public var model: CloudModel.ID?                 // nil: the tier's recommendation
    public var effort: CloudEffort = .medium
    public init() {}
}

/// Where one conversation's summary will run.
public enum SummaryPlace: Equatable, Sendable {
    case thisDevice
    case mac(id: UUID, name: String)
    case cloud(CloudModel)
}

/// What a device can offer when a summary is due (`SummaryPlacementPlanner` decides from it).
public struct SummaryOptions: Equatable, Sendable {
    public var thisDeviceCanSummarize: Bool
    public var reachableMacs: [(id: UUID, name: String)]   // Macs that can summarize, reachable now
    public var cloud: CloudModel?                       // the model the preferences resolve to, if a key is set
    public init(thisDeviceCanSummarize: Bool, reachableMacs: [(id: UUID, name: String)], cloud: CloudModel?) {
        self.thisDeviceCanSummarize = thisDeviceCanSummarize; self.reachableMacs = reachableMacs; self.cloud = cloud
    }
    public static func == (a: SummaryOptions, b: SummaryOptions) -> Bool {
        a.thisDeviceCanSummarize == b.thisDeviceCanSummarize && a.cloud == b.cloud
            && a.reachableMacs.map(\.id) == b.reachableMacs.map(\.id)
    }
}

/// What a device can do with its own models, for the planner and for other devices (a Mac
/// advertises it over the link and in presence; the iPhone works out its own).
public struct ProcessingCapabilities: Codable, Equatable, Sendable {
    public var transcribes: Bool
    public var findsSpeakers: Bool
    public var summarizes: Bool
    /// The model this device would use for each role it can run (`ModelRole.rawValue` → catalog key), so
    /// another device can tell whether it would do better ("Upgrade" offers). Nil from older builds.
    public var models: [String: String]?
    public init(transcribes: Bool, findsSpeakers: Bool, summarizes: Bool, models: [String: String]? = nil) {
        self.transcribes = transcribes; self.findsSpeakers = findsSpeakers; self.summarizes = summarizes; self.models = models
    }
}

/// Summarizes one conversation with a cloud model. Implemented by the cloud stream; the placement
/// stream calls it through this protocol (and tests use a fake).
public protocol CloudSummarizing: Sendable {
    func availableModels(refresh: Bool) async -> [CloudModel]
    func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String], model: CloudModel,
                   effort: CloudEffort, progress: @escaping @Sendable (Double) -> Void) async throws -> MeetingSummary
}
