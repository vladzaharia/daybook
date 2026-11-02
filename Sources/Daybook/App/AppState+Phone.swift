import AppKit
import AVFoundation
import DaybookCore
import DaybookDevices
import DaybookKit
import DaybookLink
import Foundation

/// Starts and stops this Mac's capture when another device asks (a phone, a recorder's button). Nil
/// uses the real recorder; tests supply their own so nothing touches the microphone.
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
        else if let stored = defaults.string(forKey: ReplicaIdentity.Key.linkDeviceID).flatMap(UUID.init(uuidString:)) { id = stored }
        else { id = UUID(); defaults.set(id.uuidString, forKey: ReplicaIdentity.Key.linkDeviceID) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return LinkIdentity(deviceID: id, name: ProcessingRequest.Device.currentName, deviceClass: .mac, appVersion: version,
                            canProcess: false, features: [LinkCapabilities.recordControlFeature, LinkCapabilities.processingProgressFeature,
                                                          LinkCapabilities.recorderHandoffFeature,
                                                          LinkCapabilities.cascadeFeature, LinkCapabilities.sharedNotesFeature,
                                                          LinkCapabilities.liveCaptionsFeature, LinkCapabilities.liveLevelsFeature,
                                                          LinkCapabilities.summaryPlacementFeature, LinkCapabilities.pageStopFeature,
                                                          LinkCapabilities.recordPermissionFeature],
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
        watches.append(ObservationWatch.distinctValues(of: { [weak self] in
            RecordingPhaseKey(recording: self?.recordingID, starting: self?.isStartingRecording == true, stopping: self?.isStoppingRecording == true)
        }, initial: false) { [weak self] _ in self?.phoneLink.sendRecordingState() })
        // And what the recorders this Mac manages are doing, when that changes.
        watches.append(devices.watchRecorders { [weak self] in self?.phoneLink.sendRecordingState(onlyIfRecordersChanged: true) })
        // The phone's synced recordings list follows sync being on or off.
        watches.append(ObservationWatch({ [weak self] in _ = self?.sync.folder }) { [weak self] in
            self?.phoneSessions.forEach { $0.connection(.files)?.refresh() }
        })
        // A phone hears this Mac's Can start recording for it as it changes (on its page, or in Settings › Devices).
        watches.append(ObservationWatch.distinctValues(of: { [weak self] in
            self?.phoneSessions.map { PhoneStartPermission(id: $0.id, allowed: $0.device.recordsAlongsideMac) } ?? []
        }, initial: false) { [weak self] _ in self?.sendRecordPermissions() })
        carryOverRecordAlongOff()
        // The link follows the Mac's wake (the app's one wake observer) and hands it here.
        phoneLink.onWake = { [weak self] in await self?.systemDidWake() }
        // Going to sleep while recording, the devices recording along hear the stop first.
        recorder.beforeSleep = { [weak self] in await self?.prepareForSleep(within: RecordingController.sleepGrace) }
    }

    /// Paired phones, as devices.
    var phoneSessions: [DeviceSession] { devices.sessions.filter { $0.kind.id == DaybookPhoneIntegration.id } }

    /// At launch: the link runs when a phone is paired. The keychain is the record of pairings;
    /// a pairing whose device was removed from preferences is added back. A link that can't start yet (the
    /// keychain won't read just after login) keeps trying, and its phones stay as they were meanwhile.
    func startPhoneLinkIfPaired() async {
        guard !phoneSessions.isEmpty else { return }
        guard await phoneLink.start() else {
            phoneLink.keepStarting { [weak self] in self?.restorePairedPhones() }
            return
        }
        restorePairedPhones()
    }

    private func restorePairedPhones() {
        for device in phoneLink.paired where devices.session(device.deviceID.uuidString) == nil { phonePaired(device) }
    }

    /// After sleep the link probes every phone, reopens its listener, and reads its pairings again if the
    /// last read failed; a claim this Mac holds is renewed (it survives sleep unless another Mac took it over
    /// meanwhile), and a pass publishes it.
    func systemDidWake() async {
        await phoneLink.systemDidWake()
        renewRunningClaim(force: true)
        sync.requestSync()
    }

    // MARK: Pairing

    /// Pair with iPhone…: opens pairing; the sheet shows `phoneLink.pairing`.
    func beginPhonePairing() { Task { await phoneLink.beginPairing() } }
    func endPhonePairing() { Task { await phoneLink.endPairing() } }

    /// Unpairs a phone on both sides. Its device leaves the sidebar; its recordings stay. When the keychain
    /// refuses, the pairing stays and the window says so.
    func unpairPhone(_ phoneID: UUID) {
        let name = devices.session(phoneID.uuidString)?.device.name
            ?? phoneLink.paired.first { $0.deviceID == phoneID }?.name ?? PairingWords.unnamed(.iPhone)
        Task {
            do { try await phoneLink.unpair(phoneID) } catch {
                report(PairingWords.couldntUnpair(name), PairingWords.couldntUnpairMessage, error)
            }
        }
    }

    private func phonePaired(_ device: LinkPairedDevice) {
        let kind = DaybookPhoneIntegration().kind
        if let session = devices.session(device.deviceID.uuidString) {
            session.connections.forEach { $0.refresh() }
        } else {
            // A pairing that can't be read may have no name left.
            let name = device.name.isEmpty ? PairingWords.unnamed(.iPhone) : device.name
            devices.add(ConfiguredDevice(id: device.deviceID.uuidString, kind: kind, name: name, addedAt: device.pairedAt))
        }
    }

    private func phoneUnpaired(_ phoneID: UUID) {
        let id = phoneID.uuidString
        if devices.session(id) != nil { removeDevice(id) }
        Task { await phoneLink.stopIfIdle() }
    }

    private func phoneConnected(_ peer: LinkPeer) {
        // It hears whether it may start recording here, and an off this Mac owes it.
        sendRecordPermission(to: peer.deviceID)
        // A phone that reconnects while this Mac processes sees where it is at once.
        if let id = processingID { reportToPhones(id, force: true) }
        // A stop this Mac couldn't deliver goes now, and so do the notes and bookmarks it missed.
        sources.recorders.reconnected(peer.deviceID.uuidString)
        sendOwedNotes(to: peer.deviceID)
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
            phoneBookmarked(mark, from: phone)
        case .note(let note):
            phoneWroteNote(note, from: phone)
        case .bookmarkChange(let change):
            phoneChangedBookmark(change, from: phone)
        case .captions(let captions):
            phoneCaptioned(captions, from: phone)
        case .levels(let levels):
            phoneLevelled(levels, from: phone)
        case .recordingState(let state):
            phoneReported(state, from: phone)
        case .processingProgress:
            break
        case .summaryChoice(let choice):
            phoneChoseSummaryPlacement(choice)
        case .recordPermission(let permission):
            phoneSaidRecordPermission(permission, from: phone)
        case .recorderHandoffRequest, .recorderHandoffReply, .recorderRelease:
            recorderHandoff.receive(message, from: phone)
        case .libraryKeyRequest(let request):
            Task { await grantLibraryKey(request, to: phone) }
        case .libraryKeyGrant(let grant):
            // Kept only when it answers a request this Mac sent that iPhone (`requestLibraryKey(from:)`).
            Task { await sync.accept(grant, from: phone) }
        }
    }

    // MARK: Library keys

    /// A paired iPhone waiting for the encrypted library's key asked this Mac: it gets the key when its library is this
    /// Mac's, and the Mac says so.
    private func grantLibraryKey(_ request: LinkLibraryKeyRequest, to phone: UUID) async {
        guard phoneLink.isPaired(phone), let peer = phoneLink.peers[phone] else { return }
        let grants = await sync.libraryKeyGrants(for: request, peerLibraryID: peer.capabilities.libraryID)
        var sent = false
        for grant in grants where (try? await phoneLink.send(.libraryKeyGrant(grant), to: phone)) != nil { sent = true }
        if sent { post(["Sent this library’s key to \(peer.name)."]) }
    }

    /// Asks a connected iPhone for the encrypted library's key this Mac is waiting for. Only that iPhone's answer is
    /// kept. Throws when the iPhone can't be reached, so Settings can say so.
    func requestLibraryKey(from phone: UUID) async throws {
        guard phoneLink.peers[phone] != nil else { throw LinkError.notConnected }
        guard let request = await sync.libraryKeyRequest() else { return }
        // Noted before sending, so an answer that comes back at once already finds it.
        sync.noteKeyRequested(from: phone)
        try await phoneLink.send(.libraryKeyRequest(request), to: phone)
    }

    /// The connected phone that manages a recorder (by its synced ownership), when it starts and stops
    /// its recorders when asked: multipoint asks it rather than reaching for the recorder.
    func phoneManaging(_ ownership: RecorderOwnership) -> (session: DeviceSession, control: any AnsweringRecordControl)? {
        guard let peer = phoneLink.peers.values.first(where: { ($0.capabilities.syncDeviceID ?? $0.deviceID.uuidString) == ownership.ownerID }),
              peer.capabilities.controlsRecorders, let session = devices.session(peer.deviceID.uuidString),
              let control = session.direct as? PhoneLinkConnection else { return nil }
        return (session, control)
    }

    // MARK: Recording for a phone

    /// A phone said what it's recording. When this Mac records because that phone asked, and the
    /// phone has stopped (or moved on to another conversation), this Mac stops too and says so: the
    /// phone's stop may never have arrived.
    func phoneReported(_ state: LinkRecordingState, from phone: UUID) {
        guard let id = recordingID, let lead = phoneLeads[id], lead.sessionID == phone.uuidString else { return }
        // Its microphone, or only its recorders (an iPhone in the background), may be what records.
        guard !state.takesPart(in: id) else { return }
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
        // The phone it follows has stopped: it isn't asked to stop in turn.
        stopCause = phoneLeads[id]?.sessionID
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
        guard phoneLink.hasConnectedPhones, !checkingPhoneTranscripts.contains(meetingID),
              let meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        // While a summary is placed, its countdown (or the cloud at work) is what phones see.
        if phase == nil, let placing = placementProgress(meetingID) {
            send(placing, force: force)
            return
        }
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
        send(LinkProcessingProgress(meetingID: meetingID, phase: resolved, fraction: fraction, macName: library.thisDevice.name, detail: detail),
             force: force)
    }

    /// Sends progress to every connected phone, in order; the same phase moving less than a percent, or
    /// within half a second, waits for the next.
    private func send(_ message: LinkProcessingProgress, force: Bool) {
        if !force, let last = lastPhoneProgress, last.message.meetingID == message.meetingID, last.message.phase == message.phase {
            let moved = abs((message.fraction ?? 0) - (last.message.fraction ?? 0))
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
            // This Mac's Can start recording for that phone (on by default) says whether it may start a recording
            // here at all: one it asks on its own as it starts (a cascading start), one the person chose there, and one
            // from its page, as the phone's own toggle does for this Mac.
            guard phoneMayStartRecording(peer.deviceID) else {
                return .refused(LinkRecordRefusal(reason: .declined, message: PairingWords.notAllowedToStart(asker: .iPhone)))
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
                                           startedAt: request.timing?.startedAt, clock: clock.map(CompanionClock.init),
                                           recordsItself: request.cascade?.requesterRecords ?? true)
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
            // The phone this Mac records for, or one recording this conversation with it (a cascading stop:
            // stopping on any device stops the rest), or the phone's page for this Mac (Stop on <Mac>) when it
            // can start recording here.
            let shared = phoneLeads[id]?.sessionID == peer.deviceID.uuidString || isRecording(id, with: peer.deviceID.uuidString)
            guard shared || (request.isStandalone && phoneMayStartRecording(peer.deviceID)) else {
                return .refused(LinkRecordRefusal(reason: .declined, message: PairingWords.notAllowedToStop(asker: .iPhone)))
            }
            stopCause = peer.deviceID.uuidString
            let end = Date()
            if let stop = phoneCapture.stop { await stop(id) } else { await stopRecording(manual: true) }
            return .accepted(LinkRecordAck(conversationID: id, stoppedAt: end))
        default:
            return .refused(LinkRecordRefusal(reason: .unsupported))
        }
    }

    /// Can start recording for a paired phone, on its page and in Settings › Devices (on by default): it may start
    /// a recording on this Mac, and stop one from its page. Only that way: whether the phone records when this Mac
    /// starts is its own Can Start Recording's to say, as this is for the phone's starts.
    func phoneMayStartRecording(_ phoneID: UUID) -> Bool {
        devices.session(phoneID.uuidString)?.device.recordsAlongsideMac ?? true
    }

    // MARK: Can start recording, both ways

    /// Tells a connected phone that listens this Mac's Can start recording for it and, until it has taken it, the off
    /// this Mac owes it from an earlier build (`ConfiguredDevice.recordAlongOffOwed`).
    func sendRecordPermission(to phoneID: UUID) {
        let owed = devices.session(phoneID.uuidString)?.device.recordAlongOffOwed == true
        phoneLink.sendRecordPermission(LinkRecordPermission(allowed: phoneMayStartRecording(phoneID), asksReceiverOff: owed ? true : nil),
                                       to: phoneID)
    }

    private func sendRecordPermissions() {
        for phone in phoneLink.peers.keys { sendRecordPermission(to: phone) }
    }

    /// A phone said whether this Mac may start a recording there (`PhoneLink.recordPermissions` keeps it, which
    /// multipoint reads). One that says it took this Mac's owed off holds it now, so it's no longer owed.
    private func phoneSaidRecordPermission(_ permission: LinkRecordPermission, from phone: UUID) {
        guard permission.turnedOff == true, let session = devices.session(phone.uuidString), session.device.recordAlongOffOwed == true else { return }
        session.update { $0.recordAlongOffOwed = nil }
    }

    /// Set once Record along with this Mac's off has been carried over for the phones paired then.
    static let recordAlongCarriedOverKey = "phoneRecordAlongCarriedOver"

    /// Before this build, a phone's Record along with this Mac off here also kept this Mac from asking it to record.
    /// That off is the phone's own to keep now (its Can Start Recording for this Mac), so it's owed to the phone until it
    /// says it has taken it, and meanwhile this Mac doesn't ask it. Once, for the phones paired then.
    private func carryOverRecordAlongOff() {
        guard !preferences.bool(forKey: Self.recordAlongCarriedOverKey) else { return }
        preferences.set(true, forKey: Self.recordAlongCarriedOverKey)
        for session in phoneSessions where session.device.alsoRecordsWithMac == false && session.device.recordAlongOffOwed == nil {
            session.update { $0.recordAlongOffOwed = true }
        }
    }

    /// Whether a phone records this Mac's recording `id` along with it: its link here says so (or it never
    /// answered, so it may). A phone that declined doesn't.
    func isRecording(_ id: UUID, with phoneSession: String) -> Bool {
        guard let since = recordingStartedAt else { return false }
        return meetings.first { $0.id == id }?.companions?.contains { link in
            link.deviceID == phoneSession && link.deviceKind == DaybookPhoneIntegration.id && link.macEndedAt == nil
                && link.macStartedAt >= since.addingTimeInterval(-1) && sources.recorders.mayBeRecording(link)
        } == true
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
                    || (track.alignment?.isPending == true && !meeting.revisions.contains { $0.kind == .source(track.id.uuidString) }))
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
            guard let current = meetings.first(where: { $0.id == id }), let url = await availableAudioURL(for: track, in: id) else { continue }
            var before = current
            before.tracks.removeAll { $0.id == track.id }
            sources.carried[track.sha256] = .init(transcript: nil, speakers: [], highlights: [], placement: nil,
                                                  clockOffset: nil, startedAt: track.startedAt ?? track.createdAt)
            await sourceArrived(id, before: before, imported: current, url: url, device: track.device, plan: nil)
            sources.carried[track.sha256] = nil
        }
        return false
    }

    // MARK: A recording the iPhone transcribed itself

    /// A recording Daybook on iPhone recorded alone and transcribed itself (docs/iphone.md, "Processing on this
    /// iPhone") arrives with its transcript, and with only a Summarize request, or none (the iPhone summarizes it
    /// itself, or counts down to). The first time this Mac sees one it finds its conversation as it does for one it
    /// transcribes: by its link, then overlap in time, then the sound (`deviceRecordingArrivedAlone`). Found, it moves
    /// there with its transcript and speakers, so it isn't transcribed again, and that conversation fuses and
    /// summarizes (through the placement); its own goes to the Trash unless the person worked in it, and the
    /// iPhone's countdown or summary for it stands down. Each is checked once (`MultiSourceCoordinator.markChecked`).
    ///
    /// Returns true when this job has nothing more to do: it moved, or it stays and nothing asked this Mac for more.
    /// Runs before the job touches the conversation, so a summary the iPhone made stays as it is. The iPhone may be
    /// holding the summary meanwhile (counting down to it, or making it): moving the recording ends that there.
    func phoneTranscriptArrived(_ id: UUID, job: ProcessingJob) async -> Bool {
        guard let meeting = meetings.first(where: { $0.id == id }), let track = phoneTranscriptToCheck(meeting),
              job.requestID != nil || !hasRequestThisMacCouldTake(meeting),
              await availableAudioURL(for: track, in: id) != nil else { return false }
        sources.markChecked(phoneRecording: track.id)
        // A conversation a Mac recorded with this phone (its link is here) waits for that Mac's recording.
        let recordedWithAMac = meeting.companions?.contains { $0.deviceKind == DaybookPhoneIntegration.id && $0.deviceID == track.deviceSerial } == true
        if !recordedWithAMac, await deviceRecordingArrivedAlone(track, in: meeting) { return true }
        guard job.requestID == nil else {
            // It stays, and the iPhone asked this Mac to summarize it: the job goes on, and phones hear it.
            checkingPhoneTranscripts.remove(id)
            return false
        }
        return true
    }

    /// An open request this Mac could carry out: unclaimed, its own, or one whose claim ran out.
    private func hasRequestThisMacCouldTake(_ meeting: Meeting) -> Bool {
        let me = library.thisDevice, now = Date()
        return meeting.openProcessingRequests.contains { $0.isClaimable(by: me, at: now) && !$0.isSatisfied(by: meeting) }
    }

    /// The recording to check in a conversation of the iPhone's own: its one recording, transcribed on the iPhone
    /// that made it (its Transcribe request finished by the device that asked), never placed on another's timeline,
    /// and not checked here yet. A recording a Mac transcribed was checked before the Mac transcribed it.
    func phoneTranscriptToCheck(_ meeting: Meeting) -> RecordingTrack? {
        guard meeting.tracks.count == 1, let track = meeting.tracks.first, track.deviceKind == DaybookPhoneIntegration.id,
              track.alignment == nil, meeting.transcripts.contains(where: { $0.trackID == track.id }),
              !sources.hasChecked(phoneRecording: track.id) else { return nil }
        let transcribedOnThePhone = (meeting.processingRequests ?? []).contains { request in
            request.mode != .summaryOnly && request.outcome?.result == .completed && request.outcome?.device.id == request.requestedBy.id
        }
        return transcribedOnThePhone ? track : nil
    }

    /// Conversations to check after a sync pass: an iPhone recording it transcribed itself, with no request this Mac
    /// could take (one it could take brings its own job; one the iPhone holds, counting down or summarizing, doesn't
    /// stop the check), when this Mac takes other devices' work or the recording was made with one of this Mac's
    /// conversations (its link).
    func phoneTranscriptsToCheck() -> [UUID] {
        meetings.compactMap { meeting in
            guard !hasRequestThisMacCouldTake(meeting), !movedPhoneRecordings.contains(meeting.id), processingID != meeting.id,
                  !queuedIDs.contains(meeting.id), let track = phoneTranscriptToCheck(meeting) else { return nil }
            if processSyncedAudio { return meeting.id }
            guard let identity = track.device else { return nil }
            let others = meetings.filter { $0.id != meeting.id }
            return SourceMatcher.linked(Self.fullRecording(identity), start: trackStart(track) ?? track.createdAt, in: others,
                                        policy: sources.policy) == nil ? nil : meeting.id
        }
    }

    /// A recording from Daybook on iPhone finds its conversation by its link, then overlap in time,
    /// then the sound. A recorder's recording another device imported (the phone, after a handoff)
    /// joins only by its multipoint link: this Mac would have matched it by time and sound if it had
    /// imported it itself, and its link waits for it here. One the iPhone transcribed moves with its
    /// transcript and speakers.
    private func deviceRecordingArrivedAlone(_ track: RecordingTrack, in meeting: Meeting) async -> Bool {
        guard let identity = track.device else { return false }
        let fromPhone = track.deviceKind == DaybookPhoneIntegration.id
        // Its start on this Mac's clock (the phone stamps it by its own).
        let start = (date: trackStart(track) ?? track.createdAt as Date?, reliable: true)
        if !fromPhone {
            let others = meetings.filter { $0.id != meeting.id }
            guard SourceMatcher.linked(Self.fullRecording(identity), start: start.date, in: others, policy: sources.policy) != nil else { return false }
        }
        guard let url = await availableAudioURL(for: track, in: meeting.id) else { return false }
        guard let plan = await planArrival(url: url, duration: track.duration ?? 0, device: identity, start: start, excluding: [meeting.id]) else { return false }
        if let target = plan.attachTo, canMoveSource(into: target), let title = meetings.first(where: { $0.id == target })?.title {
            let stays = meeting.hasPersonMadeContent
            if !stays { movedPhoneRecordings.insert(meeting.id) }
            // Transcribed on the iPhone: its transcript and speakers go with it.
            let transcript = meeting.transcripts.filter { $0.trackID == track.id }.max { $0.createdAt < $1.createdAt }
            let speakerIDs = Set(transcript?.segments.compactMap(\.speakerID) ?? [])
            sources.carried[track.sha256] = .init(transcript: transcript, speakers: meeting.speakers.filter { speakerIDs.contains($0.id) },
                                                  highlights: Self.highlightsMoving(with: track, from: meeting),
                                                  placement: plan.placement, clockOffset: nil, startedAt: start.date)
            defer { sources.carried[track.sha256] = nil }
            do { _ = try await importAudio([url], source: track.source, attachTo: target, device: identity) }
            catch {
                movedPhoneRecordings.remove(meeting.id)
                report("Couldn’t Add the Recording", "The \(sourceName(track)) couldn’t be added to “\(title)”. It stays in “\(meeting.title)”.", error)
                return false
            }
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

/// A paired phone's Can start recording on this Mac, as the link's watch compares it.
private struct PhoneStartPermission: Equatable {
    var id: String
    var allowed: Bool
}
