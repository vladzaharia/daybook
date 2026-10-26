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
///   format; the writer converts and pads, and the journal notes the change.
/// - Media-services resets rebuild the session and input and continue in a new segment.
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
    /// Several seconds without a single non-zero sample: muted, unplugged, or blocked.
    private(set) var isMicrophoneSilent = false
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
    /// Photos taken during this recording, kept in the staging folder.
    private(set) var photos: [CapturePhoto] = []
    private(set) var inputRoute: AudioInputRoute?
    /// The interruption ended; recording can continue.
    private(set) var canResume = false
    /// Why the recording is paused, in a sentence.
    private(set) var pauseMessage: String?
    /// Conversation seconds when the current pause began.
    private(set) var pausedAt: TimeInterval?
    private(set) var lastError: String?

    /// State, pauses, routes, and bookmarks changed (not levels).
    @ObservationIgnored var onChange: (() -> Void)?
    /// About fifteen times a second while recording.
    @ObservationIgnored var onLevel: ((AudioLevel) -> Void)?
    /// The encoder or storage failed; the recording was finished as it stood.
    @ObservationIgnored var onUnexpectedStop: ((PhoneRecording?) -> Void)?
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
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var journalTimer: Timer?
    @ObservationIgnored private var notesSave: Task<Void, Never>?
    @ObservationIgnored private var cancelStart = false
    @ObservationIgnored private let journalQueue = DispatchQueue(label: "local.daybook.phone.journal", qos: .utility)

    static let silentMicrophoneSeconds: TimeInterval = 3
    /// The pause message when iOS gives no reason (a call, Siri, an alarm).
    static let unspecifiedInterruption = "A call or another app interrupted the recording."

    init(environment: PhoneRecorderEnvironment) {
        self.environment = environment
    }

    var isActive: Bool { state != .idle }
    var isPaused: Bool { if case .paused = state { return true } else { return false } }
    /// Recording or paused: notes and bookmarks get conversation times.
    var isCapturing: Bool { state == .recording || state == .starting || isPaused }
    var bookmarkCount: Int { highlights.count }
    var stagingDirectory: URL? { directory }

    /// Seconds into the conversation. Keeps counting through a pause, because the conversation does.
    var elapsedTime: TimeInterval {
        guard let anchor = writer?.anchor else { return 0 }
        return max(0, environment.clock.continuousTime() - anchor.continuousTime)
    }

    /// Where the conversation's first sample fell on the host clock, for multipoint alignment.
    var hostTimeAnchor: TimeInterval? { writer?.anchor?.hostTime }

    // MARK: Start, pause, resume, stop

    func start(in directory: URL, id: UUID = UUID(), recordingID: UUID = UUID(), title: String) async throws {
        guard state == .idle else { throw PhoneRecorderError.alreadyRecording }
        state = .starting
        cancelStart = false
        lastError = nil; canResume = false; pauseMessage = nil
        captureID = id; self.recordingID = recordingID; self.title = title; startedAt = nil
        notes = ""; timedNotes = []; highlights = []; photos = []
        level = .silent; isMicrophoneSilent = false
        do {
            guard !FileManager.default.fileExists(atPath: PhoneCaptureJournal.url(in: directory).path) else {
                throw PhoneRecorderError.directoryInUse
            }
            guard await environment.session.requestRecordPermission() else { throw PhoneRecorderError.microphoneDenied }
            try checkStartCancelled()
            // Class C protection: the recording keeps writing while the phone is locked.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700,
                                                                 .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
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
            startTimers()
            onChange?()
        } catch {
            lastError = error.localizedDescription
            await abandonStart()
            throw error
        }
    }

    /// Continues after an interruption (or a failed input restart).
    func resume() async throws {
        guard isPaused else { throw PhoneRecorderError.notRecording }
        try environment.session.activate()
        inputRoute = environment.session.currentInput
        try startInput()
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

    /// Finishes the recording and returns it ready to file. Nil if nothing was recorded or the file
    /// couldn't be built; the staging folder then stays for recovery.
    @discardableResult
    func stop() async -> PhoneRecording? {
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
        stopTimers()
        notesSave?.cancel()
        writer?.setAcceptingAudio(false)
        input?.stop()
        input = nil
        if let writer {
            await writer.waitUntilWritten()
            await writer.closeSegment()
        }
        environment.session.deactivate()
        var recording: PhoneRecording?
        if var journal, let directory {
            sync(&journal)
            journal.endedAt = environment.clock.now()
            journal.state = .stopped
            let snapshot = journal
            // Snapshots queued earlier (a pause, a segment opening) must land before the finished
            // journal, or a late one would overwrite it with a copy that has no final file.
            await drainJournalWrites()
            do {
                let finished = try await Task.detached(priority: .userInitiated) { () throws -> (PhoneCaptureJournal, PhoneRecording) in
                    var journal = snapshot
                    let recording = try PhoneCaptureFinisher.finish(&journal, in: directory, recovered: false)
                    return (journal, recording)
                }.value
                self.journal = finished.0
                recording = finished.1
            } catch {
                lastError = error.localizedDescription
                try? snapshot.write(to: directory)
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
        try? journal.write(to: directory)
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
            try? journal.write(to: directory)
        }
    }

    // MARK: Notes and bookmarks (exactly as the Mac)

    /// Replaces the notes. New paragraphs get the conversation time; edited ones keep theirs.
    func editNotes(_ text: String) {
        guard text != notes else { return }
        timedNotes = NoteTimeline.reconcile(previous: timedNotes, text: text, captureTime: isCapturing ? elapsedTime : nil)
        notes = text
        journal?.notes = text
        journal?.timedNotes = timedNotes
        notesSave?.cancel()
        notesSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persistJournal()
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
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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

    /// A shutter moment further back than this is a clock problem, not a slow review.
    static let photoReviewLimit: TimeInterval = 600

    // MARK: Recovery

    /// Staging folders a previous run left behind (each holds a journal).
    nonisolated static func pendingCaptures(in staging: URL) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return folders.filter { FileManager.default.fileExists(atPath: PhoneCaptureJournal.url(in: $0).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Rebuilds a recording from a folder that no recorder is writing: after a crash, after the app
    /// was killed while paused, or when filing failed after Stop.
    nonisolated static func recover(in directory: URL) async throws -> PhoneRecording {
        try await Task.detached(priority: .utility) {
            var journal = try PhoneCaptureJournal.load(from: directory)
            let crashed = journal.state != .stopped
            Self.adoptOrphanSegments(&journal, in: directory)
            if crashed, journal.endedAt == nil {
                let audio = journal.segments.map { $0.startOffset + Double($0.frameCount) / journal.sampleRate }.max() ?? 0
                journal.endedAt = (journal.startedAt ?? journal.createdAt).addingTimeInterval(audio)
            }
            return try PhoneCaptureFinisher.finish(&journal, in: directory, recovered: crashed)
        }.value
    }

    /// A segment file the journal never heard of (the app died right after opening it) is placed
    /// after the previous one.
    nonisolated private static func adoptOrphanSegments(_ journal: inout PhoneCaptureJournal, in directory: URL) {
        let known = Set(journal.segments.map(\.fileName))
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("segment-") && $0.hasSuffix(".m4a") && !known.contains($0) }.sorted()
        for file in files {
            let index = Int(file.dropFirst("segment-".count).dropLast(".m4a".count)) ?? (journal.segments.count)
            let previousEnd = journal.segments.map { $0.startOffset + Double($0.frameCount) / journal.sampleRate }.max() ?? 0
            journal.segments.append(CaptureSegment(index: index, fileName: file, startOffset: previousEnd, frameCount: 0, closed: false,
                                                   firstSampleHostTime: 0, clockAnchors: [], notes: ["Placed after the previous part; its exact start wasn't saved."]))
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
            if shouldResume { Task { try? await resume() } }
        case .routeChanged(let reason, let route):
            inputRoute = route
            guard isCapturing else { return }
            journal?.routes.append(CaptureRouteEvent(time: elapsedTime, input: route, reason: reason))
            persistJournal()
            onChange?()
        case .mediaServicesReset:
            guard state == .recording || isPaused else { return }
            Task { await rebuildAfterMediaServicesReset() }
        }
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
            }
        }
    }

    private func writerFailed(_ error: Error) {
        guard state == .recording || isPaused else { return }
        lastError = error.localizedDescription
        journal?.warnings.append(error.localizedDescription)
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
        stopTimers()
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

    private func drainJournalWrites() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in journalQueue.async { done.resume() } }
    }

    private func persistJournal() {
        guard var journal, let directory else { return }
        sync(&journal)
        self.journal = journal
        let snapshot = journal
        journalQueue.async { try? snapshot.write(to: directory) }
    }

    private func startTimers() {
        stopTimers()
        let meter = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLevels() }
        }
        let journal = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistJournal() }
        }
        RunLoop.main.add(meter, forMode: .common)
        RunLoop.main.add(journal, forMode: .common)
        meterTimer = meter
        journalTimer = journal
    }

    private func stopTimers() {
        meterTimer?.invalidate(); meterTimer = nil
        journalTimer?.invalidate(); journalTimer = nil
    }

    /// Called by the meter timer; internal so tests can sample without waiting on it.
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
        let silent = elapsedTime >= Self.silentMicrophoneSeconds && !writer.meter.receivedSignal
        if silent != isMicrophoneSilent { isMicrophoneSilent = silent }
        onLevel?(level)
    }
}
