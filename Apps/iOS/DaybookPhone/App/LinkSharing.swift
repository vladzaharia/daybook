import DaybookKit
import DaybookLink
import DaybookUI
import Foundation

/// What goes to the Macs over the local link while this iPhone records (docs/iphone.md, "Every
/// source"): the recording's state on every change and every 15 seconds; its captions, a second at a time
/// and only what changed; its level, a few readings at a time about five times a second; and the notes
/// and bookmarks of a shared recording, both ways, filed as the device that made them files them.
@MainActor
final class LinkSharing {
    /// Notes and bookmarks of the shared recording, kept in step with the Macs recording it too.
    let sharedNotes = SharedNotesTracker()
    /// The recorders this iPhone manages, as last sent to Macs.
    private(set) var lastRecorders: [LinkRecorderState]?
    private var notesShare: Task<Void, Never>?
    /// This iPhone's captions going to each Mac recording the same conversation (`shareCaptions`).
    private var captionShares: [UUID: CaptionShare] = [:]
    private var captionSharing: Task<Void, Never>?
    /// This iPhone's level readings on their way to the Macs recording with it that draw them (`shareLevel`).
    private var levelShare = LevelShare()
    private var lastStateSent = Date.distantPast

    private let recorder: PhoneRecorder
    private let link: PhoneLink
    private let devices: PhoneDevices
    private let captions: LiveCaptionsController
    /// The recording with Macs and recorders it shares with (`MultipointCoordinator`).
    weak var multipoints: MultipointCoordinator?
    /// What the Live Activity shows changed (a Mac's note or bookmark arrived).
    var changed: () -> Void = {}

    static let captionShareInterval: Duration = .seconds(1)
    /// The recording state goes at least this often while recording, besides every change.
    static let stateInterval: TimeInterval = 15

    init(recorder: PhoneRecorder, link: PhoneLink, devices: PhoneDevices, captions: LiveCaptionsController) {
        self.recorder = recorder
        self.link = link
        self.devices = devices
        self.captions = captions
    }

    // MARK: The recording's state

    /// The recorder's state to connected Macs: on every change, and every `stateInterval` while recording.
    func sendRecordingState(force: Bool) {
        guard !link.connectedMacs.isEmpty, force || Date().timeIntervalSince(lastStateSent) >= Self.stateInterval else { return }
        lastStateSent = Date()
        let phase: LinkRecordingState.Phase
        switch recorder.state {
        case .idle: phase = .idle
        case .starting: phase = .starting
        case .recording: phase = .recording
        case .paused: phase = .paused
        case .stopping: phase = .stopping
        }
        let cascade = devices.cascade
        let recorders = devices.hub.recorderStates(conversation: { cascade.sharedConversation(of: $0) })
        lastRecorders = recorders
        link.sendRecordingState(LinkRecordingState(phase: phase, conversationID: recorder.captureID, startedAt: recorder.startedAt,
                                                   elapsed: recorder.isActive ? recorder.elapsedTime : 0, recorders: recorders,
                                                   sharedConversationID: recorder.isActive ? nil : multipoints?.recorderOnly?.conversationID))
    }

    // MARK: Captions

    /// While recording, this iPhone's captions (and its recorder's) go to the Macs recording the same
    /// conversation that show them, a second at a time, over the local link: the Mac's captions then
    /// have every device's lines (`LinkCaptions`), and drop the ones this iPhone took back.
    func startSharingCaptions() {
        captionShares = [:]
        captionSharing?.cancel()
        captionSharing = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.captionShareInterval)
                guard !Task.isCancelled, let self else { return }
                await self.shareCaptions()
            }
        }
    }

    /// The last of them go, then no more.
    func stopSharingCaptions() {
        captionSharing?.cancel()
        captionSharing = Task { [weak self] in await self?.shareCaptions() }
    }

    /// Sends each Mac the lines that changed since it last heard, and those taken back: every line this
    /// iPhone and its recorders heard, which the Mac puts together with its own.
    func shareCaptions() async {
        let captions = self.captions
        guard let id = recorder.captureID, let start = recorder.startedAt, captions.activeMeetingID == id, !macsShowingCaptions(id).isEmpty
        else { return }
        let lines = await captions.forwardable()
        guard recorder.captureID == id else { return }
        for mac in macsShowingCaptions(id) {
            var share = captionShares[mac] ?? CaptionShare()
            let changes = share.changes(lines, names: captions.sourceNames)
            captionShares[mac] = share
            guard !changes.lines.isEmpty || !changes.removed.isEmpty else { continue }
            link.sendShared([.captions(LinkCaptions(conversationID: id, startedAt: start, lines: changes.lines,
                                                    removed: changes.removed.isEmpty ? nil : changes.removed))], to: [mac])
        }
    }

    /// The connected Macs recording this conversation too that show other devices' captions.
    func macsShowingCaptions(_ id: UUID) -> [UUID] {
        macsRecording(id) { $0.showsCaptions }
    }

    /// The connected Macs recording this conversation too that draw this iPhone's level.
    func macsShowingLevels(_ id: UUID) -> [UUID] {
        macsRecording(id) { $0.showsLevels }
    }

    private func macsRecording(_ id: UUID, where shows: (PhoneLink.Mac) -> Bool) -> [UUID] {
        let session = multipoints?.session
        return link.connectedMacs.filter { mac in
            shows(mac) && (mac.recording?.takesPart(in: id) == true
                || session.map { $0.conversationID == id && $0.macs.contains { $0.id == mac.id && $0.state == .recording } } == true)
        }.map(\.id)
    }

    // MARK: Levels

    /// While this iPhone records a conversation with Macs that draw its level, its meter's readings go to
    /// them over the local link, a few at a time about five times a second (`LinkLevels`), so the Mac
    /// meters every source. Paused, none go: the Mac's meter for this iPhone rests.
    func shareLevel(_ level: AudioLevel, at now: Date = Date()) {
        guard recorder.state == .recording, let id = recorder.captureID else {
            levelShare = LevelShare()
            return
        }
        guard let values = levelShare.add(level.meterValue, at: now) else { return }
        let macs = macsShowingLevels(id)
        guard !macs.isEmpty else { return }
        link.sendLevels(LinkLevels(conversationID: id, values: values, interval: PhoneRecorder.levelInterval, sentAt: now), to: macs)
    }

    // MARK: Notes and bookmarks

    /// A shared recording began: the notes and bookmarks it starts with are where sharing starts.
    func beginSharedNotes(_ id: UUID) {
        sharedNotes.begin(id, notes: recorder.timedNotes, bookmarks: recorder.highlights)
    }

    /// It ended: nothing more is shared.
    func endSharedNotes() {
        sharedNotes.end()
        notesShare?.cancel()
    }

    /// The person typed: a paragraph a Mac wrote a moment ago that the editor hadn't shown yet isn't deleted
    /// by it, and what changed goes to the Macs a moment after typing pauses.
    func editNotes(_ text: String) {
        let text = sharedNotes.isActive ? sharedNotes.keepingArrivals(text, anchors: recorder.timedNotes) : text
        recorder.editNotes(text)
        scheduleNotesShare()
    }

    /// A bookmark made here goes to the Macs recording along, with the same ID as the phone's own, so the
    /// Mac's copy and the synced one are one bookmark.
    func bookmarkAdded(_ mark: Highlight) {
        guard let id = recorder.captureID, multipoints?.session != nil else { return }
        link.sendBookmark(LinkBookmark(id: mark.id, conversationID: id, recordingTime: mark.time))
        sharedNotes.bookmarkShared(mark)
    }

    /// The Macs recording this conversation with this iPhone that take shared notes.
    func macsSharingNotes(_ id: UUID) -> [UUID] {
        guard let session = multipoints?.session, session.conversationID == id else { return [] }
        return link.connectedMacs.filter { mac in
            mac.sharesNotes && session.macs.contains { $0.id == mac.id && ($0.state == .recording || $0.state == .asking) }
        }.map(\.id)
    }

    /// Where this recording's notes go on the conversation's timeline when filed (`PhoneLibrary.Join`).
    var noteShift: TimeInterval {
        guard let session = multipoints?.session, session.isMacLed, let start = recorder.startedAt else { return 0 }
        return max(0, MultipointTimeline.offset(of: start, from: session.timelineZero) ?? 0)
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
        changed()
    }
}
