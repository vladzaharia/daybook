import AVFoundation
import DaybookCaptions
import Foundation

/// Live captions from a local streaming recognizer (Nemotron 3.5 ASR Streaming on the Mac and the
/// iPhone), in place of the system's: words appear about a second behind the audio, a passage stays
/// tentative until its sentence ends or the speaker pauses, and then it's final. Never a transcript.
///
/// Like every captioner it never blocks or fails the capture: `append` only enqueues (the oldest
/// audio is dropped when the recognizer falls behind), the recognizer runs on its own task at
/// utility priority, and a failure ends only the captions. Under heat or a low battery the governor
/// pauses it; captions resume, with a gap, when conditions improve.
public final class LocalStreamingCaptioner: LiveCaptioning, @unchecked Sendable {
    public let updates: AsyncStream<[LiveCaptionSegment]>
    public let states: AsyncStream<LiveCaptionState>
    private let updatesContinuation: AsyncStream<[LiveCaptionSegment]>.Continuation
    private let statesContinuation: AsyncStream<LiveCaptionState>.Continuation
    private let input: LiveInput
    private let times: LiveTimeline
    private let makeTranscriber: @Sendable (Locale) async throws -> any LiveTranscribing
    private let governor: LiveLoadGovernor?
    private let vocabulary: LiveVocabulary?
    private let onEnd: (@Sendable () async -> Void)?
    private let lock = NSLock()
    private var builder = LiveTranscriptBuilder()
    private var worker: Task<Void, Never>?
    private var transcriber: (any LiveTranscribing)?
    private var started = false
    private var ended = false

    /// Samples gathered before each call into the recognizer, which decodes in fixed chunks anyway.
    static let feedSamples = Int(LiveAudio.sampleRate / 2)
    /// How far the recognizer's output trails the audio fed to it (a chunk waiting to fill, up to
    /// 2.24 s, and its look-ahead): a pause is judged only up to here, so a word still being decoded
    /// doesn't split its passage.
    static let decodeLag: TimeInterval = 2.5

    /// `makeTranscriber` loads the recognizer for a locale (`start` calls it). `timelineOrigin`: the
    /// buffers' time captions count from (`CaptionTimeMap`). `vocabulary`: terms to bias the
    /// recognizer toward, followed as they change. `onEnd` runs once captioning has ended, to release
    /// the models.
    public init(backlog: Int = 64, timelineOrigin: TimeInterval? = nil, governor: LiveLoadGovernor? = nil,
                vocabulary: LiveVocabulary? = nil,
                makeTranscriber: @escaping @Sendable (Locale) async throws -> any LiveTranscribing,
                onEnd: (@Sendable () async -> Void)? = nil) {
        input = LiveInput(capacity: backlog)
        times = LiveTimeline(origin: timelineOrigin)
        self.governor = governor
        self.vocabulary = vocabulary
        self.makeTranscriber = makeTranscriber
        self.onEnd = onEnd
        (updates, updatesContinuation) = AsyncStream<[LiveCaptionSegment]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        (states, statesContinuation) = AsyncStream<LiveCaptionState>.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    public func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        times.appended(at: time?.liveSeconds)
        input.append(buffer, at: time)
    }

    public func start(locale: Locale, sourceFormat: AVAudioFormat?) async {
        guard lock.withLock({ () -> Bool in defer { started = true }; return !started }) else { return }
        statesContinuation.yield(.preparing)
        let transcriber: any LiveTranscribing
        do {
            transcriber = try await makeTranscriber(locale)
        } catch {
            await end(.failed("Live transcription couldn’t start: \(error.localizedDescription)"))
            return
        }
        lock.withLock { self.transcriber = transcriber }
        // The vocabulary as the capture starts; changes are applied between batches, on the worker,
        // which is the only caller of the recognizer.
        let initial = vocabulary?.current
        if let initial, !initial.terms.isEmpty { await transcriber.setVocabulary(initial.terms) }
        let input = self.input, times = self.times, governor = self.governor, vocabulary = self.vocabulary
        worker = Task.detached(priority: .utility) { [weak self] in
            var applied = initial?.version
            let resampler = LiveResampler()
            var pending: [Float] = []
            var fed: TimeInterval = 0
            for await item in input.stream {
                input.took()
                if let governor, governor.level(backlog: input.fill) == .paused { continue }
                let samples = resampler.samples(item.buffer)
                guard !samples.isEmpty else { continue }
                times.feed(sourceTime: item.time, duration: Double(item.buffer.frameLength) / item.buffer.format.sampleRate)
                pending += samples
                guard pending.count >= Self.feedSamples else { continue }
                if let vocabulary, vocabulary.current.version != applied {
                    let latest = vocabulary.current
                    await transcriber.setVocabulary(latest.terms)
                    applied = latest.version
                }
                fed += Double(pending.count) / LiveAudio.sampleRate
                do {
                    let tokens = try await transcriber.transcribe(pending)
                    pending.removeAll(keepingCapacity: true)
                    self?.received(tokens, decodedThrough: fed - Self.decodeLag)
                } catch {
                    await self?.end(.failed("Live transcription stopped: \(error.localizedDescription)"))
                    return
                }
            }
            if !pending.isEmpty, let tokens = try? await transcriber.transcribe(pending) { self?.received(tokens, decodedThrough: nil) }
        }
        statesContinuation.yield(.listening)
    }

    public func finish() async {
        input.finish()
        await worker?.value
        let transcriber = lock.withLock { self.transcriber }
        if let transcriber, let tokens = try? await transcriber.finish() { received(tokens, decodedThrough: nil) }
        let snapshot = lock.withLock { () -> [LiveCaptionSegment] in builder.finish(); return mapped(builder.segments) }
        updatesContinuation.yield(snapshot)
        await end(.finished)
    }

    // MARK: Results

    private func received(_ tokens: [LiveToken], decodedThrough time: TimeInterval?) {
        let snapshot = lock.withLock { () -> [LiveCaptionSegment]? in
            var changed = builder.add(tokens)
            if let time { changed = builder.advance(to: time) || changed }
            return changed ? mapped(builder.segments) : nil
        }
        if let snapshot { updatesContinuation.yield(snapshot) }
    }

    /// Segments on the source's timeline (the recognizer's has no gaps).
    private func mapped(_ segments: [LiveCaptionSegment]) -> [LiveCaptionSegment] {
        segments.map { segment in
            var segment = segment
            segment.start = times.sourceTime(segment.start)
            segment.end = max(segment.start, times.sourceTime(segment.end))
            return segment
        }
    }

    private func end(_ state: LiveCaptionState) async {
        guard lock.withLock({ () -> Bool in defer { ended = true }; return !ended }) else { return }
        statesContinuation.yield(state)
        input.finish()
        updatesContinuation.finish()
        statesContinuation.finish()
        await onEnd?()
    }
}
