import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation
import Observation

/// This Mac's processing queue and its model downloads: what waits, what runs, what the person paused, what waits for
/// models, and the work this Mac still owes. `AppState` drives it (`enqueue`, `runQueue`, below, and `process`); this
/// keeps the state and the rules between its parts, so the rest of the app changes it only through them.
///
/// **Owed work.** A conversation queued here stays owed until its work finishes, fails, the person pauses or cancels
/// it, it goes to the Trash, or another device takes it over. Quitting, a restart, or a crash doesn't settle it: the
/// record is kept in the library as `local-queue.json` (never synced: it's this Mac's), and the next launch queues
/// it again (`resumeOwedWork`). Work Daybook didn't come back from twice (it crashed, or was stopped, mid-run) is left
/// to the person instead, so work that brings Daybook down doesn't do so at every launch. A request another device
/// made isn't owed here, nor is a check of where an iPhone's recording belongs: both are found again in the library.
///
/// **Owed downloads.** A model asked for stays owed until it's here or the person cancels it, kept beside the owed work
/// as `local-downloads.json`. The next launch, and the network coming back, take them up again by themselves, over Wi‑Fi
/// or a wired network only (not a hotspot or Low Data Mode: they say "Waiting for Wi‑Fi"). A download that fails
/// stops the ones after it, says so where the models show ("Couldn’t download Gemma 4 12B" with Try Again), and writes
/// to the log; only a download the person's own press started raises an alert.
@MainActor
@Observable
final class ProcessingQueue {
    /// Waiting their turn, in order.
    var jobs: [ProcessingJob] = []
    /// The conversation being processed now.
    var runningID: UUID?
    /// The job running now (`runningID`'s), with the request it carries out, if any.
    var running: ProcessingJob?
    /// Conversations the person paused; they resume only when asked.
    var paused: Set<UUID> = []
    /// Conversations that start as soon as the models they need finish downloading.
    var awaitingModels: Set<UUID> = []
    /// Conversations whose running job stopped because another device took its request over.
    var claimsLost: Set<UUID> = []
    /// What the last failure of each conversation's own job was, as the error said it where the job caught it: a job
    /// with no request has no outcome to keep its kind (`processingStatus(for:)`). Kept while Daybook runs.
    var failures: [UUID: CaughtFailure] = [:]

    struct CaughtFailure: Equatable {
        var reason: String
        var kind: ProcessingRequest.FailureKind
    }
    /// The running job's progress, throttled (`ActivityProgress`). The window isn't redrawn by it: the views that draw
    /// it observe `activity`, and redraw when its percent, message, or step changes.
    let activity = ActivityProgress(IntelligenceProgress(0, "Ready"))
    /// The loop that runs jobs one after another, and the job running now in a task of its own.
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var currentRequest: Task<Void, Error>?
    /// Everything is stopping because Daybook is quitting: what was cancelled stays owed.
    @ObservationIgnored private(set) var isStopping = false
    /// The running job's conversation while its run counts on its owed work as one that hasn't ended
    /// (`OwedWork.interruptedRuns`).
    @ObservationIgnored private var countedRun: UUID?

    // MARK: The claim's heartbeat (AppState+Requests.swift)

    @ObservationIgnored var claimHeartbeat: Task<Void, Never>?
    @ObservationIgnored var lastClaimRenewal = Date.distantPast
    @ObservationIgnored var lastRenewedStage: ProcessingRequest.Stage?

    // MARK: Model downloads

    /// The model downloading now. A download holds the queue (the models run one at a time).
    var downloadingID: String?
    /// The current download's progress, throttled like `activity`.
    let downloadActivity = ActivityProgress(IntelligenceProgress(0, ""))
    /// Models still to download after the current one.
    var pendingDownloads: [String] = []
    @ObservationIgnored var downloadTask: Task<Void, Never>?
    /// Models asked for that aren't here yet ("key" or "key@revision"), in the order they were asked for: the one
    /// downloading, those waiting their turn, and those a failure or the network stopped. Kept until the model is here
    /// or the person cancels it (`local-downloads.json`).
    private(set) var owedDownloads: [String] = []
    /// Downloads that stopped on their own, by variant key, in the system's words (for the log). Kept while Daybook runs.
    var downloadFailures: [String: String] = [:]
    /// The owed downloads wait for Wi‑Fi: they'd go on by themselves, and the network is expensive or constrained.
    var downloadsWaitForWiFi = false
    /// What the downloads under way were asked for since they were last idle, for "Downloading models · 40%" over the
    /// whole set.
    var downloadBatch: [String] = []
    /// Where the owed downloads are kept; nil keeps them in memory only.
    @ObservationIgnored let downloadsURL: URL?
    /// Whether the network is being watched for owed downloads to go on.
    @ObservationIgnored var watchesNetwork = false
    @ObservationIgnored private var madeNetwork: DownloadNetwork?
    /// Downloads in tests: what `download` fetches with in place of the runtime.
    @ObservationIgnored var fetchModel: ((String, @escaping IntelligenceProgressHandler) async throws -> Void)?

    /// Where the owed work is kept; nil keeps it in memory only.
    @ObservationIgnored let owedURL: URL?
    /// The work owed, by conversation, in the order it was asked for.
    @ObservationIgnored private(set) var owed: [OwedWork] = []

    /// `owedURL` is the library's `local-queue.json`; the owed downloads are kept beside it.
    init(owedURL: URL?) {
        self.owedURL = owedURL
        var downloadsURL = owedURL?.deletingLastPathComponent().appendingPathComponent("local-downloads.json")
        #if DEBUG
        // Demos never leave a download owed for a later launch to fetch.
        if ModelDemo.isRequested || FloatingNotesDemo.scenario != nil { downloadsURL = nil }
        #endif
        self.downloadsURL = downloadsURL
    }

    /// The network downloads that go on by themselves go by; made the first time it's needed. Tests replace it.
    var network: DownloadNetwork {
        get {
            if let madeNetwork { return madeNetwork }
            let made = DownloadNetwork.system()
            madeNetwork = made
            return made
        }
        set { madeNetwork = newValue }
    }

    var queuedIDs: [UUID] { jobs.map(\.meetingID) }

    func isQueued(_ id: UUID) -> Bool { jobs.contains { $0.meetingID == id } }

    // MARK: The queue's rules

    /// A job joins the end of the queue: its conversation no longer waits for models and isn't paused.
    func add(_ job: ProcessingJob) {
        awaitingModels.remove(job.meetingID)
        paused.remove(job.meetingID)
        jobs.append(job)
    }

    /// The conversation waits for its models: it starts once they've downloaded.
    func awaitModels(_ id: UUID) {
        awaitingModels.insert(id)
    }

    /// The next job, taken off the queue.
    func next() -> ProcessingJob? {
        jobs.isEmpty ? nil : jobs.removeFirst()
    }

    /// `job` runs now. Its owed work counts the run until it ends here: if Daybook crashes meanwhile, the count stays.
    func start(_ job: ProcessingJob) {
        runningID = job.meetingID
        running = job
        claimsLost.remove(job.meetingID)
        if let index = owed.firstIndex(where: { $0.meetingID == job.meetingID }) {
            owed[index].interruptedRuns += 1
            countedRun = job.meetingID
            saveOwed()
        }
    }

    /// The running job is done, however it ended.
    func finishRunning() {
        runEnded()
        currentRequest = nil
        running = nil
        runningID = nil
    }

    /// Takes a conversation's waiting jobs out of the queue and returns them.
    @discardableResult
    func removeJobs(for id: UUID) -> [ProcessingJob] {
        let removed = jobs.filter { $0.meetingID == id }
        jobs.removeAll { $0.meetingID == id }
        return removed
    }

    /// Daybook is quitting: the loop and the running job stop, the queue empties, and what it held stays owed. The
    /// running job's run ends here, now: the quit may be over before its work notices.
    func stopAll() {
        isStopping = true
        runEnded()
        task?.cancel()
        currentRequest?.cancel()
        jobs.removeAll()
    }

    // MARK: Owed work

    /// What this Mac owes a conversation: the work it was asked for here.
    struct OwedWork: Codable, Equatable {
        var meetingID: UUID
        var mode: ProcessingRequest.Mode
        var upgrade: ProcessingRequest.Upgrade?
        /// Runs of this work that started and never ended here: Daybook crashed, or was stopped, mid-run. A quit ends
        /// a run as it stops it.
        var interruptedRuns = 0

        /// Whether the next launch queues it again: once after a run that never ended, not after a second.
        var resumesAtLaunch: Bool { interruptedRuns < 2 }

        init(meetingID: UUID, mode: ProcessingRequest.Mode, upgrade: ProcessingRequest.Upgrade?) {
            self.meetingID = meetingID
            self.mode = mode
            self.upgrade = upgrade
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            meetingID = try container.decode(UUID.self, forKey: .meetingID)
            mode = try container.decode(ProcessingRequest.Mode.self, forKey: .mode)
            upgrade = try container.decodeIfPresent(ProcessingRequest.Upgrade.self, forKey: .upgrade)
            interruptedRuns = try container.decodeIfPresent(Int.self, forKey: .interruptedRuns) ?? 0
        }
    }

    /// The work owed when Daybook last ran, read once the library opens, before anything is queued. It stays owed until
    /// it's settled. The downloads owed come with it.
    func loadOwedWork() {
        loadOwedDownloads()
        // The network is known by the time they go on (`resumeOwedDownloads`).
        if !owedDownloads.isEmpty { _ = network }
        guard let owedURL, let data = try? Data(contentsOf: owedURL),
              let saved = try? JSONDecoder().decode([OwedWork].self, from: data) else { return }
        for work in saved where !owed.contains(where: { $0.meetingID == work.meetingID }) { owed.append(work) }
    }

    /// This Mac owes `id` the work `mode` asks for: a later ask replaces an earlier one, and keeps its runs that never
    /// ended.
    func owe(_ id: UUID, mode: ProcessingRequest.Mode, upgrade: ProcessingRequest.Upgrade?) {
        if let index = owed.firstIndex(where: { $0.meetingID == id }) {
            guard owed[index].mode != mode || owed[index].upgrade != upgrade else { return }
            owed[index].mode = mode
            owed[index].upgrade = upgrade
        } else {
            owed.append(OwedWork(meetingID: id, mode: mode, upgrade: upgrade))
        }
        saveOwed()
    }

    /// Nothing is owed `id` any more, unless it's queued or running again (a job that queued its conversation again
    /// as it finished).
    func settle(_ id: UUID) {
        guard runningID != id || running == nil, !isQueued(id), owed.contains(where: { $0.meetingID == id }) else { return }
        owed.removeAll { $0.meetingID == id }
        saveOwed()
    }

    func isOwed(_ id: UUID) -> Bool { owed.contains { $0.meetingID == id } }

    /// The running job's run ended here, whichever way: it no longer counts as one that never ended.
    private func runEnded() {
        guard let id = countedRun else { return }
        countedRun = nil
        guard let index = owed.firstIndex(where: { $0.meetingID == id }), owed[index].interruptedRuns > 0 else { return }
        owed[index].interruptedRuns -= 1
        saveOwed()
    }

    private func saveOwed() {
        guard let owedURL else { return }
        let data = try? JSONEncoder().encode(owed)
        Self.writes.async { if let data { try? data.write(to: owedURL, options: .atomic) } }
    }

    /// Writes happen in order, off the main actor.
    private nonisolated static let writes = DispatchQueue(label: "local.daybook.processing.owed", qos: .utility)

    /// For tests: returns once every write asked for so far is on disk.
    nonisolated static func drainWrites() { writes.sync {} }

    // MARK: Owed downloads

    /// The downloads owed when Daybook last ran, read with the owed work.
    func loadOwedDownloads() {
        guard let downloadsURL, let data = try? Data(contentsOf: downloadsURL),
              let saved = try? JSONDecoder().decode([String].self, from: data) else { return }
        for id in saved where !owedDownloads.contains(id) { owedDownloads.append(id) }
    }

    /// These models are owed until they're here or the person cancels them.
    func oweDownloads(_ ids: [String]) {
        let new = ids.reduce(into: [String]()) { if !owedDownloads.contains($1) && !$0.contains($1) { $0.append($1) } }
        guard !new.isEmpty else { return }
        owedDownloads += new
        saveOwedDownloads()
    }

    /// `id` is here: nothing is owed for it, and nothing stopped.
    func settleDownload(_ id: String) {
        downloadFailures[ModelReference(id).id] = nil
        guard owedDownloads.contains(id) else { return }
        owedDownloads.removeAll { $0 == id }
        saveOwedDownloads()
    }

    /// The person cancelled `id`'s download (any revision of it): it's no longer owed, waiting, or stopped.
    func cancelDownload(_ id: String) {
        let key = ModelReference(id).id
        pendingDownloads.removeAll { ModelReference($0).id == key }
        downloadBatch.removeAll { ModelReference($0).id == key }
        downloadFailures[key] = nil
        if owedDownloads.contains(where: { ModelReference($0).id == key }) {
            owedDownloads.removeAll { ModelReference($0).id == key }
            saveOwedDownloads()
        }
        if owedDownloads.isEmpty { downloadsWaitForWiFi = false }
    }

    /// The person cancelled every download: nothing is owed, waiting, or stopped.
    func cancelAllDownloads() {
        pendingDownloads.removeAll()
        downloadBatch.removeAll()
        downloadFailures.removeAll()
        downloadsWaitForWiFi = false
        guard !owedDownloads.isEmpty else { return }
        owedDownloads.removeAll()
        saveOwedDownloads()
    }

    private func saveOwedDownloads() {
        guard let downloadsURL else { return }
        let data = try? JSONEncoder().encode(owedDownloads)
        Self.writes.async { if let data { try? data.write(to: downloadsURL, options: .atomic) } }
    }

    // MARK: Words

    /// What a conversation in the queue waits for, for "Waiting to transcribe after “Roadmap review”" or "Waiting to
    /// summarize after the download" (`ProcessingWords.waitingHere`). Nil when it isn't queued.
    func waiting(_ id: UUID, title: (UUID) -> String?) -> (mode: ProcessingRequest.Mode, behind: ProcessingWords.QueuedBehind)? {
        guard let position = jobs.firstIndex(where: { $0.meetingID == id }) else { return nil }
        let mode = jobs[position].mode
        if position > 0 { return (mode, .position(ahead: position + (runningID == nil ? 0 : 1))) }
        if let runningID { return (mode, .conversation(title(runningID) ?? "")) }
        if downloadingID != nil { return (mode, .download) }
        return (mode, .nothing)
    }
}

// MARK: - AppState's queue

/// The queue as `AppState` runs it: jobs are queued (`enqueue`), run one at a time (`runQueue`), paused, cancelled,
/// and given way to by model downloads.
extension AppState {
    func enqueue(_ id: UUID, mode: ProcessingRequest.Mode = .newAudio, upgrade: ProcessingRequest.Upgrade? = nil, summarizesHere: Bool = false) {
        guard id != recordingID, !queue.isQueued(id), let meeting = meetings.first(where: { $0.id == id }) else { return }
        // A conversation of an iPhone's own, queued only to check where its recording belongs, isn't owed: its mark
        // lives only while Daybook runs, and the next sync pass finds it again (`phoneTranscriptsToCheck`).
        if !checkingPhoneTranscripts.contains(id) { queue.owe(id, mode: mode, upgrade: upgrade) }
        let job = makeJob(meetingID: id, mode: mode, upgrade: upgrade, summarizesHere: summarizesHere)
        let hasNew = meeting.hasUntranscribedTranscribableAudio
        let missing = job.requiredModelIDs(hasUntranscribedAudio: hasNew).subtracting(installedModels)
        guard missing.isEmpty else {
            queue.awaitModels(id)
            update(id) { $0.errorMessage = nil }
            // Missing models leave another device's request unclaimed, for a Mac that has them.
            releaseRequests(in: id)
            reportToPhones(id, phase: .waitingForModels)
            return
        }
        // A request for the same work is carried out by this job, so it's claimed and finished with it.
        queue.add(carryingOpenRequest(job, in: meeting))
        reportToPhones(id, phase: .queued)
        runQueue()
    }

    func runQueue() {
        // Giving speakers voices gives way to real work: it stops, and starts the queue when it has.
        if voicingID != nil, !queue.jobs.isEmpty { voicingTask?.cancel(); return }
        guard queue.task == nil, readingPhotoID == nil, queue.downloadingID == nil, !library.isApplyingSync, !queue.jobs.isEmpty else { return }
        queue.task = Task { [weak self] in
            guard let self else { return }
            let queue = self.queue
            while !Task.isCancelled, let job = queue.next() {
                let id = job.meetingID
                // Never run a request another device holds, or one that finished elsewhere meanwhile.
                guard self.mayRun(job) else { queue.settle(id); continue }
                // Each job starts from nothing: no figure, and no step until the engine names one.
                self.processingProgress = IntelligenceProgress(0, "Starting")
                queue.start(job)
                self.startClaimHeartbeat()
                self.reportToPhones(id)
                // Each job runs in its own task so pausing one conversation lets the queue continue.
                let work = Task { try await self.process(job) }
                queue.currentRequest = work
                do {
                    try await work.value
                    self.finishRequests(of: queue.running ?? job, failure: nil)
                    self.reportToPhones(id, phase: .finished)
                    queue.finishRunning()
                    queue.settle(id)
                }
                catch is CancellationError {
                    if queue.claimsLost.remove(id) == nil {
                        queue.paused.insert(id)
                        self.releaseRequests(in: id)
                        self.reportToPhones(id, phase: .paused)
                    }
                    self.update(id) { $0.status = $0.summary == nil ? .imported : .ready; $0.errorMessage = nil }
                    queue.finishRunning()
                    // The person paused it, or another device took it over; quitting leaves it owed.
                    if !queue.isStopping { queue.settle(id) }
                }
                catch {
                    // The kind is kept as the error says it (a cloud key refused, models missing), not read back from words.
                    queue.failures[id] = .init(reason: error.localizedDescription, kind: ProcessingRequest.FailureKind(error))
                    self.update(id) { $0.status = .failed; $0.errorMessage = error.localizedDescription }
                    self.finishRequests(of: queue.running ?? job, failure: error)
                    self.reportToPhones(id, phase: .failed, detail: error.localizedDescription)
                    queue.finishRunning()
                    queue.settle(id)
                }
                self.stopClaimHeartbeat()
                self.phones.checkingTranscripts.remove(id)
                // Requests that waited for this conversation, or arrived meanwhile (not after Cancel).
                if !Task.isCancelled { self.pickUpRequests(start: false) }
            }
            queue.task = nil
            self.processingProgress = IntelligenceProgress(0, "Ready")
            self.collectOldModelRevisions()
            self.startPendingDownload()
            self.readNextPhotosWhenIdle()
            self.giveVoicesWhenIdle()
            self.listenToEarlierRecordingsWhenIdle()
        }
    }

    /// Stops everything, as Daybook quits. Requests this Mac held go back, so another Mac can take them, and stay
    /// paused here until the person resumes them; this Mac's own work stays owed, and the next launch queues it again.
    /// Reading photos and a model download stop with it.
    func cancelProcessing() {
        for job in queue.jobs where job.requestID != nil {
            queue.paused.insert(job.meetingID)
            releaseRequests(in: job.meetingID)
        }
        // The running job's request goes back now, not when its work notices the cancellation, so
        // a save right after (quitting) has it.
        if let running = queue.running, let requestID = running.requestID, !queue.claimsLost.contains(running.meetingID) {
            library.releaseProcessingRequest(requestID, in: running.meetingID)
        }
        queue.stopAll()
        // A model download stops too, and stays owed: the next launch takes it up again.
        queue.downloadTask?.cancel()
        photoReading?.cancel()
        photoRetry?.cancel()
    }

    /// Stops work on one conversation and keeps it paused; other conversations keep processing.
    /// A request it carried out goes back, for another Mac or until it's resumed.
    func pauseProcessing(_ id: UUID) {
        if processingID == id { queue.currentRequest?.cancel() }
        else if queue.isQueued(id) {
            queue.removeJobs(for: id)
            queue.paused.insert(id)
            queue.settle(id)
            releaseRequests(in: id)
            reportToPhones(id, phase: .paused)
        }
    }

    /// Removes a waiting conversation from the queue without marking it paused. A waiting request
    /// goes back and is paused here, so it isn't simply claimed again at the next sync.
    func cancelQueued(_ id: UUID) {
        let removed = queue.removeJobs(for: id)
        queue.settle(id)
        if removed.contains(where: { $0.requestID != nil && $0.requestID != runningJob?.requestID }) {
            queue.paused.insert(id)
            releaseRequests(in: id)
        }
    }

    /// At launch, once the library is open: the work this Mac owed when it last quit, restarted, or crashed is queued
    /// again, as it was asked for. What the person paused, what failed, and what's gone stay as they are; recorded audio
    /// that's transcribed and summarized already isn't done again. Work whose run Daybook didn't come back from a second
    /// time (`OwedWork.resumesAtLaunch`) is left to the person: the page offers Transcribe or Try Again. Then the model
    /// downloads it owed go on (`resumeOwedDownloads`), after the work that can run already.
    func resumeOwedWork() {
        for work in queue.owed {
            // Queued or running again already (a recovered recording, a request it carries out): nothing to add.
            guard processingID != work.meetingID, !queue.isQueued(work.meetingID) else { continue }
            guard work.resumesAtLaunch else { queue.settle(work.meetingID); continue }
            guard let meeting = meetings.first(where: { $0.id == work.meetingID }), meeting.status != .failed,
                  !queue.paused.contains(meeting.id) else { queue.settle(work.meetingID); continue }
            if work.mode == .newAudio, work.upgrade == nil, !meeting.hasUntranscribedTranscribableAudio,
               meeting.summary != nil || meeting.unifiedTranscript.isEmpty {
                queue.settle(work.meetingID)
                continue
            }
            enqueue(work.meetingID, mode: work.mode, upgrade: work.upgrade)
        }
        resumeOwedDownloads()
    }

    /// The next step for a conversation: transcribe audio that has none yet, otherwise summarize again.
    func defaultProcessingMode(for meeting: Meeting) -> ProcessingRequest.Mode {
        meeting.hasUntranscribedTranscribableAudio ? .newAudio : .summaryOnly
    }

    /// This Mac's queue, as `ProcessingStatus` reads it: the running job's step is the one the engine reports
    /// (`ProcessingProgress.stage`), or summarizing from when the conversation is marked so.
    var processingQueueState: ProcessingStatus.LocalQueue { queueState(readingProgress: true) }

    /// The one status the list, the conversation page, and device pages show (shared with the iPhone). Only the
    /// conversation being processed reads the job's progress, so a progress report redraws its row and page, not every row.
    func processingStatus(for meeting: Meeting) -> ProcessingStatus {
        let status = ProcessingStatus(meeting, queue: queueState(readingProgress: meeting.id == processingID))
        // A job of this Mac's own has no request to keep its failure's kind: the queue kept it where it caught the error.
        if case .failed(var failure) = status, failure.request == nil, let caught = queue.failures[meeting.id], caught.reason == failure.reason {
            failure.kind = caught.kind
            return .failed(failure)
        }
        return status
    }

    /// The queue, with the running job's progress and step when `readingProgress` (only the running conversation's
    /// status uses them).
    private func queueState(readingProgress: Bool) -> ProcessingStatus.LocalQueue {
        let progress = readingProgress ? processingProgress : IntelligenceProgress(0, "")
        let stage = progress.stage
        return ProcessingStatus.LocalQueue(running: processingID, fraction: progress.fraction,
                                           identifyingSpeakers: stage == .identifyingSpeakers,
                                           queued: queuedIDs, paused: pausedIDs, awaitingModels: awaitingModels, canProcess: canProcess,
                                           stage: stage)
    }

    /// What a conversation queued here was asked for (`ConversationStatusPresentation.Inputs.queuedMode`).
    func queuedMode(_ id: UUID) -> ProcessingRequest.Mode? { queue.jobs.first { $0.meetingID == id }?.mode }

    /// The queue waits for a model download before it goes on (`ConversationStatusPresentation.Inputs.queueWaitsForDownload`).
    var queueWaitsForDownload: Bool { queue.downloadingID != nil && processingID == nil && !queue.jobs.isEmpty }

    /// What a conversation in this Mac's queue is to say while it waits, from the job's mode and what's ahead of it:
    /// "Waiting to transcribe after “Roadmap review”", "Waiting to summarize after the download", and, short, "Waiting to
    /// transcribe" (`ProcessingWords`). Nil when it isn't queued here.
    func waitingWords(for id: UUID) -> (line: String, short: String)? {
        guard let waiting = queue.waiting(id, title: { other in meetings.first { $0.id == other }?.title }) else { return nil }
        return (ProcessingWords.waitingHere(waiting.mode, behind: waiting.behind), ProcessingWords.waitingHereShort(waiting.mode))
    }

    // MARK: Model downloads

    /// Starts `modelID`'s download unless something holds the queue, in which case it waits its turn. `asked`: the
    /// person's press started it just now, so if it fails an alert says so as well.
    func download(_ modelID: String, asked: Bool = false) {
        guard readingPhotoID == nil, queue.downloadingID == nil, processingID == nil else {
            if !queue.pendingDownloads.contains(modelID) { queue.pendingDownloads.insert(modelID, at: 0) }
            return
        }
        queue.downloadingID = modelID; downloadProgress = IntelligenceProgress(0, "Preparing download…")
        if !queue.downloadBatch.contains(modelID) { queue.downloadBatch.append(modelID) }
        queue.downloadTask = Task { [weak self] in
            guard let self else { return }
            let queue = self.queue
            var stopped = false
            do {
                let activity = queue.downloadActivity
                let report: IntelligenceProgressHandler = { progress in activity.report(progress) }
                if let fetch = queue.fetchModel { try await fetch(modelID, report) } else { try await self.runtime.download(modelID: modelID, progress: report) }
                await self.refreshInstalledModels()
                self.collectOldModelRevisions()
                queue.settleDownload(modelID)
            } catch where error is CancellationError || Task.isCancelled {
                // The person's Cancel; or quitting, which leaves it owed for the next launch.
                stopped = true
                if !queue.isStopping { self.notice = "Download canceled." }
            } catch {
                stopped = true
                self.downloadFailed(modelID, error: error, asked: asked)
            }
            queue.downloadingID = nil; queue.downloadTask = nil
            guard !queue.isStopping else { return }
            if !stopped, !queue.pendingDownloads.isEmpty {
                self.download(queue.pendingDownloads.removeFirst())
            } else {
                // Done, cancelled, or stopped by a failure, which doesn't run on into the next: what's left stays owed.
                queue.pendingDownloads.removeAll()
                queue.downloadBatch.removeAll()
                if self.canProcess { for id in queue.awaitingModels.sorted(by: { $0.uuidString < $1.uuidString }) { self.enqueue(id) } }
                self.runQueue()
                self.readNextPhotosWhenIdle()
                self.listenToEarlierRecordingsWhenIdle()
            }
        }
    }

    /// A download stopped on its own: it says so where the models show ("Couldn’t download Gemma 4 12B" with Try Again),
    /// and the log has the system's words. Only a download the person's press started just now is an alert too. It and
    /// what was to follow stay owed, for Try Again, the next launch, or the network coming back.
    func downloadFailed(_ modelID: String, error: Error, asked: Bool) {
        let key = ModelReference(modelID).id
        queue.downloadFailures[key] = error.localizedDescription
        Self.log.error("Couldn’t download \(modelID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        watchNetworkForDownloads()
        guard asked else { return }
        let name = shortModelName(key)
        if DiskSpace.isOutOfSpace(error) {
            problem = AppProblem(title: "Couldn’t Download \(name)", message: DiskSpace.freeUpSentence(ModelSize.bytes([key], in: modelCatalog)),
                                 details: error.localizedDescription)
        } else {
            report("Couldn’t Download \(name)", "Check your internet connection and try again.", error)
        }
    }

    /// The person's Cancel: the download under way stops, and nothing asked for is owed any more.
    func cancelDownload() {
        queue.cancelAllDownloads()
        queue.downloadTask?.cancel()
    }

    /// Downloads every listed model that isn't here, one after another, and keeps each owed until it is. `asked`: the
    /// person pressed Download or Try Again (Welcome, Settings › Models, the page, Floating Notes), on whatever network
    /// this is: whatever else is owed follows what they asked for, and the first is theirs (`download(_:asked:)`). The
    /// downloads that go on by themselves pass false.
    func downloadModels(_ ids: [String], asked: Bool = true) {
        var wanted = ids
        if asked {
            wanted += queue.owedDownloads.filter { !ids.contains($0) }
            queue.downloadsWaitForWiFi = false
        }
        // What stopped before is tried again.
        for id in wanted { queue.downloadFailures[ModelReference(id).id] = nil }
        let missing = wanted.reduce(into: [String]()) { missing, id in
            guard !installedModels.contains(id), id != queue.downloadingID, !queue.pendingDownloads.contains(id), !missing.contains(id) else { return }
            missing.append(id)
        }
        queue.oweDownloads(missing)
        queue.pendingDownloads += missing
        startPendingDownload(asked: asked)
    }

    /// The models the current choices need that aren't on this Mac yet.
    var missingSelectedModels: [String] {
        routedRequiredModelIDs.reduce(into: [String]()) { if !installedModels.contains($1) && !$0.contains($1) { $0.append($1) } }
    }

    func startPendingDownload(asked: Bool = false) {
        guard queue.downloadingID == nil, processingID == nil, readingPhotoID == nil, !queue.pendingDownloads.isEmpty else { return }
        download(queue.pendingDownloads.removeFirst(), asked: asked)
    }

    /// Takes one model off the downloads (the model manager's Cancel while it waits its turn, for Wi‑Fi, or after it
    /// stopped): it's no longer owed.
    func removePendingDownload(_ id: String) { queue.cancelDownload(id) }

    // MARK: Owed downloads

    /// At launch, once what's on this Mac is known: the downloads owed when Daybook last ran go on by themselves over
    /// Wi‑Fi or a wired network; on a hotspot or with Low Data Mode they wait for one ("Waiting for Wi‑Fi"), as they do
    /// on the iPhone. The network is watched from then on, so they go on when it comes back.
    func resumeOwedDownloads() {
        for id in queue.owedDownloads where installedModels.contains(id) { queue.settleDownload(id) }
        guard !queue.owedDownloads.isEmpty else { return }
        watchNetworkForDownloads()
        goOnWithOwedDownloads(queue.network.condition())
    }

    /// The owed downloads go on when the network is unrestricted and nothing is downloading, trying again what stopped;
    /// otherwise they wait for Wi‑Fi.
    func goOnWithOwedDownloads(_ condition: SyncNetworkCondition) {
        guard !queue.owedDownloads.isEmpty, queue.downloadingID == nil, queue.pendingDownloads.isEmpty else { return }
        guard condition == .unrestricted else { queue.downloadsWaitForWiFi = true; return }
        queue.downloadsWaitForWiFi = false
        downloadModels(queue.owedDownloads, asked: false)
    }

    /// Watches the network, once, for the owed downloads to go on when it comes back.
    func watchNetworkForDownloads() {
        guard !queue.watchesNetwork else { return }
        queue.watchesNetwork = true
        queue.network.watch { [weak self] condition in self?.goOnWithOwedDownloads(condition) }
    }

    // MARK: Downloads in words

    /// This Mac's model downloads as the one fact every surface says them from (`ModelDownloadState`): the whole set
    /// asked for arriving ("Downloading models · 40%"), a download that stopped, or the owed ones waiting for Wi‑Fi. Nil
    /// when nothing downloads and nothing owed needs saying.
    var modelDownloadState: ModelDownloadState? {
        if let current = queue.downloadingID {
            let keys = Self.modelKeys(queue.downloadBatch + [current] + queue.pendingDownloads)
            return .downloading(done: ModelSize.downloaded(keys, in: self), total: ModelSize.bytes(keys, in: modelCatalog))
        }
        let owed = Self.modelKeys(queue.owedDownloads).filter { !installedModels.contains($0) }
        guard !owed.isEmpty else { return nil }
        let bytes = ModelSize.bytes(owed, in: modelCatalog)
        if let failed = owed.first(where: { queue.downloadFailures[$0] != nil }) { return .failed(model: shortModelName(failed), bytes: bytes) }
        return queue.downloadsWaitForWiFi ? .waitingForWiFi(bytes: bytes) : nil
    }

    /// The owed downloads waiting for Wi‑Fi, by variant key (Settings › Models' "Waiting for Wi‑Fi"); one that stopped
    /// says so instead.
    var downloadsWaitingForWiFi: Set<String> {
        guard queue.downloadsWaitForWiFi, queue.downloadingID == nil else { return [] }
        return Set(Self.modelKeys(queue.owedDownloads)).subtracting(queue.downloadFailures.keys)
    }

    /// What this Mac can do about a conversation's processing, for its page and row: what its choices still need to
    /// download, and how its downloads stand.
    var localCapabilities: ConversationStatusPresentation.LocalCapabilities {
        .mac(missingModelBytes: ModelSize.bytes(missingSelectedModels, in: modelCatalog), models: modelDownloadState)
    }

    /// What downloading the models the choices still need takes, or nil when they're here: Floating Notes' "Download ·
    /// 0.9 GB".
    var missingSelectedBytes: Int64? {
        let missing = missingSelectedModels
        return missing.isEmpty ? nil : ModelSize.bytes(missing, in: modelCatalog)
    }

    /// A model's short name, as lists of models say it ("Gemma 4 12B 4-bit", "Community-1").
    func shortModelName(_ key: String) -> String {
        modelCatalog.model(key).map { ModelSize.shortName($0, in: modelCatalog) } ?? modelCatalog.name(for: key)
    }

    /// Variant keys, each once, in order ("key@revision" names the variant's key).
    private static func modelKeys(_ ids: [String]) -> [String] {
        ids.map { ModelReference($0).id }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    #if DEBUG
    /// Demos (`--model-demo failed:<key>|wifi:<key>`, `--notes-demo models|models-failed`): `ids` owed and stopped, or
    /// waiting for Wi‑Fi, or arriving through a download that reports 42% and then waits, never the network.
    enum DownloadDemo { case downloading, failed, waitingForWiFi }

    func demoDownloads(_ ids: [String], _ demo: DownloadDemo) {
        switch demo {
        case .downloading:
            queue.fetchModel = { _, progress in
                progress(IntelligenceProgress(0.42, "Downloading"))
                try await Task.sleep(for: .seconds(24 * 3600))
            }
            downloadModels(ids, asked: false)
        case .failed:
            queue.oweDownloads(ids)
            if let first = ids.first { queue.downloadFailures[ModelReference(first).id] = "The Internet connection appears to be offline." }
        case .waitingForWiFi:
            queue.oweDownloads(ids)
            queue.downloadsWaitForWiFi = true
        }
    }
    #endif
}

/// The network downloads that go on by themselves go by (`NetworkConditionMonitor`): unrestricted is Wi‑Fi or a wired
/// network, not Low Data Mode; a hotspot, Low Data Mode, or no network at all is restricted. Tests replace it.
struct DownloadNetwork {
    /// The condition now.
    var condition: @MainActor () -> SyncNetworkCondition
    /// Calls `changed` on the main actor whenever the condition changes, for as long as Daybook runs.
    var watch: @MainActor (@escaping @MainActor @Sendable (SyncNetworkCondition) -> Void) -> Void

    static func system() -> DownloadNetwork {
        let monitor = NetworkConditionMonitor()
        return DownloadNetwork(condition: { monitor.condition }, watch: { changed in
            monitor.onChange { condition in Task { @MainActor in changed(condition) } }
        })
    }
}
