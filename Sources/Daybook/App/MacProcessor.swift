import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation

/// This Mac's processing, the twin of the iPhone's `PhoneProcessor`: it owns the queue and the downloads' state
/// (`ProcessingQueue`), queues a conversation's work (`enqueue`), runs the queue one job at a time beside a model
/// download (`runQueue`, `process`), and keeps the running request's claim alive while a job runs (the heartbeat,
/// `renewRunningClaim`; AppState+Requests.swift says how requests are claimed). What a job does on its way through the
/// library, the iPhone link, multipoint sources, photos, speakers, and summary placement is the app's (`app`).
///
/// Views and menus read what's queued and running from `queue`; pausing, cancelling, and downloads stay `AppState`'s
/// (ProcessingQueue.swift).
@MainActor
final class MacProcessor {
    /// What waits, what runs, what the person paused, what waits for models, the work this Mac owes, and the downloads.
    let queue: ProcessingQueue
    /// The app it processes for, which owns it.
    weak var app: AppState?

    /// The claim's heartbeat while a job carries out a request, and what the last renewal said.
    private var claimHeartbeat: Task<Void, Never>?
    private var lastClaimRenewal = Date.distantPast
    private var lastRenewedStage: ProcessingRequest.Stage?

    /// `owedURL` is the library's `local-queue.json` (`ProcessingQueue`).
    init(owedURL: URL?) {
        queue = ProcessingQueue(owedURL: owedURL)
    }

    // MARK: Queueing and running

    /// Queues `id`'s work. A job waits only for what transcribes (transcript first): new audio starts once the models
    /// that transcribe and find speakers are here, and its summary waits at the summary step if it has to. A Summarize,
    /// which transcribes nothing, waits for the summary model unless the cloud takes it at once.
    func enqueue(_ id: UUID, mode: ProcessingRequest.Mode = .newAudio, upgrade: ProcessingRequest.Upgrade? = nil, summarizesHere: Bool = false,
                 summarizesInCloud: Bool = false) {
        guard let app, id != app.recordingID, !queue.isQueued(id), let meeting = app.meetings.first(where: { $0.id == id }) else { return }
        // A conversation of an iPhone's own, queued only to check where its recording belongs, isn't owed: its mark
        // lives only while Daybook runs, and the next sync pass finds it again (`phoneTranscriptsToCheck`).
        if !app.checkingPhoneTranscripts.contains(id) { queue.owe(id, mode: mode, upgrade: upgrade) }
        let job = app.makeJob(meetingID: id, mode: mode, upgrade: upgrade, summarizesHere: summarizesHere, summarizesInCloud: summarizesInCloud)
        let hasNew = meeting.hasUntranscribedTranscribableAudio
        let missing = job.transcribingModelIDs(hasUntranscribedAudio: hasNew).subtracting(app.installedModels)
        let waitsForSummaryModel = missing.isEmpty && job.mode == .summaryOnly && app.summaryWaitsForModel(job, in: meeting)
        guard missing.isEmpty, !waitsForSummaryModel else {
            if waitsForSummaryModel { queue.awaitSummaryModel(id) } else { queue.awaitModels(id) }
            app.update(id) { $0.errorMessage = nil }
            // Missing models leave another device's request unclaimed, for a Mac that has them.
            app.releaseRequests(in: id)
            app.reportToPhones(id, phase: .waitingForModels)
            return
        }
        // A request for the same work is carried out by this job, so it's claimed and finished with it.
        queue.add(app.carryingOpenRequest(job, in: meeting))
        app.reportToPhones(id, phase: .queued)
        runQueue()
    }

    func runQueue() {
        guard let app else { return }
        // Giving speakers voices gives way to real work: it stops, and starts the queue when it has.
        if app.voicingID != nil, !queue.jobs.isEmpty { app.voicingTask?.cancel(); return }
        // A model download doesn't hold it: every job queued has the models it needs here, with their revisions frozen,
        // so a transcript doesn't wait for the summary model's download (transcript first).
        guard queue.task == nil, app.readingPhotoID == nil, !app.library.isApplyingSync, !queue.jobs.isEmpty else { return }
        queue.task = Task { [weak self, weak app] in
            guard let self, let app else { return }
            let queue = self.queue
            while !Task.isCancelled, let job = queue.next() {
                let id = job.meetingID
                // Never run a request another device holds, or one that finished elsewhere meanwhile.
                guard app.mayRun(job) else { queue.settle(id); continue }
                // Each job starts from nothing: no figure, and no step until the engine names one.
                queue.activity.set(IntelligenceProgress(0, "Starting"))
                queue.start(job)
                self.startClaimHeartbeat()
                app.reportToPhones(id)
                // Each job runs in its own task so pausing one conversation lets the queue continue.
                let work = Task { try await self.process(job) }
                queue.currentRequest = work
                do {
                    try await work.value
                    app.finishRequests(of: queue.running ?? job, failure: nil)
                    // Its summary may wait for the summary model here (transcript first).
                    app.reportToPhones(id, phase: queue.awaitingSummaryModel.contains(id) ? .waitingForModels : .finished)
                    queue.finishRunning()
                    queue.settle(id)
                }
                catch is CancellationError {
                    if queue.claimsLost.remove(id) == nil {
                        queue.paused.insert(id)
                        app.releaseRequests(in: id)
                        app.reportToPhones(id, phase: .paused)
                    }
                    app.update(id) { $0.status = $0.summary == nil ? .imported : .ready; $0.errorMessage = nil }
                    queue.finishRunning()
                    // The person paused it, or another device took it over; quitting leaves it owed.
                    if !queue.isStopping { queue.settle(id) }
                }
                catch {
                    // The kind is kept as the error says it (a cloud key refused, models missing), not read back from words.
                    queue.failures[id] = .init(reason: error.localizedDescription, kind: ProcessingRequest.FailureKind(error))
                    app.update(id) { $0.status = .failed; $0.errorMessage = error.localizedDescription }
                    app.finishRequests(of: queue.running ?? job, failure: error)
                    app.reportToPhones(id, phase: .failed, detail: error.localizedDescription)
                    queue.finishRunning()
                    queue.settle(id)
                }
                self.stopClaimHeartbeat()
                app.phones.checkingTranscripts.remove(id)
                // Requests that waited for this conversation, or arrived meanwhile (not after Cancel).
                if !Task.isCancelled { app.pickUpRequests(start: false) }
            }
            queue.task = nil
            queue.activity.set(IntelligenceProgress(0, "Ready"))
            app.collectOldModelRevisions()
            app.startPendingDownload()
            app.readNextPhotosWhenIdle()
            app.giveVoicesWhenIdle()
            app.listenToEarlierRecordingsWhenIdle()
        }
    }

    /// Runs one job. The engine turns recordings into transcripts, speakers, and a summary; this
    /// Mac decides what to process, places new recordings first, applies each result as it
    /// arrives (so a pause keeps finished recordings), and moves recordings between conversations.
    func process(_ request: ProcessingJob) async throws {
        guard let app else { return }
        let id = request.meetingID
        guard app.library.isLoaded, app.meetings.contains(where: { $0.id == id }) else { return }
        await app.flush()
        // A recording the iPhone transcribed itself finds its conversation first, once (AppState+Phone.swift).
        if await app.phoneTranscriptArrived(id, job: request) { return }
        guard let initial = app.meetings.first(where: { $0.id == id }) else { return }
        let options = request.preferences
        let engine = app.processingEngine(for: request)
        let terms = app.glossary.filter { $0.approved || $0.sourceMeetingIDs.contains(id) }.map(\.term)
        app.update(id) { $0.status = .transcribing; $0.errorMessage = nil }
        let activity = queue.activity
        let progress: ProcessingProgressHandler = { value in activity.report(IntelligenceProgress(value.fraction, value.message, stage: value.stage)) }
        let matching = options.matchSpeakersAcrossSources
            ? SpeakerMatchingConfiguration(minimumSimilarity: options.speakerMatchThreshold, minimumMargin: options.speakerMatchMargin) : nil
        if request.mode != .summaryOnly {
            // A synced iPhone recording finds its conversation first; one that moved isn't processed here.
            if await app.phoneRecordingsArrived(id, job: request) { return }
            try await app.placePendingSources(id)
        }
        // An original with a derived track (the microphone before echo removal) is transcribed through it. A recording this
        // conversation waits for that syncs in meanwhile (passes run while this Mac works) joins this job before fusion,
        // placed as it would have been, so there's one fused transcript and one summary; after that point, one gets a job
        // of its own.
        if request.mode != .summaryOnly { app.phones.foldsArrivalsInto = id }
        defer { if app.phones.foldsArrivalsInto == id { app.phones.foldsArrivalsInto = nil } }
        var tracks = request.mode == .summaryOnly ? [] : initial.transcribableTracks
        var taken = Set(tracks.map(\.id))
        while !tracks.isEmpty {
            for track in tracks {
                try Task.checkCancellation()
                let previous = app.meetings.first(where: { $0.id == id })?.transcripts.filter { $0.trackID == track.id }.max { $0.createdAt < $1.createdAt }
                if request.mode == .newAudio && previous != nil { continue }
                let url = try await app.library.audioURL(for: track, in: id)
                let output = try await engine.transcribe(TrackProcessingInput(meetingID: id, track: track, audioURL: url, mode: request.mode,
                                                                              previousTranscript: previous, vocabulary: terms), progress: progress)
                app.post(output.notices)
                app.update(id) { $0.apply(output, matching: matching, allowSameSource: previous != nil) }
            }
            tracks = []
            guard request.mode != .summaryOnly, let current = app.meetings.first(where: { $0.id == id }),
                  current.transcribableTracks.contains(where: { track in !taken.contains(track.id) && !current.transcripts.contains { $0.trackID == track.id } })
            else { break }
            // The job as it runs now: it may have taken on the request the recording came with (`pickUpRequests`).
            if await app.phoneRecordingsArrived(id, job: queue.running.flatMap { $0.meetingID == id ? $0 : nil } ?? request) { return }
            try await app.placePendingSources(id)
            guard let placed = app.meetings.first(where: { $0.id == id }) else { return }
            tracks = placed.transcribableTracks.filter { !taken.contains($0.id) }
            taken.formUnion(tracks.map(\.id))
        }
        app.phones.foldsArrivalsInto = nil
        try Task.checkCancellation()
        await app.realign(id)
        if await app.sourcesAfterTranscription(id) { return }
        _ = try await app.readPhotos(id, engine: engine, progress: progress)
        await app.labelSpeakers(before: id)
        guard let before = app.meetings.first(where: { $0.id == id }) else { return }
        let transcript = MeetingEvidence.transcript(before)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.noSpeech }
        // Transcript first: without the summary model here, and with the cloud not taking the summary at once, the job ends
        // with the transcript, and the summary waits for the model or the person's Use the Cloud
        // (AppState+SummaryPlacement.swift).
        let job = queue.running.flatMap { $0.meetingID == id ? $0 : nil } ?? request
        if await app.summaryWaitsForModelAtStep(job, in: before) {
            try Task.checkCancellation()
            app.leaveSummaryForModel(id, after: job)
            return
        }
        app.update(id) { $0.status = .summarizing }
        queue.activity.enter(.summarizing)
        renewRunningClaim(force: false)
        app.reportToPhones(id)
        let template = app.template(for: request, meeting: before)
        // Where it runs: here, or in the cloud if the person chooses during the countdown (AppState+SummaryPlacement.swift).
        guard let placed = try await app.placedSummary(id, job: request, engine: engine, template: template, vocabulary: terms, progress: progress) else {
            // Another device is summarizing it; its summary arrives through sync.
            app.update(id) { $0.status = $0.summary == nil ? .imported : .ready }
            return
        }
        try Task.checkCancellation()
        let current = placed.meeting, generated = placed.output
        // What was said, written, or chosen meanwhile is summarized again; a speaker's new name follows into this one.
        let inputsChanged = app.meetings.first(where: { $0.id == id })?.summaryInputsChanged(since: current) ?? false
        // A summary another device wrote meanwhile stays: one summary per conversation.
        if app.meetings.first(where: { $0.id == id })?.summaryWrittenElsewhere(after: placed.started, excluding: app.library.thisDevice.id) == true {
            app.update(id) { $0.status = .ready }
            return
        }
        let summary = generated.summary.placed(placed.place, by: app.library.thisDevice, inputs: current.modelsBehindTranscript)
        app.update(id) { meeting in
            meeting.setSummary(summary, writtenFrom: current)
            // Keep Auto selected so a new source or revised context can change the inferred kind.
            meeting.status = .ready
            meeting.errorMessage = generated.warnings.isEmpty ? nil : generated.warnings.joined(separator: "\n")
        }
        try await app.library.proposeTerms(generated.suggestedTerms, for: id)
        await app.flush()
        if inputsChanged { enqueue(id) }
    }

    // MARK: The claim's heartbeat

    func startClaimHeartbeat() {
        claimHeartbeat?.cancel()
        claimHeartbeat = nil
        lastRenewedStage = nil
        guard let app, queue.running?.requestID != nil else { return }
        renewRunningClaim(force: true)
        let interval = app.requestTiming.renewInterval
        claimHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                self?.renewRunningClaim(force: true)
            }
        }
    }

    func stopClaimHeartbeat() {
        claimHeartbeat?.cancel()
        claimHeartbeat = nil
    }

    /// Renews the running job's claim with its stage and fraction: at every change of stage, and
    /// at least every `renewInterval`. The save asks for a sync pass, which publishes it. A renewal
    /// refused because another device holds the request stops the job.
    func renewRunningClaim(force: Bool) {
        guard let app, let job = queue.running, let requestID = job.requestID, queue.currentRequest?.isCancelled != true else { return }
        let stage = app.runningStage
        let timing = app.requestTiming
        let interval = Double(timing.renewInterval.components.seconds) + Double(timing.renewInterval.components.attoseconds) / 1e18
        guard force || stage != lastRenewedStage || Date().timeIntervalSince(lastClaimRenewal) >= interval else { return }
        lastClaimRenewal = Date()
        lastRenewedStage = stage
        if app.library.renewProcessingClaim(requestID, in: job.meetingID, stage: stage, fraction: queue.activity.value.fraction,
                                            lease: timing.lease) == nil {
            app.reconcileClaims()
        }
    }

    /// The running job reported: its claim is renewed if the step changed (or a minute passed), and the iPhones hear.
    func processingProgressChanged() {
        renewRunningClaim(force: false)
        if let id = queue.runningID { app?.reportToPhones(id) }
    }
}
