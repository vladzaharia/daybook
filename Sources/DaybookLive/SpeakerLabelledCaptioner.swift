import AVFoundation
import DaybookCaptions
import DaybookKit
import Foundation
import Synchronization

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
/// keep coming without labels, marked `needsSpeaker` where the model didn't hear them, so the
/// recording can label them afterwards (`LiveSpeakerPass`). Out of sight (`LiveWorkLevel.reduced`)
/// it hears the audio in batches and embeds only voices it hasn't named yet. Nothing here can fail
/// the capture or the words.
public final class SpeakerLabelledCaptioner: LiveCaptioning, Sendable {
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
    private let state = Mutex(State())

    private struct State {
        var latest: [LiveCaptionSegment] = []
        var timeline: LiveSpeakerTimeline?
        var identifier: LiveVoiceIdentifier?
        /// The voice of each final caption the timeline has long moved past, kept so it isn't looked up
        /// again on every update and outlives the timeline's horizon.
        var settled: [UUID: Int?] = [:]
        /// Stretches of the capture (its timeline) the speaker model didn't hear: shed, or it failed.
        var missed = LiveSpans()
        var forwarding: [Task<Void, Never>] = []
        var worker: Task<Void, Never>?
        var started = false
        /// `finish` has begun: a start that comes later begins nothing.
        var finishing = false
        var ended = false
    }

    /// Seconds of 16 kHz audio kept for embedding solo stretches: the longest stretch plus the
    /// speaker model's latency and a reduced-cadence batch, with room to spare.
    static let ringSeconds: Double = 24
    /// Out of sight, the speaker model hears the audio this many seconds at a time.
    static let reducedBatchSeconds: Double = 4

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
        times.appended(at: time?.captionSeconds)
        input.append(buffer, at: time)
    }

    public func start(locale: Locale, sourceFormat: AVAudioFormat?) async {
        let inner = self.inner, input = self.input, times = self.times, governor = self.governor
        let makeSpeakers = self.makeSpeakers, statesContinuation = self.statesContinuation
        // Everything that runs is kept in one step with the check for `finish`, which then sees all of it.
        let begins = state.withLock { state -> Bool in
            guard !state.started, !state.finishing else { return false }
            state.started = true
            state.forwarding = [
                Task { [weak self] in
                    for await snapshot in inner.updates { self?.innerUpdated(snapshot) }
                },
                Task {
                    // `.finished` is said once the last labels are in (`finish`).
                    for await value in inner.states where value != .finished { statesContinuation.yield(value) }
                },
            ]
            let speakers = Task { try await makeSpeakers() }
            state.worker = Task.detached(priority: .utility) { [weak self] in
                guard let session = try? await speakers.value else {
                    // No speaker model: the captions go on unlabelled.
                    for await _ in input.stream { input.took() }
                    return
                }
                self?.began(session)
                let resampler = LiveResampler()
                var ring = LiveAudioRing(seconds: Self.ringSeconds)
                var batch: [Float] = []
                var level = LiveWorkLevel.full
                for await item in input.stream {
                    input.took()
                    let duration = Double(item.buffer.frameLength) / item.buffer.format.sampleRate
                    level = governor?.level(backlog: input.fill) ?? .full
                    if level < .reduced {
                        self?.missed(item.time, duration: duration)
                        continue
                    }
                    let samples = resampler.samples(item.buffer)
                    guard !samples.isEmpty else { continue }
                    times.feed(sourceTime: item.time, duration: duration)
                    ring.append(samples)
                    batch += samples
                    // Out of sight, a few seconds at a time; otherwise as it comes.
                    if level == .reduced, Double(batch.count) < Self.reducedBatchSeconds * LiveAudio.sampleRate { continue }
                    defer { batch.removeAll(keepingCapacity: true) }
                    guard let frames = try? session.diarizer.diarize(batch) else {
                        self?.missed(item.time.map { $0 + duration - Double(batch.count) / LiveAudio.sampleRate },
                                     duration: Double(batch.count) / LiveAudio.sampleRate)
                        continue
                    }
                    self?.heard(frames, ring: ring, session: session, reduced: level == .reduced)
                }
                var tail = batch.isEmpty ? [] : ((try? session.diarizer.diarize(batch)) ?? [])
                tail += (try? session.diarizer.finish()) ?? []
                self?.heard(tail, ring: ring, session: session, final: true)
            }
            return true
        }
        guard begins else { return }
        await inner.start(locale: locale, sourceFormat: sourceFormat)
    }

    public func finish() async {
        state.withLock { $0.finishing = true }
        await inner.finish()
        let (forwarding, worker) = state.withLock { ($0.forwarding, $0.worker) }
        for task in forwarding { await task.value }
        input.finish()
        await worker?.value
        let times = self.times
        let snapshot = state.withLock { state -> [LiveCaptionSegment] in
            state.latest = state.latest.map { var segment = $0; segment.isTentative = false; return segment }
            return Self.labelled(state.latest, in: &state, times: times)
        }
        updatesContinuation.yield(snapshot)
        guard state.withLock({ state -> Bool in defer { state.ended = true }; return !state.ended }) else { return }
        statesContinuation.yield(.finished)
        updatesContinuation.finish()
        statesContinuation.finish()
        await onEnd?()
    }

    /// The speaker of each caption as it would be shown now (tests and diagnostics).
    var lastLabels: [LiveCaptionSpeaker?] {
        let times = self.times
        return state.withLock { state in Self.labelled(state.latest, in: &state, times: times).map(\.speaker) }
    }
    /// Buffers the speaker pipeline has taken, heard or shed (tests).
    var consumed: Int { input.taken }

    // MARK: Labelling

    private func began(_ session: LiveSpeakerSession) {
        state.withLock { state in
            state.timeline = LiveSpeakerTimeline(frameSeconds: session.diarizer.frameSeconds)
            if let embedding = session.embedding {
                let voices = LiveVoiceIdentifier(voices: session.voices, space: embedding.space)
                state.identifier = voices.hasVoices ? voices : nil
            }
        }
    }

    private func innerUpdated(_ snapshot: [LiveCaptionSegment]) {
        let times = self.times
        let labelled = state.withLock { state -> [LiveCaptionSegment] in
            state.latest = snapshot
            return Self.labelled(snapshot, in: &state, times: times)
        }
        updatesContinuation.yield(labelled)
    }

    /// Audio the speaker model didn't hear, at `time` on the source's timeline: its captions may be
    /// labelled from the recording afterwards.
    private func missed(_ time: TimeInterval?, duration: TimeInterval) {
        guard let time, let start = times.captureTime(ofSource: time) else { return }
        state.withLock { $0.missed.add(start, start + duration) }
    }

    /// New frames from the speaker model: the timeline grows, solo stretches become voice embeddings,
    /// and captions are labelled again. `reduced`: only voices not named yet are embedded.
    private func heard(_ frames: [LiveSpeakerFrames], ring: LiveAudioRing, session: LiveSpeakerSession, final: Bool = false,
                       reduced: Bool = false) {
        guard !frames.isEmpty || final else { return }
        let times = self.times
        let (solos, frameSeconds) = state.withLock { state -> ([LiveSpeakerTimeline.SoloSpan], Double) in
            guard var timeline = state.timeline else { return ([], 0) }
            var solos: [LiveSpeakerTimeline.SoloSpan] = []
            for chunk in frames { solos += timeline.append(chunk, time: times.sourceTime) }
            if final { solos += timeline.finish(time: times.sourceTime) }
            state.timeline = timeline
            guard let identifier = state.identifier else { return ([], timeline.frameSeconds) }
            return (reduced ? solos.filter { identifier.matches[$0.slot] == nil } : solos, timeline.frameSeconds)
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
        let snapshot = state.withLock { state -> [LiveCaptionSegment] in
            for item in embeddings { state.identifier?.observe(slot: item.slot, embedding: item.vector, seconds: item.seconds) }
            return Self.labelled(state.latest, in: &state, times: times)
        }
        if !snapshot.isEmpty { updatesContinuation.yield(snapshot) }
    }

    /// Each caption with the voice that spoke most of it, named when known (a name found later
    /// reaches the voice's earlier captions too). Settles the voices of captions far enough behind.
    private static func labelled(_ segments: [LiveCaptionSegment], in state: inout State, times: LiveTimeline) -> [LiveCaptionSegment] {
        guard let timeline = state.timeline else { return segments }
        // Captions this far behind what the speaker model has heard won't gain more of it.
        let heard = times.sourceTime(Double(timeline.frame) * timeline.frameSeconds)
        return segments.map { segment in
            var segment = segment
            let slot: Int?
            if let known = state.settled[segment.id] {
                slot = known
            } else {
                slot = timeline.dominantSlot(from: segment.start, to: segment.end, time: times.sourceTime)
                if !segment.isTentative, segment.end < heard - Self.settleAfter { state.settled[segment.id] = slot }
            }
            if let slot {
                let match = state.identifier?.matches[slot]
                segment.speaker = LiveCaptionSpeaker(slot: "S\(slot + 1)", name: match?.name, profileID: match?.voiceID)
                segment.needsSpeaker = nil
            } else {
                segment.needsSpeaker = state.missed.covers(segment.start, max(segment.end, segment.start + 0.2)) ? true : nil
            }
            return segment
        }
    }

    /// Seconds behind the speaker model's newest frame after which a final caption's voice is kept.
    static let settleAfter: TimeInterval = 30
}
