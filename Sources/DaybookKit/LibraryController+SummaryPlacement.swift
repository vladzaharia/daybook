import DaybookCore
import Foundation

// One summary per conversation, wherever it runs (docs/multipoint.md, "Where summaries run"). A device that
// summarizes a conversation another device might summarize too holds a claim on a request for it, through
// the request and claim mechanism every Mac already respects: the claim keeps Macs off it, the merge keeps
// the newest claim when two devices claim at once, and whoever sees it lost stands down. A summary records
// where it ran and the models behind it.

extension Meeting {
    /// Another device working on this conversation now: it holds a live claim on an open request, and every
    /// request ends with a summary. Nil when nobody else does.
    public func summaryHolder(excluding deviceID: String, at now: Date = Date(),
                              observations: ClaimObservations = .shared) -> ProcessingRequest.Device? {
        openProcessingRequests.lazy.compactMap { $0.activeClaim(at: now, observations: observations)?.device }
            .first { $0.id != deviceID }
    }

    /// A summary another device wrote after `date`: work started before it arrived shouldn't replace it.
    public func summaryWrittenElsewhere(after date: Date, excluding deviceID: String) -> Bool {
        guard let summary, summary.createdAt > date else { return false }
        return summary.origin.deviceID.map { $0 != deviceID } ?? false
    }

    /// The model behind each role that made what a summary reads, by role name: the transcripts' (the latest
    /// run of each recording, several joined in order) and the speakers'.
    public var modelsBehindTranscript: [String: String] {
        var result: [String: String] = [:]
        let latest = transcribableTracks.compactMap { track in transcripts.filter { $0.trackID == track.id }.max { $0.createdAt < $1.createdAt } }
        let transcription = Self.distinct(latest.map { $0.processingSettings?.model?.variantKey ?? $0.modelID })
        if !transcription.isEmpty { result["transcription"] = transcription.joined(separator: ",") }
        // A run's speakers are named after it ("<run>:S1").
        let runs = latest.map(\.id.uuidString)
        let diarization = Self.distinct(speakers.filter { speaker in runs.contains { speaker.id.hasPrefix($0) } }
            .compactMap { $0.analysisSettings.map { $0.model?.variantKey ?? $0.modelID } })
        if !diarization.isEmpty { result["diarization"] = diarization.joined(separator: ",") }
        return result
    }

    private static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Where a summary ran, as its provenance says.
public struct SummaryOrigin: Equatable, Sendable {
    /// The device that ran it, or sent it to the cloud (its sync replica ID). Nil for summaries made before
    /// Daybook recorded it: those were made on a Mac.
    public var deviceID: String?
    public var deviceName: String?
    /// The cloud model's name, for a summary made in the cloud.
    public var cloudModel: String?

    public init(deviceID: String? = nil, deviceName: String? = nil, cloudModel: String? = nil) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.cloudModel = cloudModel
    }

    /// The colophon's words: "Summarized with Claude Sonnet 5.5", "Summarized on this Mac", "Summarized on
    /// Vlad's MacBook Pro". `thisDevice` is how this device calls itself; `unknown` is what a summary that
    /// doesn't say reads as ("this Mac" on a Mac, "your Mac" on the iPhone).
    public func colophon(thisDeviceID: String, thisDevice: String, unknown: String) -> String {
        if let cloudModel { return "Summarized with \(cloudModel)" }
        guard let deviceID else { return "Summarized on \(unknown)" }
        if deviceID == thisDeviceID { return "Summarized on \(thisDevice)" }
        return "Summarized on \(deviceName ?? unknown)"
    }
}

extension MeetingSummary {
    /// Provenance keys (`processingSettings.parameters`).
    enum PlacementKey {
        static let device = "summarizedBy"
        static let deviceName = "summarizedByName"
        static let place = "place"
        static let cloudModel = "cloudModel"
        static let cloudProvider = "cloudProvider"
        /// Followed by a role's name: "model.transcription", "model.summarization".
        static let modelPrefix = "model."
    }

    /// Where it ran.
    public var origin: SummaryOrigin {
        let parameters = processingSettings?.parameters ?? [:]
        return SummaryOrigin(deviceID: parameters[PlacementKey.device], deviceName: parameters[PlacementKey.deviceName],
                             cloudModel: parameters[PlacementKey.place] == "cloud" ? parameters[PlacementKey.cloudModel] : nil)
    }

    /// The model behind each role, by role name, as recorded with it.
    public var modelsByRole: [String: String] {
        var result: [String: String] = [:]
        for (key, value) in processingSettings?.parameters ?? [:] where key.hasPrefix(PlacementKey.modelPrefix) {
            result[String(key.dropFirst(PlacementKey.modelPrefix.count))] = value
        }
        return result
    }

    /// The same summary with where it ran recorded: the device that ran it (or sent it to the cloud), the
    /// cloud model, and the model for each role behind it (`inputs`, plus its own as `summarization`).
    public func placed(_ place: SummaryPlace, by device: ProcessingRequest.Device, inputs: [String: String]) -> MeetingSummary {
        var summary = self
        var settings = summary.processingSettings ?? ProcessingSettings(modelID: modelID, createdAt: createdAt)
        settings.parameters[PlacementKey.device] = device.id
        settings.parameters[PlacementKey.deviceName] = device.name
        switch place {
        case .cloud(let model):
            settings.parameters[PlacementKey.place] = "cloud"
            settings.parameters[PlacementKey.cloudModel] = model.name
            settings.parameters[PlacementKey.cloudProvider] = model.provider.rawValue
            if settings.modelID.isEmpty { settings.modelID = model.id }
            if summary.modelID.isEmpty { summary.modelID = model.id }
        case .thisDevice, .mac:
            settings.parameters[PlacementKey.place] = "local"
        }
        var models = inputs
        models["summarization"] = settings.model?.variantKey ?? (settings.modelID.isEmpty ? summary.modelID : settings.modelID)
        for (role, model) in models where !model.isEmpty { settings.parameters[PlacementKey.modelPrefix + role] = model }
        summary.processingSettings = settings
        return summary
    }
}

extension LibraryController {
    /// Claims this conversation's summary for this device, before it summarizes it here or in the cloud: an
    /// open Summarize request it may take (unclaimed, its own, or with an expired claim), or a new one it
    /// makes for the purpose. Nil when another device is working on the conversation; it stands down.
    @discardableResult
    public func claimSummary(_ id: UUID, templateID: String? = nil, at now: Date = Date(),
                             lease: TimeInterval = ProcessingRequest.defaultLease) -> ProcessingRequest? {
        guard let meeting = meeting(id) else { return nil }
        let me = thisDevice
        guard meeting.summaryHolder(excluding: me.id, at: now) == nil else { return nil }
        if let open = meeting.openProcessingRequests.first(where: {
            $0.mode == .summaryOnly && $0.isClaimable(by: me, at: now) && !$0.isSatisfied(by: meeting)
        }) {
            return claimProcessingRequest(open.id, in: id, at: now, lease: lease)
        }
        let request = ProcessingRequest(meetingID: id, mode: .summaryOnly, templateID: templateID, requestedBy: me, createdAt: now)
        update(id) { $0.upsertProcessingRequest(request) }
        return claimProcessingRequest(request.id, in: id, at: now, lease: lease)
    }

    /// Applies a summary this device made (here or in the cloud) with where it ran, unless another device's
    /// summary arrived after `started`, which is kept: one summary per conversation. True when applied.
    @discardableResult
    public func applyPlacedSummary(_ summary: MeetingSummary, to id: UUID, place: SummaryPlace, started: Date) -> Bool {
        guard let meeting = meeting(id) else { return false }
        let me = thisDevice
        guard !meeting.summaryWrittenElsewhere(after: started, excluding: me.id) else { return false }
        let placed = summary.placed(place, by: me, inputs: meeting.modelsBehindTranscript)
        update(id) { meeting in
            meeting.setSummary(placed)
            meeting.status = .ready
        }
        return true
    }
}
