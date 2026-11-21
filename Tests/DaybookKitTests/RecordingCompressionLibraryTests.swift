import AVFoundation
import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Compress Older Recordings through the library: replacing a recording crash-safely, letting the original go only once
/// nothing can need it, two Macs syncing a compressed recording, and recognising it by its original's bytes.
@MainActor
final class RecordingCompressionLibraryTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = makeTemporaryFolder("DaybookCompression")
    }

    private func library(_ name: String, cloud: URL? = nil, syncs: Bool = true) async throws -> LibraryController {
        let local = root.appendingPathComponent(name, isDirectory: true)
        var sync: LibrarySyncController?
        if syncs {
            sync = LibrarySyncController(localRoot: local, defaults: makeTestDefaults("daybook.compression.\(name)"))
            if let cloud { try sync?.connect(to: cloud, monitorChanges: false) }
        }
        let library = LibraryController(rootURL: local, sync: sync)
        try await library.load()
        return library
    }

    private func pass(_ library: LibraryController, file: StaticString = #filePath, line: UInt = #line) async {
        await library.flush()
        let applied = await library.synchronize()
        XCTAssertEqual(applied?.acknowledged, true, "the sync pass ran and was acknowledged", file: file, line: line)
    }

    /// A synthetic microphone recording (48 kHz mono Float32 CAF), outside any library.
    private func recording(seconds: Double = 8, seed: Double = 1) throws -> URL {
        let url = root.appendingPathComponent("microphone-\(UUID().uuidString).caf")
        let rate = 48_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = Int(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count {
            let t = Double(index) / rate
            let burst = sin(2 * .pi * 1.3 * t + seed) > -0.3 ? 1.0 : 0.0
            buffer.floatChannelData![0][index] = Float(0.2 * burst * (sin(2 * .pi * 160 * t) + 0.4 * sin(2 * .pi * 480 * t)))
        }
        try file.write(from: buffer)
        return url
    }

    /// A conversation holding one recording, with a legacy alignment measured on it.
    private func conversation(in library: LibraryController, from source: URL) async throws -> (UUID, RecordingTrack) {
        let id = library.newMeeting(title: "Planning")
        await library.acquireLock()
        let ingested = try await library.ingest(source, into: id, provenance: .file(source: .microphone))
        library.releaseLock()
        let track = try XCTUnwrap(ingested.track)
        library.update(id) { meeting in
            meeting.audioAlignments = [TrackAudioAlignment(trackID: track.id, referenceTrackID: UUID(), alignment: AudioAlignment(offset: 1, confidence: 0.9),
                                                           trackDigest: track.sha256, referenceDigest: "")]
        }
        try await library.flushDurably()
        return (id, track)
    }

    private func url(_ library: LibraryController, _ relativePath: String, in id: UUID) -> URL {
        library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)/\(relativePath)")
    }

    private func originals(_ library: LibraryController, _ id: UUID) -> [String] {
        let folder = library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)/Originals")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func digest(_ url: URL) throws -> String { try AudioDigest.sha256(fileURL: url) }

    // MARK: One library

    func testBehaviorCompressionReplacesTheFileAndLetsTheOriginalGoLast() async throws {
        let library = try await self.library("Mac", syncs: false)
        let source = try recording()
        let (id, before) = try await conversation(in: library, from: source)
        let compressed = await library.compressRecordings([before.id], in: id, device: nil, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(compressed, [before.id])
        let track = try XCTUnwrap(library.meeting(id)?.tracks.first)
        let encoding = try XCTUnwrap(track.encoding)
        XCTAssertEqual(track.relativePath, RecordingCompression.relativePath(trackID: before.id, sha256: track.sha256))
        XCTAssertEqual(track.fileName, "microphone.m4a".replacingOccurrences(of: "microphone", with: (before.fileName as NSString).deletingPathExtension))
        XCTAssertEqual(encoding.previousSHA256, before.sha256)
        XCTAssertEqual(encoding.previousRelativePath, before.relativePath)
        XCTAssertEqual(encoding.method, "aac-lc-64")
        XCTAssertEqual(try digest(url(library, track.relativePath, in: id)), track.sha256)
        XCTAssertEqual(library.meeting(id)?.audioAlignments?.first?.trackDigest, track.sha256, "a measurement on the original places the copy")
        // The original stays until it's let go, and only then.
        XCTAssertEqual(try digest(url(library, before.relativePath, in: id)), before.sha256)
        // Saved durably: a library opened again names the copy.
        let reopened = try await self.library("Mac", syncs: false)
        XCTAssertEqual(reopened.meeting(id)?.tracks.first?.encoding, encoding)
        let value1 = await library.finishCompressions()
        XCTAssertEqual(value1, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(library, before.relativePath, in: id).path))
        let value2 = await library.finishCompressions()
        XCTAssertEqual(value2, 0, "nothing left to do")
        XCTAssertEqual(originals(library, id), [(track.relativePath as NSString).lastPathComponent])
    }

    func testBehaviorRecordingChangedBeforeTheCopyIsInPlaceKeepsItAsItWas() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, track) = try await conversation(in: library, from: try recording())
        // The bytes no longer match the track: nothing is encoded from them.
        let file = url(library, track.relativePath, in: id)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([1, 2, 3])); try handle.close()
        let value3 = await library.compressRecordings([track.id], in: id, device: nil)
        XCTAssertEqual(value3, [])
        XCTAssertNil(library.meeting(id)?.tracks.first?.encoding)
        XCTAssertEqual(originals(library, id), [(track.relativePath as NSString).lastPathComponent])
    }

    func testBehaviorRecordingChangedWhileItsCopyWasMadeKeepsItAsItWas() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, track) = try await conversation(in: library, from: try recording())
        // Another device's change arrives between making the copy and putting it in place.
        library.compressionFault = { step in
            guard step == .prepared else { return }
            MainActor.assumeIsolated { library.update(id) { $0.tracks[0].fileName = "renamed.caf" } }
        }
        let compressed = await library.compressRecordings([track.id], in: id, device: nil)
        XCTAssertEqual(compressed, [])
        XCTAssertNil(library.meeting(id)?.tracks.first?.encoding)
        XCTAssertEqual(originals(library, id), [(track.relativePath as NSString).lastPathComponent], "the copy is thrown away")
    }

    func testBehaviorOriginalStaysWhileTheCopyIsDamagedOrNotSaved() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, before) = try await conversation(in: library, from: try recording())
        let metadata = library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)/meeting.json")
        let uncompressed = try Data(contentsOf: metadata)
        await library.compressRecordings([before.id], in: id, device: nil)
        let track = try XCTUnwrap(library.meeting(id)?.tracks.first)
        let copy = url(library, track.relativePath, in: id)
        // The copy's bytes changed: the original stays.
        let good = try Data(contentsOf: copy)
        try (good + Data([0])).write(to: copy)
        var removed = await library.finishCompressions()
        XCTAssertEqual(removed, 0)
        try good.write(to: copy)
        // The conversation on disk still names the original (a save that never landed): the original stays.
        let compressed = try Data(contentsOf: metadata)
        try uncompressed.write(to: metadata)
        removed = await library.finishCompressions()
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(library, before.relativePath, in: id).path))
        try compressed.write(to: metadata)
        removed = await library.finishCompressions()
        XCTAssertEqual(removed, 1)
    }

    /// A crash at each step, then a launch: the recording is always whole, as the original or as the copy, and nothing
    /// is left behind.
    func testBehaviorCrashAtEveryStepThenLaunchLeavesOneWholeRecording() async throws {
        struct Crash: Error {}
        for step in [RecordingCompressionStep.prepared, .renamed, .saved, .removingOriginal] {
            let name = "Mac-\(step)"
            let library = try await self.library(name, syncs: false)
            let (id, before) = try await conversation(in: library, from: try recording())
            library.compressionFault = { if $0 == step { throw Crash() } }
            await library.compressRecordings([before.id], in: id, device: nil)
            if step == .removingOriginal { await library.finishCompressions() }
            // The launch after the crash.
            let launched = try await self.library(name, syncs: false)
            await launched.reconcileCompressions()
            await launched.finishCompressions()
            let track = try XCTUnwrap(launched.meeting(id)?.tracks.first)
            XCTAssertEqual(try digest(url(launched, track.relativePath, in: id)), track.sha256, "\(step): the named file is whole")
            let files = originals(launched, id)
            XCTAssertFalse(files.contains { $0.hasPrefix(RecordingCompression.temporaryPrefix) }, "\(step): no temporary copy")
            XCTAssertEqual(files, [(track.relativePath as NSString).lastPathComponent], "\(step): only the file the track names")
            XCTAssertEqual(track.isCompressed, step == .saved || step == .removingOriginal, "\(step)")
            // And it finishes on a later pass.
            if !track.isCompressed {
                let value4 = await launched.compressRecordings([before.id], in: id, device: nil)
                XCTAssertEqual(value4, [before.id], "\(step): compressed again")
            }
        }
    }

    // MARK: Never, and what's in the way

    func testBehaviorNeverArrivingMidCompressionStopsIt() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, track) = try await conversation(in: library, from: try recording())
        library.compressionFault = { step in
            guard step == .prepared else { return }
            MainActor.assumeIsolated { library.setRecordingCompression(.never) }
        }
        let compressed = await library.compressRecordings([track.id], in: id, device: nil)
        XCTAssertEqual(compressed, [])
        XCTAssertNil(library.meeting(id)?.tracks.first?.encoding)
        XCTAssertEqual(originals(library, id), [(track.relativePath as NSString).lastPathComponent], "the copy is thrown away")
        // And nothing starts under Never.
        library.compressionFault = nil
        let again = await library.compressRecordings([track.id], in: id, device: nil)
        XCTAssertEqual(again, [])
    }

    func testBehaviorUnderNeverOriginalsStayAndALaterChoiceFinishesThem() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, before) = try await conversation(in: library, from: try recording())
        await library.compressRecordings([before.id], in: id, device: nil)
        library.setRecordingCompression(.never)
        var removed = await library.finishCompressions()
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(library, before.relativePath, in: id).path))
        XCTAssertNotNil(library.meeting(id)?.tracks.first?.encoding, "the track keeps naming the copy")
        library.setRecordingCompression(.after90Days)
        removed = await library.finishCompressions()
        XCTAssertEqual(removed, 1)
    }

    func testBehaviorWhatStartedDuringTheEncodeStopsTheReplace() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, track) = try await conversation(in: library, from: try recording())
        let refused = await library.compressRecordings([track.id], in: id, device: nil) { _ in false }
        XCTAssertEqual(refused, [])
        XCTAssertEqual(originals(library, id), [(track.relativePath as NSString).lastPathComponent])
    }

    func testBehaviorCompressionIsNotAnEdit() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, track) = try await conversation(in: library, from: try recording())
        let edited = try XCTUnwrap(library.meeting(id)?.updatedAt)
        await library.compressRecordings([track.id], in: id, device: nil)
        XCTAssertNotNil(library.meeting(id)?.tracks.first?.encoding)
        XCTAssertEqual(library.meeting(id)?.updatedAt, edited)
    }

    func testBehaviorAFailedSaveRestoresTheTrack() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, track) = try await conversation(in: library, from: try recording())
        let folder = library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)")
        library.compressionFault = { step in
            if step == .renamed { try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path) }
        }
        let compressed = await library.compressRecordings([track.id], in: id, device: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        XCTAssertEqual(compressed, [])
        XCTAssertEqual(library.meeting(id)?.tracks.first.map(RecordingCompression.File.init), RecordingCompression.File(track))
        library.compressionFault = nil
        await library.flush()
        await library.reconcileCompressions()
        XCTAssertEqual(originals(library, id), [(track.relativePath as NSString).lastPathComponent], "the unsaved copy is gone")
    }

    func testBehaviorAFileAlreadyAtTheCopysPathIsLeftAlone() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, track) = try await conversation(in: library, from: try recording())
        let originalsFolder = library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)/Originals")
        var planted: URL?
        library.compressionFault = { step in
            guard step == .prepared, let name = try? FileManager.default.contentsOfDirectory(atPath: originalsFolder.path)
                .first(where: { $0.hasPrefix(RecordingCompression.temporaryPrefix) }),
                  let digest = try? AudioDigest.sha256(fileURL: originalsFolder.appendingPathComponent(name)) else { return }
            let target = library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)/\(RecordingCompression.relativePath(trackID: track.id, sha256: digest))")
            try? Data("someone else's".utf8).write(to: target)
            planted = target
        }
        let compressed = await library.compressRecordings([track.id], in: id, device: nil)
        XCTAssertEqual(compressed, [])
        XCTAssertNil(library.meeting(id)?.tracks.first?.encoding)
        let target = try XCTUnwrap(planted)
        XCTAssertEqual(try Data(contentsOf: target), Data("someone else's".utf8), "never overwritten")
    }

    func testBehaviorAnOriginalAnotherTrackStillNamesStays() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, before) = try await conversation(in: library, from: try recording())
        await library.compressRecordings([before.id], in: id, device: nil)
        library.update(id) { meeting in
            meeting.tracks.append(RecordingTrack(source: .microphone, relativePath: before.relativePath, fileName: before.fileName, sha256: before.sha256))
        }
        await library.flush()
        let removed = await library.finishCompressions()
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(library, before.relativePath, in: id).path))
    }

    func testBehaviorAnUnnamedCopyStaysWhileTheNamedFileIsntHere() async throws {
        struct Crash: Error {}
        let library = try await self.library("Mac", syncs: false)
        let (id, track) = try await conversation(in: library, from: try recording())
        library.compressionFault = { if $0 == .renamed { throw Crash() } }
        await library.compressRecordings([track.id], in: id, device: nil)
        library.compressionFault = nil
        // The file the track names is missing: the copy may be all there is.
        let named = url(library, track.relativePath, in: id)
        let bytes = try Data(contentsOf: named)
        try FileManager.default.removeItem(at: named)
        await library.reconcileCompressions()
        XCTAssertEqual(originals(library, id).filter { $0.contains(".aac-") }.count, 1)
        // Back, but not the bytes the track names: still kept.
        try Data("other".utf8).write(to: named)
        await library.reconcileCompressions()
        XCTAssertEqual(originals(library, id).filter { $0.contains(".aac-") }.count, 1)
        try bytes.write(to: named)
        await library.reconcileCompressions()
        XCTAssertEqual(originals(library, id).filter { $0.contains(".aac-") }.count, 0)
    }

    func testBehaviorTemporaryCopiesInTheTrashAreSwept() async throws {
        let library = try await self.library("Mac", syncs: false)
        let trashed = library.rootURL.appendingPathComponent("Trash/\(UUID().uuidString)/Originals")
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
        let leftover = trashed.appendingPathComponent("\(RecordingCompression.temporaryPrefix)x.m4a")
        try Data("x".utf8).write(to: leftover)
        await library.reconcileCompressions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }

    // MARK: Sync

    func testBehaviorOriginalStaysUntilTheCopyIsUploaded() async throws {
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let library = try await self.library("Mac", cloud: cloud)
        let (id, before) = try await conversation(in: library, from: try recording())
        await pass(library)
        XCTAssertEqual(library.compressionSync, .connected)
        await library.compressRecordings([before.id], in: id, device: library.sync?.deviceID)
        let track = try XCTUnwrap(library.meeting(id)?.tracks.first)
        let value5 = await library.sync?.engine?.isObjectUploaded(track.sha256)
        XCTAssertEqual(value5, false)
        let value6 = await library.finishCompressions()
        XCTAssertEqual(value6, 0, "the copy isn't in iCloud yet")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(library, before.relativePath, in: id).path))
        await pass(library)
        let value7 = await library.sync?.engine?.isObjectUploaded(track.sha256)
        XCTAssertEqual(value7, true)
        let value8 = await library.finishCompressions()
        XCTAssertEqual(value8, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(library, before.relativePath, in: id).path))
    }

    func testBehaviorLibraryThatSyncedButIsNotConnectedLetsNothingGo() async throws {
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let synced = try await self.library("Mac", cloud: cloud)
        let (id, before) = try await conversation(in: synced, from: try recording())
        await pass(synced)
        await synced.compressRecordings([before.id], in: id, device: nil)
        await synced.flush()
        let offline = try await self.library("Mac", syncs: false)
        XCTAssertEqual(offline.compressionSync, .unknown)
        let value9 = await offline.finishCompressions()
        XCTAssertEqual(value9, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(offline, before.relativePath, in: id).path))
        let facts = await offline.compressionFacts(for: try XCTUnwrap(offline.meeting(id)))
        XCTAssertEqual(facts.values.map(\.isUploaded), [false], "nothing is taken as uploaded meanwhile")
    }

    /// Mac A compresses while Mac B edits the same recording: both changes survive, B gets the copy at its new path
    /// without a conflict, and lets its original go only under the rule.
    func testBehaviorTwoMacsConvergeOnTheCopyWithoutAConflict() async throws {
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let a = try await library("A", cloud: cloud), b = try await library("B", cloud: cloud)
        let (id, before) = try await conversation(in: a, from: try recording())
        await pass(a); await pass(b)
        XCTAssertEqual(b.meeting(id)?.tracks.first?.sha256, before.sha256)
        b.update(id) { $0.tracks[0].offset = 2.5 }
        let value10 = await a.compressRecordings([before.id], in: id, device: a.sync?.deviceID)
        XCTAssertEqual(value10, [before.id])
        await pass(a); await pass(b); await pass(a); await pass(b)
        let onA = try XCTUnwrap(a.meeting(id)?.tracks.first), onB = try XCTUnwrap(b.meeting(id)?.tracks.first)
        XCTAssertEqual(RecordingCompression.File(onA), RecordingCompression.File(onB))
        XCTAssertNotNil(onB.encoding)
        XCTAssertEqual(onA.offset, 2.5); XCTAssertEqual(onB.offset, 2.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.rootURL.appendingPathComponent("Meetings/\(id.uuidString)/SyncConflicts").path))
        XCTAssertFalse((b.notice ?? "").contains(SyncWarningWords.keptBothRecordings))
        XCTAssertFalse(b.meeting(id)?.revisions.contains { $0.field.hasPrefix("sync:track") } ?? true, "no conflict in History")
        // B holds both until it lets the original go: the copy is here and whole, and the original is what it was.
        XCTAssertEqual(try digest(url(b, onB.relativePath, in: id)), onB.sha256)
        XCTAssertEqual(try digest(url(b, before.relativePath, in: id)), before.sha256)
        // A file at the old path that isn't the original is never deleted.
        let tampered = url(b, before.relativePath, in: id)
        let saved = try Data(contentsOf: tampered)
        try Data("other".utf8).write(to: tampered)
        let value11 = await b.finishCompressions()
        XCTAssertEqual(value11, 0)
        try saved.write(to: tampered)
        let value12 = await b.finishCompressions()
        XCTAssertEqual(value12, 1)
        XCTAssertEqual(originals(b, id), [(onB.relativePath as NSString).lastPathComponent])
        let value13 = await a.finishCompressions()
        XCTAssertEqual(value13, 1)
        await pass(a); await pass(b)
        XCTAssertEqual(a.meeting(id)?.tracks.first?.sha256, onA.sha256, "nothing goes back")
    }

    func testBehaviorSettingIsTheLibrarysOnEveryDevice() async throws {
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let mac = try await library("Mac", cloud: cloud), phone = try await library("Phone", cloud: cloud)
        await pass(mac); await pass(phone)
        XCTAssertEqual(phone.recordingCompression, .after30Days)
        phone.setRecordingCompression(.never)
        await pass(phone); await pass(mac)
        XCTAssertEqual(mac.recordingCompression, .never)
        mac.setRecordingCompression(.after90Days)
        await pass(mac); await pass(phone)
        XCTAssertEqual(phone.recordingCompression, .after90Days)
    }

    // MARK: Identity

    func testBehaviorReimportingTheOriginalFindsTheCompressedRecording() async throws {
        let library = try await self.library("Mac", syncs: false)
        let source = try recording()
        let (id, before) = try await conversation(in: library, from: source)
        await library.compressRecordings([before.id], in: id, device: nil)
        await library.finishCompressions()
        XCTAssertTrue(library.meeting(id)?.tracks.first?.isCompressed == true)
        XCTAssertEqual(try digest(source), before.sha256)
        let found = try await library.existingMeeting(containingAudioAt: source)
        XCTAssertEqual(found?.id, id, "the recorder's file is recognised by the original's bytes")
        await library.acquireLock()
        let again = try await library.ingest(source, into: id, provenance: .file(source: .microphone))
        library.releaseLock()
        XCTAssertEqual(again.imported.tracks.count, 1, "not imported a second time")
        XCTAssertEqual(again.imported.tracks.first?.id, before.id)
    }

    // MARK: The schedule

    func testBehaviorFirstRunWaitIsRecordedOnceAndShownUntilItPasses() {
        let defaults = makeTestDefaults("daybook.compression.schedule")
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let start = RecordingCompressionSchedule.startDate(in: defaults, key: "start", library: "L1", now: first)
        XCTAssertEqual(start, first.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(RecordingCompressionSchedule.startDate(in: defaults, key: "start", library: "L1", now: first.addingTimeInterval(86_400)), start, "recorded once")
        XCTAssertNotNil(RecordingCompressionSchedule.startsLine(start, age: .after30Days, now: first))
        XCTAssertNil(RecordingCompressionSchedule.startsLine(start, age: .never, now: first))
        XCTAssertNil(RecordingCompressionSchedule.startsLine(start, age: .after30Days, now: start))
        // Another library (one this Mac joined, or one that replaced this one) waits its own week.
        let later = first.addingTimeInterval(20 * 86_400)
        XCTAssertEqual(RecordingCompressionSchedule.startDate(in: defaults, key: "start", library: "L2", now: later), later.addingTimeInterval(7 * 86_400))
    }

    /// The iPhone shows the setting and never compresses: nothing in its app calls the steps that replace or let go.
    func testBehaviorTheIPhoneNeverCompresses() throws {
        let apps = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Apps/iOS")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: apps, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for call in ["compressRecordings(", "finishCompressions(", "reconcileCompressions(", "prepareCopy("] {
                XCTAssertFalse(text.contains(call), "\(file.lastPathComponent) calls \(call)")
            }
        }
    }
}
