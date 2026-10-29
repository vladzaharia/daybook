import AVFoundation
import DaybookCaptions
import Foundation

/// Labels saved captions with speakers afterwards, from the recording they were made from, when the
/// live speaker model missed some of it (`LiveCaptionSegment.needsSpeaker`: speakers were shed under
/// heat, Low Power Mode, or a low battery, or the model failed). The live audio ring keeps only the
/// last 24 seconds, so the pass reads the recording itself, whose timeline is the captions'.
///
/// The pass runs the same speaker model over the whole recording, from its start, and labels every
/// caption from that one run: slots from two different runs can't be mixed ("S1" in one needn't be
/// "S1" in the other), and a run that heard everything is at least as good as the live one. Names
/// come from the same voice profiles, compared over the whole recording.
public enum LiveSpeakerPass {
    /// Whether any caption is waiting for a speaker the live model didn't hear.
    public static func isNeeded(_ captions: LiveCaptions) -> Bool {
        captions.segments.contains { $0.needsSpeaker == true }
    }

    /// Every caption labelled from `audio` (16 kHz mono from the recording's start, in order), with
    /// `session`'s speaker model and voices. Captions nobody clearly spoke keep no speaker, and none
    /// is left waiting. Checks for cancellation between chunks.
    static func label(_ segments: [LiveCaptionSegment], audio: some AsyncSequence<[Float], any Error>,
                      session: LiveSpeakerSession) async throws -> [LiveCaptionSegment] {
        var timeline = LiveSpeakerTimeline(frameSeconds: session.diarizer.frameSeconds)
        timeline.horizon = .infinity
        var identifier = session.embedding.map { LiveVoiceIdentifier(voices: session.voices, space: $0.space) }
        if identifier?.hasVoices != true { identifier = nil }
        var ring = LiveAudioRing(seconds: SpeakerLabelledCaptioner.ringSeconds)
        let perFrame = Int((session.diarizer.frameSeconds * LiveAudio.sampleRate).rounded())
        let identity: (TimeInterval) -> TimeInterval = { $0 }

        func heard(_ frames: [LiveSpeakerFrames], final: Bool) {
            var solos: [LiveSpeakerTimeline.SoloSpan] = []
            for chunk in frames { solos += timeline.append(chunk, time: identity) }
            if final { solos += timeline.finish(time: identity) }
            guard identifier != nil, let embedding = session.embedding else { return }
            for solo in solos {
                guard let samples = ring.slice(solo.startFrame * perFrame, solo.endFrame * perFrame),
                      let vector = try? embedding.embed(samples), !vector.isEmpty else { continue }
                identifier?.observe(slot: solo.slot, embedding: vector, seconds: Double(solo.endFrame - solo.startFrame) * timeline.frameSeconds)
            }
        }

        for try await samples in audio {
            try Task.checkCancellation()
            guard !samples.isEmpty else { continue }
            ring.append(samples)
            heard(try session.diarizer.diarize(samples), final: false)
        }
        heard(try session.diarizer.finish(), final: true)

        let matches = identifier?.matches ?? [:]
        return segments.map { segment in
            var segment = segment
            segment.needsSpeaker = nil
            if let slot = timeline.dominantSlot(from: segment.start, to: segment.end, time: identity) {
                let match = matches[slot]
                segment.speaker = LiveCaptionSpeaker(slot: "S\(slot + 1)", name: match?.name, profileID: match?.voiceID)
            } else {
                segment.speaker = nil
            }
            return segment
        }
    }
}

/// A recording read back as 16 kHz mono, a second at a time, for `LiveSpeakerPass`. A file that
/// can't be read throws on the first chunk.
struct LiveRecordingAudio: AsyncSequence {
    typealias Element = [Float]
    let url: URL
    var chunkSeconds: Double = 1

    struct AsyncIterator: AsyncIteratorProtocol {
        let url: URL
        let chunkSeconds: Double
        var file: AVAudioFile?
        var buffer: AVAudioPCMBuffer?
        let resampler = LiveResampler()

        mutating func next() async throws -> [Float]? {
            if file == nil {
                let opened = try AVAudioFile(forReading: url)
                file = opened
                let seconds: Double = opened.processingFormat.sampleRate * chunkSeconds
                let frames = AVAudioFrameCount(Swift.max(1.0, seconds.rounded()))
                buffer = AVAudioPCMBuffer(pcmFormat: opened.processingFormat, frameCapacity: frames)
            }
            guard let file, let buffer, file.framePosition < file.length else { return nil }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { return nil }
            return resampler.samples(buffer)
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(url: url, chunkSeconds: chunkSeconds) }
}
