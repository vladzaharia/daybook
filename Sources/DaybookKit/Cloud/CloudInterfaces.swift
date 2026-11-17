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

/// How much a cloud model reasons before it writes, lowest first: the providers' `output_config.effort` (Anthropic) and
/// `reasoning.effort` (OpenAI) values. Not every model takes every level (`CloudOffer.efforts`).
public enum CloudEffort: String, Codable, CaseIterable, Comparable, Sendable {
    case low, medium, high, xhigh, max

    /// What summaries ask for unless the person chooses otherwise: Extra High, or the highest below it the model takes
    /// (`CloudOffer.effort`).
    public static let summaryDefault: CloudEffort = .xhigh
    /// What a model is taken to accept when neither its provider nor OpenRouter says: the levels every reasoning model
    /// of both providers takes.
    public static let assumed: [CloudEffort] = [.low, .medium, .high]

    public static func < (a: CloudEffort, b: CloudEffort) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

/// Which conversations may be summarized in the cloud, by where they're filed: a switch for each placement (Work,
/// Personal) in Settings › Cloud, part of this device's preferences. Personal is off and every other placement on until
/// the person changes them, as before there were switches. A conversation not filed yet (its kind isn't known until a
/// summary finds it, and the person hasn't placed it) follows Work's switch, as it followed Always before. A placement a
/// newer Daybook wrote, which this version can't read, never goes: what the person chose for it is unknown here.
public struct CloudPlacements: Codable, Equatable, Sendable {
    /// Each placement's switch, by its raw value; one not stored has its default.
    public var allowed: [String: Bool]

    public init(allowed: [String: Bool] = [:]) { self.allowed = allowed }

    /// Personal off, the rest on.
    public static func allowsByDefault(_ placement: LibraryPlacement) -> Bool { placement != .personal }

    public func allows(_ placement: LibraryPlacement) -> Bool { allowed[placement.rawValue] ?? Self.allowsByDefault(placement) }

    public mutating func set(_ placement: LibraryPlacement, allowed: Bool) { self.allowed[placement.rawValue] = allowed }

    /// Whether `meeting` may be summarized in the cloud: its placement's switch (`Meeting.effectivePlacement`), Work's for
    /// one not filed yet, and never for a placement this version doesn't know.
    public func allows(_ meeting: Meeting) -> Bool {
        guard meeting.$placement.isKnown else { return false }
        return allows(meeting.effectivePlacement ?? .work)
    }

    public init(from decoder: Decoder) throws {
        allowed = (try? decoder.singleValueContainer().decode([String: Bool].self)) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(allowed)
    }
}

/// How the person wants summaries placed (Settings).
public struct CloudSummaryPreferences: Codable, Equatable, Sendable {
    public enum Policy: String, Codable, Sendable { case ask, always, never }
    public var policy: Policy = .ask
    public var countdownSeconds: Int = 15            // 15 or 30
    public var tier: CloudTier = .balanced
    public var model: CloudModel.ID?                 // nil: the tier's recommendation
    /// The effort summaries ask for: `CloudEffort.summaryDefault` until the person chooses one (`effortIsChosen`).
    public var effort: CloudEffort = CloudEffort.summaryDefault
    /// The person chose `effort` in Settings; until then it follows the default, which a later version may raise.
    public var effortIsChosen = false
    /// Which conversations may go to the cloud, by placement.
    public var placements = CloudPlacements()
    public init() {}

    /// Whether `meeting` may be summarized in the cloud on this device: the policy isn't Never, and its placement's switch
    /// is on. A key, and a model it reaches, are the rest (`CloudSetup.resolved`).
    public func allowsCloud(for meeting: Meeting) -> Bool { policy != .never && placements.allows(meeting) }

    /// Chooses an effort in Settings: it stays until the person changes it.
    public mutating func choose(_ effort: CloudEffort) {
        self.effort = effort
        effortIsChosen = true
    }

    private enum CodingKeys: String, CodingKey { case policy, countdownSeconds, tier, model, effort, effortIsChosen, placements }

    /// Each field on its own, so preferences from an earlier version keep what they set. Those have no `effortIsChosen`:
    /// their effort was Medium unless the person changed it, and an explicit Medium can't be told from the old default, so
    /// Medium moves to the new default and Low or High stays.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        policy = (try? values.decodeIfPresent(Policy.self, forKey: .policy)) ?? .ask
        countdownSeconds = (try? values.decodeIfPresent(Int.self, forKey: .countdownSeconds)) ?? 15
        tier = (try? values.decodeIfPresent(CloudTier.self, forKey: .tier)) ?? .balanced
        model = (try? values.decodeIfPresent(String.self, forKey: .model)) ?? nil
        let stored = (try? values.decodeIfPresent(CloudEffort.self, forKey: .effort)) ?? nil
        if let chosen = (try? values.decodeIfPresent(Bool.self, forKey: .effortIsChosen)) ?? nil {
            effortIsChosen = chosen && stored != nil
        } else {
            effortIsChosen = stored != nil && stored != .medium
        }
        effort = effortIsChosen ? stored ?? CloudEffort.summaryDefault : CloudEffort.summaryDefault
        placements = (try? values.decodeIfPresent(CloudPlacements.self, forKey: .placements)) ?? CloudPlacements()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(policy, forKey: .policy)
        try values.encode(countdownSeconds, forKey: .countdownSeconds)
        try values.encode(tier, forKey: .tier)
        try values.encodeIfPresent(model, forKey: .model)
        try values.encode(effort, forKey: .effort)
        try values.encode(effortIsChosen, forKey: .effortIsChosen)
        try values.encode(placements, forKey: .placements)
    }
}

/// Why a summary went to the cloud, as its provenance records it (`cloudReason`).
public enum CloudReason: String, Codable, Equatable, Sendable {
    /// The person chose it: Use the Cloud, or an Upgrade to the cloud's model.
    case chosen
    /// Settings › Cloud says Always.
    case always
    /// Longer than the local model reads in one pass, and the cloud's model ranks clearly better
    /// (`LongConversations.cloudDoesBetter`); under Offer First, after its countdown.
    case longConversation
    /// The summary on the device failed, and the cloud was tried before giving up.
    case localFailed
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
