import XCTest
@testable import DaybookCore

/// The gain a recording plays with so recordings play at one level: lowered to the target, never raised by what a
/// player can't do, raised (for a player that can) no further than the peak allows, and left alone without speech.
final class PlaybackLevelTests: XCTestCase {
    private func speech(_ level: Double, peak: Double? = nil, quiet: Double? = nil) -> SpeechLevel.Measurement {
        SpeechLevel.Measurement(speech: level, peak: peak ?? level + 15, quiet: quiet ?? level - 30)
    }

    func testBehaviorALoudRecordingIsLoweredToTheTarget() {
        XCTAssertEqual(PlaybackLevel.gain(for: speech(-25)), -7, accuracy: 1e-9)
        XCTAssertEqual(PlaybackLevel.gain(for: speech(-32)), 0, accuracy: 1e-9, "at the target")
    }

    func testBehaviorLoweringStopsAtTheCap() {
        XCTAssertEqual(PlaybackLevel.gain(for: speech(-10)), -12, accuracy: 1e-9, "22 dB over, 12 dB taken")
    }

    func testBehaviorAQuietRecordingIsNotRaisedWhenThePlayerCannot() {
        XCTAssertEqual(PlaybackLevel.gain(for: speech(-50)), 0)
        XCTAssertEqual(PlaybackLevel.factor(for: speech(-50)), 1)
    }

    func testBehaviorABoostIsCappedAndKeepsThePeakUnderTheCeiling() {
        var policy = PlaybackLevel.Policy()
        policy.maximumBoost = 20
        XCTAssertEqual(PlaybackLevel.gain(for: speech(-40, peak: -10), policy: policy), 8, accuracy: 1e-9, "all the way to the target")
        XCTAssertEqual(PlaybackLevel.gain(for: speech(-60, peak: -30), policy: policy), 20, accuracy: 1e-9, "capped")
        XCTAssertEqual(PlaybackLevel.gain(for: speech(-40, peak: -5), policy: policy), 4, accuracy: 1e-9, "the peak reaches −1 dBFS first")
        XCTAssertEqual(PlaybackLevel.gain(for: speech(-40, peak: -0.5), policy: policy), 0, "never lowered for a peak")
        XCTAssertEqual(PlaybackLevel.gain(for: SpeechLevel.Measurement(speech: -40, peak: nil, quiet: -70), policy: policy), 0, "no peak, no boost")
    }

    func testBehaviorNoSpeechLikeDynamicsOrNoLevelPlaysAtUnity() {
        XCTAssertEqual(PlaybackLevel.gain(for: speech(-20, quiet: -22)), 0, "a loud hum: no speech to match")
        XCTAssertEqual(PlaybackLevel.gain(for: SpeechLevel.Measurement(speech: nil, peak: -3)), 0, "too little sound")
        XCTAssertEqual(PlaybackLevel.gain(for: SpeechLevel.Measurement(speech: nil, peak: nil)), 0)
        XCTAssertEqual(PlaybackLevel.gain(for: SpeechLevel.Measurement(speech: -.infinity, peak: nil)), 0)
    }

    func testBehaviorARecordedLevelHasNoQuietLevelAndIsMatchedAsItStands() {
        let recorded = LevelAdjustment(speechLevel: -22, peak: -3, gain: 0)
        XCTAssertNil(recorded.measurement.quiet)
        XCTAssertEqual(PlaybackLevel.gain(for: recorded.measurement), -10, accuracy: 1e-9)
    }

    func testBehaviorTheLatestProcessedRunsRecordedLevelIsUsed() {
        let track = UUID()
        func run(_ date: Date, _ adjustment: LevelAdjustment?) -> TrackTranscript {
            TrackTranscript(trackID: track, segments: [],
                            processingSettings: ProcessingSettings(modelID: "m", createdAt: date, levelAdjustment: adjustment))
        }
        let meeting = Meeting(transcripts: [
            run(Date(timeIntervalSince1970: 200), LevelAdjustment(speechLevel: -20, peak: -2, gain: 0)),
            run(Date(timeIntervalSince1970: 100), LevelAdjustment(speechLevel: -50, peak: -20, gain: 0)),
            run(Date(timeIntervalSince1970: 300), nil),
        ])
        XCTAssertEqual(meeting.recordedLevel(ofTrack: track)?.speech, -20)
        XCTAssertNil(meeting.recordedLevel(ofTrack: UUID()))
    }
}
