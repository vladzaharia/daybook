import DaybookCore
import DaybookKit
import XCTest
@testable import Daybook

final class ProcessingPreferencesTests: XCTestCase {
    func testOldOrPartialPreferencesDecodeWithConservativeDefaults() throws {
        let preferences = try JSONDecoder().decode(ProcessingPreferences.self, from: Data("{\"matchSpeakersAcrossSources\":false}".utf8))
        XCTAssertFalse(preferences.matchSpeakersAcrossSources)
        XCTAssertEqual(preferences.speakerMatchThreshold, 0.82)
        XCTAssertEqual(preferences.speakerMatchMargin, 0.06)
        XCTAssertEqual(preferences.speakerOptions.quality, .balanced)
    }

    func testQueuedRequestFreezesSettingsAndSurvivesSerialization() throws {
        var preferences = ProcessingPreferences(speakerOptions: .init(quality: .accurate, expectedSpeakerCount: 3))
        let request = ProcessingJob(meetingID: UUID(), mode: .speakerRefresh,
            transcriptionModelID: "whisper-small", summaryModelID: "qwen-7b", preferences: preferences)
        preferences.speakerOptions.quality = .fast
        preferences.speakerMatchThreshold = 0.6
        let restored = try JSONDecoder().decode(ProcessingJob.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(restored, request)
        XCTAssertEqual(restored.preferences.speakerOptions.quality, .accurate)
        XCTAssertEqual(restored.preferences.speakerOptions.expectedSpeakerCount, 3)
        XCTAssertEqual(restored.preferences.speakerMatchThreshold, 0.82)
    }

    func testSummarizeHereTravelsWithTheJobAndEarlierJobsReadAsBefore() throws {
        let here = ProcessingJob(meetingID: UUID(), mode: .summaryOnly, transcriptionModelID: "asr", summaryModelID: "summary",
                                 summarizesHere: true)
        XCTAssertTrue(here.summarizesHere)
        XCTAssertEqual(try JSONDecoder().decode(ProcessingJob.self, from: JSONEncoder().encode(here)), here)
        let request = ProcessingRequest(meetingID: here.meetingID, mode: .summaryOnly, requestedBy: .init(id: "phone", name: "Alex’s iPhone"))
        XCTAssertTrue(here.carrying(request).summarizesHere, "Taking on a request keeps it")

        let usual = ProcessingJob(meetingID: UUID(), transcriptionModelID: "asr", summaryModelID: "summary")
        XCTAssertFalse(usual.summarizesHere)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(usual)) as? [String: Any])
        XCTAssertFalse(stored.keys.contains("summaryHere"), "Written only when set")
        XCTAssertEqual(here.configurationFingerprint, ProcessingJob(meetingID: UUID(), transcriptionModelID: "asr", summaryModelID: "summary")
            .configurationFingerprint, "Where the summary runs isn't a model setting")
    }

    func testSummaryRefreshDoesNotRequireRemovedAudioModels() {
        let request = ProcessingJob(meetingID: UUID(), mode: .summaryOnly,
            transcriptionModelID: "removed-asr", summaryModelID: "local-summary")
        XCTAssertEqual(request.requiredModelIDs(hasUntranscribedAudio: false), ["local-summary"])
        XCTAssertEqual(request.requiredModelIDs(hasUntranscribedAudio: true), ["local-summary"])
    }

    func testSpeakerRefreshReusesTranscriptionButRequiresSelectedSpeakerModel() {
        let request = ProcessingJob(meetingID: UUID(), mode: .speakerRefresh,
            transcriptionModelID: "asr", summaryModelID: "summary", preferences: .init(speakerModelID: "selected-speaker"))
        XCTAssertEqual(request.requiredModelIDs(hasUntranscribedAudio: false), ["summary", "selected-speaker"])
        XCTAssertEqual(request.requiredModelIDs(hasUntranscribedAudio: true), ["asr", "summary", "selected-speaker"])
    }

    func testFullRetranscriptionRequiresASREvenWhenOldTranscriptExists() {
        let request = ProcessingJob(meetingID: UUID(), mode: .fullRetranscription,
            transcriptionModelID: "new-asr", summaryModelID: "summary", detectSpeakers: false)
        XCTAssertEqual(request.requiredModelIDs(hasUntranscribedAudio: false), ["new-asr", "summary"])
    }

    func testFingerprintIgnoresQueueIdentityButChangesWithAppliedSettings() {
        let first = ProcessingJob(meetingID: UUID(), transcriptionModelID: "asr", summaryModelID: "summary")
        let second = ProcessingJob(meetingID: UUID(), mode: .summaryOnly, transcriptionModelID: "asr", summaryModelID: "summary")
        let changed = ProcessingJob(meetingID: UUID(), transcriptionModelID: "asr-v2", summaryModelID: "summary")
        XCTAssertEqual(first.configurationFingerprint, second.configurationFingerprint)
        XCTAssertNotEqual(first.configurationFingerprint, changed.configurationFingerprint)
        XCTAssertEqual(first.configurationFingerprint.count, 64)
    }

    func testInvalidSimilarityValuesAreNormalizedBeforeQueueing() {
        var preferences = ProcessingPreferences()
        preferences.speakerMatchThreshold = .nan
        preferences.speakerMatchMargin = 4
        preferences.speakerOptions.expectedSpeakerCount = 99
        let request = ProcessingJob(meetingID: UUID(), transcriptionModelID: "asr", summaryModelID: "summary", preferences: preferences)
        XCTAssertEqual(request.preferences.speakerMatchThreshold, 0.82)
        XCTAssertEqual(request.preferences.speakerMatchMargin, 1)
        XCTAssertNil(request.preferences.speakerOptions.expectedSpeakerCount)
        XCTAssertNoThrow(try JSONEncoder().encode(request))
    }
}
