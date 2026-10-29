import AVFoundation
import DaybookCaptions
import DaybookKit
import Foundation

/// What live speaker labelling runs for one capture: a streaming speaker model and, when there are
/// voices to recognize, the model that embeds voices in their space.
public struct LiveSpeakerSession: Sendable {
    public var diarizer: any LiveDiarizing
    public var embedding: (any LiveVoiceEmbedding)?
    public var voices: [KnownVoice]

    public init(diarizer: any LiveDiarizing, embedding: (any LiveVoiceEmbedding)? = nil, voices: [KnownVoice] = []) {
        self.diarizer = diarizer; self.embedding = embedding; self.voices = voices
    }
}

/// Adds speakers to any captioner's captions: the same audio goes to a streaming speaker model, and
/// each caption is labelled with the voice that spoke most of it ("S2") and, once that voice matches
/// a known voice, the person's name. The words come from `inner` (a local recognizer or the system's),
/// so speakers work with either.
///
/// Speakers trail the words by the speaker model's latency (about three seconds), so the newest
/// caption gets its label a moment after its words. The speaker model runs on its own task at
/// utility priority with its own bounded backlog, and is the first work shed under load: the words
/// keep coming without labels. Nothing here can fail the capture or the words.
public final class SpeakerLabelledCaptioner: LiveCaptioning, @unchecked Sendable {
    public let updates: AsyncStream<[LiveCaptionSegment]>
    public let states: AsyncStream<LiveCaptionState>
    private let updatesContinuation: AsyncStream<[LiveCaptionSegment]>.Continuation
    private let statesContinuation: AsyncStream<LiveCaptionState>.Continuation
    private let inner: any LiveCaptioning
    private let input: LiveInput
    private let times: LiveTimeline
    private let makeSpeakers: @Sendable () async throws -> LiveSpeakerSession
    private let governor: LiveLoadGovernor?
    private let onEnd: (@Sendable () async -> Void)?
    private let lock = NSLock()
    private var latest: [LiveCaptionSegment] = []
    private var timeline: LiveSpeakerTimeline?
    private var identifier: LiveVoiceIdentifier?
    /// The voice of each final caption the timeline has long moved past, kept so it isn't looked up
    /// again on every update and outlives the timeline's horizon.
    private var settled: [UUID: Int?] = [:]
    private var forwarding: [Task<Void, Never>] = []
    private var worker: Task<Void, Never>?
    private var started = false
    private var ended = false

    /// Seconds of 16 kHz audio kept for embedding solo stretches: the longest stretch plus the
    /// speaker model's latency, with room to spare.
    static let ringSeconds: Double = 24

    public init(inner: any LiveCaptioning, backlog: Int = 64, timelineOrigin: TimeInterval? = nil,
                governor: LiveLoadGovernor? = nil,
                makeSpeakers: @escaping @Sendable () async throws -> LiveSpeakerSession,
                onEnd: (@Sendable () async -> Void)? = nil) {
        self.inner = inner
        input = LiveInput(capacity: backlog)
        times = LiveTimeline(origin: timelineOrigin)
        self.governor = governor
        self.makeSpeakers = makeSpeakers
        self.onEnd = onEnd
        (updates, updatesContinuation) = AsyncStream<[LiveCaptionSegment]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        (states, statesContinuation) = AsyncStream<LiveCaptionState>.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    public func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        inner.append(buffer, at: time)
        times.appended(at: time?.liveSeconds)
        input.append(buffer, at: time)
    }

    public func start(locale: Locale, sourceFormat: AVAudioFormat?) async {
        guard lock.withLock({ () -> Bool in defer { started = true }; return !started }) else { return }
        let inner = self.inner
        let forwardUpdates = Task { [weak self] in
            for await snapshot in inner.updates { self?.innerUpdated(snapshot) }
        }
        let forwardStates = Task { [weak self] in
            // `.finished` is said once the last labels are in (`finish`).
            for await state in inner.states where state != .finished { self?.statesContinuation.yield(state) }
        }
        lock.withLock { forwarding = [forwardUpdates, forwardStates] }
        let speakers = Task { try await makeSpeakers() }
        worker = Task.detached(priority: .utility) { [weak self, input, times, governor] in
            guard let session = try? await speakers.value else {
                // No speaker model: the captions go on unlabelled.
                for await _ in input.stream { input.took() }
                return
            }
            self?.began(session)
            let resampler = LiveResampler()
            var ring = LiveAudioRing(seconds: Self.ringSeconds)
            for await item in input.stream {
                input.took()
                if let governor, governor.level(backlog: input.fill) < .full { continue }
                let samples = resampler.samples(item.buffer)
                guard !samples.isEmpty else { continue }
                times.feed(sourceTime: item.time, duration: Double(item.buffer.frameLength) / item.buffer.format.sampleRate)
                ring.append(samples)
                guard let frames = try? session.diarizer.diarize(samples) else { continue }
                self?.heard(frames, ring: ring, session: session)
            }
            let tail = (try? session.diarizer.finish()) ?? []
            self?.heard(tail, ring: ring, session: session, final: true)
        }
        await inner.start(locale: locale, sourceFormat: sourceFormat)
    }

    public func finish() async {
        await inner.finish()
        let forwarding = lock.withLock { self.forwarding }
        for task in forwarding { await task.value }
        input.finish()
        await worker?.value
        let snapshot = lock.withLock { () -> [LiveCaptionSegment] in
            latest = latest.map { var segment = $0; segment.isTentative = false; return segment }
            return labelled(latest)
        }
        updatesContinuation.yield(snapshot)
        guard lock.withLock({ () -> Bool in defer { ended = true }; return !ended }) else { return }
        statesContinuation.yield(.finished)
        updatesContinuation.finish()
        statesContinuation.finish()
        await onEnd?()
    }

    /// The speaker of each caption as it would be shown now (tests and diagnostics).
    var lastLabels: [LiveCaptionSpeaker?] { lock.withLock { labelled(latest).map(\.speaker) } }

    // MARK: Labelling

    private func began(_ session: LiveSpeakerSession) {
        lock.withLock {
            timeline = LiveSpeakerTimeline(frameSeconds: session.diarizer.frameSeconds)
            if let embedding = session.embedding {
                let voices = LiveVoiceIdentifier(voices: session.voices, space: embedding.space)
                identifier = voices.hasVoices ? voices : nil
            }
        }
    }

    private func innerUpdated(_ snapshot: [LiveCaptionSegment]) {
        let labelled = lock.withLock { () -> [LiveCaptionSegment] in
            latest = snapshot
            return self.labelled(snapshot)
        }
        updatesContinuation.yield(labelled)
    }

    /// New frames from the speaker model: the timeline grows, solo stretches become voice embeddings,
    /// and captions are labelled again.
    private func heard(_ frames: [LiveSpeakerFrames], ring: LiveAudioRing, session: LiveSpeakerSession, final: Bool = false) {
        guard !frames.isEmpty || final else { return }
        let times = self.times
        let (solos, frameSeconds) = lock.withLock { () -> ([LiveSpeakerTimeline.SoloSpan], Double) in
            guard var timeline else { return ([], 0) }
            var solos: [LiveSpeakerTimeline.SoloSpan] = []
            for chunk in frames { solos += timeline.append(chunk, time: times.sourceTime) }
            if final { solos += timeline.finish(time: times.sourceTime) }
            self.timeline = timeline
            return (identifier == nil ? [] : solos, timeline.frameSeconds)
        }
        // Embedding runs outside the lock: a few milliseconds of Core ML per stretch.
        var embeddings: [(slot: Int, vector: [Float], seconds: Double)] = []
        if let embedding = session.embedding {
            let perFrame = Int((frameSeconds * LiveAudio.sampleRate).rounded())
            for solo in solos {
                guard let samples = ring.slice(solo.startFrame * perFrame, solo.endFrame * perFrame),
                      let vector = try? embedding.embed(samples), !vector.isEmpty else { continue }
                embeddings.append((solo.slot, vector, Double(solo.endFrame - solo.startFrame) * frameSeconds))
            }
        }
        let snapshot = lock.withLock { () -> [LiveCaptionSegment] in
            for item in embeddings { identifier?.observe(slot: item.slot, embedding: item.vector, seconds: item.seconds) }
            return labelled(latest)
        }
        if !snapshot.isEmpty { updatesContinuation.yield(snapshot) }
    }

    /// Each caption with the voice that spoke most of it, named when known (a name found later
    /// reaches the voice's earlier captions too). Call with the lock held.
    private func labelled(_ segments: [LiveCaptionSegment]) -> [LiveCaptionSegment] {
        guard let timeline else { return segments }
        let times = self.times
        // Captions this far behind what the speaker model has heard won't gain more of it.
        let heard = times.sourceTime(Double(timeline.frame) * timeline.frameSeconds)
        return segments.map { segment in
            var segment = segment
            let slot: Int?
            if let known = settled[segment.id] {
                slot = known
            } else {
                slot = timeline.dominantSlot(from: segment.start, to: segment.end, time: times.sourceTime)
                if !segment.isTentative, segment.end < heard - Self.settleAfter { settled[segment.id] = slot }
            }
            if let slot {
                let match = identifier?.matches[slot]
                segment.speaker = LiveCaptionSpeaker(slot: "S\(slot + 1)", name: match?.name, profileID: match?.voiceID)
            }
            return segment
        }
    }

    /// Seconds behind the speaker model's newest frame after which a final caption's voice is kept.
    static let settleAfter: TimeInterval = 30
}
