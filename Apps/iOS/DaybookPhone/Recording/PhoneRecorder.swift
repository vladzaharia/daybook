import AVFoundation
import DaybookCore
import Foundation
import Observation

/// Everything the recorder needs from the system, injectable so tests drive it with synthetic audio,
/// a scripted session, and a manual clock instead of the microphone.
struct PhoneRecorderEnvironment {
    var session: any AudioSessionControlling
    var makeInput: @MainActor () -> any AudioInputSource
    var clock: any RecorderClock
    var format: RecordingFormat = .speech
    /// `AVAssetWriter` real-time mode. Tests that deliver audio faster than real time turn it off.
    var realTimeEncoding = true

    @MainActor static func live() -> PhoneRecorderEnvironment {
        PhoneRecorderEnvironment(session: LiveAudioSession(), makeInput: { EngineMicrophoneInput() }, clock: SystemRecorderClock())
    }

    /// Synthetic speech and no audio session, for simulator demos: nothing opens a microphone.
    @MainActor static func synthetic() -> PhoneRecorderEnvironment {
        let clock = SystemRecorderClock()
        return PhoneRecorderEnvironment(session: ScriptedAudioSession(),
                                        makeInput: { SyntheticAudioInput(signal: .speechLike, clock: clock, realTime: true) },
                                        clock: clock)
    }
}

/// Records the iPhone's microphone into a crash-safe, interruption-safe AAC recording, with timed
/// notes and bookmarks on the same clock. UI-agnostic: views observe it; intents and the Live
/// Activity drive it through the app model.
///
/// - Timeline: the conversation starts at the first sample. Elapsed time, note times, bookmarks,
///   and segment offsets are all measured on the continuous clock from there, so they agree with
///   each other and with the finished file.
/// - Interruptions (a call, Siri, an alarm) pause: input stops and the current segment is finished,
///   so everything recorded so far is a complete file even if the app is then suspended and killed.
///   When the interruption ends the recorder resumes if the system recommends it, otherwise it
///   offers to (`canResume`). Each run is a segment; Stop joins them into one file with silence in
///   the gaps.
/// - Route changes (AirPods, a wired mic, the built-in mic) restart input on the new hardware
///   format; the writer converts and pads, and the journal notes the change. A headset coming or
///   going asks the session for the input the person's choice resolves to (`AudioInputPlan`), so
///   AirPods connecting mid-meeting don't take over from the built-in microphone; an input chosen in
///   the system's picker (`inputChosen`) is remembered for later recordings.
/// - Media-services resets rebuild the session and input and continue in a new segment.
/// - Stop has two steps: capture ends (input stops, every segment closes, the journal says `stopping`, and the
///   audio session is given back; `StopEvents.captureEnded`), then the segments are joined, by copying their
///   packets (`RecordingAssembler`). A recording iOS ends Daybook during is recovered as saved, not as cut short.
///   While the iPhone is locked the join waits for an unlock (`waitingCapture`): the parts are kept until unlock
///   (`StagingProtection`), so they can't be read back before.
/// - Hearing: the microphone isn't hearing after 5 s without a non-zero sample, or 20 s under −90 dBFS
///   (`HearingCheck`), rolling, so it's said whenever it happens and clears when sound comes back.
/// - Crash safety: segments are written as fragmented M4A (readable up to the last fragment the
///   audio passed: 2–4 s behind at the default interval) and the
///   journal sidecar records segments, timing, notes, and bookmarks. `recover(in:)` rebuilds a
///   recording from a folder a killed app left behind.
@MainActor
@Observable
final class PhoneRecorder {
    enum State: Equatable {
        case idle
        case starting
        case recording
        case paused(PauseReason)
        case stopping
    }

    enum PauseReason: Equatable {
        /// A call, Siri, an alarm, or another app took the audio session.
        case interruption
        /// The microphone couldn't restart after a route change or reset.
        case inputFailed
    }

    private(set) var state: State = .idle
    private(set) var level = AudioLevel.silent
    /// The microphone isn't hearing anything now (`HearingCheck`): muted, unplugged, blocked, or covered. Rolling: it
    /// clears as soon as it hears again.
    private(set) var isMicrophoneSilent = false
    /// When the microphone last heard something as loud as speech (`speechLevel`): following a Mac it can't reach, this
    /// iPhone stops only in a quiet room (`LeaderWatch`). Changes with every word, so unobserved.
    @ObservationIgnored private(set) var lastHeardSpeechAt: Date?
    /// At or above this level, dBFS, the microphone hears something as loud as speech (the Mac's `audibleThreshold`).
    static let speechLevel: Float = -50
    /// The conversation being recorded.
    private(set) var captureID: UUID?
    /// This recording's own ID (one conversation can hold several of this iPhone's recordings).
    private(set) var recordingID: UUID?
    private(set) var title = ""
    /// The conversation's first sample on the wall clock, once audio arrives.
    private(set) var startedAt: Date?
    private(set) var notes = ""
    private(set) var timedNotes: [TimedNote] = []
    private(set) var highlights: [Highlight] = []
    /// Paragraphs and bookmarks a Mac recording along wrote, as that Mac files them (by ID).
    private(set) var sharedNotes: [UUID: TimedNote] = [:]
    private(set) var sharedBookmarks: [UUID: Highlight] = [:]
    /// Photos taken during this recording, kept in the staging folder.
    private(set) var photos: [CapturePhoto] = []
    /// Handwriting in this recording's notes: one paragraph of `notes` per block.
    private(set) var ink: [NoteInk] = []
    private(set) var inputRoute: AudioInputRoute?
    /// The interruption ended; recording can continue.
    private(set) var canResume = false
    /// Why the recording is paused, in a sentence.
    private(set) var pauseMessage: String?
    /// Conversation seconds when the current pause began.
    private(set) var pausedAt: TimeInterval?
    /// The recorder's words for its last problem: a start, resume, or stop that failed, or one it
    /// reports while it keeps recording (`journalWarning`).
    private(set) var lastError: String?
    /// Why the last start, resume, or stop failed, when it was one of the recorder's own reasons: for
    /// callers to act on (a Mac told that the microphone isn't allowed), never to show.
    private(set) var lastFailure: PhoneRecorderError?
    /// Why the recording stopped by itself, when it did (`onUnexpectedStop`): storage that couldn't keep
    /// up (`PhoneRecorderError.diskBacklog`), or the encoder. Cleared when the next recording starts.
    private(set) var unexpectedStop: Error?
    /// The staging folder of the last recording Stop couldn't finish (`lastFailure` says why), kept for its
    /// notes and for recovery. Cleared when the next recording starts.
    private(set) var unfinishedFolder: URL?
    /// The last recording Stop ended while the iPhone was locked: whole on disk, its journal saying `stopping`, and
    /// still to be joined, which reads its parts back and so waits for an unlock (`StagingProtection`). Its caller
    /// finishes it (`finish(_:)`). Cleared when the next recording starts.
    private(set) var waitingCapture: StoppedCapture?
    /// Whether files kept until unlock can be read now (`PhoneAppEnvironment.protectedData`): when they can't, Stop
    /// ends the capture and leaves the join (`waitingCapture`).
    @ObservationIgnored var protectedDataAvailable: () -> Bool = { true }

    /// State, pauses, routes, and bookmarks changed (not levels).
    @ObservationIgnored var onChange: (() -> Void)?
    /// About fifteen times a second while recording.
    @ObservationIgnored var onLevel: ((AudioLevel) -> Void)?
    /// The encoder or storage failed: the recording is about to be finished as it stands (`onUnexpectedStop` says
    /// when it has been), so its caller can hold background time for it from now.
    @ObservationIgnored var onStoppingByItself: (() -> Void)?
    /// The encoder or storage failed; the recording was finished as it stood.
    @ObservationIgnored var onUnexpectedStop: ((PhoneRecording?) -> Void)?
    /// The interruption ended and iOS asked to continue, but recording couldn't (another app still
    /// holds the microphone, say): it stays paused, with Resume.
    @ObservationIgnored var onResumeFailed: ((Error) -> Void)?
    /// The recording is paused and won't go on by itself: an interruption ended without iOS asking to continue, or the
    /// microphone couldn't restart. Resume continues it.
    @ObservationIgnored var onNeedsResume: (() -> Void)?
    /// A copy of the live input for listeners such as live captions: each buffer after the writer has
    /// it, on the audio thread, with its host time. It must return at once and never throw; the
    /// recording doesn't wait for it or depend on it. Read when input starts (start, resume, restart).
    @ObservationIgnored var audioTap: (@Sendable (AVAudioPCMBuffer, TimeInterval) -> Void)?

    @ObservationIgnored private let environment: PhoneRecorderEnvironment
    @ObservationIgnored private var input: (any AudioInputSource)?
    @ObservationIgnored private var writer: PhoneTrackWriter?
    @ObservationIgnored private var inputGeneration = UUID()
    @ObservationIgnored private var journal: PhoneCaptureJournal?
    @ObservationIgnored private var directory: URL?
    /// The meter's and the journal's ticks while recording (`startTicks`).
    @ObservationIgnored private var ticks: [Task<Void, Never>] = []
    /// When the microphone last started listening (a start, a resume, a restart), on the host clock: the hearing check
    /// counts from there.
    @ObservationIgnored private var listeningSince: TimeInterval = 0
    @ObservationIgnored private var notesSave: Task<Void, Never>?
    @ObservationIgnored private var cancelStart = false
    @ObservationIgnored private let journalQueue = DispatchQueue(label: "local.daybook.phone.journal", qos: .utility)
    /// Whether the last journal write failed, touched only on `journalQueue`: a failure is reported
    /// once, until a write succeeds again.
    @ObservationIgnored private let journalHealth = JournalHealth()

    /// Between level readings while recording (`onLevel`), for a meter someone sees.
    static let levelInterval: TimeInterval = 1.0 / 15
    /// Between level readings while no one sees a meter (Daybook out of sight, no Mac drawing this iPhone's level):
    /// enough for the hearing check, the Live Activity, and the widgets.
    static let backgroundLevelInterval: TimeInterval = 0.5
    /// Between level readings now: `levelInterval` or `backgroundLevelInterval`, as the app model sets it.
    @ObservationIgnored var meterInterval: TimeInterval = levelInterval
    /// Between journal writes while recording, besides those a change makes.
    static let journalInterval: TimeInterval = 5
    /// The pause message when iOS gives no reason (a call, Siri, an alarm).
    static let unspecifiedInterruption = "A call or another app interrupted the recording."
    /// `lastError` when the journal can't be written, before the system's reason.
    static let journalWarning = "Notes and bookmarks couldn’t be saved with the recording"

    init(environment: PhoneRecorderEnvironment) {
        self.environment = environment
    }

    var isActive: Bool { state != .idle }
    var isPaused: Bool { if case .paused = state { return true } else { return false } }
    /// Recording or paused: notes and bookmarks get conversation times.
    var isCapturing: Bool { state == .recording || state == .starting || isPaused }
    var bookmarkCount: Int { highlights.count }
    var stagingDirectory: URL? { directory }
    /// Whether Daybook may use the microphone, without asking.
    var microphonePermission: MicrophonePermission { environment.session.microphonePermission }

    /// Seconds into the conversation. Keeps counting through a pause, because the conversation does.
    var elapsedTime: TimeInterval {
        guard let anchor = writer?.anchor else { return 0 }
        return max(0, environment.clock.continuousTime() - anchor.continuousTime)
    }

    /// Waits, for at most about one and a half seconds, until the first sample has fixed the recording's
    /// start (`startedAt`), which a Mac recording along places its own by. It arrives within a few buffers.
    func waitForFirstSample() async {
        for _ in 0..<30 where isActive && startedAt == nil {
            try? await Task.sleep(for: .milliseconds(50))
            updateLevels()
        }
    }

    // MARK: Start, pause, resume, stop

    func start(in directory: URL, id: UUID = UUID(), recordingID: UUID = UUID(), title: String) async throws {
        guard state == .idle else { throw PhoneRecorderError.alreadyRecording }
        state = .starting
        cancelStart = false
        lastError = nil; lastFailure = nil; unexpectedStop = nil; unfinishedFolder = nil; waitingCapture = nil; canResume = false; pauseMessage = nil
        captureID = id; self.recordingID = recordingID; self.title = title; startedAt = nil
        notes = ""; timedNotes = []; ink = []; highlights = []; photos = []; sharedNotes = [:]; sharedBookmarks = [:]
        level = .silent; isMicrophoneSilent = false; lastHeardSpeechAt = nil
        do {
            guard !FileManager.default.fileExists(atPath: PhoneCaptureJournal.url(in: directory).path) else {
                throw PhoneRecorderError.directoryInUse
            }
            guard await environment.session.requestRecordPermission() else { throw PhoneRecorderError.microphoneDenied }
            try checkStartCancelled()
            // Kept until unlock (class B), and everything made in it with it: a locked iPhone keeps writing the parts
            // already open and can make new ones (`StagingProtection`).
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700, .protectionKey: StagingProtection.type])
            self.directory = directory
            environment.session.onEvent = { [weak self] event in self?.handle(event) }
            try environment.session.activate()
            inputRoute = environment.session.currentInput
            var journal = PhoneCaptureJournal(id: id, title: title, createdAt: environment.clock.now(), format: environment.format)
            journal.recordingID = recordingID
            journal.routes.append(CaptureRouteEvent(time: 0, input: inputRoute, reason: "start"))
            try journal.write(to: directory)
            self.journal = journal
            writer = makeWriter(in: directory)
            try startInput()
            try checkStartCancelled()
            state = .recording
            startTicks()
            onChange?()
        } catch {
            lastError = error.localizedDescription
            lastFailure = error as? PhoneRecorderError
            await abandonStart()
            throw error
        }
    }

    /// Continues after an interruption (or a failed input restart). When it can't, it stays paused
    /// with Resume, and says why (`lastFailure`); the caller says so to the person.
    func resume() async throws {
        guard isPaused else { throw PhoneRecorderError.notRecording }
        do {
            try environment.session.activate()
            inputRoute = environment.session.currentInput
            try startInput()
        } catch {
            lastFailure = error as? PhoneRecorderError
            onChange?()
            throw error
        }
        lastFailure = nil
        state = .recording
        canResume = false
        pauseMessage = nil
        pausedAt = nil
        if var journal, let last = journal.interruptions.indices.last {
            journal.interruptions[last].resumed = true
            if journal.interruptions[last].ended == nil { journal.interruptions[last].ended = elapsedTime }
            journal.state = .recording
            self.journal = journal
        }
        persistJournal()
        onChange?()
    }

    /// What Stop tells its caller as it goes, on the main actor.
    struct StopEvents {
        /// Capture has ended: input stopped, every segment closed, the journal says the recording is being saved, and
        /// the audio session is given back. What's left is joining the segments, and the caller's filing.
        var captureEnded: () -> Void = {}
        /// Joining will decode the segments and encode them again, which takes a while
        /// (`RecordingAssembler.expectsLongJoin`).
        var longJoin: () -> Void = {}
        /// How far that join has got, 0…1.
        var joinProgress: @MainActor @Sendable (Double) -> Void = { _ in }
    }

    /// Finishes the recording and returns it ready to file. Nil if nothing was recorded or the file
    /// couldn't be built (`lastFailure` says which); the staging folder then stays for recovery.
    @discardableResult
    func stop(_ events: StopEvents = StopEvents()) async -> PhoneRecording? {
        switch state {
        case .starting:
            cancelStart = true
            return nil
        case .recording, .paused:
            break
        case .idle, .stopping:
            return nil
        }
        state = .stopping
        inputGeneration = UUID()
        onChange?()
        stopTicks()
        notesSave?.cancel()
        writer?.setAcceptingAudio(false)
        input?.stop()
        input = nil
        if let writer {
            await writer.waitUntilWritten()
            await writer.closeSegment()
        }
        // Capture has ended. The journal says so before the session goes: a recording iOS ends Daybook during from
        // here on (a Stop from the Lock Screen, Siri, or a Mac, in the background) is whole, and recovered as saved.
        var saving: PhoneCaptureJournal?
        if var journal, let directory {
            sync(&journal)
            journal.endedAt = environment.clock.now()
            journal.state = .stopping
            self.journal = journal
            // On the journal's queue, after the snapshots queued earlier (a pause, a segment opening): a late one would
            // overwrite this with a copy that's still recording.
            let stopping = journal
            await withCheckedContinuation { (written: CheckedContinuation<Void, Never>) in
                journalQueue.async {
                    try? stopping.write(to: directory)
                    written.resume()
                }
            }
            saving = journal
        }
        environment.session.deactivate()
        events.captureEnded()
        var recording: PhoneRecording?
        if let snapshot = saving, let directory, !protectedDataAvailable() {
            // Locked: the recording is whole on disk and its journal says so. Joining reads its parts back, which waits
            // for an unlock; the caller finishes it then.
            waitingCapture = StoppedCapture(directory: directory, journal: snapshot)
        } else if let snapshot = saving, let directory {
            let pieces = PhoneCaptureFinisher.pieces(snapshot, in: directory), format = snapshot.format
            let long = await Task.detached(priority: .userInitiated) { RecordingAssembler.expectsLongJoin(pieces, format: format) }.value
            if long { events.longJoin() }
            let report = events.joinProgress
            do {
                let finished = try await Task.detached(priority: .userInitiated) { () throws -> (PhoneCaptureJournal, PhoneRecording) in
                    var journal = snapshot
                    let recording = try await PhoneCaptureFinisher.finish(&journal, in: directory, recovery: nil, progress: { fraction in
                        Task { @MainActor in report(fraction) }
                    })
                    return (journal, recording)
                }.value
                self.journal = finished.0
                recording = finished.1
            } catch PhoneRecorderError.locked {
                // Locked as it joined: the journal still says `stopping`, and the join starts again once it's unlocked.
                waitingCapture = StoppedCapture(directory: directory, journal: snapshot)
            } catch {
                lastError = error.localizedDescription
                lastFailure = error as? PhoneRecorderError
                unfinishedFolder = directory
                // It stopped as it should have: the next launch joins and files it, as it finds it.
                var kept = snapshot
                kept.state = .stopped
                try? kept.write(to: directory)
            }
        }
        reset()
        onChange?()
        return recording
    }

    /// Waits until queued audio has reached the encoder and writes the journal now.
    func flush() async {
        await writer?.waitUntilWritten()
        notesSave?.cancel()
        guard var journal, let directory else { return }
        sync(&journal)
        self.journal = journal
        writeJournalNow(journal, to: directory)
    }

    /// The app is being terminated: finish the open segment and journal so the next launch recovers
    /// a complete recording.
    func prepareForTermination() {
        guard isCapturing else { return }
        writer?.setAcceptingAudio(false)
        input?.stop()
        input = nil
        writer?.closeSegmentNow()
        if var journal, let directory {
            sync(&journal)
            writeJournalNow(journal, to: directory)
        }
    }

    // MARK: Notes and bookmarks (exactly as the Mac)

    /// Replaces the notes. New paragraphs get the conversation time (none from Writing Tools' rewrite); edited ones keep theirs.
    func editNotes(_ text: String) {
        guard text != notes else { return }
        timedNotes = NoteTimeline.reconcile(previous: timedNotes, text: text,
                                            captureTime: NoteTimeline.captureTime(recording: isCapturing ? elapsedTime : nil))
        notes = text
        saveNotesSoon()
    }

    private func saveNotesSoon() {
        journal?.notes = notes
        journal?.timedNotes = timedNotes
        journal?.ink = ink.isEmpty ? nil : ink
        notesSave?.cancel()
        notesSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persistJournal()
        }
    }

    /// The recording's notes as a conversation's, for the edits handwriting shares with one (`NoteInk.swift`).
    private func editingInk(_ change: (inout Meeting) -> Void) {
        var scratch = Meeting(title: title, notes: notes, timedNotes: timedNotes)
        scratch.ink = ink
        change(&scratch)
        notes = scratch.notes
        timedNotes = scratch.timedNotes ?? []
        ink = scratch.ink ?? []
        saveNotesSoon()
    }

    /// A new block of handwriting, as a new paragraph at this moment of the recording.
    func addInk(_ block: NoteInk, after index: Int?) {
        let time = isCapturing ? elapsedTime : nil
        editingInk { $0.addInk(block, after: index, time: time) }
    }

    /// New strokes, size, or words for a block.
    func updateInk(_ block: NoteInk) {
        editingInk { $0.updateInk(block) }
    }

    /// Takes a block out, its paragraph going or staying as typed words. Returns what puts it back.
    func removeInk(_ id: UUID, keepingWords: Bool) -> (() -> Void)? {
        var removal: InkRemoval?
        editingInk { removal = $0.removeInk(id, keepingWords: keepingWords) }
        return removal.map { removal in
            { [weak self] in self?.editingInk { $0.restoreInk(removal) } }
        }
    }

    /// Marks this moment. Nil when not recording.
    @discardableResult
    func addBookmark() -> Highlight? {
        guard isCapturing, state != .starting else { return nil }
        let mark = Highlight(time: max(0, elapsedTime), text: "")
        highlights.append(mark)
        journal?.highlights = highlights
        persistJournal()
        onChange?()
        return mark
    }

    /// Keeps a photo with the recording, at the conversation time of its shutter (the camera's
    /// review step can take a while). Nil when the recording ended before the photo was saved; the
    /// caller then adds it to the filed conversation.
    @discardableResult
    func addPhoto(_ photo: CameraPhoto) async throws -> CapturePhoto? {
        guard isCapturing, state != .starting, let directory else { return nil }
        let lag = min(max(0, environment.clock.now().timeIntervalSince(photo.capturedAt)), Self.photoReviewLimit)
        let entry = CapturePhoto(fileName: "photo-\(UUID().uuidString).\(photo.fileExtension)", capturedAt: photo.capturedAt,
                                 time: max(0, elapsedTime - lag))
        let url = directory.appendingPathComponent(entry.fileName)
        let data = photo.data
        try await Task.detached(priority: .userInitiated) {
            try data.write(to: url, options: [.atomic, StagingProtection.writing])
        }.value
        guard self.directory == directory, isCapturing else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        photos.append(entry)
        journal?.photos = photos
        persistJournal()
        onChange?()
        return entry
    }

    // MARK: Notes and bookmarks from a Mac recording along

    /// A paragraph a Mac wrote, edited, or deleted (by its ID), shown here at `localTime` on this
    /// recording and filed as the Mac files it (`filed`: its time on the conversation's timeline).
    func applySharedNote(_ note: SharedNote, localTime: TimeInterval?, filed: TimeInterval?) {
        guard isActive else { return }
        let applied = NoteTimeline.applying(SharedNote(id: note.id, text: note.text, time: localTime.map { max(0, $0) }, deleted: note.deleted),
                                            to: notes, anchors: timedNotes)
        if note.deleted { sharedNotes[note.id] = nil }
        else if let anchor = applied.anchors.first(where: { $0.id == note.id }) {
            sharedNotes[note.id] = TimedNote(id: note.id, time: filed ?? sharedNotes[note.id]?.time, text: anchor.text)
        }
        notes = applied.text
        timedNotes = applied.anchors
        journal?.notes = notes
        journal?.timedNotes = timedNotes
        journal?.sharedNotes = sharedNotes.isEmpty ? nil : sharedNotes.values.sorted { $0.id.uuidString < $1.id.uuidString }
        persistJournal()
        onChange?()
    }

    /// A bookmark a Mac made, shown here at `localTime` and filed as the Mac files it (`filed`).
    func addSharedBookmark(_ mark: Highlight, localTime: TimeInterval) {
        guard isActive, !highlights.contains(where: { $0.id == mark.id }) else { return }
        highlights.append(Highlight(id: mark.id, time: max(0, localTime), text: mark.text))
        sharedBookmarks[mark.id] = mark
        journal?.highlights = highlights
        journal?.sharedBookmarks = sharedBookmarks.values.sorted { $0.id.uuidString < $1.id.uuidString }
        persistJournal()
        onChange?()
    }

    /// A bookmark's label changed on a Mac, or it was deleted there.
    func applySharedBookmarkChange(id: UUID, label: String?, deleted: Bool) {
        guard isActive, let index = highlights.firstIndex(where: { $0.id == id }) else { return }
        if deleted {
            highlights.remove(at: index)
            sharedBookmarks[id] = nil
        } else if let label {
            highlights[index].text = label
            sharedBookmarks[id]?.text = label
        }
        journal?.highlights = highlights
        journal?.sharedBookmarks = sharedBookmarks.isEmpty ? nil : sharedBookmarks.values.sorted { $0.id.uuidString < $1.id.uuidString }
        persistJournal()
        onChange?()
    }

    /// The Macs this recording is made with, kept in the journal for recovery.
    func setMultipoint(_ multipoint: CaptureMultipoint?) {
        guard isActive, journal != nil, journal?.multipoint != multipoint else { return }
        journal?.multipoint = multipoint
        persistJournal()
    }

    /// A shutter moment further back than this is a clock problem, not a slow review.
    static let photoReviewLimit: TimeInterval = 600

    // MARK: Recovery

    /// Staging folders a previous run left behind (each holds a journal).
    nonisolated static func pendingCaptures(in staging: URL) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return folders.filter { FileManager.default.fileExists(atPath: PhoneCaptureJournal.url(in: $0).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Joins a recording Stop left while the iPhone was locked (`waitingCapture`), once it's unlocked, and returns it
    /// ready to file, as Stop would have. Throws `PhoneRecorderError.locked` while its parts can't be read yet, and
    /// `nothingRecorded` when none of them has audio.
    nonisolated static func finish(_ capture: StoppedCapture) async throws -> PhoneRecording {
        try await Task.detached(priority: .userInitiated) {
            var journal = capture.journal
            return try await PhoneCaptureFinisher.finish(&journal, in: capture.directory, recovery: nil)
        }.value
    }

    /// Rebuilds a recording from a folder that no recorder is writing: after a crash, after the app
    /// was killed while paused, or when filing failed after Stop. Throws `PhoneRecorderError.locked` when the folder
    /// can't be read until the iPhone is unlocked.
    nonisolated static func recover(in directory: URL) async throws -> PhoneRecording {
        try await Task.detached(priority: .utility) {
            var journal = try PhoneCaptureJournal.load(from: directory)
            let recovery: PhoneRecording.Recovery?
            switch journal.state {
            case .recording, .paused: recovery = .quitWhileRecording
            case .stopping: recovery = .interruptedWhileSaving
            case .stopped: recovery = nil
            }
            Self.adoptOrphanSegments(&journal, in: directory)
            var recording = try await PhoneCaptureFinisher.finish(&journal, in: directory, recovery: recovery)
            // Cut short, it ended where its assembled audio does: counted frames can trail or lead what
            // reached the disk, and a segment the journal never heard of counts none.
            if recovery != nil, journal.endedAt == nil { recording.endedAt = recording.startedAt.addingTimeInterval(recording.duration) }
            return recording
        }.value
    }

    /// A segment file the journal never heard of (the app died right after opening it) is placed
    /// after the previous one.
    nonisolated private static func adoptOrphanSegments(_ journal: inout PhoneCaptureJournal, in directory: URL) {
        let known = Set(journal.segments.map(\.fileName))
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .compactMap { name in CaptureSegment.index(fromFileName: name).map { (index: $0, name: name) } }
            .filter { !known.contains($0.name) }
            .sorted { $0.index < $1.index }
        for (index, file) in files {
            let previousEnd = journal.segments.map { $0.startOffset + Double($0.frameCount) / journal.sampleRate }.max() ?? 0
            journal.segments.append(CaptureSegment(index: index, fileName: file, startOffset: previousEnd, frameCount: 0, closed: false,
                                                   firstSampleHostTime: 0, clockAnchors: [], notes: ["Placed after the previous part; its exact start wasn’t saved."]))
        }
    }

    // MARK: Events

    private func handle(_ event: AudioSessionEvent) {
        switch event {
        case .interruptionBegan(let reason):
            guard state == .recording else { return }
            Task { await pause(.interruption, message: reason ?? Self.unspecifiedInterruption) }
        case .interruptionEnded(let shouldResume):
            guard state == .paused(.interruption) else { return }
            if var journal, let last = journal.interruptions.indices.last, journal.interruptions[last].ended == nil {
                journal.interruptions[last].ended = elapsedTime
                self.journal = journal
            }
            canResume = true
            persistJournal()
            onChange?()
            guard shouldResume else {
                onNeedsResume?()
                return
            }
            Task {
                do { try await resume() } catch { onResumeFailed?(error) }
            }
        case .routeChanged(let reason, let route):
            inputRoute = route
            guard isCapturing else { return }
            journal?.routes.append(CaptureRouteEvent(time: elapsedTime, input: route, reason: reason))
            // A headset came or went: record from what the choice resolves to now, so AirPods connecting mid-meeting
            // don't take over from the built-in microphone, and a chosen headset coming back is used again.
            if reason == "new-device" || reason == "device-removed" {
                environment.session.applyInputChoice()
                noteInputChange(reason: "choice")
            }
            persistJournal()
            onChange?()
        case .mediaServicesReset:
            guard state == .recording || isPaused else { return }
            Task { await rebuildAfterMediaServicesReset() }
        }
    }

    /// The person chose an input in the system's input picker: it's remembered for the recordings after this one, and
    /// recorded from now (with far-field capture when it's AirPods that can hear the room).
    func inputChosen() {
        guard isCapturing else { return }
        environment.session.rememberCurrentInput()
        noteInputChange(reason: "chosen")
        persistJournal()
        onChange?()
    }

    /// The session moved to another input on its own account: said where the route events are.
    private func noteInputChange(reason: String) {
        let now = environment.session.currentInput
        guard now != inputRoute else { return }
        inputRoute = now
        journal?.routes.append(CaptureRouteEvent(time: elapsedTime, input: now, reason: reason))
    }

    private func pause(_ reason: PauseReason, message: String) async {
        guard state == .recording else { return }
        inputGeneration = UUID()
        state = .paused(reason)
        pauseMessage = message
        pausedAt = elapsedTime
        writer?.setAcceptingAudio(false)
        input?.stop()
        input = nil
        journal?.interruptions.append(CaptureInterruption(began: elapsedTime, reason: message))
        journal?.state = .paused
        onChange?()
        // Finish the segment: what's recorded is now a complete file, even if the app is suspended
        // during the call and never comes back.
        if let writer {
            await writer.waitUntilWritten()
            await writer.closeSegment()
        }
        persistJournal()
    }

    private func rebuildAfterMediaServicesReset() async {
        guard state == .recording || isPaused else { return }
        let generation = UUID()
        inputGeneration = generation
        let wasRecording = state == .recording
        writer?.setAcceptingAudio(false)
        input?.stop()
        input = nil
        journal?.warnings.append("Audio services restarted during the recording; it continued in a new part.")
        if let writer {
            await writer.waitUntilWritten()
            guard inputGeneration == generation else { return }
            await writer.closeSegment()
        }
        guard inputGeneration == generation else { return }
        if wasRecording, state == .recording {
            do {
                try environment.session.activate()
                inputRoute = environment.session.currentInput
                try startInput()
            } catch {
                state = .paused(.inputFailed)
                pauseMessage = "The microphone stopped after audio services restarted."
                pausedAt = elapsedTime
                canResume = true
                journal?.interruptions.append(CaptureInterruption(began: elapsedTime, reason: pauseMessage))
            }
        }
        persistJournal()
        onChange?()
        if state == .paused(.inputFailed) { onNeedsResume?() }
    }

    private func inputEvent(_ event: AudioInputEvent) {
        switch event {
        case .restarted(let note):
            writer?.markDiscontinuity(note)
        case .failed(let reason):
            guard state == .recording else { return }
            Task {
                await pause(.inputFailed, message: reason)
                canResume = true
                onChange?()
                onNeedsResume?()
            }
        }
    }

    private func writerFailed(_ error: Error) {
        guard state == .recording || isPaused else { return }
        lastError = error.localizedDescription
        unexpectedStop = error
        journal?.warnings.append(error.localizedDescription)
        onStoppingByItself?()
        Task {
            let recording = await stop()
            onUnexpectedStop?(recording)
        }
    }

    // MARK: Plumbing

    private func makeWriter(in directory: URL) -> PhoneTrackWriter {
        PhoneTrackWriter(directory: directory, format: environment.format, clock: environment.clock,
                         realTime: environment.realTimeEncoding,
                         segmentOpened: { [weak self] in Task { @MainActor in self?.persistJournal() } },
                         failure: { [weak self] error in Task { @MainActor in self?.writerFailed(error) } })
    }

    private func startInput() throws {
        guard let writer else { throw PhoneRecorderError.notRecording }
        inputGeneration = UUID()
        let input = environment.makeInput()
        writer.setAcceptingAudio(true)
        listeningSince = environment.clock.hostTime()
        let tap = audioTap
        try input.start(onBuffer: { buffer, host in
                            writer.append(buffer, hostTime: host)
                            tap?(buffer, host)
                        },
                        onEvent: { [weak self] event in Task { @MainActor in self?.inputEvent(event) } })
        self.input = input
    }

    private func checkStartCancelled() throws {
        if cancelStart { throw CancellationError() }
    }

    /// Undoes a start that failed. A folder with audio stays for recovery; an empty one goes.
    private func abandonStart() async {
        writer?.setAcceptingAudio(false)
        input?.stop()
        input = nil
        environment.session.deactivate()
        if let writer, writer.anchor != nil, var journal, let directory {
            await writer.closeSegment()
            sync(&journal)
            journal.state = .stopped
            try? journal.write(to: directory)
        } else if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        reset()
    }

    private func reset() {
        stopTicks()
        writer = nil
        input = nil
        journal = nil
        directory = nil
        captureID = nil
        recordingID = nil
        startedAt = nil
        canResume = false
        pauseMessage = nil
        pausedAt = nil
        level = .silent
        isMicrophoneSilent = false
        state = .idle
    }

    /// Copies the writer's segments and the first-sample anchor into the journal.
    private func sync(_ journal: inout PhoneCaptureJournal) {
        guard let writer else { return }
        journal.segments = writer.snapshot
        if journal.startedAt == nil, let anchor = writer.anchor {
            journal.startedAt = anchor.date
            journal.hostTimeSeconds = anchor.hostTime
            journal.continuousTimeSeconds = anchor.continuousTime
        }
    }

    private func persistJournal() {
        // Stopping, Stop writes the journal itself: a write queued now could land over the finished one.
        guard state != .stopping, var journal, let directory else { return }
        sync(&journal)
        self.journal = journal
        let snapshot = journal, health = journalHealth
        journalQueue.async { [weak self] in
            do {
                try snapshot.write(to: directory)
                health.failing = false
            } catch {
                guard !health.failing else { return }
                health.failing = true
                let message = error.localizedDescription
                Task { @MainActor in self?.journalWriteFailed(message) }
            }
        }
    }

    /// Writes the journal now, on the caller's thread; a failure is reported like a queued one.
    private func writeJournalNow(_ journal: PhoneCaptureJournal, to directory: URL) {
        do { try journal.write(to: directory) }
        catch { journalWriteFailed(error.localizedDescription) }
    }

    /// The recording's journal (its notes, bookmarks, and how to recover the audio) couldn't be
    /// written, usually because the iPhone is full. Said once, not every five seconds; the audio
    /// already written stays.
    private func journalWriteFailed(_ message: String) {
        let warning = "\(Self.journalWarning): \(message)"
        guard lastError != warning else { return }
        lastError = warning
        onChange?()
    }

    /// While recording: the meter reads every `meterInterval` (fifteen times a second while someone sees a meter, twice
    /// otherwise), and the journal is written every few seconds besides the writes a change makes. Each tick is a task
    /// on the main actor, stopped with the recording.
    private func startTicks() {
        stopTicks()
        ticks = [
            Self.repeating(every: { [weak self] in self?.meterInterval ?? Self.levelInterval }) { [weak self] in self?.updateLevels() != nil },
            Self.repeating(every: { Self.journalInterval }) { [weak self] in self?.persistJournal() != nil },
        ]
    }

    private func stopTicks() {
        for tick in ticks { tick.cancel() }
        ticks = []
    }

    /// Runs `tick` every `interval()` seconds until cancelled, or until it says the recorder is gone.
    private static func repeating(every interval: @escaping @MainActor () -> TimeInterval,
                                  _ tick: @escaping @MainActor () -> Bool) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval()))
                guard !Task.isCancelled, tick() else { return }
            }
        }
    }

    /// Called by the meter's tick; internal so tests can sample without waiting on it.
    func updateLevels() {
        guard let writer else { return }
        if startedAt == nil, let anchor = writer.anchor {
            startedAt = anchor.date
            persistJournal()
            onChange?()
        }
        guard state == .recording else { return }
        let reading = writer.meter.read()
        if abs(reading.rms - level.rms) >= 0.5 || abs(reading.peak - level.peak) >= 0.5 { level = reading }
        if reading.rms >= Self.speechLevel { lastHeardSpeechAt = Date() }
        let silent = HearingCheck.isNotHearing(writer.meter.heard, listeningSince: listeningSince, now: environment.clock.hostTime())
        if silent != isMicrophoneSilent { isMicrophoneSilent = silent }
        onLevel?(level)
    }
}

/// A recording whose capture Stop has ended (every part closed, the journal saying `stopping`) and that's still to be
/// joined: what Stop leaves while the iPhone is locked (`PhoneRecorder.waitingCapture`).
struct StoppedCapture: Equatable, Sendable {
    var directory: URL
    var journal: PhoneCaptureJournal

    var conversationID: UUID { journal.id }
    /// Where the recording ends, by its parts' counted frames.
    var duration: TimeInterval {
        journal.segments.map { $0.startOffset + Double($0.frameCount) / journal.sampleRate }.max() ?? 0
    }
}

/// Whether journal writes are failing; read and written only on the recorder's journal queue.
private final class JournalHealth: @unchecked Sendable {
    var failing = false
}
