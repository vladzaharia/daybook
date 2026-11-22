import AVFoundation
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookCore
@testable import DaybookKit

/// A superseded original's object leaving iCloud through the library (LibrarySyncSuperseded.swift): the library tells
/// the compacting Mac which conversations' originals voice profiles still need before every pass, and deletes what the
/// pass found due right after it, under the library's lock, asking that again.
@MainActor
final class SupersededOriginalsLibraryTests: XCTestCase {
    private var root: URL!
    private let speaker = "run:1"
    private let day: TimeInterval = 86_400

    override func setUp() async throws {
        root = makeTemporaryFolder("DaybookSupersededLibrary")
    }

    private func library(cloud: URL) async throws -> LibraryController {
        let local = root.appendingPathComponent("Mac", isDirectory: true)
        let sync = LibrarySyncController(localRoot: local, defaults: makeTestDefaults("daybook.superseded.mac"))
        sync.replica = SyncReplicaConfiguration(audioPolicy: .eager, device: SyncDeviceIdentity(deviceClass: .mac, displayName: "Mac", canProcess: true),
                                                compaction: .eager)
        try sync.connect(to: cloud, monitorChanges: false)
        let library = LibraryController(rootURL: local, sync: sync)
        try await library.load()
        // The Mac's speaker profiles, settled before each pass (a Mac that may delete without them deletes nothing).
        let coordinator = SpeakerProfileCoordinator(library: library, options: { SpeakerProfileOptions(recognizes: false) })
        library.speakerProfileCoordinator = coordinator
        coordinators.append(coordinator)
        return library
    }

    private var last: Date?
    private var coordinators: [SpeakerProfileCoordinator] = []

    /// A pass as the app runs it, with the engine's clocks at `now`; and the passes every few hours before it that a running
    /// Mac makes (a day is a day watched).
    private func pass(_ library: LibraryController, at now: Date, file: StaticString = #filePath, line: UInt = #line) async throws {
        if let last, now.timeIntervalSince(last) > 6 * 3600 {
            var step = last.addingTimeInterval(6 * 3600)
            while now.timeIntervalSince(step) > 1 { try await single(library, at: step, file: file, line: line); step = step.addingTimeInterval(6 * 3600) }
        }
        try await single(library, at: now, file: file, line: line)
    }

    private func single(_ library: LibraryController, at now: Date, acknowledged: Bool = true, file: StaticString = #filePath,
                        line: UInt = #line) async throws {
        last = now
        let engine = try XCTUnwrap(library.sync?.engine)
        await engine.setCompactionClock { now }
        await engine.setContinuousClock { SyncClockMark(boot: "test", seconds: now.timeIntervalSince1970) }
        await engine.setPresenceClock { now }
        await library.flush()
        for coordinator in coordinators where library.speakerProfileCoordinator === coordinator { await coordinator.refresh() }
        let applied = await library.synchronize()
        XCTAssertEqual(applied?.acknowledged ?? false, acknowledged, "the sync pass ran and was acknowledged", file: file, line: line)
    }

    private func recording() throws -> URL {
        let url = root.appendingPathComponent("microphone.caf")
        let rate = 48_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = Int(rate * 8)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count {
            let t = Double(index) / rate
            let burst = sin(2 * .pi * 1.3 * t + 1) > -0.3 ? 1.0 : 0.0
            buffer.floatChannelData![0][index] = Float(0.2 * burst * (sin(2 * .pi * 160 * t) + 0.4 * sin(2 * .pi * 480 * t)))
        }
        try file.write(from: buffer)
        return url
    }

    /// A single Mac's library with a recording compressed, nothing holding its original: listed and acknowledged, and due a
    /// day after the moment returned.
    private func listed() async throws -> (library: LibraryController, object: URL, acknowledged: Date, meeting: UUID) {
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let library = try await library(cloud: cloud)
        let id = library.newMeeting(title: "Planning")
        await library.acquireLock()
        let ingested = try await library.ingest(try recording(), into: id, provenance: .file(source: .microphone))
        library.releaseLock()
        let track = try XCTUnwrap(ingested.track)
        try await library.flushDurably()
        var now = Date()
        try await pass(library, at: now)
        let listener = RecordingCompressionListener(model: "parakeet/test", isDeterministic: true) { _, spans in
            spans.map { _ in (0..<40).map { "word\($0)" }.joined(separator: " ") }
        }
        let compressed = await library.compressRecordings([track.id], in: id, device: library.sync?.deviceID, listener: listener)
        XCTAssertEqual(compressed, [track.id])
        for _ in 0..<8 {
            now = now.addingTimeInterval(60)
            try await pass(library, at: now)
            if let since = await library.sync?.engine?.supersededState().objects[track.sha256]?.acknowledgedSince {
                return (library, cloud.appendingPathComponent("Blobs/\(track.sha256)"), since, id)
            }
        }
        struct NeverListed: Error {}
        XCTFail("the original was never listed")
        throw NeverListed()
    }

    private func notice(_ library: LibraryController) async throws -> SupersededRecord? {
        let engine = try XCTUnwrap(library.sync?.engine)
        let deviceID = await engine.deviceID
        let url = root.appendingPathComponent("Cloud/Superseded/\(SupersededRecord.fileName(for: deviceID))")
        return FileManager.default.fileExists(atPath: url.path) ? SupersededRecord.decode(try Data(contentsOf: url)) : nil
    }

    /// What the library says keeps an original whose day is up: Never, settings a newer Daybook wrote that this version
    /// skipped, a setting or a voiceprint or profile in a shape it can't read (nothing is listed); and settings that aren't
    /// the library's as sync last delivered them (nothing comes due, the wait goes on).
    func testBehaviorTheLibrarysSettingsKeepItWhenTheyMust() async throws {
        let (library, object, since, _) = try await listed()
        try await pass(library, at: since.addingTimeInterval(day - 60))
        var now = since.addingTimeInterval(day + 60)
        func newer<Value: Codable>(_ type: Value.Type) throws -> LibraryValue<Value> {
            try JSONDecoder().decode(LibraryValue<Value>.self, from: Data(#"{"id":"new","value":{"newerShape":true},"modifiedAt":0}"#.utf8))
        }
        let stops: [(String, () throws -> Void, () -> Void)] = [
            ("Never", { library.setRecordingCompression(.never) }, { library.setRecordingCompression(.after30Days) }),
            ("newer settings skipped", { library.newerSettingsSkipped = true }, {}),
            ("a folder it can't read", { let value = try newer(LibraryFolder.self); library.updateMetadata { $0.folders.append(value) } },
             { library.updateMetadata { $0.folders.removeAll { $0.id == "new" } } }),
            ("a voiceprint it can't read", { let value = try newer(Voiceprint.self); library.updateMetadata { $0.voiceprints = [value] } },
             { library.updateMetadata { $0.voiceprints = [] } }),
            ("a profile it can't read", { let value = try newer(SpeakerProfile.self); library.updateMetadata { $0.speakerProfiles = [value] } },
             { library.updateMetadata { $0.speakerProfiles = [] } }),
        ]
        for (name, stop, undo) in stops {
            try stop()
            try await single(library, at: now)
            XCTAssertTrue(FileManager.default.fileExists(atPath: object.path), name)
            let listing = try await notice(library)
            XCTAssertEqual(listing?.objects, [], "\(name): listed no more")
            let voice = await library.sync?.engine?.originalsHeldForVoice
            XCTAssertNil(voice.map(\.held), "\(name): every one held, the sealer's included")
            undo()
            // Listed again from the start, a day watched from then.
            for _ in 0..<3 { now = now.addingTimeInterval(60); try await single(library, at: now) }
            let state = await library.sync?.engine?.supersededState()
            let wait = try XCTUnwrap(state?.objects.first?.value, name)
            try await pass(library, at: try XCTUnwrap(wait.acknowledgedSince).addingTimeInterval(day - 60))
            now = try XCTUnwrap(wait.acknowledgedSince).addingTimeInterval(day + 60)
        }
        // Settings not the library's as sync last delivered them: the wait goes on, nothing comes due on that pass.
        library.settingsAppliedFromSync = nil
        let before = await library.sync?.engine?.supersededState().objects.first?.value
        try await single(library, at: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path), "settings not current")
        let after = await library.sync?.engine?.supersededState().objects.first?.value
        XCTAssertEqual(after?.since, before?.since)
        try await single(library, at: now.addingTimeInterval(60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: object.path))
    }

    /// Not while a name may not be a voiceprint yet: right before deleting, the library asks the Mac's speaker-profile
    /// coordinator, which hasn't settled since it started, or since a name was given; and a conversation it leaves alone
    /// for now (being processed) holds its originals.
    func testBehaviorANameNotYetAVoiceprintKeepsIt() async throws {
        let (library, object, since, id) = try await listed()
        try await pass(library, at: since.addingTimeInterval(day - 60))
        var skipped: Set<UUID> = []
        let coordinator = SpeakerProfileCoordinator(library: library, options: { .init() }, skipping: { skipped })
        coordinator.delay = .seconds(3_600)
        coordinator.start()
        defer { coordinator.stop() }
        var now = since.addingTimeInterval(day + 60)
        try await single(library, at: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path), "not settled since it started")
        await coordinator.refresh()
        library.update(id) { $0.speakers = [Speaker(id: "run:1", name: "Vlad")] }
        now = now.addingTimeInterval(60)
        try await single(library, at: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path), "a name given since it last settled")
        skipped = [id]
        await coordinator.refresh()
        // The profile that name taught goes out first (a pass bringing settings judges nothing), then: held.
        for _ in 0..<2 {
            now = now.addingTimeInterval(60)
            try await single(library, at: now)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path), "left alone while it's processed")
        skipped = []
        await coordinator.refresh()
        now = now.addingTimeInterval(60)
        try await single(library, at: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: object.path))
    }

    /// A speaker named after its conversation was compressed, found without a voice (an older speaker model): its profile
    /// learns from it once it's given one, and the clip of its speech is cut from the original, so the original stays in
    /// iCloud past its day; once the voice is given and the clip is in iCloud, it goes.
    func testBehaviorASpeakerNamedBeforeItsVoiceKeepsTheOriginal() async throws {
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let library = try await library(cloud: cloud)
        let id = library.newMeeting(title: "Older")
        await library.acquireLock()
        let ingested = try await library.ingest(try recording(), into: id, provenance: .file(source: .microphone))
        library.releaseLock()
        let track = try XCTUnwrap(ingested.track)
        let speaker = speaker
        library.update(id) { meeting in
            meeting.transcripts = [TrackTranscript(trackID: track.id, segments: [
                TranscriptSegment(trackID: track.id, start: 0.5, end: 7.5, text: "hello there", speakerID: speaker)])]
            meeting.speakers = [Speaker(id: speaker, name: "Speaker 1", sourceTrackID: track.id)]
        }
        try await library.flushDurably()
        var now = Date()
        try await pass(library, at: now)
        let listener = RecordingCompressionListener(model: "parakeet/test", isDeterministic: true) { _, spans in
            spans.map { _ in (0..<40).map { "word\($0)" }.joined(separator: " ") }
        }
        let compressed = await library.compressRecordings([track.id], in: id, device: library.sync?.deviceID, listener: listener)
        XCTAssertEqual(compressed, [track.id])
        library.renameSpeaker(speaker, to: "Vlad", in: id)
        XCTAssertEqual(library.meeting(id)?.awaitsVoiceForNamedSpeaker, true)
        let held = await library.meetingsHoldingOriginalsInICloud()
        XCTAssertEqual(held, [id])
        // And while a voiceprint holds something else (learned from a conversation never on this Mac).
        let elsewhere = Voiceprint(id: "vp-elsewhere", profileID: UUID(), origin: .named, vector: VoiceVector(space: "space", values: [0, 1]),
                                   meetingID: UUID(), speakerID: "run:9", trackID: UUID(), speechSeconds: 6.5, recordedAt: Date())
        library.updateMetadata { $0.voiceprints = [LibraryValue(id: elsewhere.id, value: elsewhere)] }
        let both = await library.meetingsHoldingOriginalsInICloud()
        XCTAssertEqual(both?.contains(id), true)
        library.updateMetadata { $0.voiceprints = [] }
        let object = cloud.appendingPathComponent("Blobs/\(track.sha256)")
        for _ in 0..<4 {
            now = now.addingTimeInterval(60)
            try await pass(library, at: now)
        }
        now = now.addingTimeInterval(3 * day)
        try await pass(library, at: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path), "its voice isn't known yet")
        let waiting = await library.sync?.engine?.supersededState()
        XCTAssertEqual(waiting?.objects.isEmpty, true)
        // Given its voice: its profile learns from it, and the clip of its speech is cut from the original still here.
        library.update(id) { _ = $0.giveVoices([speaker: [1, 0]], space: "space", model: "test") }
        XCTAssertEqual(library.meeting(id)?.awaitsVoiceForNamedSpeaker, false)
        await coordinators.last?.refresh()
        XCTAssertFalse((library.metadata.voiceprints ?? []).isEmpty, "learned from the name")
        let made = await library.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(made, 1)
        for _ in 0..<4 {
            now = now.addingTimeInterval(60)
            try await pass(library, at: now)
        }
        let confirmed = await library.meetingsHoldingOriginalsInICloud()
        XCTAssertEqual(confirmed, [])
        let listed = await library.sync?.engine?.supersededState()
        let since = try XCTUnwrap(listed?.objects[track.sha256]?.acknowledgedSince)
        try await pass(library, at: since.addingTimeInterval(day + 60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: object.path))
    }

    /// A Mac that may delete with no speaker-profile coordinator to ask deletes nothing; and one whose profiles aren't
    /// settled right before deleting asks for a reconciliation, so a change it doesn't hear of (processing ending, an
    /// option) doesn't keep deletion waiting until the library next changes.
    func testBehaviorUnsettledOrMissingSpeakerProfilesAskForAReconciliation() async throws {
        let (library, object, since, _) = try await listed()
        try await pass(library, at: since.addingTimeInterval(day - 60))
        library.speakerProfileCoordinator = nil
        try await single(library, at: since.addingTimeInterval(day + 60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path), "nothing to ask")
        var skipped: Set<UUID> = [UUID()]
        let coordinator = SpeakerProfileCoordinator(library: library, options: { SpeakerProfileOptions(recognizes: false) }, skipping: { skipped })
        coordinator.delay = .milliseconds(20)
        library.speakerProfileCoordinator = coordinator
        await coordinator.refresh()
        // Processing ended elsewhere: nothing in the library changed, so nothing it watches says so.
        skipped = []
        XCTAssertTrue(coordinator.pendingVoiceWork.unsettled)
        try await single(library, at: since.addingTimeInterval(day + 120))
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path), "not settled")
        for _ in 0..<300 where coordinator.pendingVoiceWork.unsettled { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(coordinator.pendingVoiceWork.unsettled, "it reconciled when asked")
        try await single(library, at: since.addingTimeInterval(day + 180))
        XCTAssertFalse(FileManager.default.fileExists(atPath: object.path))
    }

    /// Never chosen while the pass ran: what it found due stays, asked again right before deleting.
    func testBehaviorNeverChosenDuringThePassKeepsIt() async throws {
        let (library, object, since, _) = try await listed()
        try await pass(library, at: since.addingTimeInterval(day - 60))
        library.syncApplyFault = { [unowned library] in MainActor.assumeIsolated { library.setRecordingCompression(.never) } }
        try await single(library, at: since.addingTimeInterval(day + 60))
        library.syncApplyFault = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path))
        try await single(library, at: since.addingTimeInterval(day + 120))
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path))
        let listing = try await notice(library)
        XCTAssertEqual(listing?.objects, [])
    }

    /// A single Mac's library: a recording compressed, then a voice profile learning from it with no clip of its speech
    /// yet (the original is still here). Its original's object stays in iCloud while that voiceprint's clip isn't
    /// confirmed there; once a clip is cut and uploaded, it's free, and it goes a day later, deleted by the library's own
    /// sync, right after the pass.
    func testBehaviorTheLibraryKeepsWhatVoiceProfilesHoldAndDeletesTheRestAfterThePass() async throws {
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let library = try await library(cloud: cloud)
        let id = library.newMeeting(title: "Planning")
        await library.acquireLock()
        let ingested = try await library.ingest(try recording(), into: id, provenance: .file(source: .microphone))
        library.releaseLock()
        let track = try XCTUnwrap(ingested.track)
        let speaker = speaker
        library.update(id) { meeting in
            meeting.transcripts = [TrackTranscript(trackID: track.id, segments: [
                TranscriptSegment(trackID: track.id, start: 0.5, end: 7.5, text: "hello there", speakerID: speaker)])]
            meeting.speakers = [Speaker(id: speaker, name: "Vlad", sourceTrackID: track.id, embedding: [1, 0], embeddingModelID: "space")]
        }
        try await library.flushDurably()
        var now = Date()
        try await pass(library, at: now)
        let listener = RecordingCompressionListener(model: "parakeet/test", isDeterministic: true) { _, spans in
            spans.map { _ in (0..<40).map { "word\($0)" }.joined(separator: " ") }
        }
        let compressed = await library.compressRecordings([track.id], in: id, device: library.sync?.deviceID, listener: listener)
        XCTAssertEqual(compressed, [track.id])
        // Learned from after it was compressed: no clip of it yet.
        let profile = SpeakerProfile(id: UUID(), name: "Vlad")
        let print = Voiceprint(id: "vp-\(UUID().uuidString)", profileID: profile.id, origin: .named, vector: VoiceVector(space: "space", values: [1, 0]),
                               meetingID: id, speakerID: speaker, trackID: track.id, speechSeconds: 6.5, recordedAt: Date())
        library.updateMetadata { metadata in
            metadata.speakerProfiles = [LibraryValue(id: profile.id.uuidString, value: profile)]
            metadata.voiceprints = [LibraryValue(id: print.id, value: print)]
        }
        let object = cloud.appendingPathComponent("Blobs/\(track.sha256)")
        for _ in 0..<4 {
            now = now.addingTimeInterval(60)
            try await pass(library, at: now)
        }
        let held = await library.meetingsHoldingOriginalsInICloud()
        XCTAssertEqual(held, [id])
        // A conversation in the Trash that can't be read may be where that voiceprint's recording went: nothing is said.
        let unreadable = root.appendingPathComponent("Mac/Trash/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: unreadable.appendingPathComponent("meeting.json"))
        let unsaid = await library.meetingsHoldingOriginalsInICloud()
        XCTAssertNil(unsaid)
        try FileManager.default.removeItem(at: unreadable)
        now = now.addingTimeInterval(3 * day)
        try await pass(library, at: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path), "a voiceprint whose clip isn't in iCloud holds it")
        let waiting = await library.sync?.engine?.supersededState()
        XCTAssertEqual(waiting?.objects.isEmpty, true)
        // Its clip, cut from the original still here, and uploaded: free, listed, and gone a day later.
        let made = await library.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(made, 1)
        now = now.addingTimeInterval(60)
        try await pass(library, at: now)
        let confirmed = await library.meetingsHoldingOriginalsInICloud()
        XCTAssertEqual(confirmed, [])
        now = now.addingTimeInterval(60)
        try await pass(library, at: now)
        // Listed in the notice; acknowledged once the notice is in iCloud (no other device to wait for).
        now = now.addingTimeInterval(60)
        try await pass(library, at: now)
        let listed = await library.sync?.engine?.supersededState()
        XCTAssertEqual(listed?.objects[track.sha256]?.acknowledgedSince, now)
        try await pass(library, at: now.addingTimeInterval(day - 60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path))
        // A pass the library doesn't apply (stopped after the engine's pass) deletes nothing, though it found it due.
        struct Stopped: Error {}
        library.syncApplyFault = { throw Stopped() }
        try await single(library, at: now.addingTimeInterval(day + 60), acknowledged: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path))
        library.syncApplyFault = nil
        // Nor does the next, its settings not known to be current after a pass that stopped; the one after it does.
        try await pass(library, at: now.addingTimeInterval(day + 120))
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path))
        try await pass(library, at: now.addingTimeInterval(day + 180))
        XCTAssertFalse(FileManager.default.fileExists(atPath: object.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("Blobs/\(try XCTUnwrap(library.meeting(id)?.tracks.first?.sha256))").path))
    }
}
