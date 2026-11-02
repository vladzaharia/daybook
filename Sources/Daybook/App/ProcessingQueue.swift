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

    /// Where the owed work is kept; nil keeps it in memory only.
    @ObservationIgnored let owedURL: URL?
    /// The work owed, by conversation, in the order it was asked for.
    @ObservationIgnored private(set) var owed: [OwedWork] = []

    init(owedURL: URL?) {
        self.owedURL = owedURL
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
    /// it's settled.
    func loadOwedWork() {
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
    func enqueue(_ id: UUID, mode: ProcessingRequest.Mode = .newAudio, upgrade: ProcessingRequest.Upgrade? = nil) {
        guard id != recordingID, !queue.isQueued(id), let meeting = meetings.first(where: { $0.id == id }) else { return }
        // A conversation of an iPhone's own, queued only to check where its recording belongs, isn't owed: its mark
        // lives only while Daybook runs, and the next sync pass finds it again (`phoneTranscriptsToCheck`).
        if !checkingPhoneTranscripts.contains(id) { queue.owe(id, mode: mode, upgrade: upgrade) }
        let job = makeJob(meetingID: id, mode: mode, upgrade: upgrade)
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
    /// Reading photos stops with it.
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
    /// time (`OwedWork.resumesAtLaunch`) is left to the person: the page offers Transcribe or Try Again.
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

    func download(_ modelID: String) {
        if readingPhotoID != nil {
            if !queue.pendingDownloads.contains(modelID) { queue.pendingDownloads.append(modelID) }
            return
        }
        guard queue.downloadingID == nil, processingID == nil else { return }
        queue.downloadingID = modelID; downloadProgress = IntelligenceProgress(0, "Preparing download…")
        queue.downloadTask = Task { [weak self] in
            guard let self else { return }
            let queue = self.queue
            do {
                let activity = queue.downloadActivity
                try await self.runtime.download(modelID: modelID) { progress in activity.report(progress) }
                await self.refreshInstalledModels()
                self.collectOldModelRevisions()
            } catch is CancellationError { self.notice = "Download canceled." }
            catch where DiskSpace.isOutOfSpace(error) {
                self.problem = AppProblem(title: "Couldn’t Download the Model",
                                          message: DiskSpace.freeUpSentence(ModelSize.bytes([modelID], in: self.modelCatalog)),
                                          details: error.localizedDescription)
            }
            catch { self.report("Couldn’t Download the Model", "Check your internet connection and try again.", error) }
            queue.downloadingID = nil; queue.downloadTask = nil
            if !Task.isCancelled, !queue.pendingDownloads.isEmpty {
                self.download(queue.pendingDownloads.removeFirst())
            } else {
                queue.pendingDownloads.removeAll()
                if self.canProcess { for id in queue.awaitingModels.sorted(by: { $0.uuidString < $1.uuidString }) { self.enqueue(id) } }
                self.runQueue()
                self.readNextPhotosWhenIdle()
                self.listenToEarlierRecordingsWhenIdle()
            }
        }
    }

    func cancelDownload() { queue.pendingDownloads.removeAll(); queue.downloadTask?.cancel() }

    /// Downloads every listed model that isn't installed, one after another.
    func downloadModels(_ ids: [String]) {
        let missing = ids.filter { !installedModels.contains($0) && $0 != queue.downloadingID && !queue.pendingDownloads.contains($0) }
        queue.pendingDownloads += missing
        startPendingDownload()
    }

    /// The models the current choices need that aren't on this Mac yet.
    var missingSelectedModels: [String] {
        routedRequiredModelIDs.reduce(into: [String]()) { if !installedModels.contains($1) && !$0.contains($1) { $0.append($1) } }
    }

    func startPendingDownload() {
        guard queue.downloadingID == nil, processingID == nil, readingPhotoID == nil, !queue.pendingDownloads.isEmpty else { return }
        download(queue.pendingDownloads.removeFirst())
    }

    /// Takes one waiting model off the download queue (the model manager's Cancel).
    func removePendingDownload(_ id: String) { queue.pendingDownloads.removeAll { ModelReference($0).id == ModelReference(id).id } }
}
