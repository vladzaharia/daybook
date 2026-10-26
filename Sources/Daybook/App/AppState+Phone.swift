import AppKit
import AVFoundation
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
        // The phone's synced recordings list follows sync being on or off.
        sync.$folder.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.phoneSessions.forEach { $0.connection(.files)?.refresh() } }
        }.store(in: &subscriptions)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.systemDidWake() }
        }
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
        case .recordingState, .processingProgress:
            break
        case .recorderHandoffRequest, .recorderHandoffReply, .recorderRelease:
            recorderHandoff.receive(message, from: phone)
        }
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
                let start = request.timing?.startedAt.map { clock?.localDate(fromPeer: $0) ?? $0 } ?? Date()
                library.add(Meeting(id: id, title: "Conversation at \(start.formatted(date: .omitted, time: .shortened))", date: start))
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
        let arriving = meeting.tracks.filter { track in
            track.deviceKind == DaybookPhoneIntegration.id && track.alignment == nil && !meeting.transcripts.contains { $0.trackID == track.id }
        }
        guard !arriving.isEmpty else { return false }
        if meeting.tracks.count == 1, let track = arriving.first {
            return await phoneRecordingArrivedAlone(track, in: meeting)
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

    private func phoneRecordingArrivedAlone(_ track: RecordingTrack, in meeting: Meeting) async -> Bool {
        guard let identity = track.device, let url = await audioURL(for: track, meetingID: meeting.id) else { return false }
        let start = (date: track.startedAt ?? track.createdAt as Date?, reliable: true)
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
                notice = "Added the iPhone recording to “\(title)”. “\(meeting.title)” stays, with your notes."
                return false
            }
            trashWhenIdle(meeting.id, addedTo: title)
            return true
        }
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
