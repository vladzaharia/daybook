import AVFoundation
import DaybookWatchLink
import Foundation

/// Writes a recording's audio into its segments, on its own queue: converts each microphone buffer to the speech
/// format (48 kHz mono), encodes it into the open segment's AAC M4A, and closes it for the next every
/// `WatchAudioFormat.segmentLength` seconds. It owns the recording's journal while it records and saves it whenever a
/// segment opens or closes, so the app being ended costs at most the segment being written.
///
/// Audio arrives in runs: one per stretch the microphone captures. A run's first segment starts where the wall clock
/// says (an interruption's gap is kept, never closed up), the rest follow sample by sample.
final class SegmentWriter: @unchecked Sendable {
    enum Event: Sendable {
        /// A segment closed while recording: send it. The journal is `current` (read it then: a snapshot taken here could
        /// be older than an adoption made since).
        case closed(WatchSegment)
        /// How loud the microphone is, 0…1.
        case level(Float)
        /// Writing failed (storage full, the encoder): the recording ends.
        case failed(String)
    }

    private let store: WatchStore
    private let queue = DispatchQueue(label: "local.daybook.watch.writer", qos: .userInitiated)
    private let format = WatchAudioFormat.speech
    private let pcm: AVAudioFormat
    private let onEvent: @Sendable (Event) -> Void

    // On `queue`.
    private var journal: WatchRecordingJournal
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    /// Accepting buffers: between `beginRun` and `endRun`, so a buffer still in flight after the tap is removed never
    /// starts a run of its own.
    private var accepting = false
    private var runOffset: TimeInterval?
    private var runFrames: Int64 = 0
    private var segmentFrames: Int64 = 0
    private var failed = false
    private var lastLevel = Date.distantPast
    private var metering = true

    init(journal: WatchRecordingJournal, store: WatchStore, onEvent: @escaping @Sendable (Event) -> Void) {
        self.journal = journal
        self.store = store
        self.onEvent = onEvent
        pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
    }

    /// AAC-LC, mono, 48 kHz, about 64 kbps with a constrained variable rate: the iPhone's own recording format
    /// (`RecordingFormat`), so it joins the segments by copying packets.
    private var aacSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC,
         AVSampleRateKey: format.sampleRate,
         AVNumberOfChannelsKey: 1,
         AVEncoderBitRateKey: format.bitRate,
         AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_VariableConstrained]
    }

    /// The journal as it is now.
    var current: WatchRecordingJournal { queue.sync { journal } }

    /// Seconds from the recording's first sample to the newest one written.
    var recorded: TimeInterval { queue.sync { (runOffset ?? journal.end) + Double(runFrames) / format.sampleRate } }

    /// Level events only while someone can see them: off with the wrist down, to spare the CPU the background allows.
    func setMetering(_ on: Bool) { queue.async { self.metering = on } }

    /// The microphone captures again: the next buffer starts a run.
    func beginRun() {
        queue.sync {
            accepting = true
            runOffset = nil
            runFrames = 0
            converter?.reset()
        }
    }

    /// A buffer from the microphone, its first frame captured at `hostTime` (seconds).
    func append(_ buffer: AVAudioPCMBuffer, hostTime: TimeInterval) {
        queue.async { self.write(buffer, hostTime: hostTime) }
    }

    /// The microphone stopped (an interruption): closes the open segment. Returns it, to send.
    func endRun() -> (WatchSegment?, WatchRecordingJournal) {
        queue.sync {
            accepting = false
            let segment = closeSegment(finishing: false)
            return (segment, journal)
        }
    }

    /// The recording ends: closes the open segment and finishes the journal. Returns the last segment, to send.
    func finish() -> (WatchSegment?, WatchRecordingJournal) {
        queue.sync {
            accepting = false
            let segment = closeSegment(finishing: true)
            if segment == nil { journal.finish() }
            save()
            return (segment, journal)
        }
    }

    /// The recording now records along with a conversation. Segments already sent don't carry it; the iPhone takes it
    /// from the state and the segments after (`WatchSegmentLedger.later`).
    func adopt(_ conversationID: UUID, startedAt: Date?) {
        queue.sync {
            journal.recording.conversationID = conversationID
            journal.conversationStartedAt = startedAt ?? journal.conversationStartedAt
            save()
        }
    }

    /// The iPhone's receipt: returns the journal, and the segments it asks for again (`WatchRecordingJournal.receive`).
    func receive(_ receipt: WatchReceipt) -> (WatchRecordingJournal, [WatchSegment]) {
        queue.sync {
            let resend = journal.receive(receipt)
            save()
            return (journal, resend)
        }
    }

    /// A segment's transfer finished.
    func sent(_ index: Int) -> WatchRecordingJournal {
        queue.sync {
            journal.sent(index)
            save()
            return journal
        }
    }

    // MARK: Writing (on `queue`)

    private func write(_ buffer: AVAudioPCMBuffer, hostTime: TimeInterval) {
        guard accepting, !failed, buffer.frameLength > 0 else { return }
        if runOffset == nil { startRun(hostTime: hostTime) }
        guard let converted = convert(buffer) else { return }
        if file == nil, !openSegment() { return }
        do {
            try file?.write(from: converted)
        } catch {
            fail("Couldn't save the recording")
            return
        }
        let frames = Int64(converted.frameLength)
        runFrames += frames
        segmentFrames += frames
        meter(converted)
        if Double(segmentFrames) / format.sampleRate >= WatchAudioFormat.segmentLength,
           let segment = closeSegment(finishing: false) {
            onEvent(.closed(segment))
        }
    }

    /// The run's place on the recording's timeline: its first sample's wall-clock time against the recording's first
    /// sample, never before the audio already recorded.
    private func startRun(hostTime: TimeInterval) {
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let firstSample = Date().addingTimeInterval(-max(now - hostTime, 0))
        if journal.segments.isEmpty && journal.open == nil && journal.recording.duration == 0 {
            journal.recording.startedAt = firstSample
            runOffset = 0
        } else {
            runOffset = max(journal.end, firstSample.timeIntervalSince(journal.recording.startedAt))
        }
        runFrames = 0
    }

    private func openSegment() -> Bool {
        guard WatchStore.hasRoom else {
            fail(WatchRecorderError.storageFull.line)
            return false
        }
        let offset = (runOffset ?? 0) + Double(runFrames) / format.sampleRate
        let open = journal.openSegment(at: offset)
        let url = store.url(of: open.index, in: journal.recording.id)
        do {
            file = try AVAudioFile(forWriting: url, settings: aacSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            fail("Couldn't save the recording")
            return false
        }
        segmentFrames = 0
        save()
        return true
    }

    /// Closes the open segment (its file gets its index, so it reads) and records it in the journal.
    private func closeSegment(finishing: Bool) -> WatchSegment? {
        guard let open = journal.open else { return nil }
        file?.close()
        file = nil
        let url = store.url(of: open.index, in: journal.recording.id)
        let duration = Double(segmentFrames) / format.sampleRate
        segmentFrames = 0
        let segment = journal.closeSegment(duration: duration, byteCount: WatchStore.size(of: url), finishing: finishing)
        if segment == nil { try? FileManager.default.removeItem(at: url) }
        save()
        return segment
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == pcm { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: pcm)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * pcm.sampleRate / buffer.format.sampleRate).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if given {
                outStatus.pointee = .noDataNow
                return nil
            }
            given = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    private func meter(_ buffer: AVAudioPCMBuffer) {
        guard metering, Date().timeIntervalSince(lastLevel) >= 0.1, let samples = buffer.floatChannelData?[0] else { return }
        lastLevel = Date()
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let rms = (sum / Float(max(count, 1))).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        onEvent(.level(min(max((decibels + 55) / 50, 0), 1)))
    }

    private func save() {
        try? store.save(journal)
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        accepting = false
        onEvent(.failed(message))
    }
}
