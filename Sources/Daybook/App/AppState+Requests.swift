import DaybookCore
import DaybookKit
import Foundation

/// How long a claim lasts and how often it's renewed while the work runs.
struct RequestTiming {
    /// A claim not renewed for this long expires, and another Mac may take the request over.
    var lease: TimeInterval = ProcessingRequest.defaultLease
    /// The heartbeat: renewed this often while the job runs, and at every change of stage.
    var renewInterval: Duration = .seconds(60)
}

/// Processing other devices ask for (docs/iphone.md, "Processing on the Mac"). A request is synced
/// library data; this Mac's queue carries it out:
///
/// - **Pick up.** After every sync pass, a finished job, a model download, and at launch, each open
///   request this Mac may take (unclaimed, its own, or with an expired claim) is queued, when this
///   Mac transcribes synced recordings (or the request brings a recording the conversation was
///   waiting for: Mac first) and has the models for that work. Otherwise it stays unclaimed (and a
///   claim this Mac held goes back). One job per conversation: a job already
///   queued or running for it takes the request on.
/// - **Claim.** When its job starts, the request is claimed with a lease, unless another device
///   holds it, in which case the job is dropped: a request another live Mac holds never runs here.
///   Claiming at the start, not in the queue, means the phone reads "Waiting" while it waits here,
///   and a Mac busy with a long job leaves the request to another. While it runs, the claim is
///   renewed with the stage and fraction (the heartbeat), and sync passes keep running to publish it.
/// - **Finish.** The request is completed or failed with the reason. Pause and Cancel give it back.
/// - **Lose.** A sync pass that shows another device holding the request (both claimed at once; the
///   newest claim wins the merge) stops this Mac's job without pausing it or touching the request.
///
/// Stale claims: a claim whose lease ran out (a Mac that vanished, or quit without syncing) is
/// claimable, and claiming it starts a strictly newer claim that wins every merge. Claims are
/// never cleared outright (`expireStaleClaims`): the merge keeps the newest claim, so a cleared one
/// would come back from the other copies at every pass.
///
/// This Mac writes no requests for its own work. Its queue is live on this Mac, phones see it
/// over the link, and a request per job would double every job's sync traffic. It only completes
/// requests its own work satisfied, so their status stays consistent everywhere.
extension AppState {
    // MARK: Picking up

    /// Claims and queues the open requests this Mac can carry out. `start: false` only queues them
    /// (the queue is running and will reach them).
    func pickUpRequests(start: Bool = true) {
        guard isReady, library.isLoaded else { return }
        let me = library.thisDevice, now = Date()
        for meeting in meetings {
            for request in meeting.openProcessingRequests where request.isClaimable(by: me, at: now) && !isCarried(request.id) {
                // An upgrade is for the device with the better model (or one as good): another Mac's is left to it.
                guard mayCarryOut(request) else { continue }
                let held = request.isClaimed(by: me, at: now)
                // Done already (this Mac transcribed the audio as it arrived, say): say so.
                if request.isSatisfied(by: meeting) {
                    library.completeProcessingRequest(request.id, in: meeting.id, at: now)
                    continue
                }
                let job = job(for: request, in: meeting)
                let models = job.requiredModelIDs(hasUntranscribedAudio: meeting.hasUntranscribedTranscribableAudio)
                // A recording the conversation was waiting for is added whatever the setting (Mac first).
                guard processSyncedAudio || meeting.hasAwaitedRecordingToAdd(now: now), models.isSubset(of: installedModels), meeting.id != recordingID,
                      !pausedIDs.contains(meeting.id), !movedPhoneRecordings.contains(meeting.id) else {
                    if held { library.releaseProcessingRequest(request.id, in: meeting.id, at: now) }
                    continue
                }
                // One job per conversation: one queued or running already takes the request on. The
                // running one claims it now; a queued one when it starts.
                if let running = runningJob, running.meetingID == meeting.id {
                    if running.requestID == nil, Self.covers(running.mode, request.mode), let claimed = claim(request) {
                        runningJob = running.carrying(claimed)
                        startClaimHeartbeat()
                        // Another device asked for its summary (its own countdown ran out): no second countdown here.
                        if request.mode != .newAudio, request.requestedBy.id != me.id, placements[meeting.id] != nil {
                            placements.begin(meeting.id, immediately: true)
                        }
                    }
                    continue
                }
                if let index = processingQueue.firstIndex(where: { $0.meetingID == meeting.id }) {
                    if processingQueue[index].requestID == nil, Self.covers(processingQueue[index].mode, request.mode) {
                        processingQueue[index] = processingQueue[index].carrying(request)
                    }
                    continue
                }
                awaitingModels.remove(meeting.id)
                processingQueue.append(job.carrying(request))
                reportToPhones(meeting.id, phase: .queued)
            }
        }
        if start { runQueue() }
    }

    /// A job carrying out `request`, frozen with this Mac's models and preferences.
    func job(for request: ProcessingRequest, in meeting: Meeting) -> ProcessingJob {
        makeJob(meetingID: meeting.id, mode: request.mode, templateID: request.templateID)
    }

    /// A local job for `meeting` takes on an open request it also satisfies; it's claimed when the job starts.
    func carryingOpenRequest(_ job: ProcessingJob, in meeting: Meeting) -> ProcessingJob {
        guard job.requestID == nil else { return job }
        let me = library.thisDevice, now = Date()
        guard let request = meeting.openProcessingRequests.first(where: {
            $0.isClaimable(by: me, at: now) && !isCarried($0.id) && !$0.isSatisfied(by: meeting) && Self.covers(job.mode, $0.mode) && mayCarryOut($0)
        }) else { return job }
        return job.carrying(request)
    }

    /// Whether a job in `mode` also does what a request in `asked` mode asks for.
    static func covers(_ mode: ProcessingRequest.Mode, _ asked: ProcessingRequest.Mode) -> Bool {
        switch (mode, asked) {
        case let (a, b) where a == b: return true
        case (.newAudio, .summaryOnly), (.fullRetranscription, .newAudio), (.fullRetranscription, .summaryOnly): return true
        default: return false
        }
    }

    /// Whether this Mac may carry out `request`: any request, except an upgrade asked of another device whose model
    /// for the step is better than this Mac's (docs/multipoint.md, "Upgrade").
    func mayCarryOut(_ request: ProcessingRequest) -> Bool {
        guard let upgrade = request.upgrade else { return true }
        return upgrade.mayBeCarriedOut(by: library.thisDevice, models: processingCapabilities.models, ranks: upgradeRanks)
    }

    private func claim(_ request: ProcessingRequest) -> ProcessingRequest? {
        library.claimProcessingRequest(request.id, in: request.meetingID, lease: requestTiming.lease)
    }

    /// A job queued or running carries the request out already.
    private func isCarried(_ requestID: UUID) -> Bool {
        runningJob?.requestID == requestID || processingQueue.contains { $0.requestID == requestID }
    }

    func request(_ requestID: UUID, in meetingID: UUID) -> ProcessingRequest? {
        meetings.first { $0.id == meetingID }?.processingRequests?.first { $0.id == requestID }
    }

    /// Another device holds a live claim on an open request for this conversation.
    func isHeldElsewhere(_ meetingID: UUID, at now: Date = Date()) -> Bool {
        let me = library.thisDevice.id
        return meetings.first { $0.id == meetingID }?.openProcessingRequests.contains {
            guard let holder = $0.activeClaim(at: now) else { return false }
            return holder.device.id != me
        } ?? false
    }

    // MARK: Running

    /// Just before a job runs, its request is claimed: it must still be open, nobody else may hold
    /// it, and the models it needs must be here. Otherwise the job is dropped (a claim goes back).
    func mayRun(_ job: ProcessingJob) -> Bool {
        guard let requestID = job.requestID else { return true }
        guard let request = request(requestID, in: job.meetingID), request.isOpen else { return false }
        let me = library.thisDevice, now = Date()
        guard let meeting = meetings.first(where: { $0.id == job.meetingID }),
              job.requiredModelIDs(hasUntranscribedAudio: meeting.hasUntranscribedTranscribableAudio).isSubset(of: installedModels) else {
            if request.isClaimed(by: me, at: now) { library.releaseProcessingRequest(requestID, in: job.meetingID, at: now) }
            return false
        }
        if request.isClaimed(by: me, at: now) { return true }
        return claim(request) != nil
    }

    /// The finished job's request is completed (or failed with the reason), along with any other
    /// open request on the conversation that the work satisfied.
    func finishRequests(of job: ProcessingJob, failure: String?) {
        let id = job.meetingID, me = library.thisDevice, now = Date()
        if let requestID = job.requestID {
            if let failure { library.failProcessingRequest(requestID, in: id, reason: failure, at: now) }
            else { library.completeProcessingRequest(requestID, in: id, at: now) }
        }
        guard failure == nil, let meeting = meetings.first(where: { $0.id == id }) else { return }
        for request in meeting.openProcessingRequests where request.isSatisfied(by: meeting) && request.isClaimable(by: me, at: now) {
            library.completeProcessingRequest(request.id, in: id, at: now)
        }
    }

    /// Gives back what this Mac holds on a conversation's requests (paused, cancelled, models
    /// missing), so another Mac can take them.
    func releaseRequests(in meetingID: UUID) {
        guard let meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        let me = library.thisDevice, now = Date()
        for request in meeting.openProcessingRequests where request.isClaimed(by: me, at: now) && request.id != runningJob?.requestID {
            library.releaseProcessingRequest(request.id, in: meetingID, at: now)
        }
        if let running = runningJob, running.meetingID == meetingID, let requestID = running.requestID, currentRequest?.isCancelled != false {
            library.releaseProcessingRequest(requestID, in: meetingID, at: now)
        }
    }

    // MARK: The heartbeat

    func startClaimHeartbeat() {
        claimHeartbeat?.cancel()
        claimHeartbeat = nil
        lastRenewedStage = nil
        guard runningJob?.requestID != nil else { return }
        renewRunningClaim(force: true)
        let interval = requestTiming.renewInterval
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
        guard let job = runningJob, let requestID = job.requestID, currentRequest?.isCancelled != true else { return }
        let stage = runningStage
        let interval = Double(requestTiming.renewInterval.components.seconds) + Double(requestTiming.renewInterval.components.attoseconds) / 1e18
        guard force || stage != lastRenewedStage || Date().timeIntervalSince(lastClaimRenewal) >= interval else { return }
        lastClaimRenewal = Date()
        lastRenewedStage = stage
        if library.renewProcessingClaim(requestID, in: job.meetingID, stage: stage, fraction: processingProgress.fraction,
                                        lease: requestTiming.lease) == nil {
            reconcileClaims()
        }
    }

    /// What the running job is doing, as requests record it.
    var runningStage: ProcessingRequest.Stage {
        guard let id = processingID, let meeting = meetings.first(where: { $0.id == id }),
              case .processing(let progress) = processingStatus(for: meeting) else { return .transcribing }
        return progress.stage
    }

    func processingProgressChanged() {
        renewRunningClaim(force: false)
        if let id = processingID { reportToPhones(id) }
    }

    // MARK: After a sync pass

    /// Stops work on requests another device now holds or that finished elsewhere: the running
    /// job (not paused; the request isn't this Mac's any more) and queued ones.
    func reconcileClaims() {
        let me = library.thisDevice.id, now = Date()
        func lost(_ job: ProcessingJob) -> Bool {
            guard let requestID = job.requestID, let request = request(requestID, in: job.meetingID) else { return job.requestID != nil }
            if !request.isOpen { return true }
            guard let holder = request.activeClaim(at: now) else { return false }
            return holder.device.id != me
        }
        if let running = runningJob, lost(running), currentRequest?.isCancelled == false {
            claimsLost.insert(running.meetingID)
            currentRequest?.cancel()
            if let request = running.requestID.flatMap({ request($0, in: running.meetingID) }), request.isOpen,
               let holder = request.activeClaim(at: now)?.device.name {
                notice = "\(holder) is transcribing “\(meetings.first { $0.id == running.meetingID }?.title ?? "a conversation")”."
            }
        }
        processingQueue.removeAll(where: lost)
    }

    // MARK: Presence

    /// Other devices see this Mac in its presence record and over the link, with whether it can
    /// process (it has the models automatic processing needs and transcribes synced recordings) and
    /// what it does for them with which models (`advertisedCapabilities`).
    func presenceChanged() {
        let processes = canProcess && processSyncedAudio
        // What it does for other devices, role by role, with the models it would use (docs/multipoint.md,
        // "Where summaries run").
        let capabilities = advertisedCapabilities
        let identity = SyncDeviceIdentity(deviceClass: .mac, displayName: library.thisDevice.name, canProcess: processes,
                                          capabilities: capabilities.presence)
        if sync.replica.device != identity {
            let gained = sync.replica.device?.canProcess == false && processes
            sync.updatePresence(identity)
            sync.requestSync()
            if gained { pickUpRequests() }
        }
        Task { await phoneLink.update { $0.canProcess = processes; $0.processing = capabilities.link } }
    }

    /// The link carries the sync library's ID, so a phone offers the Mac that shares its library.
    func syncedLibraryIdentity() async {
        guard let id = await sync.libraryID(), phoneLink.identity.libraryID != id else { return }
        await phoneLink.update { $0.libraryID = id }
    }

    // MARK: Words for the interface

    /// "Requested from Alex’s iPhone" while this Mac carries out a request another device made.
    func requestOrigin(for meeting: Meeting) -> String? {
        let job = runningJob?.meetingID == meeting.id ? runningJob : processingQueue.first { $0.meetingID == meeting.id }
        guard let requestID = job?.requestID, let request = meeting.processingRequests?.first(where: { $0.id == requestID }),
              request.requestedBy.id != library.thisDevice.id else { return nil }
        let name = request.requestedBy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Requested from iPhone" : "Requested from \(name)"
    }
}
