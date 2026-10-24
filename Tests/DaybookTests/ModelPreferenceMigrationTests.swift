import DaybookCore
@testable import DaybookIntelligence
@testable import DaybookKit
import Foundation
import XCTest
@testable import Daybook

/// The Mac's model choices on the model system: selections by variant, migrated from the catalog
/// IDs stored before it, and jobs that freeze exact revisions.
@MainActor
final class ModelPreferenceMigrationTests: XCTestCase {
    private var roots: [URL] = []
    private var suites: [String] = []

    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }

    private func library() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookModelPrefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func defaults() -> UserDefaults {
        let suite = "local.daybook.tests.models.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    func testStoredModelIDsMigrateToVariantSelections() throws {
        let defaults = defaults()
        defaults.set("whisper-large-turbo", forKey: "transcriptionModel")
        defaults.set("qwen-3b", forKey: "summaryModel")
        defaults.set(Data(#"{"speakerModelID":"speaker-sortformer-v2.1","matchSpeakersAcrossSources":false}"#.utf8), forKey: "processingPreferences")

        let state = AppState(libraryURL: try library(), defaults: defaults)
        XCTAssertEqual(state.transcriptionModel, "whisper/large-v3-turbo")
        XCTAssertEqual(state.summaryModel, "qwen2.5/3b-4bit")
        XCTAssertEqual(state.processingPreferences.speakerModelID, "sortformer-2.1/fp16")
        XCTAssertEqual(state.modelSelections[.diarization], "sortformer-2.1/fp16")
        XCTAssertFalse(state.processingPreferences.matchSpeakersAcrossSources, "Other preferences are untouched")
        XCTAssertNil(ModelPreset.current(in: state), "Sortformer isn't in a preset: Custom")
        let stored = try JSONDecoder().decode(ModelSelections.self, from: XCTUnwrap(defaults.data(forKey: "modelSelections")))
        XCTAssertEqual(stored, state.modelSelections, "Migrated once and saved")
        XCTAssertEqual(defaults.string(forKey: "transcriptionModel"), "whisper-large-turbo", "The old keys stay for an older build")

        // Later launches read the selection.
        state.transcriptionModel = "whisper/small"
        let relaunched = AppState(libraryURL: try library(), defaults: defaults)
        XCTAssertEqual(relaunched.transcriptionModel, "whisper/small")
        XCTAssertEqual(relaunched.processingPreferences.speakerModelID, "sortformer-2.1/fp16")

        // The speaker choice and the processing preferences stay in step, both ways.
        relaunched.processingPreferences.speakerModelID = "community-1/offline"
        XCTAssertEqual(relaunched.modelSelections[.diarization], "community-1/offline")
        relaunched.modelSelections[.diarization] = "sortformer-2.1/compact"
        XCTAssertEqual(relaunched.processingPreferences.speakerModelID, "sortformer-2.1/compact")

        // Presets come from the catalog and still read as presets.
        ModelPreset.balanced.apply(to: relaunched)
        XCTAssertEqual(relaunched.transcriptionModel, "parakeet/ultra")
        XCTAssertEqual(relaunched.summaryModel, ModelRecommendations.summary(for: .current, quality: .balanced))
        XCTAssertTrue(relaunched.summaryModel.hasPrefix("gemma-4/"), "Gemma 4 is every preset's first choice")
        XCTAssertEqual(relaunched.processingPreferences.speakerModelID, "nemotron-3-diarization/offline")
        XCTAssertEqual(ModelPreset.current(in: relaunched), .balanced)
        XCTAssertEqual(ModelPreset.detailed.modelIDs, ["parakeet/ultra", ModelRecommendations.summary(for: .current, quality: .detailed),
                                                       "nemotron-3-diarization/offline", "community-1/offline", "apple-foundation-models/system"],
                       "Transcription, summaries, and speakers first, then voice profiles and small tasks")
        // Selections saved before the voice-profile role had a model still get one for Nemotron's speakers.
        relaunched.modelSelections[.speakerEmbedding] = nil
        XCTAssertEqual(relaunched.voiceEmbeddingModel, "community-1/offline")
        XCTAssertEqual(relaunched.modelSelections[.smallTasks], "apple-foundation-models/system",
                       "Roles nothing was stored for start with the initial selection")
    }

    func testAFreshInstallStartsWithTheCatalogsInitialSelection() throws {
        let state = AppState(libraryURL: try library(), defaults: defaults())
        XCTAssertEqual(state.transcriptionModel, "parakeet/ultra")
        XCTAssertEqual(state.processingPreferences.speakerModelID, "community-1/offline")
        XCTAssertEqual(state.modelSelections[.speakerEmbedding], "community-1/offline")
        let expected: [DeviceTier: String] = [.compact: "gemma-4/e2b-4bit", .standard: "gemma-4/12b-4bit",
                                              .large: "gemma-4/26b-a4b-qat-4bit", .workstation: "gemma-4/26b-a4b-qat-4bit"]
        XCTAssertEqual(state.summaryModel, expected[DeviceTier.current])
        XCTAssertEqual(state.modelSelections[.smallTasks], "apple-foundation-models/system")
    }

    func testSmallTasksJoinASelectionMadeBeforeThemOnce() throws {
        let defaults = defaults()
        let earlier = ModelSelections([.transcription: "whisper/base", .summarization: "qwen2.5/7b-4bit", .diarization: "community-1/offline"])
        defaults.set(try JSONEncoder().encode(earlier), forKey: "modelSelections")
        let state = AppState(libraryURL: try library(), defaults: defaults)
        XCTAssertEqual(state.summaryModel, "qwen2.5/7b-4bit", "An installed Qwen 2.5 choice is kept")
        XCTAssertEqual(state.modelSelections[.smallTasks], "apple-foundation-models/system")

        // Cleared on purpose, it stays cleared.
        state.modelSelections[.smallTasks] = nil
        let relaunched = AppState(libraryURL: try library(), defaults: defaults)
        XCTAssertNil(relaunched.modelSelections[.smallTasks])
    }

    func testJobsUseTheSmallTasksModelOnlyWhenThisMacCanRunIt() throws {
        let state = AppState(libraryURL: try library(), defaults: defaults())
        state.modelSelections[.smallTasks] = "apple-foundation-models/system"
        state.installedModels = [state.transcriptionModel, state.summaryModel, "community-1/offline"]
        XCTAssertNil(state.smallTasksModel, "Apple Intelligence off: the summary model names it, as before")
        state.installedModels.insert("apple-foundation-models/system")
        XCTAssertEqual(state.smallTasksModel, "apple-foundation-models/system")

        let job = ProcessingJob(meetingID: UUID(), transcriptionModelID: state.transcriptionModel, summaryModelID: state.summaryModel,
                                smallTasksModelID: state.smallTasksModel)
        XCTAssertEqual(job.engineConfiguration.smallTasksModel, ModelReference("apple-foundation-models/system"))
        XCTAssertEqual(job.carrying(ProcessingRequest(meetingID: job.meetingID, mode: .summaryOnly, requestedBy: .init(id: "phone", name: "Phone")))
                        .smallTasksModelID, "apple-foundation-models/system")
        XCTAssertEqual(try JSONDecoder().decode(ProcessingJob.self, from: JSONEncoder().encode(job)), job)
        let without = ProcessingJob(id: job.id, meetingID: job.meetingID, createdAt: job.createdAt, transcriptionModelID: job.transcriptionModelID,
                                    summaryModelID: job.summaryModelID)
        XCTAssertNil(without.engineConfiguration.smallTasksModel)
        XCTAssertNotEqual(job.configurationFingerprint, without.configurationFingerprint)

        // A job queued before small tasks existed reads back without one.
        var stored = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(without)) as? [String: Any])
        stored.removeValue(forKey: "smallTasksModelID")
        let older = try JSONDecoder().decode(ProcessingJob.self, from: JSONSerialization.data(withJSONObject: stored))
        XCTAssertNil(older.smallTasksModelID)
        XCTAssertEqual(older.configurationFingerprint, without.configurationFingerprint)
    }

    func testLegacySpeakerModelsInStoredPreferencesDecodeToVariantKeys() throws {
        let preferences = try JSONDecoder().decode(ProcessingPreferences.self, from: Data(#"{"speakerModelID":"speaker-community-1"}"#.utf8))
        XCTAssertEqual(preferences.speakerModelID, "community-1/offline")
        let unknown = try JSONDecoder().decode(ProcessingPreferences.self, from: Data(#"{"speakerModelID":"someone-elses"}"#.utf8))
        XCTAssertEqual(unknown.speakerModelID, "someone-elses", "Never silently switched")
    }

    func testQueuedJobsFreezeTheRevisionsTheirModelsResolveTo() throws {
        let state = AppState(libraryURL: try library(), defaults: defaults())
        state.installedRevisions = ["parakeet/ultra": "rev-p", "whisper/base": "rev-w", "community-1/offline": "rev-c",
                                    state.summaryModel: "rev-g", "qwen2.5/1.5b-4bit": "rev-q15", "whisper/small": "rev-s",
                                    "whisper/large-v3-turbo": "rev-t"]
        let frozen = state.frozenModelRevisions
        XCTAssertEqual(Set(frozen.keys), Set([state.transcriptionModel, state.summaryModel, "community-1/offline", "whisper/large-v3-turbo"]),
                       "Only the models the job uses, the language check's included")
        let job = ProcessingJob(meetingID: UUID(), transcriptionModelID: state.transcriptionModel, summaryModelID: state.summaryModel,
                                preferences: state.processingPreferences, revisions: frozen)
        let configuration = job.engineConfiguration
        XCTAssertEqual(configuration.transcriptionModel, ModelReference("parakeet/ultra", revision: "rev-p"))
        XCTAssertEqual(configuration.speakerModel, ModelReference("community-1/offline", revision: "rev-c"))
        XCTAssertNil(configuration.voiceEmbeddingModel, "Community-1 makes its own voice profiles")
        XCTAssertEqual(job.carrying(ProcessingRequest(meetingID: job.meetingID, mode: .newAudio, requestedBy: .init(id: "phone", name: "Phone"))).revisions, frozen)

        let restored = try JSONDecoder().decode(ProcessingJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(restored, job)
        let older = ProcessingJob(meetingID: UUID(), transcriptionModelID: "whisper/base", summaryModelID: "qwen2.5/7b-4bit")
        XCTAssertNil(older.engineConfiguration.transcriptionModel.revision, "Jobs without frozen revisions use the newest installed one")
        XCTAssertNotEqual(job.configurationFingerprint, older.configurationFingerprint)
    }
}
