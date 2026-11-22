import AVFoundation
import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Voice clips through the library (LibraryController+VoiceClips): a recording a voice profile learned from is replaced
/// or let go only once a lossless clip of what the profile learned covers it (and, to let an original go in a synced
/// library, iCloud holds the clip too); clips sync with their conversation, so another Mac, or a new one, is covered by
/// them; a clip is cut again when its speaker's passages change, and kept as stale once there's no original to cut it
/// from; and clips go only when no voiceprint names them any more (after a grace an Undo fits in) or with their
/// conversation's files.
@MainActor
final class VoiceClipLibraryTests: XCTestCase {
    private var root: URL!
    private let speaker = "run:1"

    override func setUp() async throws {
        root = makeTemporaryFolder("DaybookVoiceClipLibrary")
    }

    /// `presence`: the library's sync writes this Mac's presence record, as the app's does.
    private func library(_ name: String, cloud: URL? = nil, syncs: Bool = false, presence: Bool = false) async throws -> LibraryController {
        let local = root.appendingPathComponent(name, isDirectory: true)
        var sync: LibrarySyncController?
        if syncs || cloud != nil {
            sync = LibrarySyncController(localRoot: local, defaults: makeTestDefaults("daybook.voiceclips.\(name)"))
            if presence { sync?.replica = .mac(displayName: name, canProcess: true) }
            if let cloud { try sync?.connect(to: cloud, monitorChanges: false) }
        }
        let library = LibraryController(rootURL: local, sync: sync)
        try await library.load()
        return library
    }

    private func cloudFolder() throws -> URL {
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        return cloud
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
                       profile: SpeakerProfile? = nil, recordedAt: Date = Date()) -> (SpeakerProfile, Voiceprint) {
        let profile = profile ?? SpeakerProfile(id: UUID(), name: "Vlad")
        let print = Voiceprint(id: "vp-\(UUID().uuidString)", profileID: profile.id, origin: origin, vector: VoiceVector(space: "space", values: [1, 0]),
                               meetingID: id, speakerID: speaker, trackID: track.id, speechSeconds: 6.5, recordedAt: recordedAt)
        library.updateMetadata { metadata in
            var profiles = metadata.speakerProfiles ?? []
            if !profiles.contains(where: { $0.id == profile.id.uuidString }) { profiles.append(LibraryValue(id: profile.id.uuidString, value: profile)) }
            metadata.speakerProfiles = profiles
            metadata.voiceprints = (metadata.voiceprints ?? []) + [LibraryValue(id: print.id, value: print)]
        }
        return (profile, print)
    }

    /// The speaker's passage holding `start` becomes another's from `start` on.
    private func reassign(_ library: LibraryController, _ id: UUID, _ track: RecordingTrack, from start: Double = 6) {
        library.update(id) { meeting in
            guard let index = meeting.transcripts[0].segments.firstIndex(where: { $0.speakerID == self.speaker && $0.start < start && $0.end > start })
            else { return }
            let end = meeting.transcripts[0].segments[index].end
            meeting.transcripts[0].segments[index].end = start
            meeting.transcripts[0].segments.append(TranscriptSegment(trackID: track.id, start: start, end: end, text: "hello", speakerID: "run:2"))
        }
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

    private func clip(_ library: LibraryController, _ id: UUID) -> VoiceClip? { library.meeting(id)?.voiceClips?.first }

    /// The clip files in a conversation's folder (not temporaries).
    private func clipFiles(_ library: LibraryController, _ id: UUID, in top: String = "Meetings") -> [String] {
        let folder = library.rootURL.appendingPathComponent("\(top)/\(id.uuidString)/\(VoiceClip.folder)")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private func key(_ id: UUID, _ track: RecordingTrack) -> String { VoiceClipSource(meetingID: id, trackID: track.id, speakerID: speaker).key }

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

    private func age(_ path: String, by interval: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-interval)], ofItemAtPath: path)
    }

    // MARK: Before a recording is replaced

    func testBehaviorALearnedFromRecordingIsReplacedOnlyOnceItsLosslessClipIsHere() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        let held = await compress(library, id, track)
        XCTAssertEqual(held, [], "a voice profile learned from it and no clip covers it")
        let holding = await library.holdingBackVoiceprints()
        XCTAssertEqual(holding.count, 1)
        // Not due: a recent conversation's speech isn't cut yet.
        let early = await library.makeVoiceClips(olderThan: Date.distantPast)
        XCTAssertEqual(early, 0)
        let edited = try XCTUnwrap(library.meeting(id)).updatedAt
        let made = await library.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(made, 1)
        let clip = try XCTUnwrap(clip(library, id))
        XCTAssertEqual(clip.relativePath, VoiceClip.relativePath(for: VoiceClipSource(meetingID: id, trackID: track.id, speakerID: speaker), sha256: clip.sha256))
        let file = URL(fileURLWithPath: path(library, clip.relativePath, in: id))
        XCTAssertEqual(try AudioDigest.sha256(fileURL: file), clip.sha256, "checksummed")
        XCTAssertEqual(clip.originalSHA256, track.sha256)
        XCTAssertEqual(clip.originalFrames, 384_000)
        XCTAssertEqual(clip.ranges, [VoiceClipRange(startFrame: 24_000, endFrame: 168_000), VoiceClipRange(startFrame: 192_000, endFrame: 360_000)])
        XCTAssertEqual(library.meeting(id)?.updatedAt, edited, "not an edit")
        // The speaker's own passages, exactly as the original holds them.
        let original = URL(fileURLWithPath: path(library, track.relativePath, in: id))
        XCTAssertEqual(try samples(file), try samples(original, frames: 24_000..<168_000) + samples(original, frames: 192_000..<360_000))
        // Named durably by the conversation.
        let reopened = try await self.library("Mac")
        XCTAssertEqual(reopened.meeting(id)?.voiceClips, [clip])
        let covered = await library.coveredVoiceSources()
        XCTAssertEqual(covered, [key(id, track)])
        let none = await library.holdingBackVoiceprints()
        XCTAssertTrue(none.isEmpty)
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
        XCTAssertEqual(clipFiles(library, id), [])
        XCTAssertEqual(library.voiceClipState()?.attempts[key(id, track)]?.failures, 1, "it waits before it's read again")
        let compressed = await compress(library, id, track)
        XCTAssertEqual(compressed, [])
        // Nothing to cut (the run's speaker isn't in any passage) is no clip either, decided before anything is read.
        try saved.write(to: URL(fileURLWithPath: original))
        library.update(id) { $0.transcripts[0].segments.removeAll { $0.speakerID == self.speaker } }
        let none = await library.makeVoiceClips(olderThan: .distantFuture, now: Date().addingTimeInterval(7 * 86_400))
        XCTAssertEqual(none, 0)
        XCTAssertEqual(library.voiceClipState()?.attempts[key(id, track)]?.failures, 1, "not read, so not another failure")
        let stillHeld = await compress(library, id, track)
        XCTAssertEqual(stillHeld, [], "the recording stays as captured")
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
        XCTAssertNil(library.meeting(id)?.voiceClips)
        XCTAssertEqual(clipFiles(library, id), [], "the cut is thrown away")
        let compressed = await compress(library, id, track)
        XCTAssertEqual(compressed, [])
        // The speaker's passages changed while it was cut: what was cut isn't what the transcript says now.
        library.voiceClipFault = { step in if step == .placed { self.reassign(library, id, track) } }
        let changed = await library.makeVoiceClips(olderThan: .distantFuture, now: Date().addingTimeInterval(86_400))
        library.voiceClipFault = nil
        XCTAssertEqual(changed, 0)
        XCTAssertNil(library.meeting(id)?.voiceClips)
    }

    func testBehaviorACrashWhileAClipIsMadeLeavesNothingReliedOn() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        struct Crash: Error {}
        for (day, step) in [VoiceClipStep.cut, .placed].enumerated() {
            library.voiceClipFault = { if $0 == step { throw Crash() } }
            // A day apart: a failure waits before it's tried again.
            let made = await library.makeVoiceClips(olderThan: .distantFuture, now: Date().addingTimeInterval(Double(day) * 86_400))
            XCTAssertEqual(made, 0)
            library.voiceClipFault = nil
            XCTAssertNil(library.meeting(id)?.voiceClips, "the conversation names nothing it can't rely on")
            let compressed = await compress(library, id, track)
            XCTAssertEqual(compressed, [], "the original stays")
        }
        // A clip placed before a crash is a file nothing names, relied on for nothing; at launch only temporaries go, and a
        // cut of it again takes its name.
        let placed = clipFiles(library, id)
        XCTAssertEqual(placed.count, 1)
        let reopened = try await self.library("Mac")
        await reopened.reconcileCompressions()
        XCTAssertEqual(clipFiles(reopened, id), placed)
        // Nor later, however old: a voiceprint names its source and no clip is named for it, so it may be all there is.
        try age(path(reopened, "\(VoiceClip.folder)/\(placed[0])", in: id), by: 2 * 86_400)
        await reopened.reconcileVoiceClips()
        XCTAssertEqual(clipFiles(reopened, id), placed)
        let made = await reopened.makeVoiceClips(olderThan: .distantFuture, now: Date().addingTimeInterval(2 * 86_400))
        XCTAssertEqual(made, 1)
        XCTAssertEqual(clipFiles(reopened, id), placed)
        XCTAssertEqual(reopened.meeting(id)?.voiceClips?.first?.relativePath, "\(VoiceClip.folder)/\(placed[0])")
    }

    func testBehaviorAClipThatChangedHoldsTheOriginalUntilItsBytesAreCheckedAgain() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        await library.makeVoiceClips(olderThan: .distantFuture)
        let compressed = await compress(library, id, track)
        XCTAssertEqual(compressed, [track.id])
        let clip = try XCTUnwrap(clip(library, id))
        let file = URL(fileURLWithPath: path(library, clip.relativePath, in: id))
        let saved = try Data(contentsOf: file)
        var damaged = saved
        damaged[damaged.count - 5] ^= 0x01
        try damaged.write(to: file)
        let damagedCover = await library.coveredVoiceSources()
        XCTAssertEqual(damagedCover, [])
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
        let moved = await library.coveredVoiceSources()
        XCTAssertEqual(moved, [])
        let none = await library.makeVoiceClips(olderThan: nil)
        XCTAssertEqual(none, 0, "nothing to cut from")
        let checked = await library.coveredVoiceSources()
        XCTAssertEqual(checked.count, 1)
    }

    func testBehaviorTheClipIsCheckedAgainUnderTheLockBeforeTheOriginalGoes() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        await library.makeVoiceClips(olderThan: .distantFuture)
        let compressed = await compress(library, id, track)
        XCTAssertEqual(compressed, [track.id])
        let clip = try XCTUnwrap(clip(library, id))
        // The clip goes after the files are hashed, before the lock is taken.
        library.compressionFault = { step in
            if step == .checked { try? FileManager.default.removeItem(atPath: self.path(library, clip.relativePath, in: id)) }
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

    /// A profile met in many conversations: the oldest ones, far past the chosen age, are the first due, and every one of
    /// them keeps its original until its own clip covers it, however many the profile has.
    func testBehaviorEveryRecordingAProfileMetOftenLearnedFromWaitsForItsOwnClip() async throws {
        let library = try await self.library("Mac")
        let profile = SpeakerProfile(id: UUID(), name: "Vlad")
        var conversations: [(UUID, RecordingTrack)] = []
        for seed in 0..<10 {
            let made = try await conversation(in: library, seed: Double(seed))
            conversations.append(made)
            teach(library, from: made.0, track: made.1, profile: profile, recordedAt: Date().addingTimeInterval(-Double(100 - seed) * 86_400))
        }
        let holding = await library.holdingBackVoiceprints()
        XCTAssertEqual(holding.count, 10)
        for (id, track) in conversations {
            let compressed = await compress(library, id, track)
            XCTAssertEqual(compressed, [], "the oldest too: no clip covers it yet")
        }
        // Three recordings read a pass, so four passes cut them all.
        var made = 0
        for _ in 0..<4 { made += await library.makeVoiceClips(olderThan: .distantFuture) }
        XCTAssertEqual(made, 10)
        for (id, track) in conversations {
            let compressed = await compress(library, id, track)
            XCTAssertEqual(compressed, [track.id])
        }
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

    // MARK: When the transcript changes

    func testBehaviorAClipIsCutAgainWhenItsSpeakersPassagesChangeAndKeptStaleOnceTheOriginalIsGone() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        let (_, print) = teach(library, from: id, track: track)
        await library.makeVoiceClips(olderThan: .distantFuture)
        let first = try XCTUnwrap(clip(library, id))
        // A passage given to someone else: the clip holds another speaker's speech now, and covers nothing.
        reassign(library, id, track)
        let changed = await library.coveredVoiceSources()
        XCTAssertEqual(changed, [])
        let held = await compress(library, id, track)
        XCTAssertEqual(held, [])
        // Cut again from the original, with the speaker's passages now.
        let recut = await library.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(recut, 1)
        let second = try XCTUnwrap(clip(library, id))
        XCTAssertEqual(library.meeting(id)?.voiceClips?.count, 1)
        XCTAssertNotEqual(second.sha256, first.sha256)
        XCTAssertEqual(second.ranges, [VoiceClipRange(startFrame: 24_000, endFrame: 168_000), VoiceClipRange(startFrame: 192_000, endFrame: 288_000)])
        let compressed = await compress(library, id, track)
        XCTAssertEqual(compressed, [track.id])
        let removed = await library.finishCompressions()
        XCTAssertEqual(removed, 1)
        // The earlier cut, a file nothing names, goes once it's a day old.
        XCTAssertEqual(clipFiles(library, id).count, 2)
        try age(path(library, first.relativePath, in: id), by: 2 * 86_400)
        await library.reconcileVoiceClips()
        XCTAssertEqual(clipFiles(library, id), [(second.relativePath as NSString).lastPathComponent])
        // Changed again with no original here to cut it from: kept, it's all there is, but stale.
        reassign(library, id, track, from: 5)
        let none = await library.makeVoiceClips(olderThan: nil)
        XCTAssertEqual(none, 0)
        let stale = try XCTUnwrap(clip(library, id))
        XCTAssertEqual(stale.stale, true)
        XCTAssertEqual(stale.sha256, second.sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(library, stale.relativePath, in: id)))
        let staleCover = await library.coveredVoiceSources()
        XCTAssertEqual(staleCover, [])
        let sample = await library.voiceSample(for: print)
        XCTAssertNil(sample, "never taken for the speaker's speech")
        // Put back as it was, it's still stale: what's recorded stays.
        library.update(id) { meeting in
            meeting.transcripts[0].segments.removeAll { $0.speakerID == "run:2" && $0.start >= 5 }
            if let index = meeting.transcripts[0].segments.firstIndex(where: { $0.speakerID == self.speaker && $0.start == 4 }) {
                meeting.transcripts[0].segments[index].end = 6
            }
            meeting.transcripts[0].segments.append(TranscriptSegment(trackID: track.id, start: 6, end: 7.5, text: "hello", speakerID: "run:2"))
        }
        let back = await library.coveredVoiceSources()
        XCTAssertEqual(back, [])
    }

    // MARK: Recordings that can't give a clip

    func testBehaviorRecordingsThatCantGiveAClipDontStarveTheOthers() async throws {
        let library = try await self.library("Mac")
        var conversations: [(UUID, RecordingTrack)] = []
        for seed in 0..<4 {
            let made = try await conversation(in: library, seed: Double(seed))
            conversations.append(made)
            teach(library, from: made.0, track: made.1)
        }
        // In the order a pass reads them: the first three can't give a clip, the last can.
        conversations.sort { "\($0.0.uuidString)|\($0.1.id.uuidString)" < "\($1.0.uuidString)|\($1.1.id.uuidString)" }
        for (id, track) in conversations.prefix(2) {
            let url = URL(fileURLWithPath: path(library, track.relativePath, in: id))
            var bytes = try Data(contentsOf: url)
            bytes[bytes.count - 9] ^= 0x40
            try bytes.write(to: url)
        }
        // The speaker's passages are past the end of the recording: nothing of them can be cut from it.
        let (pastID, pastTrack) = conversations[2]
        library.update(pastID) { meeting in
            meeting.transcripts[0].segments = [TranscriptSegment(trackID: pastTrack.id, start: 100, end: 110, text: "late", speakerID: self.speaker)]
        }
        let start = Date()
        let first = await library.makeVoiceClips(olderThan: .distantFuture, now: start)
        XCTAssertEqual(first, 0)
        let second = await library.makeVoiceClips(olderThan: .distantFuture, now: start.addingTimeInterval(60))
        XCTAssertEqual(second, 1, "the ones that failed wait, so the next is read")
        XCTAssertNotNil(clip(library, conversations[3].0))
        let state = try XCTUnwrap(library.voiceClipState())
        XCTAssertEqual(state.attempts[key(conversations[0].0, conversations[0].1)]?.failures, 1)
        XCTAssertEqual(state.attempts[key(pastID, pastTrack)]?.refused, true)
        // Once their wait is over the failures are tried again; the refusal isn't, until its passages or original change.
        let later = await library.makeVoiceClips(olderThan: .distantFuture, now: start.addingTimeInterval(LibraryController.failureWait(1) + 60))
        XCTAssertEqual(later, 0)
        let after = try XCTUnwrap(library.voiceClipState())
        XCTAssertEqual(after.attempts[key(conversations[0].0, conversations[0].1)]?.failures, 2)
        XCTAssertEqual(after.attempts[key(pastID, pastTrack)], state.attempts[key(pastID, pastTrack)])
        for (id, track) in conversations.prefix(3) {
            let compressed = await compress(library, id, track)
            XCTAssertEqual(compressed, [], "no clip, so its original stays")
        }
    }

    // MARK: The Trash

    func testBehaviorAConversationInTheTrashKeepsItsClipsWhateverItsVoiceprints() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        let (profile, print) = teach(library, from: id, track: track)
        await library.makeVoiceClips(olderThan: .distantFuture)
        let clip = try XCTUnwrap(clip(library, id))
        try await library.moveToTrash(id)
        XCTAssertEqual(clipFiles(library, id, in: "Trash"), [(clip.relativePath as NSString).lastPathComponent])
        // Not in the library, its clip covers nothing there: its recording, and any copy of it, stays as captured.
        let holding = await library.holdingBackVoiceprints()
        XCTAssertEqual(holding.map(\.id), [print.id])
        // Its profile deleted and its saved copy unreadable: nothing in the Trash is touched.
        library.deleteSpeakerProfile(profile.id)
        let saved = library.rootURL.appendingPathComponent("Trash/\(id.uuidString)/meeting.json")
        let bytes = try Data(contentsOf: saved)
        try Data("not a conversation".utf8).write(to: saved)
        let now = Date()
        await library.reconcileVoiceClips(now: now)
        let deleted = await library.reconcileVoiceClips(now: now.addingTimeInterval(2 * VoiceClips.orphanGrace))
        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(clipFiles(library, id, in: "Trash"), [(clip.relativePath as NSString).lastPathComponent])
        // Put back, it's the library's again: no voiceprint names it now, so it goes a day later.
        try bytes.write(to: saved)
        try await library.restoreFromTrash(id)
        XCTAssertEqual(library.meeting(id)?.voiceClips, [clip])
        await library.reconcileVoiceClips(now: now)
        let gone = await library.reconcileVoiceClips(now: now.addingTimeInterval(VoiceClips.orphanGrace))
        XCTAssertEqual(gone, 1)
        XCTAssertNil(library.meeting(id)?.voiceClips)
        XCTAssertEqual(clipFiles(library, id), [])
    }

    // MARK: Other Macs

    /// Mac A cuts the clip and compresses; Mac B, which holds the same original, gets the clip with the conversation and
    /// is covered by it, so it lets its own original go without cutting one.
    func testBehaviorAnotherMacIsCoveredByTheClipSyncBrings() async throws {
        let cloud = try cloudFolder()
        let a = try await library("A", cloud: cloud), b = try await library("B", cloud: cloud)
        let (id, before) = try await conversation(in: a)
        teach(a, from: id, track: before)
        await pass(a); await pass(b)
        XCTAssertEqual(b.metadata.voiceprints?.count, 1)
        let madeOnA = await a.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(madeOnA, 1)
        let compressed = await compress(a, id, before)
        XCTAssertEqual(compressed, [before.id])
        await pass(a); await pass(b); await pass(a); await pass(b)
        let onB = try XCTUnwrap(b.meeting(id))
        XCTAssertNotNil(onB.tracks.first?.encoding)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(b, before.relativePath, in: id)))
        let clip = try XCTUnwrap(onB.voiceClips?.first)
        XCTAssertEqual(onB.voiceClips, a.meeting(id)?.voiceClips, "the clip travels with its conversation")
        XCTAssertEqual(try AudioDigest.sha256(fileURL: URL(fileURLWithPath: path(b, clip.relativePath, in: id))), clip.sha256)
        // Hashed here once, it covers the source: B cuts nothing of its own, and lets its original go.
        let madeOnB = await b.makeVoiceClips(olderThan: nil)
        XCTAssertEqual(madeOnB, 0)
        let covered = await b.coveredVoiceSources()
        XCTAssertEqual(covered, [key(id, before)])
        XCTAssertEqual(clipFiles(b, id).count, 1)
        let removed = await b.finishCompressions()
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(b, before.relativePath, in: id)))
    }

    /// While a device in use doesn't keep voice clips (an older Daybook), no clip is relied on: its merge could drop a
    /// clip's record, and its sealer doesn't count a clip as live.
    func testBehaviorAnOlderDeviceInUseKeepsEveryRecordingAVoiceprintLearnedFrom() async throws {
        let cloud = try cloudFolder()
        let a = try await library("A", cloud: cloud, presence: true), b = try await library("B", cloud: cloud, presence: true)
        let (id, track) = try await conversation(in: a)
        teach(a, from: id, track: track)
        await pass(a); await pass(b); await pass(a)
        await a.makeVoiceClips(olderThan: .distantFuture)
        let walker = FileManager.default.enumerator(at: cloud, includingPropertiesForKeys: nil)
        let devices = try XCTUnwrap(walker?.compactMap { $0 as? URL }.first { $0.lastPathComponent == "Devices" })
        let deviceID = try XCTUnwrap(b.sync?.deviceID)
        var saved: (URL, Data)?
        for name in try FileManager.default.contentsOfDirectory(atPath: devices.path) where !name.hasPrefix(".") {
            let url = devices.appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            guard var record = try JSONSerialization.jsonObject(with: data) as? [String: Any], record["deviceID"] as? String == deviceID else { continue }
            saved = (url, data)
            record["features"] = (record["features"] as? [String] ?? []).filter { $0 != LibrarySyncEngine.voiceClipFeature }
            try JSONSerialization.data(withJSONObject: record).write(to: url)
        }
        let (url, data) = try XCTUnwrap(saved)
        let older = await a.coveredVoiceSources()
        XCTAssertEqual(older, [])
        let held = await compress(a, id, track)
        XCTAssertEqual(held, [])
        // Nor is a clip cut or named meanwhile: its record could be dropped, its object deleted.
        let (otherID, otherTrack) = try await conversation(in: a, seed: 5)
        teach(a, from: otherID, track: otherTrack)
        let none = await a.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(none, 0)
        XCTAssertNil(a.meeting(otherID)?.voiceClips)
        XCTAssertEqual(clipFiles(a, otherID), [])
        // The older device comes into use while a clip is cut: it isn't named (asked again under the lock).
        try data.write(to: url)
        let olderRecord = try JSONSerialization.data(withJSONObject: {
            var record = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            record["features"] = (record["features"] as? [String] ?? []).filter { $0 != LibrarySyncEngine.voiceClipFeature }
            return record
        }())
        a.voiceClipFault = { step in if step == .placed { try olderRecord.write(to: url) } }
        let late = await a.makeVoiceClips(olderThan: .distantFuture)
        a.voiceClipFault = nil
        XCTAssertEqual(late, 0)
        XCTAssertNil(a.meeting(otherID)?.voiceClips)
        try data.write(to: url)
        let updated = await a.coveredVoiceSources()
        XCTAssertEqual(updated, [key(id, track)])
        let compressed = await compress(a, id, track)
        XCTAssertEqual(compressed, [track.id])
    }

    /// A new Mac restoring the library from iCloud after A let the original go: the copy and the clip arrive, the
    /// original never does, and the voiceprint's speech is the clip's.
    func testBehaviorANewMacRestoringTheLibraryGetsTheClipAndReadsTheVoiceFromIt() async throws {
        let cloud = try cloudFolder()
        let a = try await library("A", cloud: cloud)
        let (id, before) = try await conversation(in: a)
        let (_, print) = teach(a, from: id, track: before)
        await pass(a)
        await a.makeVoiceClips(olderThan: .distantFuture)
        let compressed = await compress(a, id, before)
        XCTAssertEqual(compressed, [before.id])
        await pass(a)
        let removed = await a.finishCompressions()
        XCTAssertEqual(removed, 1, "the copy and the clip are in iCloud")
        await pass(a)
        let onA = try XCTUnwrap(clip(a, id))
        let c = try await library("C", cloud: cloud)
        await pass(c)
        let onC = try XCTUnwrap(c.meeting(id))
        XCTAssertNotNil(onC.tracks.first?.encoding)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(c, before.relativePath, in: id)), "the original never comes")
        XCTAssertEqual(onC.voiceClips, [onA])
        let clipOnC = URL(fileURLWithPath: path(c, onA.relativePath, in: id))
        XCTAssertEqual(try samples(clipOnC), try samples(URL(fileURLWithPath: path(a, onA.relativePath, in: id))))
        await c.verifyVoiceClips()
        let covered = await c.coveredVoiceSources()
        XCTAssertEqual(covered, [key(id, before)])
        let holding = await c.holdingBackVoiceprints()
        XCTAssertTrue(holding.isEmpty)
        let sample = await c.voiceSample(for: print)
        let fromClip = try XCTUnwrap(sample)
        XCTAssertTrue(fromClip.isClip)
        XCTAssertEqual(fromClip.url, clipOnC)
        // Only a Mac that cut the clip, or matched it against its own original, lets the original go from iCloud on its
        // strength: C never had the original, so to C it stays.
        let heldOnC = await c.meetingsHoldingOriginalsInICloud()
        XCTAssertEqual(heldOnC, [id])
        let heldOnA = await a.meetingsHoldingOriginalsInICloud()
        XCTAssertEqual(heldOnA, [], "its clip is in iCloud")
    }

    /// A clip another Mac cut is checked against this Mac's own original before this Mac lets that original go on its
    /// strength: its own cut of the clip's frames must give the clip's bytes. One that doesn't covers nothing here; the
    /// original stays, and this Mac cuts its own.
    func testBehaviorAClipFromAnotherMacIsCheckedAgainstThisMacsOriginalBeforeTheOriginalGoes() async throws {
        let cloud = try cloudFolder()
        let a = try await library("A", cloud: cloud), b = try await library("B", cloud: cloud)
        let (id, before) = try await conversation(in: a)
        teach(a, from: id, track: before)
        await pass(a); await pass(b)
        await a.makeVoiceClips(olderThan: .distantFuture)
        // What A names is a cut that isn't of this recording (another recording's samples, at the same frames), as a
        // Mac whose cutting went wrong would name it.
        let honest = try XCTUnwrap(clip(a, id))
        let elsewhere = try recording(seed: 9)
        let forged = try await VoiceClipAudio.extract(from: elsewhere, ranges: honest.ranges, into: root)
        let source = VoiceClipSource(meetingID: id, trackID: before.id, speakerID: speaker)
        var wrong = honest
        wrong.sha256 = forged.sha256; wrong.size = forged.size
        wrong.relativePath = VoiceClip.relativePath(for: source, sha256: forged.sha256)
        try FileManager.default.moveItem(at: forged.url, to: URL(fileURLWithPath: path(a, wrong.relativePath, in: id)))
        try FileManager.default.removeItem(atPath: path(a, honest.relativePath, in: id))
        a.update(id) { $0.voiceClips = [wrong] }
        try await a.flushDurably()
        await a.verifyVoiceClips()
        let compressed = await compress(a, id, before)
        XCTAssertEqual(compressed, [before.id])
        await pass(a); await pass(b); await pass(a); await pass(b)
        XCTAssertEqual(b.meeting(id)?.voiceClips, [wrong])
        await b.verifyVoiceClips()
        XCTAssertNotNil(b.meeting(id)?.tracks.first?.encoding)
        // Held whole and current, but not yet checked against B's own original: B's original stays.
        let unchecked = await b.finishCompressions()
        XCTAssertEqual(unchecked, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(b, before.relativePath, in: id)))
        // Checked: B's own cut gives other bytes, so it covers nothing here and is recorded so.
        let madeOnB = await b.makeVoiceClips(olderThan: nil)
        XCTAssertEqual(madeOnB, 0)
        XCTAssertEqual(b.voiceClipState()?.checked["\(id.uuidString)/\(wrong.relativePath)"]?.matches, false)
        let covered = await b.coveredVoiceSources()
        XCTAssertEqual(covered, [])
        let kept = await b.finishCompressions()
        XCTAssertEqual(kept, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(b, before.relativePath, in: id)))
        // Then B cuts its own from its original, which is the honest one, and lets its original go on that.
        let recut = await b.makeVoiceClips(olderThan: nil)
        XCTAssertEqual(recut, 1)
        XCTAssertEqual(b.meeting(id)?.voiceClips?.first?.sha256, honest.sha256, "the same bytes A's honest cut was")
        await pass(b)
        let removed = await b.finishCompressions()
        XCTAssertEqual(removed, 1)
    }

    /// A clip whose object is gone from iCloud holds nothing back: the conversation applies on another Mac without it,
    /// where the source stays uncovered (its original is kept), and comes back from a Mac that holds it.
    func testBehaviorAClipWhoseObjectIsGoneIsUploadedAgainByAMacThatHoldsIt() async throws {
        let cloud = try cloudFolder()
        let a = try await library("A", cloud: cloud), b = try await library("B", cloud: cloud)
        let (id, track) = try await conversation(in: a)
        teach(a, from: id, track: track)
        await pass(a); await pass(b)
        await a.makeVoiceClips(olderThan: .distantFuture)
        await pass(a)
        let clip = try XCTUnwrap(clip(a, id))
        let walker = FileManager.default.enumerator(at: cloud, includingPropertiesForKeys: nil)
        let object = try XCTUnwrap(walker?.compactMap { $0 as? URL }.first { $0.lastPathComponent == clip.sha256 })
        try FileManager.default.removeItem(at: object)
        await pass(b)
        XCTAssertEqual(b.meeting(id)?.voiceClips, [clip], "applied, naming the clip")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(b, clip.relativePath, in: id)))
        let uncovered = await b.coveredVoiceSources()
        XCTAssertEqual(uncovered, [])
        let held = await compress(b, id, track)
        XCTAssertEqual(held, [], "the original stays on B")
        await pass(a)
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path), "A put it back")
        await pass(b)
        await b.verifyVoiceClips()
        let covered = await b.coveredVoiceSources()
        XCTAssertEqual(covered, [key(id, track)])
    }

    /// An encrypted library tells its sealer, before each pass, which conversations' superseded originals voice profiles
    /// still need in iCloud (`meetingsHoldingOriginalsInICloud`): while the clip isn't there yet, this one's; once it is,
    /// none.
    func testBehaviorAnEncryptedLibraryTellsItsSealerWhichOriginalsVoiceProfilesStillNeed() async throws {
        let cloud = try cloudFolder()
        let local = root.appendingPathComponent("Mac", isDirectory: true)
        let sync = LibrarySyncController(localRoot: local, defaults: makeTestDefaults("daybook.voiceclips.sealed"))
        sync.replica.keyStore = MemoryLibraryKeyStore()
        sync.replica.sealsNewLibrary = true
        try sync.connect(to: cloud, monitorChanges: false)
        let library = LibraryController(rootURL: local, sync: sync)
        try await library.load()
        await pass(library)
        let sealed = await sync.engine?.sealsObjects
        XCTAssertEqual(sealed, true)
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        await pass(library)
        await library.makeVoiceClips(olderThan: .distantFuture)
        let compressed = await compress(library, id, track)
        XCTAssertEqual(compressed, [track.id])
        await pass(library)
        let first = await sync.engine?.originalsHeldForVoice
        XCTAssertEqual(first?.held, [id], "the clip wasn't in iCloud yet when the pass began")
        XCTAssertEqual(first?.judged, Set(library.meetings.map(\.id)))
        await pass(library)
        let later = await sync.engine?.originalsHeldForVoice
        XCTAssertEqual(later?.held, [])
    }

    // MARK: Clips that go with their recordings

    /// Deleted on one Mac and restored from the Trash on another: the conversation comes back under a new ID, and the
    /// voiceprints, which name the one deleted, are still covered by its clips, which come along and are never swept.
    func testBehaviorAConversationDeletedOnOneMacAndRestoredOnAnotherKeepsItsClips() async throws {
        let cloud = try cloudFolder()
        let a = try await library("A", cloud: cloud), b = try await library("B", cloud: cloud)
        let (id, track) = try await conversation(in: a)
        teach(a, from: id, track: track)
        await a.makeVoiceClips(olderThan: .distantFuture)
        await pass(a); await pass(b)
        let clip = try XCTUnwrap(clip(b, id))
        _ = try await a.moveToTrash(id)
        await pass(a); await pass(b)
        XCTAssertNil(b.meeting(id))
        let restored = try await b.restoreFromTrash(id)
        XCTAssertNotEqual(restored.id, id)
        let carried = try XCTUnwrap(restored.voiceClips?.first)
        XCTAssertEqual(carried.carriedFrom, VoiceClipSource(meetingID: id, trackID: track.id, speakerID: speaker))
        XCTAssertEqual(carried.relativePath, clip.relativePath)
        XCTAssertEqual(clipFiles(b, restored.id), [(clip.relativePath as NSString).lastPathComponent])
        await b.verifyVoiceClips()
        let covered = await b.coveredVoiceSources()
        XCTAssertEqual(covered, [key(id, track)])
        let holding = await b.holdingBackVoiceprints()
        XCTAssertTrue(holding.isEmpty)
        await pass(b)
        let now = Date()
        try age(path(b, carried.relativePath, in: restored.id), by: 3 * 86_400)
        await b.reconcileVoiceClips(now: now)
        let deleted = await b.reconcileVoiceClips(now: now.addingTimeInterval(3 * VoiceClips.orphanGrace))
        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(clipFiles(b, restored.id), [(clip.relativePath as NSString).lastPathComponent], "never swept")
        // It syncs with its clip: the other Mac is covered by it too.
        await pass(a)
        XCTAssertEqual(a.meeting(restored.id)?.voiceClips, [carried])
        XCTAssertEqual(try AudioDigest.sha256(fileURL: URL(fileURLWithPath: path(a, carried.relativePath, in: restored.id))), clip.sha256)
        await a.verifyVoiceClips()
        let onA = await a.coveredVoiceSources()
        XCTAssertEqual(onA, [key(id, track)])
    }

    /// Edited here while another Mac deleted it: what this Mac added is kept as a new conversation, with the clips.
    func testBehaviorAConversationKeptAfterAnotherMacDeletedItKeepsItsClips() async throws {
        let cloud = try cloudFolder()
        let a = try await library("A", cloud: cloud), b = try await library("B", cloud: cloud)
        let (id, track) = try await conversation(in: a)
        teach(a, from: id, track: track)
        await a.makeVoiceClips(olderThan: .distantFuture)
        await pass(a); await pass(b)
        let clip = try XCTUnwrap(clip(b, id))
        _ = try await a.moveToTrash(id)
        await pass(a)
        b.editNotes(id, text: "Added on B while A deleted it")
        await pass(b)
        let kept = try XCTUnwrap(b.meetings.first { $0.id != id && $0.notes.contains("Added on B") })
        let carried = try XCTUnwrap(kept.voiceClips?.first)
        XCTAssertEqual(carried.source(in: kept.id), VoiceClipSource(meetingID: id, trackID: track.id, speakerID: speaker))
        XCTAssertEqual(clipFiles(b, kept.id), [(clip.relativePath as NSString).lastPathComponent])
        await b.verifyVoiceClips()
        let covered = await b.coveredVoiceSources()
        XCTAssertEqual(covered, [key(id, track)])
        let now = Date()
        try age(path(b, carried.relativePath, in: kept.id), by: 3 * 86_400)
        await b.reconcileVoiceClips(now: now)
        await b.reconcileVoiceClips(now: now.addingTimeInterval(3 * VoiceClips.orphanGrace))
        XCTAssertEqual(clipFiles(b, kept.id).count, 1)
        XCTAssertEqual(b.meeting(kept.id)?.voiceClips, [carried])
    }

    /// Merged into another, a conversation's clips go with its recordings: the merged one names them, carried from it,
    /// and they still cover the voiceprints that name the conversation merged away.
    func testBehaviorMergingConversationsCarriesTheirClips() async throws {
        let library = try await self.library("Mac")
        let (first, firstTrack) = try await conversation(in: library)
        let (second, secondTrack) = try await conversation(in: library, seed: 2)
        library.update(first) { $0.date = Date().addingTimeInterval(-3_600) }
        teach(library, from: first, track: firstTrack)
        teach(library, from: second, track: secondTrack)
        let made = await library.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(made, 2)
        let own = try XCTUnwrap(clip(library, first)), folded = try XCTUnwrap(clip(library, second))
        let survivor = try await library.mergeConversations([first, second], audio: { track, id in try await library.audioURL(for: track, in: id) },
                                                            photo: { photo, id in try await library.photoURL(for: photo, in: id) },
                                                            context: { ConversationActions.Context(platform: .mac, status: ProcessingStatus($0)) })
        XCTAssertEqual(survivor, first)
        XCTAssertNil(library.meeting(second))
        let clips = try XCTUnwrap(library.meeting(first)?.voiceClips)
        XCTAssertEqual(clips.count, 2)
        XCTAssertTrue(clips.contains(own))
        let carried = try XCTUnwrap(clips.first { $0.carriedFrom != nil })
        XCTAssertEqual(carried.carriedFrom, folded.source(in: second))
        XCTAssertEqual(carried.relativePath, folded.relativePath)
        XCTAssertNotEqual(carried.trackID, secondTrack.id, "on the recording's copy in the merged conversation")
        XCTAssertEqual(try AudioDigest.sha256(fileURL: URL(fileURLWithPath: path(library, carried.relativePath, in: first))), folded.sha256)
        await library.verifyVoiceClips()
        let covered = await library.coveredVoiceSources()
        XCTAssertEqual(covered, [key(first, firstTrack), key(second, secondTrack)])
        let holding = await library.holdingBackVoiceprints()
        XCTAssertTrue(holding.isEmpty)
        let now = Date()
        await library.reconcileVoiceClips(now: now)
        let deleted = await library.reconcileVoiceClips(now: now.addingTimeInterval(3 * VoiceClips.orphanGrace))
        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(clipFiles(library, first).count, 2)
    }

    /// Move to New Conversation takes the recording's clip with it: the conversation it left names it no more, the new
    /// one names it carried from there, and the recording in its new conversation isn't held back for want of a clip.
    func testBehaviorARecordingMovedToANewConversationTakesItsClipWithIt() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        await library.makeVoiceClips(olderThan: .distantFuture)
        let clip = try XCTUnwrap(clip(library, id))
        let newID = try await library.moveRecordingToNewConversation(track.id, from: id, audio: { try await library.audioURL(for: $0, in: id) },
                                                                     undoManager: nil)
        XCTAssertNil(library.meeting(id)?.voiceClips)
        let moved = try XCTUnwrap(library.meeting(newID))
        let carried = try XCTUnwrap(moved.voiceClips?.first)
        XCTAssertEqual(carried.carriedFrom, clip.source(in: id))
        XCTAssertEqual(carried.trackID, moved.tracks.first?.id)
        XCTAssertEqual(clipFiles(library, newID), [(clip.relativePath as NSString).lastPathComponent])
        await library.verifyVoiceClips()
        let covered = await library.coveredVoiceSources()
        XCTAssertEqual(covered, [key(id, track)])
        let newTrack = try XCTUnwrap(moved.tracks.first)
        let compressed = await compress(library, newID, newTrack)
        XCTAssertEqual(compressed, [newTrack.id], "its clip came with it")
        // A day later the file left behind goes (the new conversation's is held whole), and the conversation it left
        // never names it again, though this Mac still has the record and the stamp it found it whole with.
        await library.reconcileVoiceClips(now: Date().addingTimeInterval(2 * VoiceClips.orphanGrace))
        XCTAssertNil(library.meeting(id)?.voiceClips)
        XCTAssertEqual(clipFiles(library, id), [])
        XCTAssertEqual(clipFiles(library, newID).count, 1)
        await library.reconcileVoiceClips(now: Date().addingTimeInterval(3 * VoiceClips.orphanGrace))
        XCTAssertNil(library.meeting(id)?.voiceClips)
    }

    /// A recording already compressed, moved to a new conversation: its copy there is still known by its original's
    /// bytes, so the clip carried with it is current and covers its voiceprints.
    func testBehaviorACompressedRecordingMovedToANewConversationKeepsItsClipCurrent() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        await library.makeVoiceClips(olderThan: .distantFuture)
        let compressed = await compress(library, id, track)
        XCTAssertEqual(compressed, [track.id])
        let copy = try XCTUnwrap(library.meeting(id)?.tracks.first)
        XCTAssertNotNil(copy.encoding)
        let newID = try await library.moveRecordingToNewConversation(track.id, from: id, audio: { try await library.audioURL(for: $0, in: id) },
                                                                     undoManager: nil)
        let moved = try XCTUnwrap(library.meeting(newID))
        let newTrack = try XCTUnwrap(moved.tracks.first)
        XCTAssertEqual(newTrack.sha256, copy.sha256)
        XCTAssertEqual(newTrack.encoding?.previousSHA256, track.sha256, "still known by its original's bytes")
        let carried = try XCTUnwrap(moved.voiceClips?.first)
        XCTAssertTrue(moved.voiceClipIsCurrent(carried))
        await library.verifyVoiceClips()
        let covered = await library.coveredVoiceSources()
        XCTAssertEqual(covered, [key(id, track)])
    }

    /// Undoing a move brings the recording back with the clip that went with it.
    func testBehaviorUndoingAMoveBringsItsClipBack() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        await library.makeVoiceClips(olderThan: .distantFuture)
        let clip = try XCTUnwrap(clip(library, id))
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let newID = try await library.moveRecordingToNewConversation(track.id, from: id, audio: { try await library.audioURL(for: $0, in: id) },
                                                                     undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertNil(library.meeting(id)?.voiceClips)
        undo.undo()
        try await waitUntil("the new conversation goes to the Trash") { library.meeting(newID) == nil }
        XCTAssertEqual(library.meeting(id)?.voiceClips, [clip])
        await library.verifyVoiceClips()
        let covered = await library.coveredVoiceSources()
        XCTAssertEqual(covered, [key(id, track)])
    }

    /// A Daybook from before clips that drops a clip's record in a merge leaves its file: a Mac that found it whole names
    /// it again while a voiceprint needs it; one with no record of it keeps the file, since the speech is still needed,
    /// and a cut of it again takes its name.
    func testBehaviorAClipRecordAMergeDroppedIsNamedAgain() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        await library.makeVoiceClips(olderThan: .distantFuture)
        let clip = try XCTUnwrap(clip(library, id))
        library.update(id) { $0.voiceClips = nil }
        try await library.flushDurably()
        let dropped = await library.coveredVoiceSources()
        XCTAssertEqual(dropped, [])
        let now = Date()
        // Not saved: nothing relies on a record the disk doesn't name.
        let folder = library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        await library.reconcileVoiceClips(now: now)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        XCTAssertNil(library.meeting(id)?.voiceClips)
        let unsaved = await library.coveredVoiceSources()
        XCTAssertEqual(unsaved, [])
        await library.reconcileVoiceClips(now: now)
        XCTAssertEqual(library.meeting(id)?.voiceClips, [clip], "named again")
        let reopened = try await self.library("Mac")
        XCTAssertEqual(reopened.meeting(id)?.voiceClips, [clip], "durably")
        let back = await library.coveredVoiceSources()
        XCTAssertEqual(back, [key(id, track)])
        // Not while its file isn't as it was found whole.
        library.update(id) { $0.voiceClips = nil }
        try await library.flushDurably()
        let file = URL(fileURLWithPath: path(library, clip.relativePath, in: id))
        let bytes = try Data(contentsOf: file)
        var damaged = bytes
        damaged[damaged.count - 3] ^= 0x01
        try damaged.write(to: file)
        await library.reconcileVoiceClips(now: now)
        XCTAssertNil(library.meeting(id)?.voiceClips)
        // With no record of it here, it isn't named again, and it stays: a voiceprint still needs its speech.
        try bytes.write(to: file)
        try FileManager.default.removeItem(at: library.rootURL.appendingPathComponent("voice-clips.json"))
        try age(file.path, by: 3 * 86_400)
        await library.reconcileVoiceClips(now: now.addingTimeInterval(3 * VoiceClips.orphanGrace))
        XCTAssertNil(library.meeting(id)?.voiceClips)
        XCTAssertEqual(clipFiles(library, id), [(clip.relativePath as NSString).lastPathComponent])
        let recut = await library.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(recut, 1)
        XCTAssertEqual(library.meeting(id)?.voiceClips?.first?.relativePath, clip.relativePath, "the same bytes, the same name")
    }

    /// What cleaning superseded originals out of iCloud asks: a source counts as covered there only once its clip's
    /// object is uploaded, and its conversation's originals stay (here and in iCloud) until it is.
    func testBehaviorAClipNotYetInICloudHoldsTheOriginalBack() async throws {
        let library = try await self.library("Mac", cloud: try cloudFolder())
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        await pass(library)
        await library.makeVoiceClips(olderThan: .distantFuture)
        let local = await library.coveredVoiceSources()
        XCTAssertEqual(local, [key(id, track)], "here, it covers the recording")
        var confirmed = await library.voiceSourcesConfirmedInCloud()
        XCTAssertEqual(confirmed, [])
        var holding = await library.meetingsHoldingOriginalsInICloud()
        XCTAssertEqual(holding, [id])
        let compressed = await compress(library, id, track)
        XCTAssertEqual(compressed, [track.id])
        await pass(library)
        confirmed = await library.voiceSourcesConfirmedInCloud()
        XCTAssertEqual(confirmed, [key(id, track)])
        holding = await library.meetingsHoldingOriginalsInICloud()
        XCTAssertEqual(holding, [])
        // Its passages change: the clip cut again isn't in iCloud yet, so the original stays, though the copy is.
        let earlier = try XCTUnwrap(clip(library, id))
        reassign(library, id, track)
        let recut = await library.makeVoiceClips(olderThan: nil)
        XCTAssertEqual(recut, 1)
        // The earlier cut, though a day old, stays while what sync last applied here names it.
        try age(path(library, earlier.relativePath, in: id), by: 2 * 86_400)
        await library.reconcileVoiceClips()
        XCTAssertEqual(clipFiles(library, id).count, 2)
        confirmed = await library.voiceSourcesConfirmedInCloud()
        XCTAssertEqual(confirmed, [])
        holding = await library.meetingsHoldingOriginalsInICloud()
        XCTAssertEqual(holding, [id])
        let kept = await library.finishCompressions()
        XCTAssertEqual(kept, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(library, track.relativePath, in: id)))
        await pass(library)
        confirmed = await library.voiceSourcesConfirmedInCloud()
        XCTAssertEqual(confirmed, [key(id, track)])
        let removed = await library.finishCompressions()
        XCTAssertEqual(removed, 1)
        await library.reconcileVoiceClips()
        XCTAssertEqual(clipFiles(library, id), [(try XCTUnwrap(clip(library, id)).relativePath as NSString).lastPathComponent])
    }

    /// A source is confirmed in iCloud only by the clip this Mac accepted for it (held whole, current, and matched against
    /// its own original): another conversation's clip of the same source that's uploaded, but unchecked here, confirms
    /// nothing while the accepted one isn't uploaded.
    func testBehaviorOnlyTheClipAcceptedHereConfirmsItsSourceInICloud() async throws {
        let cloud = try cloudFolder()
        let library = try await self.library("Mac", cloud: cloud)
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        await pass(library)
        await library.makeVoiceClips(olderThan: .distantFuture)
        await pass(library)
        let first = try XCTUnwrap(clip(library, id))
        var confirmed = await library.voiceSourcesConfirmedInCloud()
        XCTAssertEqual(confirmed, [key(id, track)])
        // A second conversation holds the same recording and names that first clip, carried there marked stale (it went
        // with a copy whose passages had changed): uploaded and held whole here, but not a clip this Mac accepts.
        let otherID = library.newMeeting(title: "Copy")
        let original = try await library.audioURL(for: track, in: id)
        await library.acquireLock()
        let ingested = try await library.ingest(original, into: otherID, provenance: .file(source: .microphone))
        library.releaseLock()
        let otherTrack = try XCTUnwrap(ingested.track)
        var carried = first.carried(from: id, to: otherTrack.id)
        carried.stale = true
        try library.copyVoiceClipFiles([carried], from: id, to: otherID)
        library.update(otherID) { $0.voiceClips = [carried] }
        try await library.flushDurably()
        await library.verifyVoiceClips()
        // The source's own clip is cut again (its passages changed), and not uploaded yet.
        reassign(library, id, track)
        let recut = await library.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(recut, 1)
        XCTAssertNotEqual(clip(library, id)?.sha256, first.sha256)
        confirmed = await library.voiceSourcesConfirmedInCloud()
        XCTAssertEqual(confirmed, [], "the clip accepted here isn't in iCloud yet")
        let holding = await library.meetingsHoldingOriginalsInICloud()
        XCTAssertEqual(holding?.contains(id), true, "and so its originals stay (the copy holding the same bytes too)")
        await pass(library)
        confirmed = await library.voiceSourcesConfirmedInCloud()
        XCTAssertEqual(confirmed, [key(id, track)])
    }

    // MARK: Letting clips go

    /// The sweep lets a file of a source's speech no clip names go only when a clip held here whole and current covers
    /// that source: one held whole but stale covers nothing, so a file of that speech a voiceprint still needs stays.
    func testBehaviorAStaleClipDoesntLetTheSweepTakeAnotherFileOfItsSpeech() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        teach(library, from: id, track: track)
        await library.makeVoiceClips(olderThan: .distantFuture)
        let clip = try XCTUnwrap(clip(library, id))
        // Another file of the same speech beside it that no record names (an earlier cut, say), a day old.
        let named = URL(fileURLWithPath: path(library, clip.relativePath, in: id))
        let other = named.deletingLastPathComponent().appendingPathComponent("\(key(id, track))-\(String(repeating: "0", count: 16)).caf")
        try FileManager.default.copyItem(at: named, to: other)
        try age(other.path, by: 2 * 86_400)
        library.update(id) { $0.voiceClips?[0].stale = true }
        try await library.flushDurably()
        await library.reconcileVoiceClips()
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "a stale clip covers nothing: the other file stays")
        // Current again (cut again), it covers the source, and the other file goes.
        library.update(id) { $0.voiceClips?[0].stale = nil }
        try await library.flushDurably()
        await library.reconcileVoiceClips()
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    }

    func testBehaviorAClipGoesADayAfterItsProfileIsDeletedAndAnUndoKeepsIt() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        let (profile, _) = teach(library, from: id, track: track)
        await library.makeVoiceClips(olderThan: .distantFuture)
        let name = try XCTUnwrap(clipFiles(library, id).first)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        library.deleteSpeakerProfile(profile.id, undoManager: undo)
        undo.endUndoGrouping()
        let now = Date(), clock = VoiceClipClock(boot: "boot", seconds: 1_000)
        let first = await library.reconcileVoiceClips(now: now, clock: clock)
        XCTAssertEqual(first, 0, "kept for a day")
        XCTAssertNotNil(library.voiceClipState()?.orphaned[key(id, track)])
        undo.undo()
        XCTAssertEqual(library.speakerProfiles.map(\.id), [profile.id])
        let afterUndo = await library.reconcileVoiceClips(now: now.addingTimeInterval(2 * VoiceClips.orphanGrace))
        XCTAssertEqual(afterUndo, 0, "the profile is back, and so is the clip's reason to stay")
        XCTAssertNil(library.voiceClipState()?.orphaned[key(id, track)])
        XCTAssertEqual(clipFiles(library, id), [name])
        library.deleteSpeakerProfile(profile.id)
        let marked = await library.reconcileVoiceClips(now: now, clock: clock)
        XCTAssertEqual(marked, 0)
        let early = await library.reconcileVoiceClips(now: now.addingTimeInterval(VoiceClips.orphanGrace - 60), clock: clock)
        XCTAssertEqual(early, 0)
        // The wall clock says a day passed, the continuous clock in the same boot an hour: the clock jumped, so it waits.
        let jumped = await library.reconcileVoiceClips(now: now.addingTimeInterval(2 * VoiceClips.orphanGrace),
                                                       clock: VoiceClipClock(boot: "boot", seconds: 1_000 + 3_600))
        XCTAssertEqual(jumped, 0)
        XCTAssertEqual(clipFiles(library, id), [name])
        let deleted = await library.reconcileVoiceClips(now: now.addingTimeInterval(VoiceClips.orphanGrace),
                                                        clock: VoiceClipClock(boot: "boot", seconds: 1_000 + VoiceClips.orphanGrace))
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(clipFiles(library, id), [])
        XCTAssertNil(library.meeting(id)?.voiceClips, "the conversation stops naming it first")
        let reopened = try await self.library("Mac")
        XCTAssertNil(reopened.meeting(id)?.voiceClips, "durably")
    }

    func testBehaviorAClipGoesWhenTheSpeakerIsTakenOutOfItsProfile() async throws {
        let library = try await self.library("Mac")
        let (id, track) = try await conversation(in: library)
        let (profile, print) = teach(library, from: id, track: track)
        // The profile learned from another conversation too: that voiceprint names another source, never this clip.
        let (elsewhereID, elsewhereTrack) = try await conversation(in: library, seed: 3)
        teach(library, from: elsewhereID, track: elsewhereTrack, profile: profile)
        // A second voiceprint of the same speaker (another embedding space, one that names no recording, as earlier
        // voiceprints don't) keeps the one clip they share.
        var other = print
        other.id = "vp-other"
        other.trackID = nil
        other.vector = VoiceVector(space: "older", values: [1, 0])
        library.updateMetadata { $0.voiceprints = ($0.voiceprints ?? []) + [LibraryValue(id: other.id, value: other)] }
        await library.makeVoiceClips(olderThan: .distantFuture)
        XCTAssertEqual(clipFiles(library, id).count, 1)
        XCTAssertEqual(clipFiles(library, elsewhereID).count, 1)
        let now = Date()
        library.removeVoiceprint(print.id)
        await library.reconcileVoiceClips(now: now)
        let kept = await library.reconcileVoiceClips(now: now.addingTimeInterval(2 * VoiceClips.orphanGrace))
        XCTAssertEqual(kept, 0, "another voiceprint still names the speaker")
        library.removeVoiceprint(other.id)
        await library.reconcileVoiceClips(now: now)
        let early = await library.reconcileVoiceClips(now: now.addingTimeInterval(VoiceClips.orphanGrace - 60))
        XCTAssertEqual(early, 0, "a day by the wall clock, with no continuous clock to compare")
        let deleted = await library.reconcileVoiceClips(now: now.addingTimeInterval(2 * VoiceClips.orphanGrace))
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(clipFiles(library, id), [])
        XCTAssertEqual(clipFiles(library, elsewhereID).count, 1, "the other conversation's voiceprint still names its own")
    }

    func testBehaviorNothingIsDeletedWhileARecordOrThisMacsRecordCantBeRead() async throws {
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
        XCTAssertEqual(clipFiles(library, id).count, 1)
        library.updateMetadata { $0.voiceprints?.removeAll { $0.id == "vp-new" } }
        // At launch, before sync has brought the settings, nothing goes either.
        let atLaunch = await library.reconcileVoiceClips(now: now.addingTimeInterval(2 * VoiceClips.orphanGrace), deleting: false)
        XCTAssertEqual(atLaunch, 0)
        // A record this version can't read: no clip is relied on, cut, or deleted.
        let stateURL = library.rootURL.appendingPathComponent("voice-clips.json")
        let state = try Data(contentsOf: stateURL)
        try Data(#"{"version":2}"#.utf8).write(to: stateURL)
        XCTAssertNil(library.voiceClipState())
        let unreadableCover = await library.coveredVoiceSources()
        XCTAssertEqual(unreadableCover, [])
        let unreadableState = await library.reconcileVoiceClips(now: now.addingTimeInterval(2 * VoiceClips.orphanGrace))
        XCTAssertEqual(unreadableState, 0)
        XCTAssertEqual(clipFiles(library, id).count, 1)
        XCTAssertEqual(try Data(contentsOf: stateURL), Data(#"{"version":2}"#.utf8), "a newer Daybook's record is left as it is")
        try state.write(to: stateURL)
        let deleted = await library.reconcileVoiceClips(now: now.addingTimeInterval(2 * VoiceClips.orphanGrace))
        XCTAssertEqual(deleted, 1)
    }

    func testBehaviorNothingGoesInASyncedLibraryBeforeItsSettingsAreHere() async throws {
        let library = try await self.library("Mac", cloud: try cloudFolder())
        let (id, track) = try await conversation(in: library)
        let (profile, _) = teach(library, from: id, track: track)
        await library.makeVoiceClips(olderThan: .distantFuture)
        library.deleteSpeakerProfile(profile.id)
        let current = await library.settingsAreCurrent()
        XCTAssertFalse(current)
        let now = Date()
        await library.reconcileVoiceClips(now: now)
        let early = await library.reconcileVoiceClips(now: now.addingTimeInterval(2 * VoiceClips.orphanGrace))
        XCTAssertEqual(early, 0)
        XCTAssertNil(library.voiceClipState()?.orphaned[key(id, track)], "not even marked")
        await pass(library)
        await library.reconcileVoiceClips(now: now)
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
        // An original that isn't the recording's bytes any more is never read for its speech: the clip is.
        let original = URL(fileURLWithPath: path(library, track.relativePath, in: id))
        let bytes = try Data(contentsOf: original)
        var damaged = bytes
        damaged[damaged.count - 9] ^= 0x40
        try damaged.write(to: original)
        let damagedSample = await library.voiceSample(for: print)
        XCTAssertEqual(damagedSample?.isClip, true)
        try bytes.write(to: original)
        await library.finishCompressions()
        let clipSample = await library.voiceSample(for: print)
        let fromClip = try XCTUnwrap(clipSample)
        XCTAssertTrue(fromClip.isClip)
        XCTAssertEqual(fromClip.spans, [VoiceClipSpan(start: 0, end: 3), VoiceClipSpan(start: 3, end: 6.5)])
        XCTAssertEqual(try embed(fromClip), heardFromOriginal, "the same speech, sample for sample")
        // With neither the original nor its clip, only the lossy copy is left: no sample.
        let clip = try XCTUnwrap(clip(library, id))
        try FileManager.default.removeItem(atPath: path(library, clip.relativePath, in: id))
        let none = await library.voiceSample(for: print)
        XCTAssertNil(none)
    }
}
