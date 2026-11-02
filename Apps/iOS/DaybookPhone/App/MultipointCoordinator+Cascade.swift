import DaybookKit
import DaybookLink
import Foundation

// Recording across devices (docs/multipoint.md, "Starting anywhere"): starting on this iPhone starts
// its recorders and the Macs connected to it; a Mac starting this iPhone starts its recorders too; a
// recorder's button starts this iPhone, and so its Macs. Stopping anywhere stops the rest. Each device
// records a conversation once, under the one conversation ID, however many ways it's asked.
extension MultipointCoordinator {
    /// How long after a shared recording starts a Mac that connects is still asked to join it.
    static let cascadeWindow: TimeInterval = 60

    // MARK: Starting

    /// This iPhone started recording `id`: its recorders record along, and (unless a Mac leads, or a
    /// device page asked for a recording of this iPhone's own) every Mac connected now is asked to record
    /// it too, on its own.
    func beginCascade(_ id: UUID, title: String, date: Date, session: MultipointSession?, trigger: LinkCascade.Trigger,
                      leadRecorder: String?, asksMacs: Bool) {
        let cascade = devices.cascade
        let ledHere = session?.isMacLed != true
        let previous = cascade.conversation.flatMap { $0.id == id ? nil : $0.id }
        if previous == nil { cascade.begin(id, title: title, date: date, ledHere: ledHere) }
        sharing.beginSharedNotes(id)
        Task {
            // One the last recording left under way (it ended unexpectedly) stops first.
            if let previous {
                await cascade.stop(previous)
                cascade.begin(id, title: title, date: date, ledHere: ledHere)
            }
            if let leadRecorder, let recorder = devices.sessions.first(where: { $0.id == leadRecorder }) {
                _ = await cascade.start(recorder, for: id, role: .led)
            }
            await cascade.startRecorders()
            sharing.sendRecordingState(force: true)
        }
        guard asksMacs, cascadesToMacs, session?.isMacLed != true else { return }
        cascadeAsksUntil = Date().addingTimeInterval(Self.cascadeWindow)
        askMacsToJoin(trigger: trigger)
    }

    /// Asks every connected Mac not yet involved to record the shared recording too. Waits a moment
    /// for this iPhone's first sample, which the Mac places its recording by.
    func askMacsToJoin(trigger: LinkCascade.Trigger) {
        // A Mac that said it doesn't let this iPhone start recording there isn't asked: it would only decline.
        let macs = link.connectedMacs.filter { mac in
            !mac.isRecording && !(session?.macs.contains { $0.id == mac.id } ?? false) && (recorder.isCapturing || mac.cascades)
                && mac.takesStartsFromHere != false
        }
        guard !macs.isEmpty else { return }
        Task {
            await recorder.waitForFirstSample()
            let cascade = LinkCascade(trigger: trigger, requesterRecords: recorder.isCapturing, recorders: sharing.lastRecorders)
            for mac in macs { Task { await self.recordOnMac(mac.id, cascade: cascade) } }
        }
    }

    /// A Mac connected while this iPhone's shared recording is young (or only its recorder records):
    /// it's asked to join, as if it had been connected at the start.
    func macConnectedDuringCascade(_ macID: UUID) {
        let recording = recorder.isCapturing && session?.isMacLed != true
        guard cascadesToMacs, recording || recorderOnly != nil, let until = cascadeAsksUntil, Date() < until || recorderOnly != nil,
              let mac = link.macs.first(where: { $0.id == macID }), !mac.isRecording, mac.takesStartsFromHere != false,
              !(session?.macs.contains { $0.id == macID } ?? false) else { return }
        let cascade = LinkCascade(trigger: recorderOnly != nil ? .recorder : .person, requesterRecords: recorder.isCapturing,
                                  recorders: sharing.lastRecorders)
        Task { await recordOnMac(macID, cascade: cascade) }
    }

    // MARK: Stopping

    /// This iPhone's recording ended: its recorders stop with it (each only the recording it made for
    /// it, its audio saved into the conversation), and the Mac leading it is asked to stop too unless
    /// the stop came from it (a cascading stop, owed until that Mac reconnects).
    func endCascade(_ conversation: UUID?, session ended: MultipointSession?, cascadesUp: Bool) {
        sharing.endSharedNotes()
        cascadeAsksUntil = nil
        let cascade = devices.cascade
        Task {
            if let conversation { await cascade.stop(conversation) }
            sharing.sendRecordingState(force: true)
        }
        if cascadesUp, let ended, case .macLed(let lead) = ended.role,
           ended.macs.first(where: { $0.id == lead })?.state != .stopped {
            queueStop(of: lead, conversation: ended.conversationID)
        }
    }

    /// A Mac stopped a recorder this iPhone manages: when nothing records the shared recording here any
    /// more, it ends.
    func recorderStoppedRemotely(_ conversation: UUID) {
        guard !recorder.isActive, devices.cascade.conversation?.id == conversation, !devices.cascade.hasRecordingMembers else { return }
        if recorderOnly?.conversationID == conversation { Task { await endRecorderOnly(because: nil) } }
        else { Task { await devices.cascade.stop(conversation) } }
    }

    // MARK: The recorder's button

    /// A recorder this iPhone manages started or stopped from its own button. Started: this iPhone
    /// records too (and so its Macs), or the recorder joins the recording under way. Stopped: the
    /// recording it's part of stops everywhere. Its "Record along" preference decides.
    func recorderButton(_ recorderSession: DeviceSession, _ on: Bool) {
        guard recorderSession.managedElsewhere == nil, recorderSession.device.recordsAlongsideMac else { return }
        if on {
            if recorder.isActive, let id = recorder.captureID {
                devices.cascade.join(recorderSession, conversation: id)
                return
            }
            if let only = recorderOnly {
                devices.cascade.join(recorderSession, conversation: only.conversationID)
                return
            }
            Task { await startFromRecorder(recorderSession) }
        } else {
            Task { await recorderStopped(recorderSession) }
        }
    }

    /// The recorder's button began a recording: this iPhone records the same conversation. Where iOS
    /// doesn't let it start the microphone (Daybook in the background), the recorder's audio is saved
    /// here as it records, the Macs are asked to record, and a notification says so.
    func startFromRecorder(_ recorderSession: DeviceSession) async {
        // Its push and a press caught up as the link came back can both arrive: one start.
        guard let app, !recorder.isActive, recorderOnly == nil, !startingFromRecorder else { return }
        startingFromRecorder = true
        defer { startingFromRecorder = false }
        let id = UUID()
        let title = Meeting.defaultTitle()
        do {
            try await app.startRecording(into: id, title: title, multipoint: nil, trigger: .recorder, leadRecorder: recorderSession.id)
        } catch {
            guard !recorder.isActive, recorderOnly == nil else { return }
            await beginRecorderOnly(recorderSession, id: id, title: title)
        }
    }

    /// Only the recorder records the shared recording here: its audio is saved into the conversation
    /// as it records, the Macs that understand it are asked to record (the link kept up meanwhile,
    /// reconnecting from the background), and the person is told plainly.
    func beginRecorderOnly(_ recorderSession: DeviceSession, id: UUID, title: String) async {
        let start = recorderSession.status?.recordingStartedAt ?? Date()
        recorderOnly = RecorderOnlyRecording(conversationID: id, title: title, startedAt: start, recorderID: recorderSession.id,
                                             recorderName: recorderSession.device.name)
        // Told at once, not after the recorder and the Macs answer.
        if app?.isInFront == true {
            app?.say("\(recorderSession.device.name) is recording. This iPhone couldn’t start its microphone, so it saves the recorder’s audio.")
        } else {
            app?.notices.recorderRecording(recorderSession.device.name)
        }
        session = MultipointSession(conversationID: id, role: .phoneLed)
        if let stale = devices.cascade.conversation?.id, stale != id { await devices.cascade.stop(stale) }
        devices.cascade.begin(id, title: title, date: start, ledHere: true)
        _ = await devices.cascade.start(recorderSession, for: id, role: .led)
        // A background relaunch for the recorder skips `launch`: the link starts here.
        if !link.started { await link.start() }
        await link.setActivity(.backgroundRecording)
        if cascadesToMacs {
            cascadeAsksUntil = Date().addingTimeInterval(Self.cascadeWindow)
            askMacsToJoin(trigger: .recorder)
        }
        sharing.sendRecordingState(force: true)
        app?.publish()
    }

    /// The recorder-only shared recording ended (the recorder stopped, or a Mac asked): the Macs this
    /// iPhone started stop too, the recorder (when it still records) stops, and its audio stays in the
    /// conversation, its own file following.
    func endRecorderOnly(because message: String?) async {
        guard let only = recorderOnly else { return }
        recorderOnly = nil
        let ending = session
        stopMacsStartedHere(ending)
        session = nil
        cascadeAsksUntil = nil
        app?.notices.recorderStopped()
        await devices.cascade.stop(only.conversationID)
        if let message { app?.say(message) }
        sharing.sendRecordingState(force: true)
        if app?.isInFront != true { await link.setActivity(.background) }
        app?.publish()
    }

    /// Daybook came forward while only the recorder records: this iPhone records the same conversation
    /// now, with the Macs already asked, and the notification goes.
    func recordAlongWithRecorder() async {
        guard let app, let only = recorderOnly, !recorder.isActive else { return }
        let asked = session
        do {
            try await app.startRecording(into: only.conversationID, title: only.title, multipoint: asked, trigger: .recorder)
            recorderOnly = nil
            app.notices.recorderStopped()
            sharing.sendRecordingState(force: true)
        } catch {
            // The microphone still can't start (it was refused, say): the recorder keeps saving.
        }
    }

    /// A recorder of the shared recording stopped from its button: the shared recording stops everywhere.
    func recorderStopped(_ recorderSession: DeviceSession) async {
        guard await devices.cascade.recorderStopped(recorderSession) else { return }
        let words = "\(recorderSession.device.name) stopped recording, so this iPhone stopped too."
        if let only = recorderOnly, only.recorderID == recorderSession.id {
            await endRecorderOnly(because: app?.isInFront == true ? words : nil)
            return
        }
        guard recorder.isActive, app?.isFiling == false else { return }
        try? await app?.stopRecording()
        app?.say(words)
        app?.publish()
    }
}
