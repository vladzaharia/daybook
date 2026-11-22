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
            // And it finishes on a later pass (after the wait a failure brings: the crash here is a thrown error, which a
            // real crash never gets to record).
            if !track.isCompressed {
                let value4 = await launched.compressRecordings([before.id], in: id, device: nil, now: Date().addingTimeInterval(7 * 3_600))
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

    // MARK: Settings from sync

    private func cloudFolder() throws -> URL {
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        return cloud
    }

    /// A compressed recording whose copy is uploaded, in a synced library: only the settings stand between it and letting
    /// the original go.
    private func compressedAndUploaded(_ library: LibraryController) async throws -> (UUID, RecordingTrack) {
        let (id, before) = try await conversation(in: library, from: try recording())
        await pass(library)
        await library.compressRecordings([before.id], in: id, device: library.sync?.deviceID)
        await pass(library)
        return (id, before)
    }

    func testBehaviorSettingsStillDownloadingLetNothingGo() async throws {
        let cloud = try cloudFolder()
        let other = try await self.library("Other", cloud: cloud)
        other.setRecordingCompression(.after90Days)
        await pass(other)
        // The library's settings in iCloud aren't downloaded on this Mac yet (placeholders).
        let metadata = cloud.appendingPathComponent("Metadata")
        let hidden = try FileManager.default.contentsOfDirectory(atPath: metadata.path).filter { !$0.hasPrefix(".") }
        for name in hidden { try FileManager.default.moveItem(at: metadata.appendingPathComponent(name), to: metadata.appendingPathComponent(".\(name).icloud")) }
        let library = try await self.library("Mac", cloud: cloud)
        let (id, before) = try await compressedAndUploaded(library)
        var current = await library.settingsAreCurrent()
        XCTAssertFalse(current)
        let removed = await library.finishCompressions()
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(library, before.relativePath, in: id).path))
        let planned = RecordingCompressionPlanner.Inputs(now: Date(), age: .after30Days, startsAt: .distantPast, settingsApplied: current,
                                                         everyDeviceCompresses: true, clockLooksAhead: false, thisDevice: "M", macs: nil, done: [])
        XCTAssertNil(RecordingCompressionPlanner.context(planned, meetings: []).startsAt, "nothing compressed meanwhile")
        // Downloaded: they apply, and the original goes.
        for name in hidden { try FileManager.default.moveItem(at: metadata.appendingPathComponent(".\(name).icloud"), to: metadata.appendingPathComponent(name)) }
        await pass(library)
        current = await library.settingsAreCurrent()
        XCTAssertTrue(current)
        XCTAssertEqual(library.recordingCompression, .after90Days)
        let finally = await library.finishCompressions()
        XCTAssertEqual(finally, 1)
    }

    func testBehaviorAReconnectNeedsSettingsAppliedAgain() async throws {
        let cloud = try cloudFolder()
        let library = try await self.library("Mac", cloud: cloud)
        await pass(library)
        var current = await library.settingsAreCurrent()
        XCTAssertTrue(current)
        // Current for the library they came from, not another (one switched to mid-pass).
        let connected = await library.sync?.libraryID()
        let libraryID = try XCTUnwrap(connected)
        current = await library.settingsAreCurrent(library: libraryID)
        XCTAssertTrue(current)
        current = await library.settingsAreCurrent(library: UUID())
        XCTAssertFalse(current)
        try library.sync?.connect(to: cloud, monitorChanges: false)
        current = await library.settingsAreCurrent()
        XCTAssertFalse(current, "another engine")
        await pass(library)
        current = await library.settingsAreCurrent()
        XCTAssertTrue(current)
    }

    func testBehaviorSettingsANewerDaybookWroteCountAsNever() async throws {
        let cloud = try cloudFolder()
        let library = try await self.library("Mac", cloud: cloud)
        await pass(library)
        XCTAssertEqual(library.recordingCompression, .after30Days)
        let metadata = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: cloud.appendingPathComponent("Metadata").path).first)
        let record: [String: Any] = ["schemaVersion": 1, "deviceID": "Future", "sequence": 9, "parents": [String(metadata.dropLast(5))],
                                     "data": Data(#"{"schemaVersion":1,"folders":"not a list"}"#.utf8).base64EncodedString()]
        let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try bytes.write(to: cloud.appendingPathComponent("Metadata/\(AudioDigest.sha256(data: bytes)).json"))
        await pass(library)
        XCTAssertEqual(library.recordingCompression, .never)
        // In another library, one in a newer format the engine leaves out whole (so nothing of it reaches the settings
        // here): Never too, on the engine's word (`SyncResult.settingsUnreadable`).
        let otherCloud = root.appendingPathComponent("Other Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: otherCloud, withIntermediateDirectories: true)
        let first = try await self.library("First", cloud: otherCloud)
        await pass(first)
        let parent = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: otherCloud.appendingPathComponent("Metadata").path).first)
        let newer: [String: Any] = ["schemaVersion": 1, "deviceID": "Future", "sequence": 10, "parents": [String(parent.dropLast(5))],
                                    "data": Data(#"{"schemaVersion":3}"#.utf8).base64EncodedString()]
        let newerBytes = try JSONSerialization.data(withJSONObject: newer, options: [.sortedKeys])
        try newerBytes.write(to: otherCloud.appendingPathComponent("Metadata/\(AudioDigest.sha256(data: newerBytes)).json"))
        let fresh = try await self.library("Fresh", cloud: otherCloud)
        await pass(fresh)
        XCTAssertEqual(fresh.recordingCompression, .never)
        await pass(fresh)
        XCTAssertEqual(fresh.recordingCompression, .never, "and on every pass after")
    }

    // MARK: Letting go, checked again under the lock

    func testBehaviorAnOriginalThatChangesAfterItsHashIsKept() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, before) = try await conversation(in: library, from: try recording())
        await library.compressRecordings([before.id], in: id, device: nil)
        let original = url(library, before.relativePath, in: id)
        library.compressionFault = { step in
            guard step == .checked, let bytes = try? Data(contentsOf: original) else { return }
            try? (bytes + Data([0])).write(to: original)
        }
        var removed = await library.finishCompressions()
        XCTAssertEqual(removed, 0, "the file changed between being hashed and being deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        // The track changed meanwhile (another device's merge, say): kept too.
        let saved = try Data(contentsOf: original)
        try saved.dropLast().write(to: original)
        library.compressionFault = { step in
            guard step == .checked else { return }
            MainActor.assumeIsolated { library.update(id) { $0.tracks[0].fileName = "renamed.m4a" } }
        }
        removed = await library.finishCompressions()
        XCTAssertEqual(removed, 0)
        // Another track named the original meanwhile: kept.
        await library.flush()
        library.compressionFault = { step in
            guard step == .checked else { return }
            MainActor.assumeIsolated {
                library.update(id) { $0.tracks.append(RecordingTrack(relativePath: before.relativePath, fileName: before.fileName, sha256: before.sha256)) }
            }
        }
        removed = await library.finishCompressions()
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testBehaviorAnOriginalRewrittenUnderItsOldDateIsKept() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, before) = try await conversation(in: library, from: try recording())
        await library.compressRecordings([before.id], in: id, device: nil)
        let original = url(library, before.relativePath, in: id)
        // As many bytes as before, rewritten in place, and the modification time put back to the nanosecond: only the
        // status-change time (which can't be set back) shows it.
        var hashed = stat()
        library.compressionFault = { step in
            guard step == .checked, lstat(original.path, &hashed) == 0, let handle = try? FileHandle(forWritingTo: original) else { return }
            try? handle.seek(toOffset: 8_192); try? handle.write(contentsOf: Data(repeating: 0x55, count: 64)); try? handle.close()
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), hashed.st_mtimespec]
            _ = utimensat(AT_FDCWD, original.path, &times, 0)
        }
        let removed = await library.finishCompressions()
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        var after = stat()
        XCTAssertEqual(lstat(original.path, &after), 0)
        XCTAssertEqual([after.st_size, Int64(after.st_mtimespec.tv_sec), Int64(after.st_mtimespec.tv_nsec)],
                       [hashed.st_size, Int64(hashed.st_mtimespec.tv_sec), Int64(hashed.st_mtimespec.tv_nsec)], "the same size and modification time")
        XCTAssertEqual(after.st_ino, hashed.st_ino, "the same file")
    }

    func testBehaviorACopyRewrittenUnderItsOldDateKeepsTheOriginal() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, before) = try await conversation(in: library, from: try recording())
        await library.compressRecordings([before.id], in: id, device: nil)
        let copy = url(library, try XCTUnwrap(library.meeting(id)?.tracks.first).relativePath, in: id)
        // The copy, as many bytes as before, rewritten in place after it was hashed, its modification time put back to the
        // nanosecond: the original stays.
        var hashed = stat()
        library.compressionFault = { step in
            guard step == .checked, lstat(copy.path, &hashed) == 0, let handle = try? FileHandle(forWritingTo: copy) else { return }
            try? handle.seek(toOffset: 2_048); try? handle.write(contentsOf: Data(repeating: 0x55, count: 64)); try? handle.close()
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), hashed.st_mtimespec]
            _ = utimensat(AT_FDCWD, copy.path, &times, 0)
        }
        let removed = await library.finishCompressions()
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(try digest(url(library, before.relativePath, in: id)), before.sha256)
        var after = stat()
        XCTAssertEqual(lstat(copy.path, &after), 0)
        XCTAssertEqual([after.st_size, Int64(after.st_mtimespec.tv_sec), Int64(after.st_mtimespec.tv_nsec), Int64(bitPattern: after.st_ino)],
                       [hashed.st_size, Int64(hashed.st_mtimespec.tv_sec), Int64(hashed.st_mtimespec.tv_nsec), Int64(bitPattern: hashed.st_ino)],
                       "the same file, size, and modification time")
    }

    func testBehaviorACopyGoneBeforeTheLockKeepsTheOriginal() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, before) = try await conversation(in: library, from: try recording())
        await library.compressRecordings([before.id], in: id, device: nil)
        let copy = url(library, try XCTUnwrap(library.meeting(id)?.tracks.first).relativePath, in: id)
        library.compressionFault = { step in
            if step == .checked { try? FileManager.default.removeItem(at: copy) }
        }
        let removed = await library.finishCompressions()
        XCTAssertEqual(removed, 0, "the copy went after it was hashed")
        XCTAssertEqual(try digest(url(library, before.relativePath, in: id)), before.sha256)
    }

    func testBehaviorSettingsNoLongerCurrentUnderTheLockKeepTheOriginal() async throws {
        let library = try await self.library("Mac", cloud: try cloudFolder())
        let (id, before) = try await compressedAndUploaded(library)
        library.compressionFault = { step in
            if step == .checked { MainActor.assumeIsolated { library.settingsAppliedFromSync = nil } }
        }
        var removed = await library.finishCompressions()
        XCTAssertEqual(removed, 0, "settings not current by the time the lock was held")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(library, before.relativePath, in: id).path))
        library.compressionFault = nil
        await pass(library)
        removed = await library.finishCompressions()
        XCTAssertEqual(removed, 1)
    }

    func testBehaviorOnlyThisDevicesCompressionIsPointedBackAtItsOriginal() async throws {
        let library = try await self.library("Mac", cloud: try cloudFolder())
        await pass(library)
        let (id, before) = try await conversation(in: library, from: try recording())
        // Another Mac's copy that hasn't arrived yet is on its way: the track keeps naming it.
        await library.compressRecordings([before.id], in: id, device: "Other Mac")
        let copy = try XCTUnwrap(library.meeting(id)?.tracks.first)
        try FileManager.default.removeItem(at: url(library, copy.relativePath, in: id))
        await library.reconcileCompressions()
        XCTAssertEqual(library.meeting(id)?.tracks.first.map(RecordingCompression.File.init), RecordingCompression.File(copy))
        // This Mac's own: named back.
        library.update(id) { $0.tracks[0].encoding?.device = library.sync?.deviceID }
        try await library.flushDurably()
        await library.reconcileCompressions()
        XCTAssertEqual(library.meeting(id)?.tracks.first.map(RecordingCompression.File.init), RecordingCompression.File(before))
    }

    /// In a synced library too, a missing copy of this Mac's own points the track back at its original while the original
    /// is here with its bytes: connected (whether or not iCloud has the copy) and before it's connected (at launch). The
    /// original is the recording: the next pass uploads it again when iCloud no longer has it (its object may have gone,
    /// LibrarySyncSuperseded.swift).
    func testBehaviorAMissingCopyIsPointedBackInASyncedLibraryConnectedOrNot() async throws {
        let cloud = try cloudFolder()
        let library = try await self.library("Mac", cloud: cloud)
        let (id, before) = try await compressedAndUploaded(library)
        let copy = try XCTUnwrap(library.meeting(id)?.tracks.first)
        let uploaded = await library.sync?.engine?.isObjectUploaded(copy.sha256)
        XCTAssertEqual(uploaded, true)
        try FileManager.default.removeItem(at: url(library, copy.relativePath, in: id))
        // Its original's object went from iCloud meanwhile.
        try FileManager.default.removeItem(at: cloud.appendingPathComponent("Blobs/\(before.sha256)"))
        await library.reconcileCompressions()
        XCTAssertEqual(library.meeting(id)?.tracks.first.map(RecordingCompression.File.init), RecordingCompression.File(before))
        await pass(library)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("Blobs/\(before.sha256)").path), "uploaded again")
        // Synced before, not connected now (at launch, before sync connects): pointed back as well.
        await library.compressRecordings([before.id], in: id, device: library.sync?.deviceID)
        await pass(library)
        let again = try XCTUnwrap(library.meeting(id)?.tracks.first)
        XCTAssertNotNil(again.encoding)
        try FileManager.default.removeItem(at: url(library, again.relativePath, in: id))
        await library.flush()
        let offline = try await self.library("Mac")
        XCTAssertEqual(offline.compressionSync, .unknown)
        // (A test's defaults give the relaunched library another device ID; the app keeps its own.)
        offline.update(id) { $0.tracks[0].encoding?.device = offline.sync?.deviceID }
        try await offline.flushDurably()
        await offline.reconcileCompressions()
        XCTAssertEqual(offline.meeting(id)?.tracks.first.map(RecordingCompression.File.init), RecordingCompression.File(before))
    }

    func testBehaviorAMissingCopyPointsTheTrackBackAtItsOriginal() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, before) = try await conversation(in: library, from: try recording())
        await library.compressRecordings([before.id], in: id, device: nil)
        let track = try XCTUnwrap(library.meeting(id)?.tracks.first)
        try FileManager.default.removeItem(at: url(library, track.relativePath, in: id))
        await library.reconcileCompressions()
        let repaired = try XCTUnwrap(library.meeting(id)?.tracks.first)
        XCTAssertEqual(RecordingCompression.File(repaired), RecordingCompression.File(before))
        XCTAssertEqual(library.meeting(id)?.audioAlignments?.first?.trackDigest, before.sha256)
        XCTAssertEqual(try digest(url(library, repaired.relativePath, in: id)), repaired.sha256)
    }

    func testBehaviorAFailedSaveKeepsWhatElseArrived() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, track) = try await conversation(in: library, from: try recording())
        let other = TrackAudioAlignment(trackID: UUID(), referenceTrackID: UUID(), alignment: nil)
        library.update(id) { $0.audioAlignments?.append(other) }
        try await library.flushDurably()
        let folder = library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)")
        library.compressionFault = { step in
            if step == .renamed { try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path) }
        }
        _ = await library.compressRecordings([track.id], in: id, device: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let records = library.meeting(id)?.audioAlignments ?? []
        XCTAssertTrue(records.contains(other), "an unrelated measurement stays")
        XCTAssertEqual(records.first { $0.trackID == track.id }?.trackDigest, track.sha256, "the track's goes back")
    }

    // MARK: The transcript bar

    /// A conversation with speech in its transcript, so the bar listens.
    private func spokenConversation(in library: LibraryController) async throws -> (UUID, RecordingTrack) {
        let (id, track) = try await conversation(in: library, from: try recording(seconds: 8))
        library.update(id) { meeting in
            meeting.transcripts = [TrackTranscript(trackID: track.id, segments: [TranscriptSegment(trackID: track.id, start: 0.5, end: 7.5, text: "hello")])]
        }
        try await library.flushDurably()
        return (id, track)
    }

    private final class Heard: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        func count() { lock.withLock { calls += 1 } }
        var value: Int { lock.withLock { calls } }
    }

    private func listener(_ heard: Heard, copySays: String? = nil, originalSays: String? = nil, fails: Bool = false,
                          wait: Duration? = nil) -> RecordingCompressionListener {
        RecordingCompressionListener(model: "parakeet/test", isDeterministic: true) { url, spans in
            heard.count()
            if let wait { try await Task.sleep(for: wait) }
            // A span past the end of the file (`SpanTranscription.cut`), a model that won't load: an error, not a verdict.
            if fails { throw CocoaError(.fileReadCorruptFile) }
            let original = (0..<40).map { "word\($0)" }.joined(separator: " ")
            let isCopy = url.lastPathComponent.hasPrefix(RecordingCompression.temporaryPrefix)
            return spans.map { _ in isCopy ? (copySays ?? original) : (originalSays ?? original) }
        }
    }

    func testBehaviorACopyThatSaysTheSameIsUsedAndTheCheckRecorded() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, track) = try await spokenConversation(in: library)
        let heard = Heard()
        let compressed = await library.compressRecordings([track.id], in: id, device: nil, listener: listener(heard))
        XCTAssertEqual(compressed, [track.id])
        XCTAssertEqual(heard.value, 2, "the original and the copy")
        let check = try XCTUnwrap(library.meeting(id)?.tracks.first?.encoding?.transcriptCheck)
        XCTAssertTrue(check.ran)
        XCTAssertEqual(check.model, "parakeet/test")
        XCTAssertEqual(check.disagreement, 0)
        XCTAssertEqual(check.sampleSeconds ?? 0, 7, accuracy: 0.01)
    }

    func testBehaviorACopyThatSaysOtherwiseIsKeptOutAndNotTriedAgain() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, track) = try await spokenConversation(in: library)
        let heard = Heard()
        let wrong = (0..<40).map { $0 < 4 ? "other" : "word\($0)" }.joined(separator: " ")
        var compressed = await library.compressRecordings([track.id], in: id, device: nil, listener: listener(heard, copySays: wrong))
        XCTAssertEqual(compressed, [])
        XCTAssertNil(library.meeting(id)?.tracks.first?.encoding)
        XCTAssertEqual(originals(library, id), [(track.relativePath as NSString).lastPathComponent])
        XCTAssertTrue(library.compressionWasRefused(track))
        compressed = await library.compressRecordings([track.id], in: id, device: nil, listener: listener(heard))
        XCTAssertEqual(compressed, [])
        XCTAssertEqual(heard.value, 2, "not encoded or heard again under the same rule")
    }

    func testBehaviorSpeechWaitsForTheModelAndOnlyNoSpeechIsSkipped() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (spoken, spokenTrack) = try await spokenConversation(in: library)
        // Speech and no model this pass: left as it was for a pass that has one, nothing encoded, nothing remembered.
        let waited = await library.compressRecordings([spokenTrack.id], in: spoken, device: nil, listener: nil)
        XCTAssertEqual(waited, [])
        XCTAssertNil(library.meeting(spoken)?.tracks.first?.encoding)
        XCTAssertEqual(originals(library, spoken), [(spokenTrack.relativePath as NSString).lastPathComponent], "nothing encoded")
        XCTAssertTrue(library.compressionHeldBack(now: Date()).isEmpty)
        // With the model, the same recording is heard and compressed.
        let heardSpoken = Heard()
        let compressed = await library.compressRecordings([spokenTrack.id], in: spoken, device: nil, listener: listener(heardSpoken))
        XCTAssertEqual(compressed, [spokenTrack.id])
        XCTAssertEqual(heardSpoken.value, 2)
        // No speech in its transcript: skipped, and said so, with or without a model.
        let (silent, silentTrack) = try await conversation(in: library, from: try recording(seed: 2))
        _ = await library.compressRecordings([silentTrack.id], in: silent, device: nil, listener: nil)
        XCTAssertEqual(library.meeting(silent)?.tracks.first?.encoding?.transcriptCheck, TranscriptCheck(ran: false, skipped: "no speech"))
    }

    func testBehaviorAnOriginalHeardSayingNothingIsntAPassOrARefusal() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, track) = try await spokenConversation(in: library)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // The model hears no words in the original where its transcript has speech, whatever the copy says.
        for (index, copySays) in ["", "hello there"].enumerated() {
            let heard = Heard()
            let now = start.addingTimeInterval(Double(index) * 40 * 86_400)
            let compressed = await library.compressRecordings([track.id], in: id, device: nil, now: now,
                                                              listener: listener(heard, copySays: copySays, originalSays: ""))
            XCTAssertEqual(compressed, [], "copy says \"\(copySays)\"")
            XCTAssertEqual(heard.value, 2)
            XCTAssertNil(library.meeting(id)?.tracks.first?.encoding)
            XCTAssertEqual(originals(library, id), [(track.relativePath as NSString).lastPathComponent])
            XCTAssertFalse(library.compressionWasRefused(track), "couldn't check isn't a refusal")
            XCTAssertTrue(library.compressionHeldBack(now: now.addingTimeInterval(60)).contains(track.sha256), "it waits instead")
        }
    }

    func testBehaviorAFailureWaitsLongerEachTimeAndIsntARefusal() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, track) = try await spokenConversation(in: library)
        let heard = Heard(), start = Date(timeIntervalSince1970: 1_800_000_000)
        var compressed = await library.compressRecordings([track.id], in: id, device: nil, now: start, listener: listener(heard, fails: true))
        XCTAssertEqual(compressed, [])
        XCTAssertFalse(library.compressionWasRefused(track))
        XCTAssertEqual(library.compressionAttempts()[track.sha256]?.failures, 1)
        // Within the wait, it isn't encoded or heard again, so it takes no pass's place.
        compressed = await library.compressRecordings([track.id], in: id, device: nil, now: start.addingTimeInterval(3_600), listener: listener(heard))
        XCTAssertEqual(compressed, [])
        XCTAssertEqual(heard.value, 1)
        // After it, tried again; failing again, it waits twice as long.
        compressed = await library.compressRecordings([track.id], in: id, device: nil, now: start.addingTimeInterval(7 * 3_600),
                                                      listener: listener(heard, fails: true))
        XCTAssertEqual(heard.value, 2)
        XCTAssertEqual(library.compressionAttempts()[track.sha256]?.failures, 2)
        XCTAssertTrue(library.compressionHeldBack(now: start.addingTimeInterval(7 * 3_600 + 11 * 3_600)).contains(track.sha256))
        XCTAssertFalse(library.compressionHeldBack(now: start.addingTimeInterval(7 * 3_600 + 13 * 3_600)).contains(track.sha256))
        XCTAssertEqual(LibraryController.failureWait(30), 30 * 86_400, "at most 30 days")
        // Then it works, and nothing is remembered of it.
        compressed = await library.compressRecordings([track.id], in: id, device: nil, now: start.addingTimeInterval(21 * 3_600), listener: listener(heard))
        XCTAssertEqual(compressed, [track.id])
        XCTAssertNil(library.compressionAttempts()[track.sha256])
    }

    func testBehaviorAReadErrorIsntRememberedAsARefusal() async throws {
        let library = try await self.library("Mac", syncs: false)
        // A CAF cut short: its header declares every frame, and reading fails partway (`Refusal.shortRead`).
        let whole = try recording(seconds: 8)
        var bytes = try Data(contentsOf: whole)
        bytes.removeLast(bytes.count / 3)
        let cut = root.appendingPathComponent("cut.caf")
        try bytes.write(to: cut)
        let (id, track) = try await conversation(in: library, from: cut)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let compressed = await library.compressRecordings([track.id], in: id, device: nil, now: now)
        XCTAssertEqual(compressed, [])
        XCTAssertFalse(library.compressionWasRefused(track), "a read error may not happen another time")
        XCTAssertEqual(library.compressionAttempts()[track.sha256]?.failures, 1)
        XCTAssertEqual(originals(library, id), [(track.relativePath as NSString).lastPathComponent], "nothing left behind")
    }

    func testBehaviorStoppedOrNeverWhileAskedLastKeepsTheOriginal() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (stopped, stoppedTrack) = try await conversation(in: library, from: try recording())
        // Stopped while the last answer was being given.
        let work = Task {
            await library.compressRecordings([stoppedTrack.id], in: stopped, device: nil) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }
        }
        let stoppedResult = await work.value
        XCTAssertEqual(stoppedResult, [])
        XCTAssertNil(library.meeting(stopped)?.tracks.first?.encoding)
        XCTAssertEqual(originals(library, stopped), [(stoppedTrack.relativePath as NSString).lastPathComponent])
        // Never chosen while it was being given.
        let (never, neverTrack) = try await conversation(in: library, from: try recording(seed: 4))
        let neverResult = await library.compressRecordings([neverTrack.id], in: never, device: nil) { _ in
            library.setRecordingCompression(.never)
            return true
        }
        XCTAssertEqual(neverResult, [])
        XCTAssertNil(library.meeting(never)?.tracks.first?.encoding)
        XCTAssertEqual(originals(library, never), [(neverTrack.relativePath as NSString).lastPathComponent])
    }

    func testBehaviorAVoiceprintThisVersionCantReadMakesThePassNever() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (done, doneTrack) = try await conversation(in: library, from: try recording())
        await library.compressRecordings([doneTrack.id], in: done, device: nil)
        let (id, track) = try await conversation(in: library, from: try recording(seed: 3))
        // A voiceprint in a shape a newer Daybook wrote.
        let unreadable = try JSONDecoder().decode(LibraryValue<Voiceprint>.self,
                                                  from: Data(#"{"id":"vp-new","value":{"newerShape":true},"modifiedAt":0}"#.utf8))
        XCTAssertNotNil(unreadable.unreadableValue)
        library.updateMetadata { $0.voiceprints = ($0.voiceprints ?? []) + [unreadable] }
        XCTAssertEqual(library.recordingCompression, .after30Days, "the row still shows the choice")
        XCTAssertEqual(library.compressionPassAge, .never)
        let compressed = await library.compressRecordings([track.id], in: id, device: nil)
        XCTAssertEqual(compressed, [])
        let removed = await library.finishCompressions()
        XCTAssertEqual(removed, 0, "originals stay, as under Never")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(library, doneTrack.relativePath, in: done).path))
    }

    func testBehaviorStoppingDuringTheCheckLeavesNothing() async throws {
        let library = try await self.library("Mac", syncs: false)
        let (id, track) = try await spokenConversation(in: library)
        let heard = Heard()
        let work = Task { await library.compressRecordings([track.id], in: id, device: nil, listener: listener(heard, wait: .seconds(30))) }
        while heard.value == 0 { try await Task.sleep(for: .milliseconds(20)) }
        work.cancel()
        let compressed = await work.value
        XCTAssertEqual(compressed, [])
        XCTAssertNil(library.meeting(id)?.tracks.first?.encoding)
        XCTAssertEqual(originals(library, id), [(track.relativePath as NSString).lastPathComponent], "no copy, no temporary")
        XCTAssertFalse(library.compressionWasRefused(track), "a stop isn't a refusal")
        XCTAssertTrue(library.compressionHeldBack(now: Date()).isEmpty, "nor a failure")
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
        // Once this Mac may start, a device that can't compress yet is what holds it back; Never has nothing to wait for.
        XCTAssertEqual(RecordingCompressionSchedule.statusLine(start, age: .after30Days, waitingOnDevices: true, now: start), "Waiting for another device")
        XCTAssertNil(RecordingCompressionSchedule.statusLine(start, age: .after30Days, waitingOnDevices: false, now: start))
        XCTAssertNil(RecordingCompressionSchedule.statusLine(start, age: .never, waitingOnDevices: true, now: start))
        XCTAssertEqual(RecordingCompressionSchedule.statusLine(start, age: .after30Days, waitingOnDevices: true, now: first),
                       RecordingCompressionSchedule.startsLine(start, age: .after30Days, now: first), "the start date comes first")
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
