import AVFoundation
import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Voice clips through the library (LibraryController+VoiceClips): a recording a voice profile learned from is replaced
/// or let go only once this Mac holds the lossless clip of what the profile learned, clips are deleted only when no
/// voiceprint names them any more (and only after a grace an Undo fits in), and a voiceprint's speech is read from the
/// clip once the original is gone.
@MainActor
final class VoiceClipLibraryTests: XCTestCase {
    private var root: URL!
    private let speaker = "run:1"

    override func setUp() async throws {
        root = makeTemporaryFolder("DaybookVoiceClipLibrary")
    }

    private func library(_ name: String, cloud: URL? = nil, syncs: Bool = false) async throws -> LibraryController {
        let local = root.appendingPathComponent(name, isDirectory: true)
        var sync: LibrarySyncController?
        if syncs {
            sync = LibrarySyncController(localRoot: local, defaults: makeTestDefaults("daybook.voiceclips.\(name)"))
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

    /// A conversation with one recording, transcribed: `speaker` talks 0.5–3.5 and 4–7.5, another 3.5–4.
    private func conversation(in library: LibraryController, seed: Double = 1) async throws -> (UUID, RecordingTrack) {
        let source = try recording(seed: seed)
        let id = library.newMeeting(title: "Planning")
        await library.acquireLock()
        let ingested = try await library.ingest(source, into: id, provenance: .file(source: .microphone))
        library.releaseLock()
        let track = try XCTUnwrap(ingested.track)
        let speaker = speaker
        library.update(id) { meeting in
            let segments = [(speaker, 0.5, 3.5), ("run:2", 3.5, 4.0), (speaker, 4.0, 7.5)].map {
                TranscriptSegment(trackID: track.id, start: $0.1, end: $0.2, text: "hello there", speakerID: $0.0)
            }
            meeting.transcripts = [TrackTranscript(trackID: track.id, segments: segments)]
            meeting.speakers = [Speaker(id: speaker, name: "Vlad", sourceTrackID: track.id, embedding: [1, 0], embeddingModelID: "space"),
                                Speaker(id: "run:2", name: "Speaker 2", sourceTrackID: track.id, embedding: [0, 1], embeddingModelID: "space")]
        }
        try await library.flushDurably()
        return (id, track)
    }

    /// A profile with a named voiceprint learned from `speaker` in the conversation.
    @discardableResult
    private func teach(_ library: LibraryController, from id: UUID, track: RecordingTrack, origin: Voiceprint.Origin = .named,
                       profile: SpeakerProfile? = nil) -> (SpeakerProfile, Voiceprint) {
        let profile = profile ?? SpeakerProfile(id: UUID(), name: "Vlad")
        let print = Voiceprint(id: "vp-\(UUID().uuidString)", profileID: profile.id, origin: origin, vector: VoiceVector(space: "space", values: [1, 0]),
                               meetingID: id, speakerID: speaker, trackID: track.id, speechSeconds: 6.5, recordedAt: Date())
        library.updateMetadata { metadata in
            var profiles = metadata.speakerProfiles ?? []
            if !profiles.contains(where: { $0.id == profile.id.uuidString }) { profiles.append(LibraryValue(id: profile.id.uuidString, value: profile)) }
            metadata.speakerProfiles = profiles
            metadata.voiceprints = (metadata.voiceprints ?? []) + [LibraryValue(id: print.id, value: print)]
        }
        return (profile, print)
    }

    private func listener() -> RecordingCompressionListener {
        RecordingCompressionListener(model: "parakeet/test", isDeterministic: true) { _, spans in
            spans.map { _ in (0..<40).map { "word\($0)" }.joined(separator: " ") }
        }
    }

    private func compress(_ library: LibraryController, _ id: UUID, _ track: RecordingTrack) async -> [UUID] {
        await library.compressRecordings([track.id], in: id, device: library.sync?.deviceID, listener: listener())
    }

    private func path(_ library: LibraryController, _ relativePath: String, in id: UUID) -> String {
        library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)/\(relativePath)").path
    }

    private func clips(_ library: LibraryController) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: library.voiceClipsFolder.path)) ?? []).filter { $0 != VoiceClips.indexName }.sorted()
    }

    private func samples(_ url: URL, frames: Range<Int64>? = nil) throws -> [UInt32] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let range = frames ?? 0..<file.length
        file.framePosition = range.lowerBound
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(range.count))!
        var result: [UInt32] = []
        // A read may deliver fewer frames than asked.
        while result.count < range.count {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(range.count - result.count))
            guard buffer.frameLength > 0 else { break }
            result += (0..<Int(buffer.frameLength)).map { buffer.floatChannelData![0][$0].bitPattern }
        }
        return result
    }

    // MARK: Before a recording is replaced

    func testBehaviorALearnedFromRecordingIsReplacedOnlyOnceItsLosslessClipIsHere() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        let held = await compress(library, id, track)
        XCTAssertEqual(held, [], "a voice profile learned from it and its clip isn't here")
        XCTAssertEqual(library.holdingBackVoiceprints().count, 1)
        // Not due: a recent conversation's speech isn't cut yet.
        let early = await library.makeVoiceClips(olderThan: Date.distantPast)
        XCTAssertEqual(early, 0)
        let made = await library.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(made, 1)
        let index = try XCTUnwrap(library.voiceClipIndex())
        let source = VoiceClipSource(meetingID: id, trackID: track.id, speakerID: speaker)
        let clip = try XCTUnwrap(index.clips[source.key])
        let file = library.voiceClipsFolder.appendingPathComponent(clip.fileName)
        XCTAssertEqual(try AudioDigest.sha256(fileURL: file), clip.sha256, "checksummed")
        XCTAssertEqual(clip.originalSHA256, track.sha256)
        XCTAssertEqual(clip.ranges, [VoiceClipRange(startFrame: 24_000, endFrame: 168_000), VoiceClipRange(startFrame: 192_000, endFrame: 360_000)])
        // The speaker's own passages, exactly as the original holds them.
        let original = URL(fileURLWithPath: path(library, track.relativePath, in: id))
        XCTAssertEqual(try samples(file), try samples(original, frames: 24_000..<168_000) + samples(original, frames: 192_000..<360_000))
        XCTAssertTrue(library.holdingBackVoiceprints().isEmpty)
        let again = await library.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(again, 0, "one clip a source")
        let compressed = await compress(library, id, track)
        XCTAssertEqual(compressed, [track.id])
        let removed = await library.finishCompressions()
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try AudioDigest.sha256(fileURL: file), clip.sha256, "the clip outlives the original")
    }

    func testBehaviorAnOriginalThatIsntTheRecordingsBytesGivesNoClipAndIsKept() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        let original = path(library, track.relativePath, in: id)
        let saved = try Data(contentsOf: URL(fileURLWithPath: original))
        var changed = saved
        changed[changed.count - 9] ^= 0x40
        try changed.write(to: URL(fileURLWithPath: original))
        let made = await library.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(made, 0)
        XCTAssertEqual(clips(library), [])
        let compressed = await compress(library, id, track)
        XCTAssertEqual(compressed, [])
        // Nothing to cut (the run's speaker isn't in any passage) is no clip either.
        try saved.write(to: URL(fileURLWithPath: original))
        library.update(id) { $0.transcripts[0].segments.removeAll { $0.speakerID == self.speaker } }
        let none = await library.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(none, 0)
        let stillHeld = await compress(library, id, track)
        XCTAssertEqual(stillHeld, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original))
    }

    func testBehaviorAnOriginalWrittenAgainWhileItsClipIsCutGivesNoClip() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        let original = URL(fileURLWithPath: path(library, track.relativePath, in: id))
        // The same bytes written again after they were hashed: what was cut can't be known to be what was hashed.
        library.voiceClipFault = { step in
            if step == .cut, let bytes = try? Data(contentsOf: original) { try? bytes.write(to: original) }
        }
        let made = await library.makeVoiceClips(olderThan: .distantFuture)
        library.voiceClipFault = nil
        XCTAssertEqual(made, 0)
        XCTAssertEqual(library.voiceClipIndex()?.clips.isEmpty, true)
        XCTAssertEqual(clips(library), [], "the cut is thrown away")
        let compressed = await compress(library, id, track)
        XCTAssertEqual(compressed, [])
    }

    func testBehaviorACrashWhileAClipIsMadeLeavesNothingReliedOn() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        struct Crash: Error {}
        for step in [VoiceClipStep.cut, .placed] {
            library.voiceClipFault = { if $0 == step { throw Crash() } }
            let made = await library.makeVoiceClips(olderThan: .distantFuture)
            XCTAssertEqual(made, 0)
            library.voiceClipFault = nil
            XCTAssertEqual(library.voiceClipIndex()?.clips.isEmpty, true, "the index names nothing it can't rely on")
            let compressed = await compress(library, id, track)
            XCTAssertEqual(compressed, [], "the original stays")
        }
        // A clip placed before a crash is a file nothing names: swept at launch.
        XCTAssertEqual(clips(library).count, 1)
        let reopened = try await self.library("Mac")
        await reopened.reconcileCompressions()
        XCTAssertEqual(clips(reopened), [])
        let made = await reopened.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(made, 1)
    }

    func testBehaviorAClipThatChangedHoldsTheOriginalUntilItsBytesAreCheckedAgain() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        await library.makeVoiceClips(olderThan: .distantFuture)
        let compressed = await compress(library, id, track)
        XCTAssertEqual(compressed, [track.id])
        let clip = try XCTUnwrap(library.voiceClipIndex()?.clips.values.first)
        let file = library.voiceClipsFolder.appendingPathComponent(clip.fileName)
        let saved = try Data(contentsOf: file)
        var damaged = saved
        damaged[damaged.count - 5] ^= 0x01
        try damaged.write(to: file)
        XCTAssertEqual(library.coveredVoiceSources(), [])
        let kept = await library.finishCompressions()
        XCTAssertEqual(kept, 0, "a clip that isn't the bytes checked isn't relied on")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(library, track.relativePath, in: id)))
        // Damaged: cut again from the original still here (the recording is compressed, so it's due at once).
        let recut = await library.makeVoiceClips(olderThan: nil)
        XCTAssertEqual(recut, 1)
        XCTAssertEqual(try Data(contentsOf: file), saved)
        let removed = await library.finishCompressions()
        XCTAssertEqual(removed, 1)
        // With the original gone, the same bytes under a new stamp (a copy put back) are trusted again once hashed.
        let aside = root.appendingPathComponent("aside.caf")
        try FileManager.default.copyItem(at: file, to: aside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: aside, to: file)
        XCTAssertEqual(library.coveredVoiceSources(), [])
        let none = await library.makeVoiceClips(olderThan: nil)
        XCTAssertEqual(none, 0, "nothing to cut from")
        XCTAssertEqual(library.coveredVoiceSources().count, 1)
    }

    func testBehaviorTheClipIsCheckedAgainUnderTheLockBeforeTheOriginalGoes() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        await library.makeVoiceClips(olderThan: .distantFuture)
        let compressed = await compress(library, id, track)
        XCTAssertEqual(compressed, [track.id])
        let clip = try XCTUnwrap(library.voiceClipIndex()?.clips.values.first)
        // The clip goes after the files are hashed, before the lock is taken.
        library.compressionFault = { step in
            if step == .checked { try? FileManager.default.removeItem(at: library.voiceClipsFolder.appendingPathComponent(clip.fileName)) }
        }
        let removed = await library.finishCompressions()
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(library, track.relativePath, in: id)))
    }

    func testBehaviorAVoiceprintTaughtWhileTheCopyIsMadeKeepsTheOriginal() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        // Taught under the lock, after the pass found nothing holding it back.
        let compressed = await library.compressRecordings([track.id], in: id, device: nil, listener: listener()) { _ in
            self.teach(library, from: id, track: track)
            return true
        }
        XCTAssertEqual(compressed, [])
        XCTAssertNil(library.meeting(id)?.tracks.first?.encoding)
        // Taught after the copy is at its own path, with nothing awaited from the last check to the track naming it.
        let (otherID, otherTrack) = try await conversation(in: library, seed: 4)
        library.compressionFault = { step in if step == .renamed { self.teach(library, from: otherID, track: otherTrack) } }
        let late = await library.compressRecordings([otherTrack.id], in: otherID, device: nil, listener: listener())
        library.compressionFault = nil
        XCTAssertEqual(late, [])
        XCTAssertNil(library.meeting(otherID)?.tracks.first?.encoding)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(library, otherTrack.relativePath, in: otherID)))
    }

    func testBehaviorALearnedVoiceprintBeyondItsProfilesClipsDoesntHoldARecordingBack() async throws {
        let library = try await self.library("Mac")
        let (profile, _) = (SpeakerProfile(id: UUID(), name: "Vlad"), ())
        var conversations: [(UUID, RecordingTrack)] = []
        for seed in 0..<(VoiceClips.maximumSourcesPerProfile + 1) {
            let made = try await conversation(in: library, seed: Double(seed))
            conversations.append(made)
            teach(library, from: made.0, track: made.1, origin: seed == 0 ? .recognized : .named, profile: profile)
        }
        // Eight the person named fill the profile's clips; the learned one beyond them holds nothing back.
        XCTAssertEqual(library.holdingBackVoiceprints().count, VoiceClips.maximumSourcesPerProfile)
        let learned = await compress(library, conversations[0].0, conversations[0].1)
        XCTAssertEqual(learned, [conversations[0].1.id])
        let named = await compress(library, conversations[1].0, conversations[1].1)
        XCTAssertEqual(named, [])
    }

    func testBehaviorANameGivenBeforeItsVoiceKeepsTheRecordingUntilTheVoiceIsMade() async throws {
        let library = try await self.library("Mac")
        let (id, _) = try await conversation(in: library)
        library.update(id) { meeting in
            for index in meeting.speakers.indices { meeting.speakers[index].embedding = nil; meeting.speakers[index].embeddingModelID = nil }
        }
        XCTAssertFalse(try XCTUnwrap(library.meeting(id)).awaitsVoiceForNamedSpeaker, "no name the person gave")
        library.renameSpeaker(speaker, to: "Sam", in: id)
        let meeting = try XCTUnwrap(library.meeting(id))
        XCTAssertTrue(meeting.awaitsVoiceForNamedSpeaker)
        let inputs = RecordingCompressionPlanner.Inputs(now: Date().addingTimeInterval(90 * 86_400), age: .after30Days, startsAt: .distantPast,
                                                        settingsApplied: true, everyDeviceCompresses: true, clockLooksAhead: false, thisDevice: "M",
                                                        macs: nil, done: [id])
        let facts = RecordingCompressionPlanner.facts(meeting, inputs, learned: [])
        XCTAssertTrue(facts.teachesVoiceProfile)
        library.update(id) { $0.giveVoices([self.speaker: [1, 0]], space: "space", model: "community-1") }
        XCTAssertFalse(RecordingCompressionPlanner.facts(try XCTUnwrap(library.meeting(id)), inputs, learned: []).teachesVoiceProfile)
    }

    // MARK: Another Mac

    /// Mac A compresses a recording a profile learned from, after cutting its clip; Mac B, which holds the same
    /// original, lets its own go only once it has cut its own clip from it.
    func testBehaviorAnotherMacLetsItsOriginalGoOnlyOnceItHoldsItsOwnClip() async throws {
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let a = try await library("A", cloud: cloud, syncs: true), b = try await library("B", cloud: cloud, syncs: true)
        let (id, before) = try await conversation(in: a)
        teach(a, from: id, track: before)
        await pass(a); await pass(b)
        XCTAssertEqual(b.metadata.voiceprints?.count, 1, "profiles' voiceprints sync; their clips don't")
        let madeOnA = await a.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(madeOnA, 1)
        let compressed = await compress(a, id, before)
        XCTAssertEqual(compressed, [before.id])
        await pass(a); await pass(b); await pass(a); await pass(b)
        let onB = try XCTUnwrap(b.meeting(id)?.tracks.first)
        XCTAssertNotNil(onB.encoding)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(b, before.relativePath, in: id)))
        XCTAssertEqual(clips(b), [], "nothing synced the clip")
        let kept = await b.finishCompressions()
        XCTAssertEqual(kept, 0, "B holds no clip of what the profile learned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(b, before.relativePath, in: id)))
        // B cuts its own from the original the copy replaced, then lets that original go.
        let madeOnB = await b.makeVoiceClips(olderThan: nil)
        XCTAssertEqual(madeOnB, 1)
        XCTAssertEqual(b.voiceClipIndex()?.clips.values.first?.sha256, a.voiceClipIndex()?.clips.values.first?.sha256, "the same original, the same clip")
        let removed = await b.finishCompressions()
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(b, before.relativePath, in: id)))
    }

    // MARK: Letting clips go

    func testBehaviorAClipGoesADayAfterItsProfileIsDeletedAndAnUndoKeepsIt() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        let (profile, _) = teach(library, from: id, track: track)
        await library.makeVoiceClips(olderThan: .distantFuture)
        let name = try XCTUnwrap(clips(library).first)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        library.deleteSpeakerProfile(profile.id, undoManager: undo)
        undo.endUndoGrouping()
        let now = Date()
        let first = await library.reconcileVoiceClips(now: now)
        XCTAssertEqual(first, 0, "kept for a day")
        XCTAssertNotNil(library.voiceClipIndex()?.clips.values.first?.orphanedAt)
        undo.undo()
        XCTAssertEqual(library.speakerProfiles.map(\.id), [profile.id])
        let afterUndo = await library.reconcileVoiceClips(now: now.addingTimeInterval(2 * VoiceClips.orphanGrace))
        XCTAssertEqual(afterUndo, 0, "the profile is back, and so is the clip's reason to stay")
        XCTAssertNil(library.voiceClipIndex()?.clips.values.first?.orphanedAt)
        XCTAssertEqual(clips(library), [name])
        library.deleteSpeakerProfile(profile.id)
        let marked = await library.reconcileVoiceClips(now: now)
        XCTAssertEqual(marked, 0)
        let early = await library.reconcileVoiceClips(now: now.addingTimeInterval(VoiceClips.orphanGrace - 60))
        XCTAssertEqual(early, 0)
        let deleted = await library.reconcileVoiceClips(now: now.addingTimeInterval(VoiceClips.orphanGrace))
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(clips(library), [])
        XCTAssertEqual(library.voiceClipIndex()?.clips.isEmpty, true)
    }

    func testBehaviorAClipGoesWhenTheSpeakerIsTakenOutOfItsProfile() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        let (_, print) = teach(library, from: id, track: track)
        // A second voiceprint of the same speaker (another embedding space) keeps the one clip they share.
        var other = print
        other.id = "vp-other"
        other.vector = VoiceVector(space: "older", values: [1, 0])
        library.updateMetadata { $0.voiceprints = ($0.voiceprints ?? []) + [LibraryValue(id: other.id, value: other)] }
        await library.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(clips(library).count, 1)
        let now = Date()
        library.removeVoiceprint(print.id)
        await library.reconcileVoiceClips(now: now)
        let kept = await library.reconcileVoiceClips(now: now.addingTimeInterval(2 * VoiceClips.orphanGrace))
        XCTAssertEqual(kept, 0, "another voiceprint still names the speaker")
        library.removeVoiceprint(other.id)
        await library.reconcileVoiceClips(now: now)
        let deleted = await library.reconcileVoiceClips(now: now.addingTimeInterval(2 * VoiceClips.orphanGrace))
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(clips(library), [])
    }

    func testBehaviorNothingIsDeletedWhileARecordOrTheIndexCantBeRead() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        let (profile, _) = teach(library, from: id, track: track)
        await library.makeVoiceClips(olderThan: .distantFuture)
        library.deleteSpeakerProfile(profile.id)
        let now = Date()
        await library.reconcileVoiceClips(now: now)
        // A voiceprint a newer Daybook wrote: which sources are live can't be known.
        let unreadable = try JSONDecoder().decode(LibraryValue<Voiceprint>.self,
                                                  from: Data(#"{"id":"vp-new","value":{"newerShape":true},"modifiedAt":0}"#.utf8))
        library.updateMetadata { $0.voiceprints = ($0.voiceprints ?? []) + [unreadable] }
        let kept = await library.reconcileVoiceClips(now: now.addingTimeInterval(2 * VoiceClips.orphanGrace))
        XCTAssertEqual(kept, 0)
        XCTAssertEqual(clips(library).count, 1)
        library.updateMetadata { $0.voiceprints?.removeAll { $0.id == "vp-new" } }
        // At launch, before sync has brought the settings, nothing goes either.
        let atLaunch = await library.reconcileVoiceClips(now: now.addingTimeInterval(2 * VoiceClips.orphanGrace), deleting: false)
        XCTAssertEqual(atLaunch, 0)
        // An index this version can't read: no clip is relied on, written, or deleted.
        let indexURL = library.voiceClipsFolder.appendingPathComponent(VoiceClips.indexName)
        let index = try Data(contentsOf: indexURL)
        try Data(#"{"version":2,"clips":{}}"#.utf8).write(to: indexURL)
        XCTAssertNil(library.voiceClipIndex())
        XCTAssertEqual(library.coveredVoiceSources(), [])
        let unreadableIndex = await library.reconcileVoiceClips(now: now.addingTimeInterval(2 * VoiceClips.orphanGrace))
        XCTAssertEqual(unreadableIndex, 0)
        XCTAssertEqual(clips(library).count, 1, "not even as a file the index doesn't name")
        try index.write(to: indexURL)
        let deleted = await library.reconcileVoiceClips(now: now.addingTimeInterval(2 * VoiceClips.orphanGrace))
        XCTAssertEqual(deleted, 1)
    }

    // MARK: Reading a voiceprint's speech

    /// A stand-in for the voice model: the mean square of the speaker's samples. Equal for two readings exactly when
    /// they read the same samples (to rounding).
    private func embed(_ sample: LibraryController.VoiceSample) throws -> Double {
        let file = try AVAudioFile(forReading: sample.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        var sum = 0.0, count = 0
        for span in sample.spans {
            let start = Int64((span.start * 48_000).rounded(.down)), end = Int64((span.end * 48_000).rounded(.up))
            for bits in try samples(sample.url, frames: start..<min(end, file.length)) {
                let value = Double(Float(bitPattern: bits)); sum += value * value; count += 1
            }
        }
        return sum / Double(max(count, 1))
    }

    func testBehaviorAVoiceprintsSpeechIsTheOriginalWhileItsHereAndItsClipOnceItsGone() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        let (_, print) = teach(library, from: id, track: track)
        let originalSample = await library.voiceSample(for: print)
        let fromOriginal = try XCTUnwrap(originalSample)
        XCTAssertFalse(fromOriginal.isClip)
        XCTAssertEqual(fromOriginal.spans, [VoiceClipSpan(start: 0.5, end: 3.5), VoiceClipSpan(start: 4, end: 7.5)])
        let heardFromOriginal = try embed(fromOriginal)
        await library.makeVoiceClips(olderThan: .distantFuture)
        _ = await compress(library, id, track)
        let replacedSample = await library.voiceSample(for: print)
        let compressedOriginal = try XCTUnwrap(replacedSample)
        XCTAssertFalse(compressedOriginal.isClip, "the original a copy replaced, while it's still here")
        await library.finishCompressions()
        let clipSample = await library.voiceSample(for: print)
        let fromClip = try XCTUnwrap(clipSample)
        XCTAssertTrue(fromClip.isClip)
        XCTAssertEqual(fromClip.spans, [VoiceClipSpan(start: 0, end: 3), VoiceClipSpan(start: 3, end: 6.5)])
        XCTAssertEqual(try embed(fromClip), heardFromOriginal, "the same speech, sample for sample")
        // With neither the original nor its clip, only the lossy copy is left: no sample.
        let clip = try XCTUnwrap(library.voiceClipIndex()?.clips.values.first)
        try FileManager.default.removeItem(at: library.voiceClipsFolder.appendingPathComponent(clip.fileName))
        let none = await library.voiceSample(for: print)
        XCTAssertNil(none)
    }
}
