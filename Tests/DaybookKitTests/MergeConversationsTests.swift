import CoreGraphics
import DaybookCore
import DaybookTestSupport
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DaybookKit

/// Merge… in the library (`LibraryController.mergeConversations`): every recording and photo of the others is copied into
/// the earliest, which keeps its ID and gets everything they held; the others go to the Trash with their recordings marked
/// moved there; the merged conversation is asked to be transcribed again in full. It waits while any is busy, and one asked
/// for again after it stopped partway finishes. Synthetic files in a temporary library; nothing is transcribed.
@MainActor
final class MergeConversationsTests: XCTestCase {
    private var root: URL!
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUp() async throws {
        root = makeTemporaryFolder("DaybookMerge")
    }

    private func open() async throws -> LibraryController {
        let library = LibraryController(rootURL: root.appendingPathComponent("Library"), sync: nil)
        try await library.load()
        return library
    }

    /// A file of distinct bytes; nothing reads it as audio.
    private func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data((name + UUID().uuidString).utf8).write(to: url)
        return url
    }

    private func png() throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url = root.appendingPathComponent("whiteboard-\(UUID().uuidString).png")
        try (data as Data).write(to: url)
        return url
    }

    /// A conversation recorded at `date`: one minute of microphone at its timeline's zero, transcribed (`said`) and fused,
    /// with a bookmark on its timeline, notes, and with `photo` a photo taken 20 s in.
    private func conversation(_ library: LibraryController, _ title: String, at date: Date, said: String, photo: Bool = false) async throws -> UUID {
        let id = library.newMeeting(title: title, date: date)
        await library.acquireLock()
        let ingested = try await library.ingest(try file("\(title).wav"), into: id, provenance: .file(source: .microphone, duration: 60))
        library.releaseLock()
        let track = try XCTUnwrap(ingested.track?.id)
        library.update(id) { meeting in
            meeting.tracks[0].offset = 0
            meeting.tracks[0].startedAt = date
            meeting.transcripts = [TrackTranscript(trackID: track, segments: [TranscriptSegment(trackID: track, start: 1, end: 5, text: said,
                                                                                                speakerID: "\(title):S1")],
                                                   words: [TranscriptWord(text: said, start: 1, end: 5)])]
            meeting.speakers = [Speaker(id: "\(title):S1", name: "Speaker 1", sourceTrackID: track)]
            meeting.highlights = [Highlight(time: 3, text: "\(title) bookmark")]
            meeting.notes = "\(title) notes"
        }
        if photo {
            let added = await library.importPhotos([try png()], into: id, timing: PhotoTimingInput(capturedAt: date, time: 20))
            XCTAssertEqual(added.photos.count, 1)
        }
        await library.realign(id)
        return id
    }

    /// What this test's app knows of a conversation: only what the library says.
    private func context(_ meeting: Meeting) -> ConversationActions.Context {
        ConversationActions.Context(platform: .mac, status: ProcessingStatus(meeting))
    }

    private func merge(_ ids: [UUID], in library: LibraryController, context: ((Meeting) -> ConversationActions.Context)? = nil,
                       process: (@MainActor (UUID, ProcessingRequest.Mode) -> Void)? = nil) async throws -> UUID {
        try await library.mergeConversations(ids, audio: { track, id in try await library.audioURL(for: track, in: id) },
                                             photo: { photo, id in try await library.photoURL(for: photo, in: id) },
                                             context: context ?? self.context, process: process)
    }

    func testBehaviorTheOthersFoldIntoTheEarliestWithTheirRecordingsAndPhotosAndGoToTheTrash() async throws {
        let library = try await open()
        let standup = try await conversation(library, "Standup", at: start, said: "Morning everyone")
        let planning = try await conversation(library, "Planning", at: start.addingTimeInterval(3_600), said: "Budget review first", photo: true)
        let original = try XCTUnwrap(library.meeting(planning))
        var asked: [(UUID, ProcessingRequest.Mode)] = []

        let survivor = try await merge([planning, standup], in: library) { asked.append(($0, $1)) }
        XCTAssertEqual(survivor, standup, "the earliest keeps its ID")
        XCTAssertNil(library.meeting(planning))
        XCTAssertTrue(library.trashedMeetingIDs().contains(planning), "the other one is in the Trash")
        XCTAssertEqual(asked.map(\.0), [standup])
        XCTAssertEqual(asked.map(\.1), [.fullRetranscription], "transcribed again in full, as one")

        let merged = try XCTUnwrap(library.meeting(standup))
        XCTAssertEqual(merged.title, "Standup")
        XCTAssertEqual(merged.tracks.count, 2)
        let copy = try XCTUnwrap(merged.tracks.first { $0.mergedFrom == planning })
        XCTAssertEqual(copy.sha256, original.tracks[0].sha256, "the same recording")
        XCTAssertNil(copy.removal)
        let copied = try Data(contentsOf: try await library.audioURL(for: copy, in: standup))
        XCTAssertEqual(AudioDigest.sha256(data: copied), copy.sha256, "its audio is in the survivor's folder")
        XCTAssertEqual(copy.alignment?.method, .manual)
        XCTAssertEqual(copy.alignment?.offset, 60, "recorded an hour later: right after the standup's minute")
        XCTAssertEqual(merged.transcripts.first { $0.trackID == copy.id }?.words?.first?.text, "Budget review first", "its run, words and all")
        XCTAssertEqual(merged.unifiedTranscript.map(\.text), ["Morning everyone", "Budget review first"], "one transcript, in order")
        XCTAssertEqual(merged.unifiedTranscript.last?.start, 61)
        XCTAssertEqual(merged.highlights.map(\.time), [3, 63])
        XCTAssertEqual(merged.notes, "Standup notes\n\nPlanning notes")
        let photo = try XCTUnwrap(merged.photos?.first)
        XCTAssertEqual(photo.time, 80, "taken 20 s into the planning")
        let photoURL = try await library.photoURL(for: photo, in: standup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoURL.path))
        XCTAssertEqual(merged.revisions.last?.newValue, "Merged “Planning”")

        // What's in the Trash says its recordings are in the survivor now, so the library holds each recording once.
        let trashed = try XCTUnwrap(LibraryController.trashedMeeting(planning, in: root.appendingPathComponent("Library")))
        XCTAssertEqual(trashed.tracks.map { $0.removal?.movedTo }, [standup])
        XCTAssertTrue(trashed.tracks.allSatisfy(\.isMovedOut))
    }

    func testBehaviorItWaitsWhileAnyOfThemIsRecordedOrProcessedAnywhere() async throws {
        let library = try await open()
        let standup = try await conversation(library, "Standup", at: start, said: "Morning everyone")
        let planning = try await conversation(library, "Planning", at: start.addingTimeInterval(3_600), said: "Budget review first")

        // Asked for on another device: it waits, as Remove and Move do.
        library.requestProcessing(planning, mode: .summaryOnly)
        await assertRefused({ try await self.merge([standup, planning], in: library) }, .busy("Planning"))
        // Recording here.
        let recording: (Meeting) -> ConversationActions.Context = { meeting in
            ConversationActions.Context(platform: .mac, isRecording: meeting.id == standup)
        }
        await assertRefused({ try await self.merge([standup, planning], in: library, context: recording) }, .busy("Standup"))
        await assertRefused({ try await self.merge([standup], in: library) }, .tooFew)

        XCTAssertEqual(library.meeting(standup)?.tracks.count, 1, "nothing changed")
        XCTAssertNotNil(library.meeting(planning))
        XCTAssertTrue(library.trashedMeetingIDs().isEmpty)
    }

    private func assertRefused(_ work: () async throws -> UUID, _ expected: ConversationMergeError,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await work()
            XCTFail("merged", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ConversationMergeError, expected, file: file, line: line)
            XCTAssertFalse((error as? ConversationMergeError)?.errorDescription?.isEmpty ?? true)
        }
    }

    func testBehaviorAMergeAskedForAgainAfterItStoppedPartwayFinishesWithoutDoublingAnything() async throws {
        let library = try await open()
        let standup = try await conversation(library, "Standup", at: start, said: "Morning everyone")
        let planning = try await conversation(library, "Planning", at: start.addingTimeInterval(3_600), said: "Budget review first")
        // It stopped after copying the recording in: the copy waits in the survivor, out of its transcript.
        let original = try XCTUnwrap(library.meeting(planning)?.tracks.first)
        let source = try await library.audioURL(for: original, in: planning)
        await library.acquireLock()
        let ingested = try await library.ingest(source, into: standup, provenance: .file(source: .microphone))
        library.releaseLock()
        let leftover = try XCTUnwrap(ingested.track)
        library.update(standup) { meeting in
            let index = meeting.tracks.firstIndex { $0.id == leftover.id }!
            meeting.tracks[index].mergedFrom = planning
            meeting.tracks[index].removal = RecordingRemoval(removedAt: start)
        }

        _ = try await merge([standup, planning], in: library)
        let merged = try XCTUnwrap(library.meeting(standup))
        XCTAssertEqual(merged.tracks.map(\.id).count, 2, "the copy it made is the one used")
        XCTAssertEqual(merged.tracks.first { $0.id == leftover.id }?.alignment?.offset, 60)
        XCTAssertNil(merged.tracks.first { $0.id == leftover.id }?.removal, "and it's in the conversation now")

        // It stopped after folding in, before the other went to the Trash (here: put back from it).
        _ = try await library.restoreFromTrash(planning)
        XCTAssertNotNil(library.meeting(planning))
        let survivor = try await merge([standup, planning], in: library)
        XCTAssertEqual(survivor, standup)
        XCTAssertNil(library.meeting(planning), "it only goes to the Trash")
        let again = try XCTUnwrap(library.meeting(standup))
        XCTAssertEqual(again.tracks.count, 2)
        XCTAssertEqual(again.transcripts.count, merged.transcripts.count)
        XCTAssertEqual(again.notes, "Standup notes\n\nPlanning notes")
        XCTAssertEqual(again.revisions.filter { $0.kind == ConversationMerge.revisionField(planning) }.count, 1)
    }

    func testBehaviorOnTheIPhoneTheMergedConversationAsksAMacToTranscribeItAgain() async throws {
        let library = try await open()
        let standup = try await conversation(library, "Standup", at: start, said: "Morning everyone")
        let planning = try await conversation(library, "Planning", at: start.addingTimeInterval(3_600), said: "Budget review first")
        _ = try await merge([standup, planning], in: library) { id, mode in library.requestProcessing(id, mode: mode) }
        let requests = try XCTUnwrap(library.meeting(standup)?.openProcessingRequests)
        XCTAssertEqual(requests.map(\.mode), [.fullRetranscription])
        XCTAssertEqual(ConversationActions.Context(platform: .iPhone, status: ProcessingStatus(try XCTUnwrap(library.meeting(standup)))).mergeBusy,
                       "Waiting to process", "and it can't be merged again until a Mac has")
    }
}
