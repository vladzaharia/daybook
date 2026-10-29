import DaybookCore
import DaybookKit
@testable import DaybookLive
import XCTest

/// Who spoke when, as frames arrive, and naming voices from known voices: thresholds, margins, one
/// person per voice, and embedding spaces that never mix.
final class LiveSpeakerTests: XCTestCase {
    /// `seconds` of 10 ms frames where `slot` (or nobody, for nil) is active among `speakers`.
    static func frames(_ seconds: Double, slot: Int?, overlap: Int? = nil, speakers: Int = 4) -> LiveSpeakerFrames {
        let count = Int((seconds * 100).rounded())
        var probabilities = [Float](repeating: 0.02, count: count * speakers)
        for frame in 0..<count {
            if let slot { probabilities[frame * speakers + slot] = 0.9 }
            if let overlap { probabilities[frame * speakers + overlap] = 0.8 }
        }
        return LiveSpeakerFrames(probabilities: probabilities, frames: count, speakers: speakers)
    }

    func testRunsSoloStretchesAndTheDominantVoice() {
        var timeline = LiveSpeakerTimeline(frameSeconds: 0.01)
        let identity: (TimeInterval) -> TimeInterval = { $0 }
        var solos = timeline.append(Self.frames(2, slot: 0), time: identity)
        XCTAssertTrue(solos.isEmpty, "a stretch closes when someone else speaks")
        solos += timeline.append(Self.frames(0.5, slot: 0, overlap: 1), time: identity)
        solos += timeline.append(Self.frames(3, slot: 1), time: identity)
        solos += timeline.append(Self.frames(1, slot: nil), time: identity)
        XCTAssertEqual(solos.map(\.slot), [0, 1])
        XCTAssertEqual(solos[0].startFrame, 0)
        XCTAssertEqual(solos[0].endFrame, 200, "only the stretch nobody else spoke over")
        XCTAssertEqual(solos[1].startFrame, 250)
        XCTAssertEqual(timeline.dominantSlot(from: 0.2, to: 1.8, time: identity), 0)
        XCTAssertEqual(timeline.dominantSlot(from: 3.0, to: 5.0, time: identity), 1)
        XCTAssertNil(timeline.dominantSlot(from: 6.0, to: 6.4, time: identity), "silence has no speaker")
    }

    func testShortStretchesMakeNoProfileAndLongOnesAreCut() {
        var timeline = LiveSpeakerTimeline(frameSeconds: 0.01)
        var solos = timeline.append(Self.frames(1, slot: 2), time: { $0 })
        solos += timeline.append(Self.frames(0.5, slot: nil), time: { $0 })
        XCTAssertTrue(solos.isEmpty, "a second is too short for a voice profile")
        solos += timeline.append(Self.frames(25, slot: 3), time: { $0 })
        solos += timeline.finish(time: { $0 })
        XCTAssertEqual(solos.map { $0.endFrame - $0.startFrame }, [1000, 1000, 500], "cut at ten seconds")
    }

    func testTheTimelineFollowsTheCapturesClock() {
        var timeline = LiveSpeakerTimeline(frameSeconds: 0.01)
        // The diarizer heard 2 s, then audio was shed for 10 s, then 2 s more.
        let shifted: (TimeInterval) -> TimeInterval = { $0 < 2 ? $0 : $0 + 10 }
        _ = timeline.append(Self.frames(2, slot: 0), time: shifted)
        _ = timeline.append(Self.frames(2, slot: 1), time: shifted)
        _ = timeline.finish(time: shifted)
        XCTAssertEqual(timeline.dominantSlot(from: 12.5, to: 13.5, time: shifted), 1)
        XCTAssertNil(timeline.dominantSlot(from: 5, to: 9, time: shifted))
    }

    // MARK: Names

    private func voice(_ name: String, _ vector: [Float], space: String = "space-a") -> KnownVoice {
        KnownVoice(id: "name:\(name.lowercased())", name: name, embeddingSpace: space, embeddings: [vector])
    }

    func testAVoiceIsNamedOnlyWhenCloseAndClearlyCloserThanAnyone() {
        var identifier = LiveVoiceIdentifier(voices: [voice("Priya", [1, 0, 0]), voice("Alex", [0, 1, 0])], space: "space-a")
        XCTAssertFalse(identifier.observe(slot: 0, embedding: [0.98, 0.1, 0], seconds: 2), "not enough speech yet")
        XCTAssertTrue(identifier.observe(slot: 0, embedding: [0.97, 0.12, 0.05], seconds: 2))
        XCTAssertEqual(identifier.matches[0]?.name, "Priya")
        // Halfway between two people: no name.
        identifier.observe(slot: 1, embedding: [0.7, 0.7, 0], seconds: 5)
        XCTAssertNil(identifier.matches[1])
        // Nobody close: no name.
        identifier.observe(slot: 2, embedding: [0, 0, 1], seconds: 5)
        XCTAssertNil(identifier.matches[2])
    }

    func testOnePersonKeepsOneVoice() {
        var identifier = LiveVoiceIdentifier(voices: [voice("Priya", [1, 0, 0])], space: "space-a")
        identifier.observe(slot: 0, embedding: [0.99, 0.05, 0], seconds: 4)
        identifier.observe(slot: 1, embedding: [0.985, 0.07, 0], seconds: 4)
        XCTAssertTrue(identifier.matches.isEmpty, "two voices about as close to Priya: neither is named")
        identifier.observe(slot: 1, embedding: [0.6, 0.8, 0], seconds: 30)
        XCTAssertEqual(identifier.matches[0]?.name, "Priya", "once one is clearly closer, it keeps the name")
        XCTAssertNil(identifier.matches[1])
    }

    func testVoicesFromAnotherSpaceAreNeverCompared() {
        let identifier = LiveVoiceIdentifier(voices: [voice("Priya", [1, 0, 0], space: "space-b")], space: "space-a")
        XCTAssertFalse(identifier.hasVoices)
    }

    // MARK: Known voices

    func testTheLibrarysVoiceProfilesAreKnownVoices() {
        let space = "fluid-community1-embedding-df2625ac79a7ac6b"
        let priya = SpeakerProfile(id: UUID(), name: "Priya"), alex = SpeakerProfile(id: UUID(), name: "Alex")
        let sam = SpeakerProfile(id: UUID(), name: "Sam"), gone = SpeakerProfile(id: UUID(), name: "Gone")
        func print(_ profile: SpeakerProfile, _ values: [Float], space: String = space, at time: TimeInterval) -> LibraryValue<Voiceprint> {
            let id = "vp-\(profile.name)-\(time)"
            return LibraryValue(id: id, value: Voiceprint(id: id, profileID: profile.id, origin: .named, vector: VoiceVector(space: space, values: values),
                                                          meetingID: UUID(), speakerID: "S1", speechSeconds: 60, recordedAt: Date(timeIntervalSince1970: time)))
        }
        var metadata = LibraryMetadata()
        metadata.speakerProfiles = [priya, alex, sam].map { LibraryValue(id: $0.id.uuidString, value: $0) }
            + [LibraryValue(id: gone.id.uuidString, value: nil)]
        metadata.voiceprints = [print(priya, [1, 0], at: 100), print(priya, [0.75, 0.25], at: 200),
                                print(alex, [0, 1], space: "another-space", at: 100), print(sam, [0, 0], at: 100),
                                print(gone, [0.5, 0.5], at: 100)]
        let voices = KnownVoices.fromProfiles(metadata, space: space)
        XCTAssertEqual(voices.map(\.name), ["Priya"], "other-space, unusable, and deleted profiles' voices are left out")
        XCTAssertEqual(voices[0].id, "profile:\(priya.id.uuidString)")
        XCTAssertEqual(voices[0].embeddings, [[0.75, 0.25], [1, 0]], "newest first")
    }

    // MARK: Audio kept for profiles

    func testTheRingKeepsTheNewestAudioByItsOwnIndex() {
        var ring = LiveAudioRing(seconds: 1)
        ring.append([Float](repeating: 0.1, count: 16_000))
        ring.append([Float](repeating: 0.2, count: 16_000))
        XCTAssertEqual(ring.end, 32_000)
        XCTAssertNil(ring.slice(0, 100), "dropped")
        XCTAssertEqual(ring.slice(31_000, 32_000)?.first, 0.2)
        XCTAssertNil(ring.slice(31_000, 33_000), "not heard yet")
    }
}
