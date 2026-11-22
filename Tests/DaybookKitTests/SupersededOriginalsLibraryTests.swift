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
        return library
    }

    private var last: Date?

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
        try await pass(library, at: now.addingTimeInterval(day + 120))
        XCTAssertFalse(FileManager.default.fileExists(atPath: object.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("Blobs/\(try XCTUnwrap(library.meeting(id)?.tracks.first?.sha256))").path))
    }
}
