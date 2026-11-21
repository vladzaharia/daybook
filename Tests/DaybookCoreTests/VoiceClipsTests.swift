import AVFoundation
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookCore

/// Voice clips (`VoiceClips`, `VoiceClipAudio`): which speech a library's profiles need kept, which voiceprints still
/// hold a recording back, and that a clip is the original's samples exactly.
final class VoiceClipsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400
    private var root: URL!

    override func setUp() async throws { root = makeTemporaryFolder("DaybookVoiceClips") }

    // MARK: Planning

    private func meeting(_ segments: [(String, Double, Double)], matches: [SpeakerMatch]? = nil) -> Meeting {
        let track = RecordingTrack(source: .microphone, relativePath: "Originals/a.caf", fileName: "a.caf", sha256: String(repeating: "a", count: 64))
        let run = TrackTranscript(trackID: track.id, segments: segments.map {
            TranscriptSegment(trackID: track.id, start: $0.1, end: $0.2, text: "words", speakerID: $0.0)
        })
        var meeting = Meeting(title: "Planning", date: now, tracks: [track], transcripts: [run],
                              speakers: Set(segments.map(\.0)).sorted().map { Speaker(id: $0, name: "", sourceTrackID: track.id) })
        meeting.speakerMatches = matches
        return meeting
    }

    private func print(_ profile: UUID, _ meeting: Meeting, speaker: String = "s1", origin: Voiceprint.Origin = .named,
                       daysAgo: Double = 0, trackID: UUID?? = nil) -> Voiceprint {
        Voiceprint(id: "vp-\(UUID().uuidString)", profileID: profile, origin: origin, vector: VoiceVector(space: "s", values: [1, 0]),
                   meetingID: meeting.id, speakerID: speaker, trackID: trackID ?? meeting.tracks.first?.id, speechSeconds: 20,
                   recordedAt: now.addingTimeInterval(-daysAgo * day))
    }

    private func metadata(profiles: [SpeakerProfile], prints: [Voiceprint]) -> LibraryMetadata {
        var metadata = LibraryMetadata()
        metadata.speakerProfiles = profiles.map { LibraryValue(id: $0.id.uuidString, value: $0, modifiedAt: now) }
        metadata.voiceprints = prints.map { LibraryValue(id: $0.id, value: $0, modifiedAt: now) }
        return metadata
    }

    func testBehaviorSpansAreTheSpeakersCleanPassagesLongestFirstUpToThirtySeconds() {
        // s1 talks 0–10, 12–40 (s2 over it 20–25), and 50–55; s2's 20–25 is never s1's.
        let conversation = meeting([("s1", 0, 10), ("s1", 12, 40), ("s2", 20, 25), ("s1", 50, 55)])
        let source = VoiceClipSource(meetingID: conversation.id, trackID: conversation.tracks[0].id, speakerID: "s1")
        let spans = VoiceClips.spans(for: source, in: conversation)
        // Clean: 0–10 (10), 12–20 (8), 25–40 (15), 50–55 (5). Longest first: 15, 10, then 5 of the 8 to make 30.
        XCTAssertEqual(spans, [VoiceClipSpan(start: 0, end: 10), VoiceClipSpan(start: 12, end: 17), VoiceClipSpan(start: 25, end: 40)])
        XCTAssertEqual(spans.reduce(0) { $0 + $1.length }, VoiceClips.maximumSecondsPerSource, accuracy: 1e-9)
        let nobody = VoiceClipSource(meetingID: conversation.id, trackID: conversation.tracks[0].id, speakerID: "s9")
        XCTAssertEqual(VoiceClips.spans(for: nobody, in: conversation), [], "nothing to cut")
    }

    func testBehaviorAMatchedSpeakerIsReadUnderTheLabelItWasMatchedTo() {
        let match = SpeakerMatch(sourceSpeakerID: "late", targetSpeakerID: "s1", status: .matched, reason: "")
        let conversation = meeting([("s1", 2, 6)], matches: [match])
        let source = VoiceClipSource(meetingID: conversation.id, trackID: conversation.tracks[0].id, speakerID: "late")
        XCTAssertEqual(VoiceClips.spans(for: source, in: conversation), [VoiceClipSpan(start: 2, end: 6)])
        var rejected = match
        rejected.status = .belowThreshold
        XCTAssertEqual(VoiceClips.spans(for: source, in: meeting([("s1", 2, 6)], matches: [rejected])), [])
    }

    func testBehaviorEachProfileKeepsClipsForItsEightSourcesThatCountMostThePersonsOwnFirst() {
        let vlad = SpeakerProfile(id: UUID(), name: "Vlad")
        let conversations = (0..<12).map { _ in meeting([("s1", 0, 10)]) }
        // Six the person named (older), six learned (newer): the six named, then the two newest learned.
        let named = (0..<6).map { print(vlad.id, conversations[$0], daysAgo: 100 + Double($0)) }
        let learned = (6..<12).map { print(vlad.id, conversations[$0], origin: .recognized, daysAgo: Double($0)) }
        let library = metadata(profiles: [vlad], prints: named + learned)
        let plan = VoiceClips.plan(metadata: library, meetings: conversations)
        XCTAssertTrue(plan.readable)
        XCTAssertEqual(plan.live.count, 12)
        let source = { (print: Voiceprint) in VoiceClips.source(of: print, in: nil)!.key }
        XCTAssertEqual(Set(plan.wanted.keys), Set((named + learned.prefix(2)).map(source)))
        XCTAssertEqual(plan.wanted.count, VoiceClips.maximumSourcesPerProfile)
        // Without clips, the eight hold their recordings back and the four beyond them don't.
        let holding = VoiceClips.holdingBack(plan, metadata: library, meetings: conversations, covered: [])
        XCTAssertEqual(Set(holding.map(\.id)), Set((named + learned.prefix(2)).map(\.id)))
        // A clip here lets its recording go.
        let clipped = VoiceClips.holdingBack(plan, metadata: library, meetings: conversations, covered: [source(named[0])])
        XCTAssertFalse(clipped.contains { $0.id == named[0].id })
        XCTAssertEqual(clipped.count, 7)
    }

    func testBehaviorVoiceprintsOfOneSpeakerShareOneClipAndMergedProfilesShareTheirCap() {
        let vlad = SpeakerProfile(id: UUID(), name: "Vlad")
        var vladimir = SpeakerProfile(id: UUID(), name: "Vladimir")
        vladimir.mergedInto = vlad.id
        let conversations = (0..<10).map { _ in meeting([("s1", 0, 10)]) }
        var oldSpace = print(vlad.id, conversations[0])
        oldSpace.vector = VoiceVector(space: "old", values: [1, 0])
        let prints = [oldSpace, print(vlad.id, conversations[0])] + (1..<10).map { print(vladimir.id, conversations[$0], daysAgo: Double($0)) }
        let plan = VoiceClips.plan(metadata: metadata(profiles: [vlad, vladimir], prints: prints), meetings: conversations)
        XCTAssertEqual(plan.live.count, 10, "two spaces of one speaker are one source")
        XCTAssertEqual(plan.wanted.count, VoiceClips.maximumSourcesPerProfile, "a merged profile's voiceprints count for the one it was merged into")
    }

    func testBehaviorAGoneProfileHoldsNothingBackAndAnUnknownRecordingHoldsItBack() {
        let gone = SpeakerProfile(id: UUID(), name: "Gone"), kept = SpeakerProfile(id: UUID(), name: "Kept")
        let conversation = meeting([("s1", 0, 10)])
        var library = metadata(profiles: [kept], prints: [print(gone.id, conversation), print(kept.id, conversation, speaker: "s2", trackID: .some(nil))])
        library.speakerProfiles?.append(LibraryValue(id: gone.id.uuidString, value: nil, modifiedAt: now))
        let plan = VoiceClips.plan(metadata: library, meetings: [conversation])
        XCTAssertTrue(plan.live.isEmpty, "a deleted profile's voiceprint keeps no clip, and one without a recording has no source")
        let holding = VoiceClips.holdingBack(plan, metadata: library, meetings: [conversation], covered: [])
        XCTAssertEqual(holding.map(\.speakerID), ["s2"], "a voiceprint whose recording isn't known holds back as before clips")
        // A profile with no record here at all can't be known to be gone.
        let orphan = metadata(profiles: [], prints: [print(UUID(), conversation)])
        XCTAssertEqual(VoiceClips.plan(metadata: orphan, meetings: [conversation]).wanted.count, 1)
    }

    func testBehaviorARecordThisVersionCantReadKeepsEveryVoiceprintHoldingBack() throws {
        let vlad = SpeakerProfile(id: UUID(), name: "Vlad")
        let conversations = (0..<10).map { _ in meeting([("s1", 0, 10)]) }
        let prints = conversations.map { print(vlad.id, $0, origin: .recognized) }
        var library = metadata(profiles: [vlad], prints: prints)
        let newer = try JSONDecoder().decode(LibraryValue<SpeakerProfile>.self, from: Data(#"{"id":"x","modifiedAt":0,"value":{"shape":2}}"#.utf8))
        library.speakerProfiles?.append(newer)
        let plan = VoiceClips.plan(metadata: library, meetings: conversations)
        XCTAssertFalse(plan.readable)
        XCTAssertEqual(VoiceClips.holdingBack(plan, metadata: library, meetings: conversations, covered: Set(plan.live)).count, prints.count)
    }

    // MARK: Cutting

    /// A recording outside any library: `channels` of different tones and loudness, so a swapped or dropped channel shows.
    private func recording(rate: Double = 48_000, seconds: Double = 6, channels: AVAudioChannelCount = 1,
                           settings: [String: Any]? = nil, name: String = "original.caf") throws -> URL {
        let url = root.appendingPathComponent(name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: settings ?? format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = Int(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(channels) {
            for index in 0..<count {
                let t = Double(index) / rate
                buffer.floatChannelData![channel][index] = Float(0.3 / Double(channel + 1) * sin(2 * .pi * (180 + 70 * Double(channel)) * t) * (1 + 0.5 * sin(t * 7)))
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func samples(_ url: URL, frames: Range<Int64>? = nil) throws -> [[UInt32]] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let range = frames ?? 0..<file.length
        file.framePosition = range.lowerBound
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(range.count))!
        var result = [[UInt32]](repeating: [], count: Int(file.processingFormat.channelCount))
        // A read may deliver fewer frames than asked.
        while result[0].count < range.count {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(range.count - result[0].count))
            guard buffer.frameLength > 0 else { break }
            for channel in result.indices { result[channel] += (0..<Int(buffer.frameLength)).map { buffer.floatChannelData![channel][$0].bitPattern } }
        }
        return result
    }

    private func assertHolds(_ clip: VoiceClipAudio.Extracted, of original: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        var expected: [[UInt32]] = []
        for range in clip.ranges {
            let part = try samples(original, frames: range.startFrame..<range.endFrame)
            expected = expected.isEmpty ? part : zip(expected, part).map { $0 + $1 }
        }
        XCTAssertEqual(try samples(clip.url), expected, "every sample, bit for bit", file: file, line: line)
        XCTAssertEqual(try AudioDigest.sha256(fileURL: clip.url), clip.sha256, file: file, line: line)
    }

    func testBehaviorAClipHoldsTheOriginalsSamplesBitForBit() async throws {
        let spans = [VoiceClipSpan(start: 0.5, end: 1.25), VoiceClipSpan(start: 3, end: 4.5)]
        // The Mac's microphone (48 kHz Float32 CAF), a stereo call with two different channels, and a 16-bit WAV.
        let microphone = try recording()
        let stereo = try recording(channels: 2, name: "call.caf")
        let wav = try recording(rate: 16_000, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                                         AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false], name: "soundcore.wav")
        for (original, rate, channels) in [(microphone, 48_000.0, 1), (stereo, 48_000, 2), (wav, 16_000, 1)] {
            let clip = try await VoiceClipAudio.extract(from: original, spans: spans, into: root)
            XCTAssertTrue(clip.url.lastPathComponent.hasPrefix(VoiceClips.temporaryPrefix))
            XCTAssertEqual(clip.sampleRate, rate)
            XCTAssertEqual(clip.channels, channels)
            XCTAssertEqual(clip.ranges, [VoiceClipRange(startFrame: Int64(0.5 * rate), endFrame: Int64(1.25 * rate)),
                                         VoiceClipRange(startFrame: Int64(3 * rate), endFrame: Int64(4.5 * rate))])
            try assertHolds(clip, of: original)
        }
    }

    func testBehaviorAClipIsCutOnlyFromWhatTheRecordingHolds() async throws {
        let original = try recording(seconds: 2)
        // A passage past the end is cut short to the end, and one wholly past it is left out.
        let clip = try await VoiceClipAudio.extract(from: original, spans: [VoiceClipSpan(start: 1.5, end: 9), VoiceClipSpan(start: 5, end: 6)], into: root)
        XCTAssertEqual(clip.ranges, [VoiceClipRange(startFrame: 72_000, endFrame: 96_000)])
        try assertHolds(clip, of: original)
        do {
            _ = try await VoiceClipAudio.extract(from: original, spans: [VoiceClipSpan(start: 5, end: 6)], into: root)
            XCTFail("nothing to cut")
        } catch let failure as VoiceClipAudio.Failure {
            XCTAssertEqual(failure, .nothingToCut)
        }
        do {
            _ = try await VoiceClipAudio.extract(from: root.appendingPathComponent("missing.caf"), spans: [VoiceClipSpan(start: 0, end: 1)], into: root)
            XCTFail("unreadable")
        } catch let failure as VoiceClipAudio.Failure {
            XCTAssertEqual(failure, .unreadable)
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(VoiceClips.temporaryPrefix) }
        XCTAssertEqual(left.count, 1, "only the clip that was made; a failed cut leaves nothing")
    }

    func testBehaviorAClipThatDiffersFromTheOriginalIsRefused() async throws {
        let original = try recording()
        let clip = try await VoiceClipAudio.extract(from: original, spans: [VoiceClipSpan(start: 1, end: 2)], into: root)
        try VoiceClipAudio.verify(clip: clip.url, original: original, ranges: clip.ranges, rate: 48_000, channels: 1, isCancelled: { false })
        // The same recording with one sample changed in its last bit.
        var bits = try samples(original)[0]
        bits[48_000 + 17] ^= 1
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(bits.count))!
        buffer.frameLength = AVAudioFrameCount(bits.count)
        for (index, value) in bits.enumerated() { buffer.floatChannelData![0][index] = Float(bitPattern: value) }
        let changed = root.appendingPathComponent("changed.caf")
        do {
            let out = try AVAudioFile(forWriting: changed, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try out.write(from: buffer)
        }
        XCTAssertThrowsError(try VoiceClipAudio.verify(clip: clip.url, original: changed, ranges: clip.ranges, rate: 48_000, channels: 1,
                                                       isCancelled: { false })) { XCTAssertEqual($0 as? VoiceClipAudio.Failure, .differs) }
        XCTAssertThrowsError(try VoiceClipAudio.verify(clip: clip.url, original: original, ranges: [VoiceClipRange(startFrame: 0, endFrame: 48_000)],
                                                       rate: 48_000, channels: 1, isCancelled: { false }), "other frames")
        XCTAssertThrowsError(try VoiceClipAudio.verify(clip: clip.url, original: original, ranges: clip.ranges, rate: 48_000, channels: 2,
                                                       isCancelled: { false }), "other channels")
    }

    func testBehaviorTheClipsTurnsAreItsPassagesBackToBack() {
        let source = VoiceClipSource(meetingID: UUID(), trackID: UUID(), speakerID: "s1")
        let clip = VoiceClip(source: source, fileName: "x.caf", sha256: "", size: 0, originalSHA256: "", sampleRate: 16_000, channels: 1,
                             ranges: [VoiceClipRange(startFrame: 16_000, endFrame: 48_000), VoiceClipRange(startFrame: 80_000, endFrame: 88_000)],
                             createdAt: now, stamp: [])
        XCTAssertEqual(clip.spansInClip, [VoiceClipSpan(start: 0, end: 2), VoiceClipSpan(start: 2, end: 2.5)])
        XCTAssertEqual(source.key, VoiceClipSource(meetingID: source.meetingID, trackID: source.trackID, speakerID: "s1").key, "the same on every Mac")
        XCTAssertEqual(source.key.count, 32)
    }
}
