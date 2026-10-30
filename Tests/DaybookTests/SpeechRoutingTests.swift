import DaybookCore
@testable import DaybookIntelligence
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// What a queued job freezes after routing: the transcription language picks the model (or adds a
/// language check), a large expected speaker count picks a speaker model without a limit, and
/// Nemotron's speakers get voice profiles from Community-1.
@MainActor
final class SpeechRoutingTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }

    private func state() throws -> AppState {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSpeechRouting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return AppState(libraryURL: root, defaults: makeTestDefaults("local.daybook.tests.routing"))
    }

    func testAutomaticAddsAnOptionalLanguageCheck() throws {
        let state = try state()
        state.transcriptionModel = "parakeet/ultra"
        state.installedModels = ["parakeet/ultra", state.summaryModel, "community-1/offline"]
        state.installedRevisions = ["parakeet/ultra": "rev-p", "whisper/large-v3-turbo": "rev-t"]
        let job = state.makeJob(meetingID: UUID(), mode: .newAudio)
        XCTAssertEqual(job.transcriptionModelID, "parakeet/ultra")
        XCTAssertEqual(job.languageFallbackModelID, "whisper/large-v3-turbo")
        XCTAssertFalse(job.requiredModelIDs(hasUntranscribedAudio: true).contains("whisper/large-v3-turbo"), "The check never blocks a job")
        XCTAssertTrue(job.modelReferences.contains(ModelReference("whisper/large-v3-turbo", revision: "rev-t")), "Frozen and kept from removal")
        XCTAssertTrue(state.canProcess)
        XCTAssertTrue(state.missingSelectedModels.isEmpty)
        let configuration = job.engineConfiguration
        XCTAssertNil(configuration.transcriptionLanguage)
        XCTAssertEqual(configuration.languageFallbackModel, ModelReference("whisper/large-v3-turbo", revision: "rev-t"))
    }

    func testAChosenLanguageTheModelDoesntCoverGoesToTheOtherLanguagesModel() throws {
        let state = try state()
        state.transcriptionModel = "parakeet/ultra"
        state.installedModels = ["parakeet/ultra", state.summaryModel, "community-1/offline"]
        state.processingPreferences.transcriptionLanguage = "ja-JP"
        XCTAssertEqual(state.processingPreferences.normalized.transcriptionLanguage, "ja")
        let job = state.makeJob(meetingID: UUID(), mode: .newAudio)
        XCTAssertEqual(job.transcriptionModelID, "whisper/large-v3-turbo")
        XCTAssertNil(job.languageFallbackModelID)
        XCTAssertEqual(job.engineConfiguration.transcriptionLanguage, "ja")
        XCTAssertFalse(state.canProcess, "Japanese needs Whisper downloaded")
        XCTAssertEqual(state.missingSelectedModels, ["whisper/large-v3-turbo"])

        state.processingPreferences.otherLanguagesModelID = "whisper/small"
        XCTAssertEqual(state.makeJob(meetingID: UUID(), mode: .newAudio).transcriptionModelID, "whisper/small")
        state.processingPreferences.transcriptionLanguage = "de"
        let german = state.makeJob(meetingID: UUID(), mode: .newAudio)
        XCTAssertEqual(german.transcriptionModelID, "parakeet/ultra")
        XCTAssertEqual(german.engineConfiguration.transcriptionLanguage, "de")
        XCTAssertTrue(state.canProcess)
    }

    func testRoutedModelsAreWorkedOutOncePerChangeOfWhatRoutesThem() throws {
        let state = try state()
        state.transcriptionModel = "parakeet/ultra"
        state.installedModels = ["parakeet/ultra", state.summaryModel, "community-1/offline"]
        let routed = state.routedRequiredModelIDs
        XCTAssertEqual(routed, ["parakeet/ultra", state.summaryModel, "community-1/offline"])
        let kept = try XCTUnwrap(state.routeMemo)
        XCTAssertTrue(state.canProcess)
        XCTAssertEqual(state.routeMemo?.key, kept.key, "Every row and status line asks; it's routed once")
        // Whatever routing reads routes again: speakers, the language, what's installed, the selection, the catalog.
        state.detectSpeakers = false
        XCTAssertEqual(state.routedRequiredModelIDs, ["parakeet/ultra", state.summaryModel])
        state.detectSpeakers = true
        state.processingPreferences.transcriptionLanguage = "ja"
        XCTAssertEqual(state.routedRequiredModelIDs.first, "whisper/large-v3-turbo")
        XCTAssertFalse(state.canProcess, "Japanese needs Whisper downloaded")
        state.installedModels.insert("whisper/large-v3-turbo")
        XCTAssertTrue(state.canProcess)
        state.processingPreferences.transcriptionLanguage = nil
        state.transcriptionModel = "whisper/large-v3-turbo"
        XCTAssertEqual(state.routedRequiredModelIDs.first, "whisper/large-v3-turbo")
        let revision = state.catalogRevision
        state.modelCatalog = state.modelCatalog
        XCTAssertEqual(state.catalogRevision, revision + 1)
        _ = state.routedRequiredModelIDs
        XCTAssertEqual(state.routeMemo?.key.catalogRevision, revision + 1, "A new catalog routes again")
    }

    func testNemotronJobsGetVoiceProfilesAndLargeGroupsGoToCommunity1() throws {
        let state = try state()
        state.processingPreferences.speakerModelID = "nemotron-3-diarization/offline"
        state.installedModels = [state.transcriptionModel, state.summaryModel, "nemotron-3-diarization/offline"]
        let job = state.makeJob(meetingID: UUID(), mode: .newAudio)
        XCTAssertEqual(job.preferences.speakerModelID, "nemotron-3-diarization/offline")
        XCTAssertEqual(job.voiceEmbeddingModelID, "community-1/offline")
        XCTAssertFalse(state.canProcess, "Voice profiles need Community-1")
        XCTAssertEqual(state.missingSelectedModels, ["community-1/offline"])

        state.installedModels.insert("community-1/offline")
        XCTAssertTrue(state.canProcess)
        state.processingPreferences.speakerOptions.expectedSpeakerCount = 12
        let large = state.makeJob(meetingID: UUID(), mode: .newAudio)
        XCTAssertEqual(large.preferences.speakerModelID, "community-1/offline", "More than eight speakers")
        XCTAssertNil(large.voiceEmbeddingModelID, "Community-1 makes its own profiles")
        XCTAssertEqual(state.processingPreferences.speakerModelID, "nemotron-3-diarization/offline", "The choice itself is unchanged")
    }

    func testLanguagePreferencesPersistAndLeaveEarlierFingerprintsAlone() throws {
        let earlier = ProcessingJob(meetingID: UUID(), transcriptionModelID: "parakeet/ultra", summaryModelID: "qwen2.5/7b-4bit",
                                    preferences: ProcessingPreferences())
        let encoded = String(decoding: try JSONEncoder().encode(ProcessingPreferences()), as: UTF8.self)
        XCTAssertFalse(encoded.contains("transcriptionLanguage"), "Automatic encodes nothing new")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(earlier), as: UTF8.self).contains("languageFallbackModelID"))

        let chosen = ProcessingPreferences(transcriptionLanguage: "pt-BR", otherLanguagesModelID: "whisper/small")
        let decoded = try JSONDecoder().decode(ProcessingPreferences.self, from: JSONEncoder().encode(chosen))
        XCTAssertEqual(decoded.transcriptionLanguage, "pt")
        XCTAssertEqual(decoded.otherLanguagesModelID, "whisper/small")
        let withCheck = ProcessingJob(meetingID: UUID(), transcriptionModelID: "parakeet/ultra", summaryModelID: "qwen2.5/7b-4bit",
                                      preferences: ProcessingPreferences(), languageFallbackModelID: "whisper/large-v3-turbo")
        XCTAssertNotEqual(withCheck.configurationFingerprint, earlier.configurationFingerprint)
        let restored = try JSONDecoder().decode(ProcessingJob.self, from: JSONEncoder().encode(withCheck))
        XCTAssertEqual(restored, withCheck)
    }
}
