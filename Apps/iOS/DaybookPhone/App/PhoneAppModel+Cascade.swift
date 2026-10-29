import DaybookKit
import DaybookLink
import Foundation
import UIKit

// Recording across devices (docs/multipoint.md, "Starting anywhere"): starting on this iPhone starts
// its recorders and the Macs connected to it; a Mac starting this iPhone starts its recorders too; a
// recorder's button starts this iPhone, and so its Macs. Stopping anywhere stops the rest. Each device
// records a conversation once, under the one conversation ID, however many ways it's asked.
extension PhoneAppModel {
    /// How long after a shared recording starts a Mac that connects is still asked to join it.
    static let cascadeWindow: TimeInterval = 60

    /// Daybook is in front: its scene is active, and iOS says so (a background relaunch for the recorder
    /// has no scene to say otherwise).
    var isInFront: Bool { isForeground && UIApplication.shared.applicationState == .active }

    // MARK: Starting

    /// This iPhone started recording `id`: its recorders record along, and (unless a Mac leads, or a
    /// device page asked for a recording of this iPhone's own) every Mac connected now is asked to record
    /// it too, on its own.
    func beginCascade(_ id: UUID, title: String, date: Date, session: MultipointSession?, trigger: LinkCascade.Trigger,
                      leadRecorder: String?, asksMacs: Bool) {
        let cascade = devices.cascade
        cascade.begin(id, title: title, date: date, ledHere: session?.isMacLed != true)
        sharedNotes.begin(id, notes: recorder.timedNotes, bookmarks: recorder.highlights)
        Task {
            if let leadRecorder, let session = devices.sessions.first(where: { $0.id == leadRecorder }) {
                _ = await cascade.start(session, for: id, role: .led)
            }
            await cascade.startRecorders()
            sendRecordingState(force: true)
        }
        guard asksMacs, cascadesToMacs, session?.isMacLed != true else { return }
        cascadeAsksUntil = Date().addingTimeInterval(Self.cascadeWindow)
        askMacsToJoin(trigger: trigger)
    }

    /// Asks every connected Mac not yet involved to record the shared recording too. Waits a moment
    /// for this iPhone's first sample, which the Mac places its recording by.
    func askMacsToJoin(trigger: LinkCascade.Trigger) {
        let macs = link.connectedMacs.filter { mac in
            !mac.isRecording && !(multipoint?.macs.contains { $0.id == mac.id } ?? false) && (recorder.isCapturing || mac.cascades)
        }
        guard !macs.isEmpty else { return }
        Task {
            for _ in 0..<30 where recorder.isActive && recorder.startedAt == nil {
                try? await Task.sleep(for: .milliseconds(50))
                recorder.updateLevels()
            }
            let cascade = LinkCascade(trigger: trigger, requesterRecords: recorder.isCapturing, recorders: lastRecorders)
            for mac in macs { Task { await self.recordOnMac(mac.id, cascade: cascade) } }
        }
    }

    /// A Mac connected while this iPhone's shared recording is young (or only its recorder records):
    /// it's asked to join, as if it had been connected at the start.
    func macConnectedDuringCascade(_ macID: UUID) {
        let recording = recorder.isCapturing && multipoint?.isMacLed != true
        guard cascadesToMacs, recording || recorderOnly != nil, let until = cascadeAsksUntil, Date() < until || recorderOnly != nil,
              let mac = link.macs.first(where: { $0.id == macID }), !mac.isRecording,
              !(multipoint?.macs.contains { $0.id == macID } ?? false) else { return }
        let cascade = LinkCascade(trigger: recorderOnly != nil ? .recorder : .person, requesterRecords: recorder.isCapturing,
                                  recorders: lastRecorders)
        Task { await recordOnMac(macID, cascade: cascade) }
    }

    // MARK: Stopping

    /// This iPhone's recording ended: its recorders stop with it (each only the recording it made for
    /// it, its audio saved into the conversation), and the Mac leading it is asked to stop too unless
    /// the stop came from it (a cascading stop, owed until that Mac reconnects).
    func endCascade(_ conversation: UUID?, session: MultipointSession?, cascadesUp: Bool) {
        sharedNotes.end()
        notesShare?.cancel()
        cascadeAsksUntil = nil
        let cascade = devices.cascade
        Task {
            if let conversation { await cascade.stop(conversation) }
            sendRecordingState(force: true)
        }
        if cascadesUp, let session, case .macLed(let lead) = session.role,
           session.macs.first(where: { $0.id == lead })?.state != .stopped {
            queueStop(of: lead, conversation: session.conversationID)
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
    func recorderButton(_ session: DeviceSession, _ on: Bool) {
        guard session.managedElsewhere == nil, session.device.recordsAlongsideMac else { return }
        if on {
            if recorder.isActive, let id = recorder.captureID {
                devices.cascade.join(session, conversation: id)
                return
            }
            if let only = recorderOnly {
                devices.cascade.join(session, conversation: only.conversationID)
                return
            }
            Task { await startFromRecorder(session) }
        } else {
            Task { await recorderStopped(session) }
        }
    }

    /// The recorder's button began a recording: this iPhone records the same conversation. Where iOS
    /// doesn't let it start the microphone (Daybook in the background), the recorder's audio is saved
    /// here as it records, the Macs are asked to record, and a notification says so.
    func startFromRecorder(_ session: DeviceSession) async {
        guard !recorder.isActive, recorderOnly == nil else { return }
        let id = UUID()
        let title = "Conversation at \(Date().formatted(date: .omitted, time: .shortened))"
        do {
            try await startRecording(into: id, title: title, multipoint: nil, trigger: .recorder, leadRecorder: session.id)
        } catch {
            guard !recorder.isActive else { return }
            await beginRecorderOnly(session, id: id, title: title)
        }
    }

    /// Only the recorder records the shared recording here: its audio is saved into the conversation
    /// as it records, the Macs that understand it are asked to record (the link kept up meanwhile,
    /// reconnecting from the background), and the person is told plainly.
    func beginRecorderOnly(_ session: DeviceSession, id: UUID, title: String) async {
        let start = session.status?.recordingStartedAt ?? Date()
        recorderOnly = RecorderOnlyRecording(conversationID: id, title: title, startedAt: start, recorderID: session.id,
                                             recorderName: session.device.name)
        multipoint = MultipointSession(conversationID: id, role: .phoneLed)
        devices.cascade.begin(id, title: title, date: start, ledHere: true)
        _ = await devices.cascade.start(session, for: id, role: .led)
        if isInFront {
            say("\(session.device.name) is recording. This iPhone couldn’t start its microphone, so it saves the recorder’s audio.")
        } else {
            cascadeNotices.recorderRecording(session.device.name)
        }
        // A background relaunch for the recorder skips `launch`: the link starts here.
        if !link.started { await link.start() }
        await link.setActivity(.backgroundRecording)
        if cascadesToMacs {
            cascadeAsksUntil = Date().addingTimeInterval(Self.cascadeWindow)
            askMacsToJoin(trigger: .recorder)
        }
        sendRecordingState(force: true)
        publish()
    }

    /// The recorder-only shared recording ended (the recorder stopped, or a Mac asked): the Macs this
    /// iPhone started stop too, the recorder (when it still records) stops, and its audio stays in the
    /// conversation, its own file following.
    func endRecorderOnly(because message: String?) async {
        guard let only = recorderOnly else { return }
        recorderOnly = nil
        let session = multipoint
        stopMacsStartedHere(session)
        multipoint = nil
        cascadeAsksUntil = nil
        cascadeNotices.recorderStopped()
        await devices.cascade.stop(only.conversationID)
        if let message { say(message) }
        sendRecordingState(force: true)
        if !isInFront { await link.setActivity(.background) }
        publish()
    }

    /// Daybook came forward while only the recorder records: this iPhone records the same conversation
    /// now, with the Macs already asked, and the notification goes.
    func recordAlongWithRecorder() async {
        guard let only = recorderOnly, !recorder.isActive else { return }
        let session = multipoint
        do {
            try await startRecording(into: only.conversationID, title: only.title, multipoint: session, trigger: .recorder)
            recorderOnly = nil
            cascadeNotices.recorderStopped()
            sendRecordingState(force: true)
        } catch {
            // The microphone still can't start (it was refused, say): the recorder keeps saving.
        }
    }

    /// A recorder of the shared recording stopped from its button: the shared recording stops everywhere.
    func recorderStopped(_ session: DeviceSession) async {
        guard await devices.cascade.recorderStopped(session) else { return }
        let words = "\(session.device.name) stopped recording, so this iPhone stopped too."
        if let only = recorderOnly, only.recorderID == session.id {
            await endRecorderOnly(because: isInFront ? words : nil)
            return
        }
        guard recorder.isActive, !isFiling else { return }
        try? await stopRecording()
        say(words)
        publish()
    }

    // MARK: Notes and bookmarks

    /// The Macs recording this conversation with this iPhone that take shared notes.
    func macsSharingNotes(_ id: UUID) -> [UUID] {
        guard let session = multipoint, session.conversationID == id else { return [] }
        return link.connectedMacs.filter { mac in
            mac.sharesNotes && session.macs.contains { $0.id == mac.id && ($0.state == .recording || $0.state == .asking) }
        }.map(\.id)
    }

    /// Where this recording's notes go on the conversation's timeline when filed (`PhoneLibrary.Join`).
    var noteShift: TimeInterval {
        guard let session = multipoint, session.isMacLed, let start = recorder.startedAt else { return 0 }
        let offset = session.leadClockOffset
        let zero = (session.timelineStart ?? session.leadStartedAt).map { start in offset.map { start.addingTimeInterval(-$0) } ?? start }
        return max(0, zero.map { start.timeIntervalSince($0) } ?? 0)
    }

    /// Notes are shared a moment after typing pauses.
    func scheduleNotesShare() {
        guard sharedNotes.isActive else { return }
        notesShare?.cancel()
        notesShare = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.flushSharedNotes()
        }
    }

    /// Sends the paragraphs written, edited, or deleted since they were last shared, each with the time
    /// this iPhone files it at (a Mac's paragraph keeps the Mac's).
    func flushSharedNotes() {
        notesShare?.cancel()
        guard sharedNotes.isActive, let id = recorder.captureID else { return }
        let changes = sharedNotes.notesChanged(recorder.timedNotes)
        let macs = macsSharingNotes(id)
        guard !changes.isEmpty, !macs.isEmpty else { return }
        let now = Date(), start = recorder.startedAt ?? now, shift = noteShift
        let messages: [LinkMessage] = changes.map { change in
            let filed = recorder.sharedNotes[change.id]?.time ?? change.time.map { $0 + shift }
            return .note(LinkNote(id: change.id, conversationID: id, text: change.text, time: filed,
                                  madeAt: change.time.map { start.addingTimeInterval($0) } ?? now, deleted: change.deleted, changedAt: now))
        }
        link.sendShared(messages, to: macs)
    }

    /// A Mac recording this conversation too wrote a note or made or changed a bookmark: it shows on the
    /// recording screen at once, at its moment in this recording, and is filed as the Mac files it.
    func macSharedNotes(_ message: LinkMessage, from macID: UUID) {
        guard recorder.isActive, let id = recorder.captureID, sharedNotes.conversationID == id else { return }
        let clock = link.macs.first { $0.id == macID }?.clock
        let local = { (date: Date) in clock?.localDate(fromPeer: date) ?? date }
        let start = recorder.startedAt ?? Date()
        switch message {
        case .note(let note) where note.conversationID == id:
            let shared = SharedNote(id: note.id, text: note.text, time: note.time, deleted: note.deleted)
            guard sharedNotes.received(shared, changedAt: local(note.changedAt)) else { return }
            recorder.applySharedNote(shared, localTime: local(note.madeAt).timeIntervalSince(start), filed: note.time)
        case .bookmark(let mark) where mark.conversationID == id:
            let filed = Highlight(id: mark.id, time: mark.recordingTime, text: mark.label ?? "")
            guard sharedNotes.received(bookmark: filed, at: Date()) else { return }
            recorder.addSharedBookmark(filed, localTime: local(mark.createdAt).timeIntervalSince(start))
        case .bookmarkChange(let change) where change.conversationID == id:
            guard sharedNotes.received(bookmarkChange: change.id, label: change.label, deleted: change.deleted,
                                       changedAt: local(change.changedAt)) else { return }
            recorder.applySharedBookmarkChange(id: change.id, label: change.label, deleted: change.deleted)
        default:
            break
        }
        updateActivity()
    }
}
