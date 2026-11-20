import AVFoundation
import DaybookWatchLink
import Foundation

enum WatchRecorderError: Error {
    case microphoneDenied
    case noMicrophone
    case storageFull

    /// The watch's status line.
    var line: String {
        switch self {
        case .microphoneDenied: return "Allow Microphone in Settings"
        case .noMicrophone: return "Couldn't use the microphone"
        case .storageFull: return "Apple Watch storage is full"
        }
    }

    /// Why the watch didn't start, for the iPhone (`WatchReply.refused`).
    var phoneWords: String {
        switch self {
        case .microphoneDenied: return "Allow the microphone for Daybook on your Apple Watch."
        case .noMicrophone: return "Apple Watch couldn't use its microphone."
        case .storageFull: return "Apple Watch storage is full."
        }
    }
}

/// The watch's microphone through `AVAudioEngine`'s input node, into a `SegmentWriter` (docs/watch.md, "Recording").
///
/// Recording starts only with Daybook in the foreground; once the microphone captures, it goes on with the wrist down
/// (the `audio` background mode, with the red microphone indicator). A call or Siri interrupts it, and watchOS doesn't let
/// it start again in the background: the open segment closes, and the next run starts when Daybook is active again.
@MainActor
final class WatchRecorder {
    enum Event {
        case closed(WatchSegment)
        case level(Float)
        /// The microphone stopped for a call or Siri (or the audio system reset, or a route it couldn't start again on):
        /// the segment it was writing closed.
        case interrupted(WatchSegment?)
        /// The interruption is over: capture can start again, in the foreground.
        case interruptionEnded
        case failed(String)
    }

    var onEvent: (Event) -> Void = { _ in }
    private(set) var journal: WatchRecordingJournal?
    private(set) var isCapturing = false

    private let store: WatchStore
    /// Made again when the audio system resets: the old one can't start any more.
    private var engine = AVAudioEngine()
    private var writer: SegmentWriter?
    private var observers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?

    init(store: WatchStore) {
        self.store = store
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated { self?.interruption(raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mediaServicesReset() }
        })
        observeEngine()
    }

    /// A route or format change stops the engine; it starts again on the new format.
    private func observeEngine() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
    }

    var isRecording: Bool { journal != nil }

    /// Asks for the microphone the first time; true once allowed.
    static func microphoneAllowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// Starts a new recording (Daybook must be in the foreground).
    func start(_ journal: WatchRecordingJournal) throws {
        guard WatchStore.hasRoom else { throw WatchRecorderError.storageFull }
        try store.create(journal)
        let writer = SegmentWriter(journal: journal, store: store) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.writerEvent(event) } }
        }
        self.writer = writer
        self.journal = journal
        do {
            try capture()
        } catch {
            self.writer = nil
            self.journal = nil
            store.delete(journal.recording.id)
            throw error
        }
    }

    /// Starts capturing again after an interruption (Daybook must be in the foreground).
    func resume() throws {
        guard writer != nil, !isCapturing else { return }
        try capture()
    }

    /// Stops the recording: returns the finished journal, whose unsent segments (its last among them) are to send.
    @discardableResult
    func stop() -> WatchRecordingJournal? {
        guard let writer else { return nil }
        stopEngine()
        let (_, journal) = writer.finish()
        self.writer = nil
        self.journal = nil
        deactivate()
        return journal
    }

    /// The recording now records along with a conversation.
    func adopt(_ conversationID: UUID, startedAt: Date?) {
        writer?.adopt(conversationID, startedAt: startedAt)
        if let writer { journal = writer.current }
    }

    /// The iPhone's receipt for the recording in progress: returns the segments it asks for again.
    func receive(_ receipt: WatchReceipt) -> [WatchSegment] {
        guard let writer else { return [] }
        let (journal, resend) = writer.receive(receipt)
        self.journal = journal
        return resend
    }

    /// A segment of the recording in progress finished its transfer.
    func sent(_ index: Int) {
        if let writer { journal = writer.sent(index) }
    }

    /// The level only while it's seen.
    func setMetering(_ on: Bool) { writer?.setMetering(on) }

    /// Seconds recorded so far, gaps included.
    var recorded: TimeInterval { writer?.recorded ?? 0 }

    // MARK: Capture

    /// Starts a run. If it can't, the audio session is let go, and a segment the run closed goes out as `.closed`.
    private func capture() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // Record only: no route picker (that's long-form playback's), and haptics still play while recording.
            try session.setCategory(.record, mode: .default, options: [])
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
        } catch {
            deactivate()
            throw error
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            deactivate()
            throw WatchRecorderError.noMicrophone
        }
        writer?.beginRun()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_800, format: format, block: Self.tap(into: writer))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if let (segment, journal) = writer?.endRun() {
                self.journal = journal
                if let segment { onEvent(.closed(segment)) }
            }
            deactivate()
            throw error
        }
        isCapturing = true
    }

    private func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?) {
        guard let writer else { return }
        switch type {
        case .began:
            guard isCapturing else { return }
            stopEngine()
            let (segment, journal) = writer.endRun()
            self.journal = journal
            onEvent(.interrupted(segment))
        case .ended:
            if !isCapturing { onEvent(.interruptionEnded) }
        default:
            break
        }
    }

    /// The audio system reset: whatever was capturing stopped, and the engine is made again for the next run, which can
    /// start at once (in the foreground).
    private func mediaServicesReset() {
        interruption(.began)
        engine.inputNode.removeTap(onBus: 0)
        engine = AVAudioEngine()
        observeEngine()
        isCapturing = false
        if writer != nil { onEvent(.interruptionEnded) }
    }

    /// The run ends where the old configuration stopped, so the restart's gap stays a gap, and the next starts on the
    /// new one.
    private func configurationChanged() {
        guard let writer, isCapturing else { return }
        stopEngine()
        let (segment, journal) = writer.endRun()
        self.journal = journal
        do {
            try capture()
            if let segment { onEvent(.closed(segment)) }
        } catch {
            // It can't start again from here (in the background, it can't at all): wait as for an interruption.
            onEvent(.interrupted(segment))
        }
    }

    private func writerEvent(_ event: SegmentWriter.Event) {
        guard let writer else { return }
        switch event {
        case .closed(let segment):
            journal = writer.current
            onEvent(.closed(segment))
        case .level(let level):
            onEvent(.level(level))
        case .failed(let message):
            onEvent(.failed(message))
        }
    }

    /// The tap, which runs on the engine's thread, never the main actor's.
    nonisolated private static func tap(into writer: SegmentWriter?) -> AVAudioNodeTapBlock {
        { buffer, when in
            let host = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime)
                                            : AVAudioTime.seconds(forHostTime: mach_absolute_time())
            // The engine reuses its buffer; the writer keeps a copy.
            guard let copy = copy(buffer) else { return }
            writer?.append(copy, hostTime: host)
        }
    }

    nonisolated private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        if let source = buffer.floatChannelData, let target = copy.floatChannelData {
            let count = Int(buffer.frameLength) * (buffer.format.isInterleaved ? channels : 1)
            for channel in 0..<(buffer.format.isInterleaved ? 1 : channels) {
                target[channel].update(from: source[channel], count: count)
            }
        } else if let source = buffer.int16ChannelData, let target = copy.int16ChannelData {
            let count = Int(buffer.frameLength) * (buffer.format.isInterleaved ? channels : 1)
            for channel in 0..<(buffer.format.isInterleaved ? 1 : channels) {
                target[channel].update(from: source[channel], count: count)
            }
        } else {
            return nil
        }
        return copy
    }
}
