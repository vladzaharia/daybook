import XCTest
@testable import DaybookCore

/// The gain a recording plays with so recordings play at one level: lowered to the target, never raised by what a
/// player can't do, raised (for a player that can) no further than the peak allows, and left alone without speech.
final class PlaybackLevelTests: XCTestCase {
    private func speech(_ level: Double, quiet: Double? = nil) -> SpeechLevel.Measurement {
        SpeechLevel.Measurement(speech: level, peak: level + 15, quiet: quiet ?? level - 30)
    }

    private func gain(_ level: Double, among levels: [Double]) -> Double {
        PlaybackLevel.gain(for: speech(level), among: levels.map { speech($0) })
    }

    func testBehaviorASingleRecordingPlaysAsCaptured() {
        XCTAssertEqual(gain(-20, among: [-20]), 0)
        XCTAssertEqual(gain(-20, among: []), 0)
    }

    func testBehaviorRecordingsWithinTheDeadBandPlayAsCaptured() {
        XCTAssertEqual(gain(-25, among: [-25, -27.5]), 0)
        XCTAssertEqual(gain(-27.5, among: [-25, -27.5]), 0)
        XCTAssertEqual(gain(-25, among: [-25, -28]), -3, accuracy: 1e-9, "3 dB apart is the edge: matched")
    }

    func testBehaviorTheLoudOneComesDownToTheQuietOneAndTheQuietOneIsUntouched() {
        XCTAssertEqual(gain(-25, among: [-25, -35]), -10, accuracy: 1e-9)
        XCTAssertEqual(gain(-35, among: [-25, -35]), 0)
        XCTAssertEqual(gain(-30, among: [-25, -30, -35]), -5, accuracy: 1e-9, "one in between")
    }

    func testBehaviorASpreadWiderThanTheCapLowersTheLoudOneByExactlyTheCap() {
        XCTAssertEqual(gain(-15, among: [-15, -50]), -12, accuracy: 1e-9)
        XCTAssertEqual(gain(-50, among: [-15, -50]), 0)
        XCTAssertEqual(gain(-38, among: [-15, -50]), 0, "already under the target: lowering stops at the cap")
        XCTAssertEqual(gain(-30, among: [-15, -30, -50]), -0, accuracy: 1e-9, "the target is -27")
        XCTAssertEqual(gain(-20, among: [-15, -20, -50]), -7, accuracy: 1e-9)
    }

    func testBehaviorARecordingWithoutAUsableLevelIsIgnoredAndPlaysAsCaptured() {
        let unmeasured = SpeechLevel.Measurement(speech: nil, peak: nil)
        let hum = speech(-20, quiet: -22)
        XCTAssertEqual(PlaybackLevel.gain(for: speech(-25), among: [speech(-25), unmeasured, hum]), 0, "no one to match")
        XCTAssertEqual(PlaybackLevel.gain(for: speech(-25), among: [speech(-25), speech(-35), unmeasured, hum]), -10, accuracy: 1e-9)
        XCTAssertEqual(PlaybackLevel.gain(for: unmeasured, among: [speech(-25), speech(-35)]), 0)
        XCTAssertEqual(PlaybackLevel.gain(for: hum, among: [hum, speech(-35)]), 0, "a loud hum has no speech to bring down")
        XCTAssertEqual(PlaybackLevel.factor(for: speech(-25), among: [speech(-25), speech(-35)]), Float(pow(10, -10.0 / 20)), accuracy: 1e-6)
    }

    func testBehaviorARecordedLevelHasNoQuietLevelAndIsMatchedAsItStands() {
        let recorded = LevelAdjustment(speechLevel: -22, peak: -3, gain: 0)
        XCTAssertNil(recorded.measurement.quiet)
        XCTAssertEqual(PlaybackLevel.gain(for: recorded.measurement, among: [recorded.measurement, speech(-32)]), -10, accuracy: 1e-9)
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
        XCTAssertEqual(meeting.playbackLevels(ofTrack: track).own?.speech, -20)
    }
}
