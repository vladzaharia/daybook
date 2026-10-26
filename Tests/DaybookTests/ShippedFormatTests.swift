import AVFoundation
import DaybookCore
@testable import DaybookDevices
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// Files that shipped versions of Daybook wrote, read by today's code the way the app reads them.
/// The fixtures (Fixtures/Shipped) were written by v0.1.0-preview's and v0.2.2's own code, so a field
/// renamed, retyped, or made required since then fails here; the README there says how to remake them.
/// Synthetic content only.
@MainActor
final class ShippedFormatTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    // MARK: Conversations and library settings

    func testAV010PreviewLibraryLoadsWithEveryFieldIntact() async throws {
        let (library, meeting) = try await loadLibrary("v0.1.0-preview", meeting: "0A1B2C3D-0000-4000-8000-000000000001")
        XCTAssertEqual(meeting.title, "Prototype planning")
        XCTAssertEqual(meeting.date, Date(timeIntervalSince1970: 1_792_500_000))
        XCTAssertEqual(meeting.updatedAt, Date(timeIntervalSince1970: 1_792_500_300))
        XCTAssertEqual(meeting.kind, .general)
        XCTAssertEqual(meeting.status, .ready)
        XCTAssertEqual(meeting.notes, "Agenda\nShip the prototype")
        XCTAssertEqual(meeting.timedNotes?.map(\.text), ["Agenda", "Ship the prototype"])
        XCTAssertEqual(meeting.timedNotes?.map(\.time), [nil, 12.5], "an untimed note stays untimed")
        XCTAssertEqual(meeting.folderID?.uuidString, "0A1B2C3D-0000-4000-8000-0000000000F1")
        XCTAssertEqual(meeting.tags, ["planning", "synthetic"])
        XCTAssertEqual(meeting.templateID, "general")

        XCTAssertEqual(meeting.tracks.map(\.source), [.microphone, .systemAudio, .soundcore])
        XCTAssertEqual(meeting.tracks.map(\.fileName), ["microphone.caf", "systemAudio.caf", "2026-10-20 Planning.m4a"])
        XCTAssertEqual(meeting.tracks.map(\.relativePath), ["Originals/microphone.caf", "Originals/systemAudio.caf",
                                                            "Originals/2026-10-20 Planning.m4a"])
        XCTAssertEqual(meeting.tracks.map(\.offset), [0, 0.125, nil], "a recorder with no known offset waits to be aligned")
        XCTAssertEqual(meeting.tracks.map(\.duration), [61.25, 60.5, 58.5])
        XCTAssertEqual(meeting.tracks[0].sha256, String(repeating: "a1", count: 32))
        XCTAssertNil(meeting.tracks[2].device, "no recorder identity before devices existed")

        let microphone = try XCTUnwrap(meeting.transcripts.first { $0.trackID == meeting.tracks[0].id })
        XCTAssertEqual(microphone.segments.map(\.text), ["Let's review the agenda."])
        XCTAssertEqual(microphone.segments[0].start, 0.5)
        XCTAssertEqual(microphone.segments[0].end, 2.25)
        XCTAssertEqual(microphone.segments[0].speakerID, "S1")
        XCTAssertEqual(microphone.words?.map(\.text), ["Let's", "review", "the", "agenda."])
        XCTAssertEqual(microphone.words?.map(\.start), [0.5, 0.75, 1.25, 1.5])
        XCTAssertEqual(microphone.words?.map(\.confidence), [0.91, 0.875, nil, 0.96875])
        XCTAssertEqual(microphone.modelID, "whisper-base", "results keep the catalog ID they were made with")
        XCTAssertEqual(microphone.knownOffset, 0)
        XCTAssertEqual(microphone.processingSettings?.parameters, ["language": "en", "temperature": "0"])
        XCTAssertNil(microphone.processingSettings?.model)
        XCTAssertEqual(meeting.unifiedTranscript.map(\.text), ["Let's review the agenda.", "We ship the prototype on Friday."])
        XCTAssertEqual(meeting.unifiedTranscript[1].provenance.map(\.trackID), [meeting.tracks[1].id, meeting.tracks[2].id])
        XCTAssertEqual(meeting.alignmentReports.map(\.method), [.reference, .provided, .anchors])
        XCTAssertEqual(meeting.alignmentReports[2].offset, 2.875)
        XCTAssertEqual(meeting.alignmentReports[2].rate, 1.0001220703125)

        let summary = try XCTUnwrap(meeting.summary)
        XCTAssertEqual(summary.title, "Prototype planning")
        XCTAssertEqual(summary.overview, "The team agreed to ship the prototype on Friday.")
        XCTAssertEqual(summary.sections.map(\.heading), ["Decisions"])
        XCTAssertNil(summary.sections[0].photoIDs)
        XCTAssertEqual(summary.actionItems.map(\.owner), ["Alex"])
        XCTAssertEqual(summary.actionItems.map(\.completed), [true])
        XCTAssertEqual(summary.modelID, "qwen-7b")
        XCTAssertEqual(meeting.highlights.map(\.time), [4.5, 1.5])
        XCTAssertEqual(meeting.highlights.map(\.text), ["Decision", ""])
        XCTAssertEqual(meeting.highlights.map(\.trackID), [nil, meeting.tracks[2].id])
        XCTAssertEqual(meeting.highlights.map(\.duration), [nil, 5])
        XCTAssertEqual(meeting.revisions.map(\.field), ["notes"])
        XCTAssertEqual(meeting.speakers.map(\.name), ["Alex", "Speaker 2"])
        XCTAssertEqual(meeting.speakers[0].embedding, [0.125, -0.5, 0.25])
        XCTAssertEqual(meeting.speakerMatches?.map(\.status), [.belowThreshold])
        XCTAssertNil(meeting.photos)

        XCTAssertEqual(library.metadata.folders.compactMap(\.value).map(\.name), ["Projects"])
        XCTAssertEqual(library.metadata.folders.filter { $0.value == nil }.map(\.id), ["0A1B2C3D-0000-4000-8000-0000000000F2"],
                       "a deleted folder stays deleted")
        XCTAssertEqual(library.metadata.templates.compactMap(\.value).map(\.name), ["Design review"])
        XCTAssertEqual(library.glossary.map(\.term), ["Daybook"])
        XCTAssertEqual(library.glossary.first?.approved, true)
        XCTAssertNil(library.metadata.recorders)
    }

    func testAV022LibraryLoadsWithEveryFieldIntact() async throws {
        let (library, meeting) = try await loadLibrary("v0.2.2", meeting: "0B2C3D4E-0000-4000-8000-000000000001")
        XCTAssertEqual(meeting.title, "Prototype planning")
        XCTAssertEqual(meeting.date, Date(timeIntervalSince1970: 1_792_600_000))
        XCTAssertEqual(meeting.placement, .work)
        XCTAssertEqual(meeting.timedNotes?.map(\.time), [nil, 12.5])

        XCTAssertEqual(meeting.tracks.map(\.fileName), ["microphone.caf", "systemAudio.caf", "microphone.echo-cancelled.caf",
                                                        "Soundcore-1792600000.wav", "iPhone.m4a"])
        let derived = meeting.tracks[2]
        XCTAssertEqual(derived.derivedFrom, meeting.tracks[0].id)
        XCTAssertEqual(derived.processing, "echo-cancelled")
        XCTAssertEqual(derived.capture?.echoRemoval?.outcome, .applied)
        XCTAssertEqual(derived.capture?.echoRemoval?.echoReturnLossEnhancementDB, 18.5)
        XCTAssertEqual(meeting.tracks[0].capture?.clockRate, 48_000.5)
        XCTAssertEqual(meeting.tracks[0].capture?.peerClocks?.first?.offset, 0.375)
        XCTAssertEqual(meeting.tracks[0].startedAt, Date(timeIntervalSince1970: 1_792_600_000.25))
        XCTAssertEqual(meeting.tracks[1].capture?.method, "process-tap")
        XCTAssertEqual(meeting.tracks[1].capture?.capturedApps, ["us.zoom.xos"])
        let recorder = meeting.tracks[3]
        XCTAssertEqual(recorder.device, DeviceRecordingIdentity(kind: "soundcore.work", serial: "D3200SIM0000001", recordingID: "1792600000"))
        XCTAssertEqual(recorder.alignment?.method, .audio)
        XCTAssertEqual(recorder.alignment?.offset, 2.875)
        XCTAssertEqual(recorder.alignment?.referenceTrackID, meeting.tracks[0].id)
        XCTAssertEqual(recorder.alignment?.audioChecked, true)
        XCTAssertEqual(meeting.tracks[4].alignment?.method, .pending)
        XCTAssertEqual(meeting.tracks[4].alignment?.heldNoteIDs, [meeting.timedNotes?[1].id].compactMap { $0 })

        let microphone = try XCTUnwrap(meeting.transcripts.first { $0.trackID == derived.id }, "the derived track is the one transcribed")
        XCTAssertEqual(microphone.words?.map(\.end), [0.75, 1.25, 1.5, 2.25])
        XCTAssertEqual(microphone.processingSettings?.model?.variantKey, "whisper/base")
        XCTAssertEqual(microphone.processingSettings?.model?.revision, "0f63a7800b00dd0226abd051b906c246e1907482")
        XCTAssertEqual(meeting.unifiedTranscript[0].provenance.first?.wordIndices, [0, 1, 2, 3])
        XCTAssertEqual(meeting.summary?.processingSettings?.model?.family, "gemma-4")
        XCTAssertEqual(meeting.summary?.actionItems.map(\.text), ["Ship the prototype"])
        XCTAssertEqual(meeting.highlights.map(\.trackID), [nil, recorder.id])

        XCTAssertEqual(meeting.companions?.map(\.state), [.attached])
        XCTAssertEqual(meeting.companions?.first?.clock?.offset, 3)
        XCTAssertEqual(meeting.companions?.first?.trackID, recorder.id)
        XCTAssertEqual(meeting.sourceSuggestions?.first?.reason, .severalConversations)
        XCTAssertEqual(meeting.sourceSuggestions?.first?.clockOffsets?.values.first, -1_800)
        XCTAssertEqual(meeting.audioAlignments?.first?.explanation, "Too little shared speech.")
        XCTAssertNil(meeting.audioAlignments?.first?.alignment)
        XCTAssertEqual(meeting.fusionSummary?.sources.map(\.role), [.microphone, .room])
        XCTAssertEqual(meeting.fusionSummary?.ownerSpeakerID, "owner")
        XCTAssertEqual(meeting.fusionSummary?.speakerMappings.first?.reason, .sharedSpeech)
        let request = try XCTUnwrap(meeting.processingRequests?.first)
        XCTAssertEqual(request.mode, .summaryOnly)
        XCTAssertEqual(request.requestedBy.name, "Alex’s iPhone")
        XCTAssertEqual(request.claim?.stage, .summarizing)
        XCTAssertEqual(request.outcome?.result, .completed)

        XCTAssertEqual(library.metadata.recorderOwners.map(\.ownerName), ["Studio Mac"])
        XCTAssertEqual(library.metadata.recorderHandoffs.map(\.phase), [.released])
        XCTAssertEqual(library.metadata.recorderHandoffs.first?.pendingImports?.map(\.recordingID), ["1792603600"])
        XCTAssertEqual(library.metadata.recorderHandoffs.first?.importedRecordingIDs, ["1792600000"])
        XCTAssertEqual(library.metadata.templates.compactMap(\.value).map(\.name), ["Design review"])
        XCTAssertEqual(library.glossary.map(\.term), ["Daybook"])
    }

    // MARK: Capture sidecars

    func testAFinishedCaptureFromEachShippedVersionIsReadFromItsResult() throws {
        for version in Self.versions {
            let directory = try copy(version, "Capture")
            // The echo-cancelled file v0.2.2 made; recovery keeps derived tracks whose files exist.
            FileManager.default.createFile(atPath: directory.appendingPathComponent("microphone.echo-cancelled.caf").path, contents: Data())
            let result = try XCTUnwrap(CaptureRecovery.recover(in: directory), version)
            let started = version == "v0.2.2" ? 1_792_600_000.0 : 1_792_500_000.0
            XCTAssertEqual(result.startedAt, Date(timeIntervalSince1970: started), version)
            XCTAssertEqual(result.endedAt, Date(timeIntervalSince1970: started + 61.5), version)
            XCTAssertEqual(result.directory, directory, version)
            XCTAssertEqual(result.tracks.map(\.role), [.microphone, .systemAudio], version)
            XCTAssertEqual(result.tracks.map(\.url), [directory.appendingPathComponent("microphone.caf"),
                                                      directory.appendingPathComponent("systemAudio.caf")], "rebased onto where it is now")
            XCTAssertEqual(result.tracks.map(\.offsetSeconds), [0.25, 0.5], version)
            XCTAssertEqual(result.tracks.map(\.startedAt), [Date(timeIntervalSince1970: started + 0.25),
                                                            Date(timeIntervalSince1970: started + 0.5)], version)
            XCTAssertEqual(result.tracks.map(\.channelCount), [1, 2], version)
            XCTAssertEqual(result.tracks.map(\.frameCount), [2_940_000, 2_904_000], version)
            XCTAssertEqual(result.tracks[0].duration, 61.25, version)
            XCTAssertEqual(result.warnings, ["No system audio was received for the first second."], version)
            try assertEveryFieldSurvives(directory.appendingPathComponent("capture-result.json"), as: CaptureResult.self,
                                         decoder: CaptureJSON.decoder(), encoder: CaptureJSON.encoder())
            try assertEveryFieldSurvives(directory.appendingPathComponent("capture-session.json"), as: CaptureSessionManifest.self,
                                         decoder: CaptureJSON.decoder(), encoder: CaptureJSON.encoder())

            if version == "v0.2.2" {
                XCTAssertEqual(result.systemAudio?.method, .processTap)
                XCTAssertEqual(result.systemAudio?.capturedApps, ["us.zoom.xos"])
                XCTAssertEqual(result.outputRoutes?.map(\.route.kind), [.speakers, .headphones])
                XCTAssertEqual(result.outputRouteSummary, .mixed)
                XCTAssertEqual(result.echoRemoval?.outcome, .applied)
                XCTAssertEqual(result.derivedTracks?.map(\.url), [directory.appendingPathComponent("microphone.echo-cancelled.caf")])
                XCTAssertEqual(result.derivedTracks?.first?.processing, "echo-cancelled")
                XCTAssertEqual(result.tracks[0].clockAnchors?.count, 3)
                XCTAssertEqual(result.tracks[0].clockAnchors?.last?.resync, true)
                XCTAssertEqual(result.tracks[0].notes, ["Switched to MacBook Pro Microphone at 12.5 s."])
                let manifest = try CaptureJSON.decoder().decode(CaptureSessionManifest.self,
                                                                from: Data(contentsOf: directory.appendingPathComponent("capture-session.json")))
                XCTAssertEqual(manifest.callApp?.bundleID, "us.zoom.xos")
            } else {
                XCTAssertNil(result.systemAudio)
                XCTAssertNil(result.derivedTracks)
                XCTAssertNil(result.tracks[0].clockAnchors)
            }
        }
    }

    func testAnInterruptedCaptureFromEachShippedVersionKeepsItsTrackTiming() throws {
        for version in Self.versions {
            let directory = try copy(version, "Capture")
            try FileManager.default.removeItem(at: directory.appendingPathComponent("capture-result.json"))
            // The audio as a crash left it: shorter than the last sidecar said.
            try writeTone(directory.appendingPathComponent("microphone.caf"), channels: 1, frames: 24_000)
            try writeTone(directory.appendingPathComponent("systemAudio.caf"), channels: 2, frames: 12_000)
            for sidecar in ["microphone.json", "systemAudio.json"] {
                try assertEveryFieldSurvives(directory.appendingPathComponent(sidecar), as: CapturedAudioTrack.self,
                                             decoder: CaptureJSON.decoder(), encoder: CaptureJSON.encoder())
            }

            let result = try XCTUnwrap(CaptureRecovery.recover(in: directory), version)
            let started = version == "v0.2.2" ? 1_792_600_000.0 : 1_792_500_000.0
            XCTAssertEqual(result.id.uuidString.suffix(4), "00E1", version)
            XCTAssertEqual(result.startedAt, Date(timeIntervalSince1970: started), version)
            XCTAssertEqual(result.warnings, ["Recovered an interrupted recording. The final seconds may be incomplete."],
                           "\(version): the sidecars were read, so no start time is approximate")
            XCTAssertEqual(result.tracks.map(\.role), [.microphone, .systemAudio], version)
            XCTAssertEqual(result.tracks.map(\.offsetSeconds), [0.25, 0.5], version)
            XCTAssertEqual(result.tracks.map(\.firstSampleHostTimeSeconds),
                           version == "v0.2.2" ? [91_234.75, 91_235] : [81_234.75, 81_235], version)
            XCTAssertEqual(result.tracks.map(\.frameCount), [24_000, 12_000], "\(version): the audio file is authoritative")
            XCTAssertEqual(result.tracks.map(\.channelCount), [1, 2], version)
            XCTAssertEqual(result.endedAt, Date(timeIntervalSince1970: started + 0.25 + 0.5), version)
            XCTAssertEqual(result.tracks[0].clockAnchors?.count, version == "v0.2.2" ? 3 : nil, version)
        }
    }

    // MARK: Stored preferences

    func testV010PreviewPreferencesBecomeSelectionsAndItsImportFolderBecomesADevice() throws {
        let (defaults, values) = try loadDefaults("v0.1.0-preview")
        // The folder's bookmark is machine-specific, so the fixture leaves it out; any bookmark moves as is.
        let folder = try temporaryRoot()
        let bookmark = try folder.bookmarkData()
        defaults.set(bookmark, forKey: "importFolderBookmark")

        let state = AppState(libraryURL: try temporaryRoot(), defaults: defaults)
        XCTAssertEqual(state.transcriptionModel, "whisper/small")
        XCTAssertEqual(state.summaryModel, "qwen2.5/3b-4bit")
        XCTAssertEqual(state.modelSelections[.diarization], "sortformer-2.1/fp16")
        XCTAssertEqual(state.processingPreferences.speakerModelID, "sortformer-2.1/fp16")
        XCTAssertEqual(state.processingPreferences.speakerOptions.quality, .accurate)
        XCTAssertEqual(state.processingPreferences.speakerOptions.expectedSpeakerCount, 3)
        XCTAssertFalse(state.processingPreferences.matchSpeakersAcrossSources)
        XCTAssertEqual(state.processingPreferences.speakerMatchThreshold, 0.875)
        XCTAssertEqual(state.processingPreferences.speakerMatchMargin, 0.0625)
        XCTAssertNil(state.processingPreferences.transcriptionLanguage)
        XCTAssertTrue(state.automaticRecording)
        XCTAssertFalse(state.includeComputerAudio)
        XCTAssertFalse(state.processSyncedAudio)
        XCTAssertTrue(state.detectSpeakers)
        XCTAssertEqual(defaults.string(forKey: "transcriptionModel"), "whisper-small", "the old keys stay for an older build")
        let stored = try JSONDecoder().decode(ModelSelections.self, from: XCTUnwrap(defaults.data(forKey: "modelSelections")))
        XCTAssertEqual(stored, state.modelSelections)
        try assertEveryFieldSurvives(XCTUnwrap(values["processingPreferences"] as? Data), as: ProcessingPreferences.self,
                                     ignoring: ["speakerModelID"]) // migrated to a variant key, checked above

        // v0.1.0 imported the folder as Soundcore recordings; it becomes that device's files method,
        // and the files it imported stay imported.
        XCTAssertEqual(state.devices.devices.map(\.kindID), [SoundcoreWorkIntegration.id])
        let device = try XCTUnwrap(state.devices.devices.first)
        let files = DeviceStorage(defaults: defaults, prefix: "device.\(device.id).files.")
        XCTAssertEqual(files.data(ImportFolderWatcher.Keys.bookmark), bookmark)
        XCTAssertEqual(files.strings(ImportFolderWatcher.Keys.completed),
                       [ImportFolderWatcher.recordingID(name: "2026-10-20 Planning.m4a", size: 482_113)])
        XCTAssertNil(defaults.object(forKey: "importedFileFingerprints"), "moved, not copied")
        XCTAssertNil(defaults.object(forKey: "importFolderBookmark"))
    }

    func testV022SelectionsPreferencesAndConfiguredDevicesReadBack() throws {
        let (defaults, values) = try loadDefaults("v0.2.2")
        let state = AppState(libraryURL: try temporaryRoot(), defaults: defaults)
        XCTAssertEqual(state.modelSelections[.transcription], "parakeet/ultra")
        XCTAssertEqual(state.modelSelections[.diarization], "community-1/offline")
        XCTAssertEqual(state.modelSelections[.speakerEmbedding], "community-1/offline")
        XCTAssertEqual(state.modelSelections[.summarization], "gemma-4/e4b-4bit")
        XCTAssertEqual(state.modelSelections[.smallTasks], "apple-foundation-models/system")
        XCTAssertEqual(state.modelSelections[.imageDescription], ModelRecommendations.initialSelections()[.imageDescription],
                       "the photo role, which came later, joins once")
        XCTAssertTrue(defaults.bool(forKey: "modelSelections.imageDescriptionAdded"))
        XCTAssertEqual(state.processingPreferences.speakerModelID, "community-1/offline")
        XCTAssertEqual(state.processingPreferences.speakerOptions.quality, .accurate)
        XCTAssertEqual(state.processingPreferences.speakerOptions.expectedSpeakerCount, 3)
        XCTAssertEqual(state.processingPreferences.transcriptionLanguage, "de")
        XCTAssertEqual(state.processingPreferences.otherLanguagesModelID, "whisper/small")
        XCTAssertFalse(state.processingPreferences.matchSpeakersAcrossSources)
        XCTAssertFalse(state.includeComputerAudio)
        XCTAssertEqual(state.readingScale, 1.25)
        try assertEveryFieldSurvives(XCTUnwrap(values["modelSelections"] as? Data), as: ModelSelections.self)
        try assertEveryFieldSurvives(XCTUnwrap(values["processingPreferences"] as? Data), as: ProcessingPreferences.self)

        let devices = state.devices.devices
        XCTAssertEqual(devices.map(\.id), ["0B2C3D4E-0000-4000-8000-0000000000D9", "0B2C3D4E-0000-4000-8000-0000000000DB",
                                           "5D6E7F80-0000-4000-8000-00000000000B"])
        XCTAssertEqual(devices.map(\.kindID), [SoundcoreWorkIntegration.id, OtherRecorderIntegration.id, DaybookPhoneIntegration.id])
        XCTAssertEqual(devices.map(\.name), ["Desk recorder", "Other Recorder", "Alex’s iPhone"])
        XCTAssertEqual(devices.map(\.addedAt), [1_792_400_000, 1_792_410_000, 1_792_430_000].map(Date.init(timeIntervalSince1970:)))
        XCTAssertEqual(devices[1].automaticImportsSince, Date(timeIntervalSince1970: 1_792_420_000))
        XCTAssertEqual(devices.map(\.importsAutomatically), [false, true, true])
        XCTAssertEqual(devices.map(\.alsoRecordsWithMac), [false, nil, nil])
        XCTAssertEqual(devices[0].disabledMethods, [.files])
        try assertEveryFieldSurvives(XCTUnwrap(values[DeviceHub.storageKey] as? Data), as: [ConfiguredDevice].self)

        let direct = DeviceStorage(defaults: defaults, prefix: "device.\(devices[0].id).direct.")
        let snapshot = try XCTUnwrap(direct.decode(SoundcoreSnapshot.self, "recorder"))
        XCTAssertEqual(snapshot.serial, "D3200SIM0000001")
        XCTAssertEqual(snapshot.info?.microphoneBattery, 80)
        XCTAssertEqual(snapshot.info?.freeBytes, 6_100_000_000)
        XCTAssertEqual(snapshot.lastConnectedAt, Date(timeIntervalSince1970: 1_792_600_600))
        XCTAssertEqual(snapshot.recordings.map(\.id), [1_792_600_000, 1_792_603_600])
        XCTAssertEqual(snapshot.recordings.map(\.endTimestamp), [1_792_600_058, nil])
        try assertEveryFieldSurvives(XCTUnwrap(direct.data("recorder")), as: SoundcoreSnapshot.self)
        let files = DeviceStorage(defaults: defaults, prefix: "device.\(devices[1].id).files.")
        XCTAssertEqual(files.strings(ImportFolderWatcher.Keys.completed), ["file:2026-10-20 Planning.m4a|482113", "file:notes.m4a|20480"],
                       "name-and-size records wait to be matched to a file's digest")
        XCTAssertEqual(files.date(ImportFolderWatcher.Keys.lastImport), Date(timeIntervalSince1970: 1_792_500_150))
    }

    // MARK: Harness

    private static let versions = ["v0.1.0-preview", "v0.2.2"]

    private func fixture(_ version: String, _ path: String) throws -> URL {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil), "the fixtures are a resource of this target")
        let url = root.appendingPathComponent("Shipped/\(version)/\(path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        return url
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookShipped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    /// A writable copy of a fixture folder.
    private func copy(_ version: String, _ path: String) throws -> URL {
        let destination = try temporaryRoot().appendingPathComponent(path, isDirectory: true)
        try FileManager.default.copyItem(at: fixture(version, path), to: destination)
        return destination
    }

    /// Opens a copy of the version's library the way the app does, and returns it with one conversation,
    /// after checking that the conversation and the library settings lose nothing on today's encoders.
    private func loadLibrary(_ version: String, meeting id: String) async throws -> (LibraryController, Meeting) {
        let root = try copy(version, "Library")
        let meetingFile = root.appendingPathComponent("Meetings/\(id)/meeting.json")
        try assertEveryFieldSurvives(meetingFile, as: Meeting.self, encoder: Self.storeEncoder)
        try assertEveryFieldSurvives(root.appendingPathComponent("library.json"), as: LibraryMetadata.self, encoder: Self.storeEncoder)
        try assertEveryFieldSurvives(root.appendingPathComponent("glossary.json"), as: [GlossaryTerm].self, encoder: Self.storeEncoder)

        let library = LibraryController(rootURL: root, sync: nil)
        try await library.load()
        let meeting = try XCTUnwrap(library.meetings.first { $0.id.uuidString == id }, "\(version): the conversation loads")
        XCTAssertEqual(library.meetings.count, 1)

        // Saved by today's store and read again, nothing changes.
        let store = try MeetingStore(rootURL: root)
        try await store.save(meeting)
        let reloaded = try await store.load(meeting.id)
        XCTAssertEqual(reloaded, meeting, "\(version): a save and reload with today's store changes nothing")
        return (library, meeting)
    }

    /// The fixture's UserDefaults values in a suite of this test's own, and the values themselves.
    private func loadDefaults(_ version: String) throws -> (UserDefaults, [String: Any]) {
        let data = try Data(contentsOf: fixture(version, "defaults.plist"))
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let defaults = makeTestDefaults("local.daybook.tests.shipped")
        for (key, value) in values { defaults.set(value, forKey: key) }
        return (defaults, values)
    }

    /// MeetingStore's, GlossaryStore's, and LibraryController's encoder (default date strategy).
    private static var storeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func assertEveryFieldSurvives<T: Codable>(_ url: URL, as type: T.Type, decoder: JSONDecoder = JSONDecoder(),
                                                      encoder: JSONEncoder = JSONEncoder(), ignoring: Set<String> = [],
                                                      file: StaticString = #filePath, line: UInt = #line) throws {
        try assertEveryFieldSurvives(Data(contentsOf: url), as: type, decoder: decoder, encoder: encoder, ignoring: ignoring,
                                     name: url.lastPathComponent, file: file, line: line)
    }

    /// Decodes what an old version wrote with today's type, encodes it again, decodes that, and checks
    /// that every value the old file had is still there under the same key, and that the second decode
    /// equals the first. A field that was renamed, retyped, or dropped fails here.
    private func assertEveryFieldSurvives<T: Codable>(_ data: Data, as type: T.Type, decoder: JSONDecoder = JSONDecoder(),
                                                      encoder: JSONEncoder = JSONEncoder(), ignoring: Set<String> = [],
                                                      name: String = "\(T.self)", file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try decoder.decode(T.self, from: data)
        let again = try encoder.encode(value)
        let old = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let new = try JSONSerialization.jsonObject(with: again, options: [.fragmentsAllowed])
        var missing: [String] = []
        Self.collectMissing(old, in: new, path: name, ignoring: ignoring, into: &missing)
        XCTAssertEqual(missing, [], "Values today's \(T.self) drops or changes", file: file, line: line)
        if let value = value as? any Equatable {
            XCTAssertTrue(Self.isEqual(value, try decoder.decode(T.self, from: again)), "\(name) round trip", file: file, line: line)
        }
    }

    private static func isEqual<E: Equatable>(_ lhs: E, _ rhs: Any) -> Bool { (rhs as? E) == lhs }

    private static func collectMissing(_ old: Any, in new: Any, path: String, ignoring: Set<String>, into missing: inout [String]) {
        switch old {
        case let object as [String: Any]:
            guard let newObject = new as? [String: Any] else { missing.append("\(path): not an object"); return }
            for (key, value) in object where !ignoring.contains(key) {
                guard let newValue = newObject[key] else { missing.append("\(path).\(key): dropped"); continue }
                collectMissing(value, in: newValue, path: "\(path).\(key)", ignoring: ignoring, into: &missing)
            }
        case let array as [Any]:
            guard let newArray = new as? [Any], newArray.count == array.count else { missing.append("\(path): different length"); return }
            for (index, value) in array.enumerated() {
                collectMissing(value, in: newArray[index], path: "\(path)[\(index)]", ignoring: ignoring, into: &missing)
            }
        default:
            if !((old as AnyObject).isEqual(new)) { missing.append("\(path): \(old) became \(new)") }
        }
    }

    private func writeTone(_ url: URL, channels: AVAudioChannelCount, frames: AVAudioFrameCount) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for index in 0..<Int(frames) { buffer.floatChannelData![channel][index] = sin(Float(index) * 2 * .pi * 440 / 48_000) * 0.25 }
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }
}
