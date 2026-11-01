import DaybookCore
import Foundation

// "Upgrade" (docs/multipoint.md, "Upgrade"): when a clearly better model than the one that made a conversation's
// transcript, speakers, or summary is within reach (this device's own, a reachable Mac's, or, for summaries, the cloud
// model Settings › Cloud resolves to), the conversation page offers to redo that step there, and every step after it.
// The person can dismiss it. Every device works the offer out for itself from the synced provenance and what it can
// reach, so it shows wherever a better option is visible and goes everywhere once the work is done or dismissed.
// Pure: both apps ask it.

/// A step an upgrade redoes, in the pipeline's order. Redoing one redoes every later one: a better transcript means
/// speakers found again, voice profiles, fusion, and a new summary.
public enum UpgradeRole: String, CaseIterable, Comparable, Sendable {
    case transcription, diarization, summarization

    public var modelRole: ModelRole { ModelRole(rawValue) }

    /// What it improves, in the offer's words: "transcript", "speakers", "summary".
    public var noun: String {
        switch self {
        case .transcription: return "transcript"
        case .diarization: return "speakers"
        case .summarization: return "summary"
        }
    }

    /// How much higher the better model must rank (docs/models.md, "Quality ranks") to be offered: clearly better, a
    /// generation rather than a revision. Transcripts: Parakeet Redux (80) to Ultra (90) is offered, Whisper Large v3
    /// Turbo (85) to Ultra isn't. Speakers: Sortformer (79) to Nemotron 3 (89) is, Community-1 (85) to Nemotron 3 isn't.
    /// Summaries: Gemma 4 E4B (53) to 26B A4B (90) is, 26B A4B to the cloud's best (95) isn't, so a good local summary
    /// never nags toward the cloud.
    public var margin: Int {
        switch self {
        case .transcription: return 10
        case .diarization: return 10
        case .summarization: return 10
        }
    }

    /// The work that redoes it, with every step after it: Transcribe Everything Again, Identify Speakers Again, or
    /// Summarize Again.
    public var mode: ProcessingRequest.Mode {
        switch self {
        case .transcription: return .fullRetranscription
        case .diarization: return .speakerRefresh
        case .summarization: return .summaryOnly
        }
    }

    public static func < (a: UpgradeRole, b: UpgradeRole) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// How good each model is at each step, from the catalogs (data, never code): the model catalog's `quality` for a local
/// model, and the cloud catalog's `summaryQuality` for a cloud one, on one scale for summaries.
public struct UpgradeRanks: Sendable {
    public var catalog: ModelCatalog
    public var cloud: CloudCatalog

    public init(catalog: ModelCatalog = .builtIn, cloud: CloudCatalog = .builtIn) {
        self.catalog = catalog; self.cloud = cloud
    }

    public static let builtIn = UpgradeRanks()

    /// The rank of the model `key` names for `role` (a catalog key, a legacy ID, or "anthropic/claude-sonnet-5-5");
    /// nil when it's unknown or unranked, which offers nothing.
    public func quality(of key: String, for role: UpgradeRole) -> Int? {
        let id = ModelReference(key).id
        if role == .summarization, let cloud = cloudSummaryQuality(id) { return cloud }
        return catalog.model(id)?.quality(for: role.modelRole)
    }

    /// A cloud model's summary quality: its own, measured, else its family's newest measured model's (a newer version
    /// or a dated snapshot reads as the version measured). Nil for a model ID no family places.
    func cloudSummaryQuality(_ key: String) -> Int? {
        guard let (provider, id) = Self.cloudModel(key) else { return nil }
        if let measured = cloud.model(id, provider: provider)?.summaryQuality { return measured }
        guard let name = cloud.name(id, provider: provider) else { return nil }
        if let alias = cloud.model(name.alias, provider: provider)?.summaryQuality { return alias }
        return cloud.latest(in: name.family)?.model.summaryQuality
    }

    /// "anthropic/claude-sonnet-5-5" read as the provider and its model ID; nil for anything else.
    static func cloudModel(_ key: String) -> (CloudProvider, String)? {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let provider = CloudProvider(rawValue: parts[0]), !parts[1].isEmpty else { return nil }
        return (provider, parts[1])
    }

    /// Whether `key` names a cloud model.
    public static func isCloud(_ key: String) -> Bool { cloudModel(key) != nil }
}

/// What a device can reach for an upgrade now.
public struct UpgradeCandidates: Sendable {
    /// What this device runs with its own models (`ProcessingCapabilities.models`), whether or not it takes other
    /// devices' work.
    public var thisDevice: ProcessingCapabilities
    /// Whether this device redoes a conversation's recordings itself (its transcript and speakers): a Mac always; the
    /// iPhone only when every recording is its own (`OnDeviceProcessing`). Its summary goes through the placement either way.
    public var redoesRecordings: @Sendable (Meeting) -> Bool
    /// The Macs reachable now, with what they'd run (`ProcessingMac.reachable`), connected ones first.
    public var macs: [ProcessingMac]
    /// The cloud model Settings › Cloud resolves to, for summaries: nil without a key, or with Never.
    public var cloud: CloudModel?

    public init(thisDevice: ProcessingCapabilities, redoesRecordings: @escaping @Sendable (Meeting) -> Bool = { _ in true },
                macs: [ProcessingMac] = [], cloud: CloudModel? = nil) {
        self.thisDevice = thisDevice; self.redoesRecordings = redoesRecordings; self.macs = macs; self.cloud = cloud
    }
}

/// An offer to redo one step of a conversation with a better model.
public struct UpgradeOffer: Equatable, Sendable {
    /// Where the better model is.
    public enum Place: Equatable, Sendable {
        case thisDevice
        /// A reachable Mac, as requests name devices (its sync ID and name).
        case mac(ProcessingRequest.Device)
        case cloud(CloudModel)
    }

    public var role: UpgradeRole
    public var place: Place
    /// The better model: a catalog key, or "anthropic/claude-sonnet-5-5".
    public var model: String
    public var quality: Int
    /// The weakest model behind the step now (several recordings may have been made with different ones), and its rank.
    public var current: String
    public var currentQuality: Int

    public init(role: UpgradeRole, place: Place, model: String, quality: Int, current: String, currentQuality: Int) {
        self.role = role; self.place = place; self.model = model; self.quality = quality
        self.current = current; self.currentQuality = currentQuality
    }

    /// The page's words, the same on both apps: "Upgrade transcript" (this device does it), "Upgrade transcript on Studio
    /// Mac", "Upgrade summary with Claude Sonnet 5.5".
    public var line: String {
        let what = "Upgrade \(role.noun)"
        switch place {
        case .thisDevice: return what
        case .mac(let device): return "\(what) on \(device.name)"
        case .cloud(let model): return "\(what) with \(model.name)"
        }
    }

    /// What a request for it asks: the step, the model, and the device that has it (this one, or a Mac).
    public func request(by thisDevice: ProcessingRequest.Device) -> ProcessingRequest.Upgrade {
        let device: ProcessingRequest.Device?
        switch place {
        case .thisDevice: device = thisDevice
        case .mac(let mac): device = mac
        case .cloud: device = nil
        }
        return ProcessingRequest.Upgrade(role: role.rawValue, model: model, quality: quality, device: device)
    }
}

public enum Upgrades {
    /// The one offer a conversation's page makes now, or nil: only for a conversation with nothing working or waiting
    /// (`status` is done), for the most upstream step a clearly better model could redo (it redoes the rest anyway), and
    /// never for a step whose provenance is unknown, or an offer the person dismissed (nor any no better than it).
    public static func offer(for meeting: Meeting, status: ProcessingStatus, candidates: UpgradeCandidates,
                             ranks: UpgradeRanks = .builtIn) -> UpgradeOffer? {
        guard status == .done else { return nil }
        for role in UpgradeRole.allCases {
            if let offer = offer(role, for: meeting, candidates: candidates, ranks: ranks) { return offer }
        }
        return nil
    }

    /// The offer for one step, whatever the others: the best model within reach, when it clears the step's margin over
    /// the weakest model behind it now and isn't dismissed.
    public static func offer(_ role: UpgradeRole, for meeting: Meeting, candidates: UpgradeCandidates,
                             ranks: UpgradeRanks = .builtIn) -> UpgradeOffer? {
        guard let current = meeting.upgradeCurrent(role, ranks: ranks),
              let best = best(role, for: meeting, candidates: candidates, ranks: ranks),
              best.quality >= current.quality + role.margin,
              !meeting.dismissedUpgrade(role: role.rawValue, model: best.model, quality: best.quality) else { return nil }
        return UpgradeOffer(role: role, place: best.place, model: best.model, quality: best.quality,
                            current: current.model, currentQuality: current.quality)
    }

    /// The best model within reach for `role`, by rank: this device's, then each reachable Mac's in order, then (for
    /// summaries) the cloud's; on a tie the earlier one, so work stays nearest. A transcription model is a candidate only
    /// when it covers every recording's language as transcribed.
    static func best(_ role: UpgradeRole, for meeting: Meeting, candidates: UpgradeCandidates,
                     ranks: UpgradeRanks) -> (place: UpgradeOffer.Place, model: String, quality: Int)? {
        var options: [(place: UpgradeOffer.Place, model: String)] = []
        if role == .summarization || candidates.redoesRecordings(meeting), let model = runs(role, candidates.thisDevice) {
            options.append((.thisDevice, model))
        }
        for mac in candidates.macs {
            if let model = runs(role, mac.capabilities) { options.append((.mac(ProcessingRequest.Device(id: mac.id, name: mac.name)), model)) }
        }
        if role == .summarization, let cloud = candidates.cloud { options.append((.cloud(cloud), "\(cloud.provider.rawValue)/\(cloud.id)")) }
        var best: (place: UpgradeOffer.Place, model: String, quality: Int)?
        for option in options {
            guard let quality = ranks.quality(of: option.model, for: role), quality > (best?.quality ?? -1) else { continue }
            if role == .transcription, !covers(option.model, meeting: meeting, catalog: ranks.catalog) { continue }
            best = (option.place, option.model, quality)
        }
        return best
    }

    /// The model a device would use for `role`, when it can run that step.
    static func runs(_ role: UpgradeRole, _ capabilities: ProcessingCapabilities) -> String? {
        let can: Bool
        switch role {
        case .transcription: can = capabilities.transcribes
        case .diarization: can = capabilities.findsSpeakers
        case .summarization: can = capabilities.summarizes
        }
        guard can, let model = capabilities.models?[role.rawValue], !model.isEmpty else { return nil }
        return model
    }

    /// Whether a transcription model covers each recording's language as its latest transcript recorded it (a
    /// transcript Whisper made because Parakeet doesn't know its language stays Whisper's).
    static func covers(_ model: String, meeting: Meeting, catalog: ModelCatalog) -> Bool {
        let languages = catalog.model(ModelReference(model).id)?.capabilities.languages
        return meeting.latestTranscripts.allSatisfy { run in
            run.language.map { TranscriptionLanguages.covers(languages, $0) } ?? true
        }
    }
}

extension Meeting {
    /// Each recording's latest transcript.
    var latestTranscripts: [TrackTranscript] {
        transcribableTracks.compactMap { track in transcripts.filter { $0.trackID == track.id }.max { $0.createdAt < $1.createdAt } }
    }

    /// The model behind `role` now and its rank: for transcripts and speakers, the weakest of the recordings' (each
    /// recording's latest run, as `modelsBehindTranscript` reads them); for the summary, the model its provenance names.
    /// Nil when there's nothing yet, or any of them is unknown (no provenance, or a model the catalogs don't rank).
    public func upgradeCurrent(_ role: UpgradeRole, ranks: UpgradeRanks = .builtIn) -> (model: String, quality: Int)? {
        var keys: [String]
        switch role {
        case .transcription:
            keys = latestTranscripts.map { $0.processingSettings?.model?.variantKey ?? $0.modelID }
        case .diarization:
            // A run's speakers are named after it ("<run>:S1"); a run without speakers (nothing said) has none to compare.
            keys = latestTranscripts.flatMap { run in
                speakers.filter { $0.id.hasPrefix(run.id.uuidString) }.map { $0.analysisSettings.map { $0.model?.variantKey ?? $0.modelID } ?? "" }
            }
            if keys.isEmpty { return nil }
        case .summarization:
            guard let summary else { return nil }
            let settings = summary.processingSettings
            let key = summary.modelsByRole[role.rawValue] ?? settings?.model?.variantKey ?? (settings?.modelID).flatMap { $0.isEmpty ? nil : $0 }
                ?? summary.modelID
            keys = [key]
        }
        var weakest: (model: String, quality: Int)?
        for key in keys {
            guard !key.isEmpty, let quality = ranks.quality(of: key, for: role) else { return nil }
            if quality < (weakest?.quality ?? .max) { weakest = (key, quality) }
        }
        return weakest
    }
}

extension ProcessingRequest.Upgrade {
    /// The step it redoes.
    public var step: UpgradeRole? { UpgradeRole(rawValue: role) }

    /// While it waits for the device with the better model: "Waiting for Studio Mac to upgrade the transcript".
    public var waitingLine: String {
        "Waiting for \(device?.name ?? "your Mac") to upgrade the \(step?.noun ?? "conversation")"
    }

    /// Whether `device` may carry it out: it's the device asked, or its own model for the step (`models`, as its
    /// capabilities name them) is at least as good, so the upgrade still happens if the device asked is gone.
    public func mayBeCarriedOut(by device: ProcessingRequest.Device, models: [String: String]?, ranks: UpgradeRanks = .builtIn) -> Bool {
        if self.device?.id == device.id { return true }
        guard let step, let model = models?[role], let quality = ranks.quality(of: model, for: step) else { return false }
        return quality >= self.quality
    }
}

extension LibraryController {
    /// The person dismissed `offer`: it syncs with the conversation, so the offer goes on every device. A later, better
    /// model may offer again.
    public func dismissUpgrade(_ offer: UpgradeOffer, in id: UUID, at now: Date = Date()) {
        update(id) { $0.dismissUpgrade(role: offer.role.rawValue, model: offer.model, quality: offer.quality, at: now) }
    }

    /// Asks the device with the better model to redo the step, and every step after it: a request (Transcribe Everything
    /// Again, Identify Speakers Again, or Summarize Again) naming the step, the model, and the device, which that device
    /// (or one with a model at least as good) claims and carries out. An open request for the same upgrade is returned
    /// instead of a second one. The cloud's isn't a request: the device the person accepted it on runs it.
    @discardableResult
    public func requestUpgrade(_ offer: UpgradeOffer, in id: UUID, at now: Date = Date()) -> ProcessingRequest? {
        guard let meeting = meeting(id) else { return nil }
        if case .cloud = offer.place { return nil }
        let upgrade = offer.request(by: thisDevice)
        if let open = meeting.openProcessingRequests.first(where: { $0.mode == offer.role.mode && $0.upgrade == upgrade }) { return open }
        let request = ProcessingRequest(meetingID: id, mode: offer.role.mode, requestedBy: thisDevice, createdAt: now, upgrade: upgrade)
        update(id) { $0.upsertProcessingRequest(request) }
        return request
    }
}
