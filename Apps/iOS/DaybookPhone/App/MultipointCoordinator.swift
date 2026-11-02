import DaybookDevices
import DaybookKit
import DaybookLink
import Foundation
import Observation

/// Recording with Macs and the recorders this iPhone manages (docs/multipoint.md): a Mac's record
/// requests and this iPhone's to Macs, the session the recording screen shows, stops owed to Macs across
/// relaunches, and the cascade (`MultipointCoordinator+Cascade.swift`), in which starting anywhere starts
/// the rest. The app model starts and stops the recording itself; this decides who else records it.
@MainActor
@Observable
final class MultipointCoordinator {
    /// While a Mac records this conversation too, or asked this iPhone to. Kept in the recording's
    /// journal, so a recording recovered after Daybook was killed still joins and stops its Macs.
    var session: MultipointSession? {
        didSet { if session != oldValue { recorder.setMultipoint(session?.journaled) } }
    }
    /// A shared recording this iPhone takes part in only through its recorder: its button started it
    /// while Daybook was in the background, where iOS doesn't let this iPhone start its microphone.
    var recorderOnly: RecorderOnlyRecording?
    /// Recording here asks the connected Macs on its own (a cascading start). Tests of the person's own
    /// "Record on Studio Mac too" turn it off.
    @ObservationIgnored var cascadesToMacs = true
    /// Until when a Mac that connects is asked to join this iPhone's recording on its own (the link can
    /// take a few seconds to come back as the app comes forward or wakes in the background).
    @ObservationIgnored var cascadeAsksUntil: Date?
    /// The stop under way came from a Mac (it asked, or this iPhone followed it): that Mac isn't asked
    /// to stop in turn.
    @ObservationIgnored var stopIsFromMac = false
    /// A recorder's button is starting a recording here.
    @ObservationIgnored var startingFromRecorder = false
    /// Stops this iPhone owes Macs it started, by Mac: the conversation to stop. Kept in a file in the
    /// library's folder that never syncs (`owedStopsFile`), so a relaunch still sends them as the Mac connects.
    @ObservationIgnored private(set) var pendingStops: [UUID: UUID] = [:] {
        didSet { if pendingStops != oldValue { saveOwedStops() } }
    }
    /// The Mac whose device page started this recording (a conversation of this iPhone's own).
    @ObservationIgnored private var startedFromMac: UUID?
    /// When each of `pendingStops` was first owed.
    @ObservationIgnored private var owedSince: [UUID: Date] = [:]
    @ObservationIgnored private let owedStops: OwedStopsStore<OwedMacStop>
    @ObservationIgnored private var stopsInFlight: Set<UUID> = []
    /// What this follows in the settings and the link, for as long as it lives.
    @ObservationIgnored private var watches: [ObservationWatch] = []

    /// The app it coordinates for, which starts and stops the recording and speaks to the person. Work
    /// still under way when the app has gone does nothing more.
    @ObservationIgnored weak var app: PhoneAppModel?
    @ObservationIgnored let recorder: PhoneRecorder
    @ObservationIgnored let link: PhoneLink
    @ObservationIgnored let devices: PhoneDevices
    @ObservationIgnored let settings: PhoneSettings
    @ObservationIgnored let library: PhoneLibrary
    /// What goes to the Macs while recording.
    @ObservationIgnored let sharing: LinkSharing

    /// Where the stops this iPhone owes are kept, in the library's folder.
    static let owedStopsFile = "owed-stops.json"
    /// How long a start that gets no answer is asked again.
    static let startRetryWindow: TimeInterval = 30
    /// A Mac this iPhone records for, not heard from for this long, is taken to have stopped.
    static let leaderSilenceLimit: TimeInterval = 30 * 60

    init(app: PhoneAppModel, sharing: LinkSharing) {
        self.app = app
        recorder = app.recorder
        link = app.link
        devices = app.devices
        settings = app.settings
        library = app.library
        self.sharing = sharing
        // Stops a previous run owed, sent as each Mac connects.
        let owedStops = OwedStopsStore<OwedMacStop>(file: app.library.rootURL.appendingPathComponent(Self.owedStopsFile))
        let owed = owedStops.load()
        self.owedStops = owedStops
        owedSince = Dictionary(owed.map { ($0.macID, $0.owedAt) }, uniquingKeysWith: { _, later in later })
        pendingStops = Dictionary(owed.map { ($0.macID, $0.conversationID) }, uniquingKeysWith: { _, later in later })
    }

    /// Hears the Macs and the recorders.
    func wire() {
        link.recordRequestHandler = { [weak self] mac, request in
            await self?.answer(mac, request) ?? .refused(LinkRecordRefusal(reason: .unsupported))
        }
        link.onMacRecordingState = { [weak self] mac, state in self?.macReported(state, from: mac) }
        link.onMacConnected = { [weak self] mac in self?.macConnected(mac) }
        link.onSharedNotes = { [weak self] message, mac in self?.sharing.macSharedNotes(message, from: mac) }
        link.onRecordPermission = { [weak self] mac, permission in self?.macSaidRecordPermission(permission, from: mac) }
        // Each connected Mac hears whether it may start recording here as that changes (its Can Start Recording, or
        // Recording with Your Mac).
        watches.append(ObservationWatch.distinctValues(of: { [weak self] in
            self.map { coordinator in
                Dictionary(coordinator.link.macs.map { ($0.id, coordinator.letsMacStartRecording($0)) }, uniquingKeysWith: { a, _ in a })
            } ?? [:]
        }, initial: false) { [weak self] _ in self?.sendRecordPermissions() })
        devices.hub.onRecorderButton = { [weak self] session, on in self?.recorderButton(session, on) }
        devices.cascade.onChange = { [weak self] in self?.sharing.sendRecordingState(force: true) }
    }

    /// This iPhone's recording ended: the Mac that started it from its page no longer may stop it.
    func recordingEnded() {
        startedFromMac = nil
    }

    // MARK: Asking Macs

    /// Macs connected now that could record this conversation too.
    var macsToRecordWith: [PhoneLink.Mac] {
        guard recorder.isCapturing, session?.isMacLed != true else { return [] }
        // A Mac that said no, or never answered, can be asked again.
        let involved = Set(session?.macs.filter { [.asking, .recording, .stopped].contains($0.state) }.map(\.id) ?? [])
        return link.connectedMacs.filter { !involved.contains($0.id) && !$0.isRecording }
    }

    /// The multipoint line for the recording screen: the session, plus any Mac that reports
    /// recording this conversation on its own.
    var line: String? {
        if let line = session?.line { return line }
        guard let id = recorder.captureID else { return nil }
        let names = link.connectedMacs.filter { $0.recording?.conversationID == id && $0.isRecording }.map(\.name)
        return names.isEmpty ? nil : "Also recording on \(ListFormatter.localizedString(byJoining: names))"
    }

    /// "Record on Studio Mac too": asks a connected Mac to record this conversation, with this
    /// iPhone's timing so it can be placed at once.
    ///
    /// An answer that doesn't come (a reconnect, a microphone prompt on the Mac) is asked for again
    /// with the same request, for up to `startRetryWindow`; the Mac answers a repeat with its first
    /// answer, so whether it started because of this iPhone is never lost. A Mac whose start comes
    /// back after this iPhone stopped, or that never answered, is stopped with it.
    func recordOnMac(_ macID: UUID, cascade: LinkCascade? = nil) async {
        guard let mac = link.macs.first(where: { $0.id == macID }) else { return }
        // This iPhone's own recording, or (in the background) only its recorder's.
        let own = recorder.isCapturing ? recorder.captureID : nil
        guard let id = own ?? recorderOnly?.conversationID else { return }
        // Only Macs that understand it are asked to record along with a recorder alone: an older one
        // would expect a recording from this iPhone.
        if own == nil, !mac.cascades { return }
        var asking = session ?? MultipointSession(conversationID: id, role: .phoneLed)
        // A Mac asked already (on its own as recording began, or by the person) isn't asked twice.
        if let asked = asking.macs.first(where: { $0.id == macID }), asked.state == .asking || asked.state == .recording { return }
        // A Mac that didn't answer before is asked the same request again.
        let requestID = asking.macs.first(where: { $0.id == macID && $0.state.isUnanswered })?.startRequestID ?? UUID()
        asking.macs.removeAll { $0.id == macID }
        asking.macs.append(MultipointSession.Mac(id: macID, name: mac.name, state: .asking, startedAt: nil, startedByPhone: true,
                                                 startRequestID: requestID))
        session = asking
        // This iPhone's recording (or its recorder's) sets its conversation's timeline.
        let start = own != nil ? recorder.startedAt : recorderOnly?.startedAt
        let timing = LinkTiming(startedAt: start, elapsed: start.map { max(0, Date().timeIntervalSince($0)) },
                                clockOffset: mac.clock?.offset, clockUncertainty: mac.clock?.uncertainty, timelineStart: start)
        // The conversation as this iPhone will file it, so a Mac that creates it makes the same one.
        let (title, date) = own != nil ? (recorder.title, recorder.startedAt) : (recorderOnly?.title ?? recorder.title, start)
        let stillAsking = { [weak self] in self?.session?.conversationID == id && self?.session?.macs.first { $0.id == macID }?.state == .asking }
        let deadline = Date().addingTimeInterval(Self.startRetryWindow)
        var result = await link.request(.start, id: requestID, conversationID: id, timing: timing, title: title, date: date,
                                        cascade: cascade, from: macID)
        while case .failure(.unreachable) = result, stillAsking(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            guard link.macs.first(where: { $0.id == macID })?.isConnected == true else { continue }
            result = await link.request(.start, id: requestID, conversationID: id, timing: timing, title: title, date: date,
                                        cascade: cascade, from: macID)
        }
        guard stillAsking() else {
            // This iPhone stopped meanwhile (and asked it to stop then); a start it made anyway is stopped too.
            if case .success(let ack) = result, !ack.wasAlreadyRecording { queueStop(of: macID, conversation: id) }
            return
        }
        switch result {
        case .success(let ack):
            session?.update(macID) { entry in
                entry.state = .recording
                entry.startedAt = ack.startedAt
                entry.startedByPhone = !ack.wasAlreadyRecording
            }
        case .failure(.refused(let refusal)) where cascade != nil && refusal.reason == .declined:
            // Asked on its own, it said no as the person set it to (its Can start recording for this iPhone): their
            // choice, so nothing is said, as for a Mac known not to take it.
            session?.macs.removeAll { $0.id == macID }
        case .failure(let failure):
            let message = failure.message(mac: mac.name)
            session?.update(macID) { $0.state = failure == .unreachable ? .noAnswer(message) : .failed(message) }
            app?.say(message)
        }
        app?.updateActivity()
        app?.publish()
    }

    // MARK: What the Macs say

    /// A Mac said what it's recording. One this iPhone records with that has stopped, or moved on to
    /// another conversation, is marked so on the recording screen. When it's the Mac that asked this
    /// iPhone to record, this iPhone stops too, and says so: its stop may never have arrived.
    private func macReported(_ state: LinkRecordingState, from macID: UUID) {
        guard let current = session, let mac = current.macs.first(where: { $0.id == macID }) else { return }
        let recordsThis = state.conversationID == current.conversationID && state.phase != .idle
        guard !recordsThis else { return }
        if mac.state == .recording { session?.update(macID) { $0.state = .stopped } }
        if case .macLed(let lead) = current.role, lead == macID {
            stopFollowing(lead: mac.name, conversation: current.conversationID, because: "\(mac.name) stopped recording, so this iPhone stopped too.")
            return
        }
        app?.updateActivity()
        app?.publish()
    }

    /// Recording because a Mac asked, and that Mac has stopped (or can't be reached any more): stop too.
    private func stopFollowing(lead name: String, conversation: UUID, because message: String) {
        guard recorder.isActive, recorder.captureID == conversation, app?.isFiling == false else { return }
        stopIsFromMac = true
        Task {
            try? await app?.stopRecording()
            app?.say(message)
            app?.publish()
        }
    }

    /// While recording for a Mac: one that has been unreachable for `leaderSilenceLimit` won't stop
    /// this recording itself, so this iPhone does.
    func checkLead(now: Date = Date()) {
        guard let current = session, case .macLed(let lead) = current.role,
              let mac = link.macs.first(where: { $0.id == lead }), !mac.isConnected,
              let last = mac.lastConnectedAt, now.timeIntervalSince(last) > Self.leaderSilenceLimit else { return }
        stopFollowing(lead: mac.name, conversation: current.conversationID,
                      because: "\(mac.name) couldn’t be reached for \(Int(Self.leaderSilenceLimit / 60)) minutes, so this iPhone stopped recording.")
    }

    /// Whether a Mac may stop this iPhone's recording: the one that started it, or one this iPhone
    /// asked to record along. The person can always stop it here.
    func mayStop(_ macID: UUID) -> Bool {
        startedFromMac == macID || session?.macs.contains(where: { $0.id == macID }) == true
    }

    /// A Mac connected: it hears this iPhone's recording state and whether it may start recording here at
    /// once, and a stop that didn't reach it before goes now.
    private func macConnected(_ macID: UUID) {
        sendRecordPermission(to: macID)
        sharing.sendRecordingState(force: true)
        sendPendingStop(to: macID)
        macConnectedDuringCascade(macID)
    }

    // MARK: Stops owed to Macs

    /// Stopping here stops the Macs this iPhone started, those still being asked, and those that never
    /// answered; a Mac that was already recording keeps going.
    func stopMacsStartedHere(_ stopping: MultipointSession?) {
        guard let stopping, !stopping.isMacLed else { return }
        for mac in stopping.macs where mac.needsStop {
            session?.update(mac.id) { $0.state = .stopped }
            queueStop(of: mac.id, conversation: stopping.conversationID)
        }
    }

    /// A stop for a Mac this iPhone started: sent now, and again whenever it connects, until it answers,
    /// even after a relaunch.
    func queueStop(of macID: UUID, conversation: UUID) {
        if pendingStops[macID] != conversation { owedSince[macID] = Date() }
        pendingStops[macID] = conversation
        sendPendingStop(to: macID)
    }

    private func saveOwedStops() {
        owedSince = owedSince.filter { pendingStops[$0.key] != nil }
        owedStops.save(pendingStops.map { OwedMacStop(macID: $0.key, conversationID: $0.value, owedAt: owedSince[$0.key] ?? Date()) })
    }

    private func sendPendingStop(to macID: UUID) {
        guard let conversation = pendingStops[macID], link.macs.first(where: { $0.id == macID })?.isConnected == true,
              !stopsInFlight.contains(macID) else { return }
        stopsInFlight.insert(macID)
        Task {
            let result = await link.request(.stop, conversationID: conversation, timing: nil, from: macID)
            stopsInFlight.remove(macID)
            // Stopped, or it says it isn't recording that (or won't stop it): either way, done.
            if case .failure(.unreachable) = result { return }
            if pendingStops[macID] == conversation { pendingStops[macID] = nil }
        }
    }

    // MARK: Can Start Recording, both ways

    /// Whether a Mac may start a recording here (and stop one from its page): Recording with Your Mac, and its own
    /// Can Start Recording.
    func letsMacStartRecording(_ mac: PhoneLink.Mac) -> Bool {
        settings.acceptsMacRecordRequests && settings.macMayStartRecording(mac.id, pairedAt: mac.pairedAt)
    }

    /// Tells a connected Mac that takes it whether it may start recording here; `turnedOff` answers its ask to keep an
    /// off it had (`LinkRecordPermission.asksReceiverOff`).
    func sendRecordPermission(to macID: UUID, turnedOff: Bool = false) {
        guard let mac = link.macs.first(where: { $0.id == macID }) else { return }
        link.sendRecordPermission(LinkRecordPermission(allowed: letsMacStartRecording(mac), turnedOff: turnedOff ? true : nil), to: macID)
    }

    private func sendRecordPermissions() {
        for mac in link.connectedMacs { sendRecordPermission(to: mac.id) }
    }

    /// A Mac said whether this iPhone may start a recording there (`PhoneLink.Mac.takesStartsFromHere` keeps it). One
    /// that had Record along with this Mac off for this iPhone in an earlier build asks it to keep that off: Can Start
    /// Recording for it goes off here (once for this pairing), and the Mac hears it's taken.
    private func macSaidRecordPermission(_ permission: LinkRecordPermission, from macID: UUID) {
        guard permission.asksReceiverOff == true, let mac = link.macs.first(where: { $0.id == macID }) else { return }
        settings.takeMacOff(mac.id, pairedAt: mac.pairedAt)
        sendRecordPermission(to: macID, turnedOff: true)
    }

    // MARK: A Mac's record requests

    /// "It isn’t set to let Macs start recording." with where to turn it on.
    static let macsNotAllowed = "It isn’t set to let Macs start recording. Turn on Recording with Your Mac in Settings › Recording on the iPhone."

    /// A Mac's record request: start recording its conversation here (with its timing), or stop.
    func answer(_ mac: PhoneLink.Mac, _ request: LinkRecordRequest) async -> LinkRecordReply.Outcome {
        // A recorder this iPhone manages, which the Mac records along with through it. A stop names the
        // recording it means, so it never pauses one the person started since.
        if let target = request.recorder {
            guard settings.acceptsMacRecordRequests else {
                return .refused(LinkRecordRefusal(reason: .declined, message: Self.macsNotAllowed))
            }
            let answer = await RecorderRemoteControl.answer(request, target: target, sessions: devices.sessions, cascade: devices.cascade)
            if request.action == .stop { recorderStoppedRemotely(request.conversationID) }
            return answer
        }
        // The recording's own ID, which its track carries, so the Mac's link finds it when it syncs.
        var recordingID: String? { recorder.recordingID?.uuidString }
        switch request.action {
        case .start:
            guard settings.acceptsMacRecordRequests else {
                return .refused(LinkRecordRefusal(reason: .declined, message: Self.macsNotAllowed))
            }
            // Can Start Recording for that Mac: the one thing that decides whether it records here when it starts, as
            // the Mac's own does for this iPhone's starts.
            guard settings.macMayStartRecording(mac.id, pairedAt: mac.pairedAt) else {
                return .refused(LinkRecordRefusal(reason: .declined, message: PairingWords.notAllowedToStart(asker: .mac)))
            }
            if recorder.isActive {
                if recorder.captureID == request.conversationID {
                    return .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: recorder.startedAt,
                                                   recordingID: recordingID, wasAlreadyRecording: true))
                }
                return .refused(LinkRecordRefusal(reason: .recordingSomethingElse, conversationID: recorder.captureID))
            }
            // Only its recorder records another conversation (the iPhone was in the background): it can't
            // join this one as well.
            if let only = recorderOnly, only.conversationID != request.conversationID {
                return .refused(LinkRecordRefusal(reason: .recordingSomethingElse, conversationID: only.conversationID))
            }
            // A device page's Start Recording on iPhone: a conversation of this iPhone's own, which that
            // Mac may stop. Otherwise this iPhone records the Mac's conversation alongside it.
            let joining = request.isStandalone ? nil : MultipointSession(
                conversationID: request.conversationID, role: .macLed(macID: mac.id),
                macs: [MultipointSession.Mac(id: mac.id, name: mac.name, state: .recording, startedAt: request.timing?.startedAt, startedByPhone: false)],
                leadStartedAt: request.timing?.startedAt, timelineStart: request.timing?.timelineStart,
                leadClockOffset: mac.clock?.offset ?? request.timing?.clockOffset.map { -$0 },
                title: request.title, date: request.date)
            // The title shown while recording; filing never writes it on the Mac's conversation.
            let title = library.controller.meeting(request.conversationID)?.title ?? request.title
            guard let app else { return .refused(LinkRecordRefusal(reason: .unsupported)) }
            do {
                // A Mac asked: this iPhone's recorders record along; Macs aren't asked (the one that asked leads).
                try await app.startRecording(into: request.conversationID, title: title, multipoint: joining, trigger: .device, asksMacs: false)
                if joining == nil { startedFromMac = mac.id }
            } catch {
                if recorder.isActive, recorder.captureID != request.conversationID {
                    return .refused(LinkRecordRefusal(reason: .recordingSomethingElse, conversationID: recorder.captureID))
                }
                let denied = recorder.lastFailure == .microphoneDenied
                return .refused(LinkRecordRefusal(reason: denied ? .permissionDenied : .microphoneUnavailable, message: recorder.lastError))
            }
            // The first sample fixes the recording's start.
            await recorder.waitForFirstSample()
            return .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: recorder.startedAt ?? Date(),
                                           recordingID: recordingID, wasAlreadyRecording: false))
        case .stop:
            // The Mac this recording is with (the one that started it, or one this iPhone asked to record), or that
            // Mac's page (Stop on iPhone, a standalone stop) when it can start recording here, as on the Mac.
            let shared = mayStop(mac.id)
            let fromPage = request.isStandalone && letsMacStartRecording(mac)
            if !recorder.isActive, let only = recorderOnly, only.conversationID == request.conversationID, shared || fromPage {
                // Only its recorder records this conversation: it stops with the Mac.
                Task { await self.endRecorderOnly(because: nil) }
                return .accepted(LinkRecordAck(conversationID: request.conversationID, stoppedAt: Date()))
            }
            guard recorder.isActive, recorder.captureID == request.conversationID else {
                return .refused(LinkRecordRefusal(reason: .notRecording, conversationID: recorder.captureID))
            }
            guard shared || fromPage else {
                return .refused(LinkRecordRefusal(reason: .declined, message: request.isStandalone
                    ? PairingWords.notAllowedToStop(asker: .mac) : "This recording was started on the iPhone. Stop it there."))
            }
            let stoppedAt = Date(), stopped = recordingID
            // Answer now; finishing and filing a long recording can outlast the request's timeout. A stop from the Mac
            // it records with doesn't go back to it; one from another Mac's page goes on to the Mac this recording is with.
            stopIsFromMac = shared
            Task { try? await self.app?.stopRecording() }
            return .accepted(LinkRecordAck(conversationID: request.conversationID, stoppedAt: stoppedAt, recordingID: stopped))
        default:
            return .refused(LinkRecordRefusal(reason: .unsupported))
        }
    }

    /// How a recording made with a Mac joins its conversation: always when a Mac leads it, and when
    /// this iPhone led, once a Mac recorded it too (or may have). Its notes and bookmarks then stay
    /// with its track until the Mac places it. Nil files it as a conversation of its own.
    func join(for recording: PhoneRecording, session: MultipointSession?) -> PhoneLibrary.Join? {
        guard let session, session.conversationID == recording.id else { return nil }
        guard session.isMacLed else {
            return session.macs.contains(where: \.mayHaveRecorded) ? PhoneLibrary.Join() : nil
        }
        // Where the phone's recording probably starts on the Mac's timeline, by the link's clocks. A
        // Mac that didn't say where its timeline began (an older one) began it with its own recording.
        return PhoneLibrary.Join(estimatedOffset: MultipointTimeline.offset(of: recording.startedAt, from: session.timelineZero),
                                 title: session.title, date: session.date)
    }
}
