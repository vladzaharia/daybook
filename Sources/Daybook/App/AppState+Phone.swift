import AppKit
import AVFoundation
import Combine
import DaybookCore
import DaybookKit
import DaybookLink
import Foundation

/// Starts and stops this Mac's capture when a phone asks. Nil uses the real recorder; tests supply
/// their own so nothing touches the microphone.
struct PhoneCapture {
    /// Records into the conversation; true once recording.
    var start: (@MainActor (UUID) async -> Bool)?
    var stop: (@MainActor (UUID) async -> Void)?
}

/// Daybook on iPhone, from this Mac's side: pairing, the paired phones as devices, record control
/// in both directions, live progress for phones, their nudges, and their recordings joining
/// conversations once they arrive through sync (docs/iphone.md, docs/multipoint.md).
extension AppState {
    /// This Mac on the link. Its device ID is its sync replica's, so a phone can match a paired
    /// Mac with its presence record and with the claims it makes on requests.
    static func linkIdentity(sync: LibrarySyncController, defaults: UserDefaults) -> LinkIdentity {
        let id: UUID
        if let replica = UUID(uuidString: sync.deviceID) { id = replica }
        else if let stored = defaults.string(forKey: "linkDeviceID").flatMap(UUID.init(uuidString:)) { id = stored }
        else { id = UUID(); defaults.set(id.uuidString, forKey: "linkDeviceID") }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return LinkIdentity(deviceID: id, name: ProcessingRequest.Device.currentName, deviceClass: .mac, appVersion: version,
                            canProcess: false, features: ["recordControl", "processingProgress", LinkCapabilities.recorderHandoffFeature],
                            syncDeviceID: sync.deviceID)
    }

    /// Connects the link to the library and the devices. Call once from `init`.
    func wirePhones() {
        phoneLink.onPaired = { [weak self] device in self?.phonePaired(device) }
        phoneLink.onUnpaired = { [weak self] id in self?.phoneUnpaired(id) }
        phoneLink.onMessage = { [weak self] message, phone in self?.phoneSaid(message, from: phone) }
        phoneLink.onConnected = { [weak self] peer in self?.phoneConnected(peer) }
        phoneLink.recordHandler = { [weak self] peer, request in
            guard let self else { return .refused(LinkRecordRefusal(reason: .unsupported)) }
            return await self.answerPhone(request, from: peer)
        }
        // Phones hear what this Mac records: when that changes, every 15 s meanwhile, and as they connect.
        phoneLink.localRecordingState = { [weak self] in
            // Sent every 15 s while recording: also when a phone this Mac records for has been gone too long.
            self?.checkPhoneLead()
            return self?.macRecordingState() ?? LinkRecordingState(phase: .idle)
        }
        Publishers.CombineLatest3($recordingID, $isStartingRecording, $isStoppingRecording)
            .map { RecordingPhaseKey(recording: $0, starting: $1, stopping: $2) }
            .removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.phoneLink.sendRecordingState() } }
            .store(in: &subscriptions)
        // And what the recorders this Mac manages are doing, when that changes.
        devices.recorderChanges()
            .sink { [weak self] in self?.phoneLink.sendRecordingState(onlyIfRecordersChanged: true) }
            .store(in: &subscriptions)
        // The phone's synced recordings list follows sync being on or off.
        sync.$folder.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.phoneSessions.forEach { $0.connection(.files)?.refresh() } }
        }.store(in: &subscriptions)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.systemDidWake() }
        }
        // Going to sleep while recording, the devices recording along hear the stop first.
        recorder.beforeSleep = { [weak self] in await self?.prepareForSleep(within: RecordingController.sleepGrace) }
    }

    /// Paired phones, as devices.
    var phoneSessions: [DeviceSession] { devices.sessions.filter { $0.kind.id == DaybookPhoneIntegration.id } }

    /// At launch: the link runs when a phone is paired. The keychain is the record of pairings;
    /// a pairing whose device was removed from preferences is added back.
    func startPhoneLinkIfPaired() async {
        guard !phoneSessions.isEmpty, await phoneLink.start() else { return }
        for device in phoneLink.paired where devices.session(device.deviceID.uuidString) == nil { phonePaired(device) }
    }

    /// After sleep the link probes every phone and reopens its listener; a claim this Mac holds is
    /// renewed (it survives sleep unless another Mac took it over meanwhile), and a pass publishes it.
    func systemDidWake() async {
        await phoneLink.systemDidWake()
        renewRunningClaim(force: true)
        sync.requestSync()
    }

    // MARK: Pairing

    /// Add iPhone…: opens pairing; the sheet shows `phoneLink.pairing`.
    func beginPhonePairing() { Task { await phoneLink.beginPairing() } }
    func endPhonePairing() { Task { await phoneLink.endPairing() } }

    /// Unpairs a phone on both sides. Its device leaves the sidebar; its recordings stay.
    func unpairPhone(_ phoneID: UUID) { Task { await phoneLink.unpair(phoneID) } }

    private func phonePaired(_ device: LinkPairedDevice) {
        let kind = DaybookPhoneIntegration().kind
        if let session = devices.session(device.deviceID.uuidString) {
            session.connections.forEach { $0.refresh() }
        } else {
            devices.add(ConfiguredDevice(id: device.deviceID.uuidString, kind: kind, name: device.name, addedAt: device.pairedAt))
        }
    }

    private func phoneUnpaired(_ phoneID: UUID) {
        let id = phoneID.uuidString
        if devices.session(id) != nil { removeDevice(id) }
        Task { await phoneLink.stopIfIdle() }
    }

    private func phoneConnected(_ peer: LinkPeer) {
        // A phone that reconnects while this Mac processes sees where it is at once.
        if let id = processingID { reportToPhones(id, force: true) }
        // A stop this Mac couldn't deliver goes now.
        sources.recorders.reconnected(peer.deviceID.uuidString)
    }

    /// This Mac's recorder, as phones see it.
    func macRecordingState(now: Date = Date()) -> LinkRecordingState {
        let phase: LinkRecordingState.Phase = isStoppingRecording ? .stopping : recordingID != nil ? .recording : isStartingRecording ? .starting : .idle
        // A recorder recording along with this Mac's recording says which conversation.
        let links = recordingID.flatMap { id in meetings.first { $0.id == id }?.companions } ?? []
        let recorders = LinkRecorderState.states(of: sources.recorders.sessions()) { session in
            links.contains { $0.deviceID == session.id && $0.macEndedAt == nil && [.recording, .alreadyRecording].contains($0.state) } ? self.recordingID : nil
        }
        return LinkRecordingState(phase: phase, conversationID: recordingID, startedAt: recordingStartedAt,
                                  elapsed: recordingStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0, sentAt: now,
                                  recorders: recorders)
    }

    // MARK: Messages from phones

    private func phoneSaid(_ message: LinkMessage, from phone: UUID) {
        switch message {
        case .processingNudge:
            // "I just wrote a request": look now rather than at the next pass.
            Task { await synchronizeLibrary(); pickUpRequests() }
        case .bookmark(let mark):
            // A bookmark on the phone while this Mac records the same conversation, at this Mac's time.
            // It keeps the phone's ID, so the phone's own copy, arriving with its recording, is the same bookmark.
            guard recordingID == mark.conversationID, let start = recordingStartedAt else { return }
            let clock = phoneLink.peers[phone]?.clock
            let when = clock?.localDate(fromPeer: mark.createdAt) ?? mark.createdAt
            library.addBookmark(id: mark.id, in: mark.conversationID, at: max(0, when.timeIntervalSince(start)))
        case .recordingState(let state):
            phoneReported(state, from: phone)
        case .processingProgress:
            break
        case .recorderHandoffRequest, .recorderHandoffReply, .recorderRelease:
            recorderHandoff.receive(message, from: phone)
        }
    }

    // MARK: Recording for a phone

    /// A phone said what it's recording. When this Mac records because that phone asked, and the
    /// phone has stopped (or moved on to another conversation), this Mac stops too and says so: the
    /// phone's stop may never have arrived.
    func phoneReported(_ state: LinkRecordingState, from phone: UUID) {
        guard let id = recordingID, let lead = phoneLeads[id], lead.sessionID == phone.uuidString else { return }
        guard state.conversationID != id || state.phase == .idle else { return }
        stopFollowing(id, because: "\(lead.deviceName) stopped recording, so this Mac stopped too.")
    }

    /// A phone this Mac records for, not heard from for this long, is taken to have stopped.
    static let phoneLeadSilenceLimit: TimeInterval = 30 * 60

    /// While recording for a phone: one that has been unreachable for `phoneLeadSilenceLimit` won't
    /// stop this recording itself, so this Mac does. Checked with every state this Mac sends.
    func checkPhoneLead(now: Date = Date()) {
        guard let id = recordingID, let lead = phoneLeads[id], let phone = UUID(uuidString: lead.sessionID),
              phoneLink.peers[phone] == nil, let last = phoneLink.lastConnected[phone],
              now.timeIntervalSince(last) > Self.phoneLeadSilenceLimit else { return }
        stopFollowing(id, because: "\(lead.deviceName) couldn’t be reached for \(Int(Self.phoneLeadSilenceLimit / 60)) minutes, so this Mac stopped recording.")
    }

    private func stopFollowing(_ id: UUID, because message: String) {
        guard !isStoppingRecording else { return }
        Task {
            if let stop = phoneCapture.stop { await stop(id) } else { await stopRecording(manual: false) }
            notice = message
        }
    }

    /// As the Mac goes to sleep: once its recording has stopped (capture stops on its own), the
    /// devices recording along are told before the network goes, waiting at most `limit` in all.
    func prepareForSleep(within limit: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while recordingID != nil || isStoppingRecording, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        await sources.recorders.settle(within: ContinuousClock.now.duration(to: deadline))
    }

    // MARK: Live progress for phones

    /// Sends a conversation's processing progress to connected phones: at every change of phase,
    /// and as the fraction moves (at most every half second). Coarse progress also syncs with a
    /// request's claim; this is the live version.
    func reportToPhones(_ meetingID: UUID, phase: LinkProcessingProgress.Phase? = nil, detail: String? = nil, force: Bool = false) {
        guard phoneLink.hasConnectedPhones, let meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        var fraction: Double?
        let resolved: LinkProcessingProgress.Phase
        if let phase {
            resolved = phase
            if phase == .finished { fraction = 1 }
        } else {
            guard case .processing(let progress) = processingStatus(for: meeting), progress.device == nil else { return }
            if processingProgress.message.hasPrefix("Lining up") { resolved = .aligning }
            else {
                switch progress.stage {
                case .transcribing: resolved = .transcribing
                case .identifyingSpeakers: resolved = .identifyingSpeakers
                case .summarizing: resolved = .summarizing
                }
            }
            fraction = min(1, max(0, processingProgress.fraction))
        }
        let message = LinkProcessingProgress(meetingID: meetingID, phase: resolved, fraction: fraction, macName: library.thisDevice.name, detail: detail)
        if !force, let last = lastPhoneProgress, last.message.meetingID == meetingID, last.message.phase == resolved {
            let moved = abs((fraction ?? 0) - (last.message.fraction ?? 0))
            guard moved >= 0.01, Date().timeIntervalSince(last.at) >= 0.5 else { return }
        }
        lastPhoneProgress = (message, Date())
        let link = phoneLink, previous = phoneProgressSend
        phoneProgressSend = Task {
            await previous?.value
            await link.broadcast(.processingProgress(message))
        }
    }

    // MARK: A phone asks this Mac to record

    /// The phone records a conversation and asks this Mac to record it too. This Mac records into
    /// the phone's conversation (creating it here if it hasn't synced yet), or says why it can't.
    func answerPhone(_ request: LinkRecordRequest, from peer: LinkPeer) async -> LinkRecordReply.Outcome {
        let id = request.conversationID
        switch request.action {
        case .start:
            if recordingID == id {
                return .accepted(LinkRecordAck(conversationID: id, startedAt: recordingStartedAt, wasAlreadyRecording: true))
            }
            if let current = recordingID {
                return .refused(LinkRecordRefusal(reason: .recordingSomethingElse, message: "This Mac is recording another conversation.", conversationID: current))
            }
            guard isReady, !isStartingRecording, !isStoppingRecording else {
                return .refused(LinkRecordRefusal(reason: .busy, message: "This Mac is starting or stopping a recording."))
            }
            switch microphoneAccess() {
            case .authorized: break
            case .notDetermined:
                return .refused(LinkRecordRefusal(reason: .permissionDenied,
                    message: "Start a recording on the Mac once to allow its microphone."))
            default:
                return .refused(LinkRecordRefusal(reason: .permissionDenied,
                    message: "Allow the Mac’s microphone in System Settings › Privacy & Security."))
            }
            let clock = peer.clock
            if !meetings.contains(where: { $0.id == id }) {
                // Made as the phone files it (its title and date came with the request), so the two
                // copies agree when they meet; it keeps that date while this Mac records into it.
                let start = request.timing?.startedAt.map { clock?.localDate(fromPeer: $0) ?? $0 } ?? Date()
                library.add(Meeting(id: id, title: request.title ?? "Conversation at \(start.formatted(date: .omitted, time: .shortened))",
                                    date: request.date ?? start))
            }
            guard canRecordInto(id) else {
                return .refused(LinkRecordRefusal(reason: .busy, message: "This Mac is processing that conversation. Try again when it’s done."))
            }
            phoneLeads[id] = CompanionLead(sessionID: peer.deviceID.uuidString, deviceKind: DaybookPhoneIntegration.id,
                                           deviceName: devices.session(peer.deviceID.uuidString)?.device.name ?? peer.name,
                                           startedAt: request.timing?.startedAt, clock: clock.map(CompanionClock.init))
            let started: Bool
            if let start = phoneCapture.start { started = await start(id) }
            else { await startRecording(into: id); started = recordingID == id }
            guard started else {
                phoneLeads[id] = nil
                return .refused(LinkRecordRefusal(reason: .microphoneUnavailable, message: errorMessage ?? "This Mac couldn’t start recording."))
            }
            return .accepted(LinkRecordAck(conversationID: id, startedAt: recordingStartedAt))
        case .stop:
            guard recordingID == id else { return .refused(LinkRecordRefusal(reason: .notRecording)) }
            guard phoneLeads[id]?.sessionID == peer.deviceID.uuidString else {
                return .refused(LinkRecordRefusal(reason: .declined, message: "This recording was started on the Mac. Stop it there."))
            }
            let end = Date()
            if let stop = phoneCapture.stop { await stop(id) } else { await stopRecording(manual: true) }
            return .accepted(LinkRecordAck(conversationID: id, stoppedAt: end))
        default:
            return .refused(LinkRecordRefusal(reason: .unsupported))
        }
    }

    // MARK: A phone's recording arrives through sync

    /// A recording from Daybook on iPhone joins the multipoint pipeline when it's first processed,
    /// so only the Mac carrying out the phone's request (or any, when nothing asked) does this:
    ///
    /// - In a conversation of its own, the link by recording ID, then overlap in time, then the
    ///   sound decide whether it belongs to another conversation. If so it moves there like any
    ///   recording that finds its conversation later, with the link's clock as the timing prior,
    ///   and its own conversation goes to the Trash unless the person worked in it. Returns true
    ///   then: this conversation isn't processed on its own.
    /// - In a conversation that has this Mac's recordings (the phone recorded into it), it waits to
    ///   be lined up, from the clock prior.
    func phoneRecordingsArrived(_ id: UUID, job: ProcessingJob) async -> Bool {
        guard let meeting = meetings.first(where: { $0.id == id }), job.requestID != nil || meeting.openProcessingRequests.isEmpty else { return false }
        // Not yet seen here: from a device (the phone, or a recorder another device imported), no
        // transcript, and not yet a source of this conversation (the phone may have filed it as one
        // still to place, holding the notes typed on it). Recordings this Mac imported were placed then.
        let arriving = meeting.tracks.filter { track in
            track.deviceKind != nil && !meeting.transcripts.contains { $0.trackID == track.id }
                && (track.alignment == nil
                    || (track.alignment?.isPending == true && !meeting.revisions.contains { $0.field == "source:\(track.id.uuidString)" }))
        }
        guard !arriving.isEmpty else { return false }
        if meeting.tracks.count == 1, let track = arriving.first {
            // A conversation a Mac recorded with this phone (its link is here) waits for that Mac's
            // recording, rather than letting the phone's move to another conversation.
            if meeting.companions?.contains(where: { $0.deviceKind == DaybookPhoneIntegration.id && $0.deviceID == track.deviceSerial }) == true {
                return false
            }
            return await deviceRecordingArrivedAlone(track, in: meeting)
        }
        // With recordings of this Mac's placed already, the phone's waits to be lined up.
        let placed = meeting.tracks.contains { $0.deviceKind != DaybookPhoneIntegration.id && meeting.timelinePlacement(of: $0.id) != nil }
        guard placed else { return false }
        for track in arriving {
            guard let current = meetings.first(where: { $0.id == id }), let url = await audioURL(for: track, meetingID: id) else { continue }
            var before = current
            before.tracks.removeAll { $0.id == track.id }
            sources.carried[track.sha256] = .init(transcript: nil, speakers: [], highlights: [], placement: nil,
                                                  clockOffset: nil, startedAt: track.startedAt ?? track.createdAt)
            await sourceArrived(id, before: before, imported: current, url: url, device: track.device, plan: nil)
            sources.carried[track.sha256] = nil
        }
        return false
    }

    /// A recording from Daybook on iPhone finds its conversation by its link, then overlap in time,
    /// then the sound. A recorder's recording another device imported (the phone, after a handoff)
    /// joins only by its multipoint link: this Mac would have matched it by time and sound if it had
    /// imported it itself, and its link waits for it here.
    private func deviceRecordingArrivedAlone(_ track: RecordingTrack, in meeting: Meeting) async -> Bool {
        guard let identity = track.device else { return false }
        let fromPhone = track.deviceKind == DaybookPhoneIntegration.id
        // Its start on this Mac's clock (the phone stamps it by its own).
        let start = (date: trackStart(track) ?? track.createdAt as Date?, reliable: true)
        if !fromPhone {
            let others = meetings.filter { $0.id != meeting.id }
            guard SourceMatcher.linked(Self.fullRecording(identity), start: start.date, in: others, policy: sources.policy) != nil else { return false }
        }
        guard let url = await audioURL(for: track, meetingID: meeting.id) else { return false }
        guard let plan = await planArrival(url: url, duration: track.duration ?? 0, device: identity, start: start, excluding: [meeting.id]) else { return false }
        if let target = plan.attachTo, canMoveSource(into: target), let title = meetings.first(where: { $0.id == target })?.title {
            let stays = meeting.hasPersonMadeContent
            if !stays { movedPhoneRecordings.insert(meeting.id) }
            sources.carried[track.sha256] = .init(transcript: nil, speakers: [], highlights: Self.highlightsMoving(with: track, from: meeting),
                                                  placement: plan.placement, clockOffset: nil, startedAt: start.date)
            defer { sources.carried[track.sha256] = nil }
            do { _ = try await importAudio([url], source: track.source, attachTo: target, device: identity) }
            catch { movedPhoneRecordings.remove(meeting.id); errorMessage = error.localizedDescription; return false }
            guard !stays else {
                notice = "Added the \(sourceName(track)) to “\(title)”. “\(meeting.title)” stays, with your notes."
                return false
            }
            trashWhenIdle(meeting.id, addedTo: title)
            return true
        }
        guard fromPhone else { return false }
        // It stays: filed as a source to place (it may have joined a Mac's recording that never came),
        // it's this conversation's own recording after all, and sets its timeline.
        update(meeting.id) { $0.makeTimelineOrigin(track.id) }
        if let suggestion = plan.suggestion {
            update(meeting.id) { current in
                guard !(current.sourceSuggestions ?? []).contains(where: { $0.trackID == track.id }) else { return }
                current.sourceSuggestions = (current.sourceSuggestions ?? []) + [SourceSuggestion(
                    trackID: track.id, candidateMeetingIDs: suggestion.candidates, reason: suggestion.reason, confidence: suggestion.confidence,
                    clockOffsets: suggestion.clockOffsets.isEmpty ? nil : suggestion.clockOffsets)]
            }
        }
        return false
    }
}

/// What a phone's view of this Mac's recorder changes with.
private struct RecordingPhaseKey: Equatable {
    var recording: UUID?
    var starting: Bool
    var stopping: Bool
}
