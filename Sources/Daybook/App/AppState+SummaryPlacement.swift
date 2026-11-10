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
///
/// A Personal conversation (placed there, or its template or kind says so) is never sent to the cloud on its own:
/// under Always it counts down as Offer First does, and the cloud is the person's choice for it (Use the Cloud).
///
/// **Transcript first.** A job never waits for the summary model to start: it transcribes with what transcribes, and at
/// the summary step, when the summary model isn't here and the cloud wouldn't take the summary at once (Always, unless
/// the conversation is Personal), it ends with the transcript. The summary is owed (`ProcessingQueue.awaitingSummaryModel`,
/// kept with the owed work), and the page says "Waiting to summarize after the download · 38%", with Use the Cloud when
/// the cloud is on offer. When the model arrives, every conversation waiting for it is summarized, oldest first. Another
/// device's request is done as far as its transcript goes, and a Summarize request stays open in this Mac's name, so the
/// device reads "Waiting for your Mac to summarize" and whichever Mac summarizes first takes it.
extension AppState {
    /// "this Mac" in the countdown's words.
    nonisolated static let thisDeviceWords = "this Mac"

    func wireSummaryPlacements() {
        placements.onChange = { [weak self] id in self?.reportSummaryPlacement(id) }
        placements.isPersonal = { [weak self] id in
            self?.meetings.first(where: { $0.id == id })?.effectivePlacement == .personal
        }
    }

    // MARK: What this Mac offers

    /// Whether this Mac summarizes with its own model (`summarizesLocally`), and the model Settings › Cloud resolves to
    /// (`cloud`), none without a key. It never waits for another Mac: a summary it can't place at once waits for its own
    /// model (`summaryWaitsForModel`), so under Always the cloud needs no summary model here at all.
    var summaryOptions: SummaryOptions {
        SummaryOptions(thisDeviceCanSummarize: summarizesLocally, reachableMacs: [], cloud: cloud.resolved?.model)
    }

    /// This Mac's summary model is here: the running job's, else the one chosen now. Whether it fits this Mac's memory is
    /// what other devices are told (`processingCapabilities`); this Mac's own work runs the model the person chose.
    var summarizesLocally: Bool {
        let model = processor.queue.running?.summaryModelID ?? summaryModel
        return !model.isEmpty && installedModels.contains(model)
    }

    /// The cloud is on offer for a summary: a key, a model it reaches, and not Never.
    var cloudOnOffer: Bool { cloud.preferences.policy != .never && cloud.resolved != nil }

    /// A key, the models offered, or the preferences changed (`CloudSetup.onChange`), or a summary is about to be
    /// placed: every countdown follows. Nothing to do before the cloud is first needed.
    func placementOptionsChanged() {
        guard hasCloudSetup else { return }
        placements.update(options: summaryOptions, preferences: cloud.preferences)
    }

    /// What this Mac can do with its own models: the routed models installed, and, for summaries, the memory
    /// the summary model suggests. With the model it would use for each role it runs.
    var processingCapabilities: ProcessingCapabilities {
        let route = speechRoute, installed = installedModels
        let transcribes = installed.contains(route.transcription.model)
        let speakerModels = [route.speakerModel] + [route.voiceEmbedder].compactMap { $0 }
        let findsSpeakers = detectSpeakers && speakerModels.allSatisfy(installed.contains)
        let summary = summaryModel
        let fits = modelCatalog.model(summary).map { LiveModelChoices.fitsMemory($0, physicalMemory: physicalMemory) } ?? true
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

    // MARK: Waiting for the summary model

    /// Whether a summary of `meeting` made now would wait for this Mac's summary model: `model` (the one chosen, unless a
    /// job froze another) isn't here, and the cloud wouldn't take the summary at once. It does under Always, unless the
    /// conversation is Personal, and whenever the person chose it for this summary (`toCloud`: Use the Cloud, an upgrade to
    /// the cloud's model); never for one they asked to run here (`here`: Summarize on This Mac).
    func summaryWaitsForModel(_ meeting: Meeting, model: String? = nil, toCloud: Bool = false, here: Bool = false) -> Bool {
        let model = model ?? summaryModel
        if !model.isEmpty, installedModels.contains(model) { return false }
        guard !here, cloudOnOffer else { return true }
        return !toCloud && (cloud.preferences.policy != .always || meeting.effectivePlacement == .personal)
    }

    /// The same for a job's summary, by what the job froze and what the person chose for it.
    func summaryWaitsForModel(_ job: ProcessingJob, in meeting: Meeting) -> Bool {
        let toCloud = job.summarizesInCloud || job.upgrade.map { UpgradeRanks.isCloud($0.model) } == true
        return summaryWaitsForModel(meeting, model: job.summaryModelID, toCloud: toCloud, here: job.summarizesHere)
    }

    /// At the job's summary step: the same, with the keys read again first, as placing it would (a key added on another
    /// device arrives through iCloud Keychain).
    func summaryWaitsForModelAtStep(_ job: ProcessingJob, in meeting: Meeting) async -> Bool {
        guard summaryWaitsForModel(job, in: meeting) else { return false }
        await cloud.reload()
        return summaryWaitsForModel(job, in: meeting)
    }

    /// The job ends with the transcript, its summary waiting for the summary model. This Mac's own work owes it
    /// (`ProcessingQueue.awaitSummaryModel`). Another device's request is done as far as the transcript goes, and its
    /// summary stays asked for in the library, in this Mac's name, so the device reads "Waiting for your Mac to
    /// summarize" and whichever Mac summarizes first takes it (this one too, once its model is here); a Summarize request
    /// the job carried goes back as it was.
    func leaveSummaryForModel(_ id: UUID, after job: ProcessingJob) {
        update(id) { $0.status = $0.summary == nil ? .imported : .ready; $0.errorMessage = nil }
        guard let requestID = job.requestID, let request = request(requestID, in: id) else {
            processor.queue.awaitSummaryModel(id)
            return
        }
        if request.mode == .summaryOnly {
            library.releaseProcessingRequest(requestID, in: id)
            // Finishing the job then leaves the request open.
            processor.queue.running = job.withoutRequest
        } else {
            library.requestProcessing(id, mode: .summaryOnly, templateID: job.templateID, by: library.thisDevice)
        }
    }

    /// The summary model arrived, or a model that's here was chosen: what waited for one goes on.
    func summaryModelArrived() {
        takeUpWaitingSummaries()
        pickUpRequests()
    }

    /// The summaries owed for the summary model go on once they can start (the model is here, or the cloud now takes
    /// them at once), the oldest conversation first.
    func takeUpWaitingSummaries() {
        guard library.isLoaded, !processor.queue.awaitingSummaryModel.isEmpty else { return }
        let waiting = meetings.filter { processor.queue.awaitingSummaryModel.contains($0.id) }.sorted { $0.date < $1.date }
        for meeting in waiting where !summaryWaitsForModel(meeting) { processor.enqueue(meeting.id, mode: .summaryOnly) }
    }

    // MARK: The summary step

    /// Whether a job's summary was asked for, so it starts at once: anything but Transcribe (Summarize Again,
    /// a template, Identify Speakers Again, Transcribe Everything Again), here or from another device. New
    /// audio's summary is due, and counts down.
    func summaryIsAskedFor(_ job: ProcessingJob) -> Bool {
        // An upgrade's summary is due like new audio's: it counts down while the cloud is on offer (docs/multipoint.md,
        // "Upgrade"), unless the cloud was the better model, which it goes to at once.
        if job.upgrade != nil { return false }
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
    func placedSummary(_ id: UUID, job started: ProcessingJob, engine: any ProcessingEngine, template: SummaryTemplate?, vocabulary: [String],
                       progress: @escaping ProcessingProgressHandler) async throws -> PlacedSummary? {
        // The job as it is now: it may have taken on another device's request since it started.
        let job = processor.queue.running.flatMap { $0.meetingID == id ? $0 : nil } ?? started
        if summaryHolderElsewhere(id, job: job) != nil { return nil }
        // The keys and models as they are now (a key added on another device arrives through iCloud Keychain).
        await cloud.reload()
        placementOptionsChanged()
        defer { placements.end(id) }
        if job.summarizesHere {
            // Summarize on This Mac: here, whatever the cloud preferences say. Placed only now, so it lasts as long as
            // this step does.
            placements.beginHere(id)
        } else if job.summarizesInCloud || job.upgrade.map({ UpgradeRanks.isCloud($0.model) }) == true {
            // The person chose the cloud (Use the Cloud for a summary that waited for the summary model, or the cloud's
            // better summary): no countdown. Without the cloud on offer now (the key went), it places as any due summary does.
            placements.beginInCloud(id)
        }
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
            if cloud.keys[model.provider] != nil {
                let output = try await cloudSummarizer.summaryOutput(meeting, template: template, vocabulary: vocabulary, model: model,
                                                                     effort: cloud.preferences.effort) { fraction in
                    progress(ProcessingProgress(fraction: fraction, message: SummaryPlacementWords.inCloud(model.name), stage: .summarizing))
                }
                return PlacedSummary(output: output, place: place, meeting: meeting, started: started)
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

    /// Summarize on This Mac, after the cloud couldn't: a summary that runs here whatever the cloud preferences say. The
    /// job carries the choice to its summary step (`ProcessingJob.summarizesHere`), so Cancel or Pause before then
    /// leaves nothing placed, and the next Summarize places as usual.
    func summarizeHere(_ id: UUID) {
        processor.enqueue(id, mode: .summaryOnly, summarizesHere: true)
    }

    /// Use the Cloud or Start Now, from the page, the inspector, Floating Notes, or a phone. A summary waiting for the
    /// summary model has no countdown: Use the Cloud summarizes it there now (`summarizeInCloud`).
    func chooseSummaryPlacement(_ action: SummaryPlacementPlanner.Action, for id: UUID) {
        if action == .useCloud, placements[id] == nil, processor.queue.runningID != id, !processor.queue.isQueued(id) {
            summarizeInCloud(id)
            return
        }
        placements.perform(action, for: id)
    }

    /// Use the Cloud for a summary waiting for this Mac's summary model: a Summarize that goes to the cloud with no
    /// countdown (`ProcessingJob.summarizesInCloud`), carrying out a Summarize request left open for it.
    func summarizeInCloud(_ id: UUID) {
        processor.enqueue(id, mode: .summaryOnly, summarizesInCloud: true)
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
            return LinkProcessingProgress(meetingID: id, phase: .summarizing, fraction: min(1, max(0, processor.queue.activity.value.fraction)),
                                          macName: name, cloudModel: model.name)
        case .started, .waitingForMac, .waiting:
            return nil
        }
    }
}
