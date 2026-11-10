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
        let state = AppState(libraryURL: root, defaults: makeTestDefaults("local.daybook.tests.routing"))
        // Community-1 for speakers, which makes its own voice profiles (a fresh Mac's recommended preset may choose
        // Nemotron 3 with it: ModelPreferenceMigrationTests).
        state.processingPreferences.speakerModelID = "community-1/offline"
        return state
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
        state.transcriptionLanguage = "ja-JP"
        XCTAssertEqual(state.transcriptionLanguage, "ja", "the library's, normalized")
        let job = state.makeJob(meetingID: UUID(), mode: .newAudio)
        XCTAssertEqual(job.transcriptionModelID, "whisper/large-v3-turbo")
        XCTAssertNil(job.languageFallbackModelID)
        XCTAssertEqual(job.engineConfiguration.transcriptionLanguage, "ja")
        XCTAssertFalse(state.canProcess, "Japanese needs Whisper downloaded")
        XCTAssertEqual(state.missingSelectedModels, ["whisper/large-v3-turbo"])

        state.processingPreferences.otherLanguagesModelID = "whisper/small"
        XCTAssertEqual(state.makeJob(meetingID: UUID(), mode: .newAudio).transcriptionModelID, "whisper/small")
        state.transcriptionLanguage = "de"
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
        XCTAssertEqual(routed, ["parakeet/ultra", "community-1/offline", state.summaryModel], "What transcribes first, then the summary model")
        XCTAssertEqual(state.routedTranscribingModelIDs, ["parakeet/ultra", "community-1/offline"])
        let kept = try XCTUnwrap(state.routeMemo)
        XCTAssertTrue(state.canProcess)
        XCTAssertEqual(state.routeMemo?.key, kept.key, "Every row and status line asks; it's routed once")
        // Whatever routing reads routes again: speakers, the language, what's installed, the selection, the catalog.
        state.detectSpeakers = false
        XCTAssertEqual(state.routedRequiredModelIDs, ["parakeet/ultra", state.summaryModel])
        state.detectSpeakers = true
        state.transcriptionLanguage = "ja"
        XCTAssertEqual(state.routedRequiredModelIDs.first, "whisper/large-v3-turbo")
        XCTAssertFalse(state.canProcess, "Japanese needs Whisper downloaded")
        state.installedModels.insert("whisper/large-v3-turbo")
        XCTAssertTrue(state.canProcess)
        state.transcriptionLanguage = nil
        state.transcriptionModel = "whisper/large-v3-turbo"
        XCTAssertEqual(state.routedRequiredModelIDs.first, "whisper/large-v3-turbo")
        let revision = state.catalogRevision
        state.modelCatalog = state.modelCatalog
        XCTAssertEqual(state.catalogRevision, revision + 1)
        _ = state.routedRequiredModelIDs
        XCTAssertEqual(state.routeMemo?.key.catalogRevision, revision + 1, "A new catalog routes again")
    }

    /// Transcript first (uxf-01): what transcribes is all a job needs to start, and all `canProcess` asks for; the summary
    /// model downloads last and is needed only to summarize here.
    func testBehaviorTheSummaryModelIsntNeededToTranscribe() throws {
        let state = try state()
        state.transcriptionModel = "parakeet/ultra"
        state.installedModels = ["parakeet/ultra", "community-1/offline"]
        XCTAssertTrue(state.canProcess, "Transcribes without the summary model")
        XCTAssertFalse(state.summarizesLocally)
        XCTAssertEqual(state.missingSelectedModels, [state.summaryModel])
        let job = state.makeJob(meetingID: UUID(), mode: .newAudio)
        XCTAssertEqual(job.transcribingModelIDs(hasUntranscribedAudio: true), ["parakeet/ultra", "community-1/offline"])
        XCTAssertEqual(job.requiredModelIDs(hasUntranscribedAudio: true), ["parakeet/ultra", "community-1/offline", state.summaryModel])
        XCTAssertEqual(state.makeJob(meetingID: UUID(), mode: .summaryOnly).transcribingModelIDs(hasUntranscribedAudio: true), [],
                       "A Summarize transcribes nothing")

        // Use the Cloud for a waiting summary rides on the job, and on the request it carries.
        let cloud = state.makeJob(meetingID: UUID(), mode: .summaryOnly, summarizesInCloud: true)
        XCTAssertTrue(cloud.summarizesInCloud)
        let request = ProcessingRequest(meetingID: cloud.meetingID, mode: .summaryOnly, requestedBy: .phone)
        XCTAssertTrue(cloud.carrying(request).summarizesInCloud)
        XCTAssertNil(cloud.carrying(request).withoutRequest.requestID)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(job), as: UTF8.self).contains("summaryInCloud"), "Stored only when chosen")
        XCTAssertEqual(try JSONDecoder().decode(ProcessingJob.self, from: JSONEncoder().encode(cloud)), cloud)
    }

    /// The catalog with a system transcription model on Apple Vision's engine, which every Mac has, standing in for the
    /// system's speech model, which a test host may not have (macOS 15, or no transcriber).
    private func catalogWithSystemSpeech() throws -> ModelCatalog {
        let json = """
            {"schemaVersion": 1, "minimumReaderVersion": 1, "families": [{"id": "system-speech", "name": "System Speech",
             "engine": "appleVision", "roles": ["transcription"],
             "variants": [{"id": "system", "name": "System Speech", "systemProvided": true, "revisions": []}]}]}
            """
        var manifest = try ModelCatalog.readBuiltInManifest().manifest
        manifest.families += try ModelManifestReader.read(Data(json.utf8)).manifest.families
        return ModelCatalog(builtIn: manifest)
    }

    /// Transcripts without a download: while the chosen model isn't here, the system's speech model transcribes, with
    /// no speakers until their models arrive and with them after; the choices still download what they chose, and the
    /// route switches back once the chosen model is here (the Upgrade offer then redoes the stand-in's transcripts).
    func testBehaviorTheSystemsSpeechModelStandsInWhileTheChosenModelDownloads() throws {
        let state = try state()
        XCTAssertEqual(AppState.Preference.transcriptionStandIn, TestDefaults.transcriptionStandInKey)
        XCTAssertFalse(state.transcriptionStandsIn, "Off in tests, so no models means none")
        let unset = makeTestDefaults("local.daybook.tests.standin")
        unset.removeObject(forKey: TestDefaults.transcriptionStandInKey)
        XCTAssertTrue(AppState(libraryURL: makeTemporaryFolder("DaybookStandIn"), defaults: unset).transcriptionStandsIn, "On unless set off")
        state.transcriptionStandsIn = true
        state.modelCatalog = try catalogWithSystemSpeech()
        state.transcriptionModel = "parakeet/ultra"
        state.transcriptionLanguage = "en"
        let standIn = "system-speech/system"
        state.installedModels = [standIn, state.summaryModel]
        XCTAssertTrue(state.canProcess, "Transcribes now, with nothing downloaded")
        XCTAssertEqual(state.routedTranscribingModelIDs, [standIn], "No speakers until their models are here")
        XCTAssertEqual(state.missingSelectedModels, ["parakeet/ultra", "community-1/offline"], "The chosen models still download")
        let job = state.makeJob(meetingID: UUID(), mode: .newAudio)
        XCTAssertEqual(job.transcriptionModelID, standIn)
        XCTAssertEqual(job.engineConfiguration.transcriptionLanguage, "en", "The language stays as routed")
        XCTAssertFalse(job.detectSpeakers)
        XCTAssertNil(job.revisions?[standIn], "A system model has no revision to freeze")
        XCTAssertEqual(job.transcribingModelIDs(hasUntranscribedAudio: true), [standIn])
        XCTAssertEqual(state.processingCapabilities.models?["transcription"], standIn, "What it transcribes with, for other devices")

        state.installedModels.insert("community-1/offline")
        XCTAssertEqual(state.routedTranscribingModelIDs, [standIn, "community-1/offline"], "Speakers once they're here")
        XCTAssertTrue(state.makeJob(meetingID: UUID(), mode: .newAudio).detectSpeakers)

        state.installedModels.insert("parakeet/ultra")
        XCTAssertEqual(state.routedTranscribingModelIDs, ["parakeet/ultra", "community-1/offline"], "The chosen model, once it's here")
        XCTAssertEqual(state.makeJob(meetingID: UUID(), mode: .newAudio).transcriptionModelID, "parakeet/ultra")
        XCTAssertTrue(state.missingSelectedModels.isEmpty)

        // Nothing to stand in: the job waits for the download, and "Download models to transcribe" is what's left.
        state.installedModels = [state.summaryModel]
        XCTAssertFalse(state.canProcess)
        XCTAssertEqual(state.routedTranscribingModelIDs, ["parakeet/ultra", "community-1/offline"])
        XCTAssertTrue(state.makeJob(meetingID: UUID(), mode: .newAudio).detectSpeakers, "Speakers asked for as before")
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

    // MARK: The library's language (xdev-settings-08)

    /// The language is the library's, not this Mac's: a job freezes the one it was queued with, a change routes the next
    /// job, and the model for other languages stays this Mac's preference.
    func testBehaviorAJobKeepsTheLibrarysLanguageItWasQueuedWith() throws {
        let state = try state()
        state.transcriptionModel = "parakeet/ultra"
        state.installedModels = ["parakeet/ultra", state.summaryModel, "community-1/offline"]
        state.transcriptionLanguage = "de"
        XCTAssertEqual(state.library.transcriptionLanguage, "de", "a library setting")
        XCTAssertNil(state.processingPreferences.transcriptionLanguage, "never this Mac's preference")
        let german = state.makeJob(meetingID: UUID(), mode: .newAudio)
        XCTAssertEqual(german.preferences.transcriptionLanguage, "de")
        XCTAssertEqual(state.routedSpeech.transcription.language, "de")

        state.transcriptionLanguage = "fr"
        XCTAssertEqual(state.routeMemo?.key.language, "de", "worked out for German")
        XCTAssertEqual(state.routedSpeech.transcription.language, "fr", "a change of language routes again")
        XCTAssertEqual(german.engineConfiguration.transcriptionLanguage, "de", "the queued job keeps its language")
        XCTAssertEqual(state.makeJob(meetingID: UUID(), mode: .newAudio).engineConfiguration.transcriptionLanguage, "fr")
        let restored = try JSONDecoder().decode(ProcessingJob.self, from: JSONEncoder().encode(german))
        XCTAssertEqual(restored.preferences.transcriptionLanguage, "de", "and across a relaunch")

        state.processingPreferences.otherLanguagesModelID = "whisper/small"
        state.transcriptionLanguage = "ja"
        XCTAssertEqual(state.makeJob(meetingID: UUID(), mode: .newAudio).transcriptionModelID, "whisper/small",
                       "this Mac's model for other languages")
    }

    /// A change on another device changes what this Mac transcribes with once it syncs, and what it offers other devices.
    func testBehaviorAnotherDevicesLanguageChangesWhatThisMacTranscribesWith() async throws {
        let root = makeTemporaryFolder("DaybookLanguageSync")
        roots.append(root)
        let cloud = root.appendingPathComponent("Cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let a = AppState(libraryURL: root.appendingPathComponent("MacA"), defaults: makeTestDefaults("local.daybook.tests.language.A"))
        let b = AppState(libraryURL: root.appendingPathComponent("MacB"), defaults: makeTestDefaults("local.daybook.tests.language.B"))
        defer { a.sync.disconnect(); b.sync.disconnect() }
        await a.initialize(); await b.initialize()
        // The test runs every pass itself; an edit's automatic pass would race it.
        a.sync.syncDebounce = nil; b.sync.syncDebounce = nil
        try a.sync.connect(to: cloud, monitorChanges: false)
        try b.sync.connect(to: cloud, monitorChanges: false)
        for state in [a, b] {
            state.transcriptionModel = "parakeet/ultra"
            state.processingPreferences.speakerModelID = "community-1/offline"
            state.installedModels = ["parakeet/ultra", state.summaryModel, "community-1/offline"]
        }
        XCTAssertEqual(b.makeJob(meetingID: UUID(), mode: .newAudio).transcriptionModelID, "parakeet/ultra")
        XCTAssertTrue(b.canProcess)

        a.transcriptionLanguage = "ja"
        await a.flush()
        await a.synchronizeLibrary(); await b.synchronizeLibrary()
        XCTAssertEqual(b.transcriptionLanguage, "ja")
        let job = b.makeJob(meetingID: UUID(), mode: .newAudio)
        XCTAssertEqual(job.transcriptionModelID, "whisper/large-v3-turbo", "Japanese goes to the model for other languages")
        XCTAssertEqual(job.engineConfiguration.transcriptionLanguage, "ja")
        XCTAssertFalse(b.canProcess, "Japanese needs Whisper downloaded here")
    }
}
