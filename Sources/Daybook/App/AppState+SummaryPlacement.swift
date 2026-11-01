import DaybookCore
import DaybookIntelligence
import DaybookKit
import DaybookLink
import Foundation

/// Where this Mac's summaries run (docs/multipoint.md, "Where summaries run"). The summary step of every
/// job goes through `placements`: with a cloud model on offer it counts down (15 s, or the setting) to
/// summarizing here, with Use the Cloud and Start Now, on the page, the list, the inspector, Floating Notes,
/// and connected iPhones, which may choose too. A summary someone asked for (Summarize Again here, any
/// request another device made but Transcribe) starts at once. Without a key nothing changes.
///
/// One summary per conversation: a summary another device is working on (it holds a claim on one of the
/// conversation's requests: an iPhone summarizing it in the cloud, say) isn't written here too, and one
/// that arrives while this Mac summarizes is kept rather than replaced.
extension AppState {
    /// "this Mac" in the countdown's words.
    nonisolated static let thisDeviceWords = "this Mac"

    func wireSummaryPlacements() {
        placements.onChange = { [weak self] id in self?.reportSummaryPlacement(id) }
        placementOptionsChanged()
    }

    // MARK: What this Mac offers

    /// A job reaches the summary step only with the summary model here, so this Mac can always summarize its
    /// own; the choice is whether to use the cloud first. It never waits for another Mac.
    var summaryOptions: SummaryOptions {
        SummaryOptions(thisDeviceCanSummarize: true, reachableMacs: [], cloud: cloudPreferences.resolve(in: cloudModels))
    }

    func placementOptionsChanged() {
        placements.update(options: summaryOptions, preferences: cloudPreferences)
    }

    /// The models the person's keys reach, as the cloud says (cached there; `refresh` asks the providers).
    func refreshCloudModels(refresh: Bool = false) async {
        guard let cloud = cloudSummarizer else {
            if !cloudModels.isEmpty { cloudModels = [] }
            return
        }
        let models = await cloud.availableModels(refresh: refresh)
        if models != cloudModels { cloudModels = models }
    }

    /// What this Mac can do with its own models: the routed models installed, and, for summaries, the memory
    /// the summary model suggests. With the model it would use for each role it runs.
    var processingCapabilities: ProcessingCapabilities {
        let route = speechRoute, installed = installedModels
        let transcribes = installed.contains(route.transcription.model)
        let speakerModels = [route.speakerModel] + [route.voiceEmbedder].compactMap { $0 }
        let findsSpeakers = detectSpeakers && speakerModels.allSatisfy(installed.contains)
        let summary = summaryModel
        let fits = modelCatalog.model(summary).map { LiveModelChoices.fitsMemory($0) } ?? true
        let summarizes = !summary.isEmpty && installed.contains(summary) && fits
        var models: [String: String] = [:]
        if transcribes { models[ModelRole.transcription.rawValue] = route.transcription.model }
        if findsSpeakers {
            models[ModelRole.diarization.rawValue] = route.speakerModel
            if let embedder = route.voiceEmbedder { models[ModelRole.speakerEmbedding.rawValue] = embedder }
        }
        if summarizes { models[ModelRole.summarization.rawValue] = summary }
        return ProcessingCapabilities(transcribes: transcribes, findsSpeakers: findsSpeakers, summarizes: summarizes,
                                      models: models.isEmpty ? nil : models)
    }

    /// What other devices may send this Mac: its capabilities while it takes their work (Transcribe synced
    /// recordings on this Mac), nothing otherwise.
    var advertisedCapabilities: ProcessingCapabilities {
        processSyncedAudio ? processingCapabilities : .none
    }

    // MARK: The summary step

    /// Whether a job's summary was asked for, so it starts at once: anything but Transcribe (Summarize Again,
    /// a template, Identify Speakers Again, Transcribe Everything Again), here or from another device. New
    /// audio's summary is due, and counts down.
    func summaryIsAskedFor(_ job: ProcessingJob) -> Bool {
        if job.mode != .newAudio { return true }
        guard let requestID = job.requestID, let request = request(requestID, in: job.meetingID) else { return false }
        return request.mode != .newAudio && request.requestedBy.id != library.thisDevice.id
    }

    /// Another device working on this conversation's summary: an open request it holds a live claim on that
    /// this job doesn't carry.
    func summaryHolderElsewhere(_ id: UUID, job: ProcessingJob) -> ProcessingRequest.Device? {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return nil }
        let me = library.thisDevice.id, now = Date()
        return meeting.openProcessingRequests.lazy.filter { $0.id != job.requestID }
            .compactMap { $0.activeClaim(at: now)?.device }.first { $0.id != me }
    }

    /// Places the job's summary and makes it: counts down when it's due and the cloud is on offer, then
    /// summarizes here or in the cloud. Nil when another device has it (this Mac stands down). Throws
    /// `CancellationError` when the job is paused or cancelled during the countdown.
    func placedSummary(_ id: UUID, job: ProcessingJob, engine: any ProcessingEngine, template: SummaryTemplate?, vocabulary: [String],
                       progress: @escaping ProcessingProgressHandler) async throws -> PlacedSummary? {
        if summaryHolderElsewhere(id, job: job) != nil { return nil }
        placementOptionsChanged()
        defer { placements.end(id) }
        guard let place = await placements.place(id, immediately: summaryIsAskedFor(job)) else { throw CancellationError() }
        try Task.checkCancellation()
        // Taken by another device while it counted down (an iPhone chose the cloud and claimed it).
        if summaryHolderElsewhere(id, job: job) != nil { return nil }
        // What the conversation is now: notes may have changed while it counted down.
        guard let meeting = meetings.first(where: { $0.id == id }) else { return nil }
        let started = Date()
        reportToPhones(id, force: true)
        switch place {
        case .cloud(let model):
            if let cloud = cloudSummarizer {
                let summary = try await cloud.summarize(meeting, template: template, vocabulary: vocabulary, model: model,
                                                        effort: cloudPreferences.effort) { fraction in
                    progress(ProcessingProgress(fraction: fraction, message: "Summarizing with \(model.name)"))
                }
                return PlacedSummary(output: SummaryProcessingOutput(summary: summary), place: place, meeting: meeting, started: started)
            }
            // The key went away as it started: here, as without one.
            fallthrough
        case .thisDevice, .mac:
            let output = try await engine.summarize(meeting, template: template, vocabulary: vocabulary, progress: progress)
            return PlacedSummary(output: output, place: .thisDevice, meeting: meeting, started: started)
        }
    }

    /// A summary made by `placedSummary`, with where it ran and what it read.
    struct PlacedSummary {
        var output: SummaryProcessingOutput
        var place: SummaryPlace
        /// The conversation as it was summarized.
        var meeting: Meeting
        var started: Date
    }

    // MARK: Choices

    /// Use the Cloud or Start Now, from the page, the inspector, Floating Notes, or a phone.
    func chooseSummaryPlacement(_ action: SummaryPlacementPlanner.Action, for id: UUID) {
        placements.perform(action, for: id)
    }

    /// A paired phone chose for a countdown this Mac shows it.
    func phoneChoseSummaryPlacement(_ choice: LinkSummaryChoice) {
        switch choice.choice {
        case .useCloud: chooseSummaryPlacement(.useCloud, for: choice.meetingID)
        case .startNow: chooseSummaryPlacement(.startNow, for: choice.meetingID)
        default: break
        }
    }

    // MARK: Phones

    /// Phones hear a countdown as it begins, changes, and ends, and the cloud's model when it runs there.
    func reportSummaryPlacement(_ id: UUID) {
        guard placements[id] != nil else { return }
        reportToPhones(id, force: true)
    }

    /// The progress a phone gets while this Mac places a summary: the countdown, or the cloud at work. Nil
    /// when nothing is being placed (the job's own progress says the rest).
    func placementProgress(_ id: UUID, now: Date = Date()) -> LinkProcessingProgress? {
        guard let planner = placements[id] else { return nil }
        let name = library.thisDevice.name
        switch planner.phase {
        case .countingDown(_, let until):
            return LinkProcessingProgress(meetingID: id, phase: .summaryCountdown, macName: name,
                                          countdown: LinkSummaryCountdown(secondsLeft: max(0, until.timeIntervalSince(now)),
                                                                          cloudOffered: planner.cloud != nil))
        case .started(.cloud(let model)):
            return LinkProcessingProgress(meetingID: id, phase: .summarizing, fraction: min(1, max(0, processingProgress.fraction)),
                                          macName: name, cloudModel: model.name)
        case .started, .waitingForMac, .waiting:
            return nil
        }
    }
}
