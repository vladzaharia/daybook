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

    /// A merge that stops after the recordings are copied in: `gaining` gets another recording while its files are fetched.
    private func stoppedPartway(_ library: LibraryController, _ ids: [UUID], gaining: UUID) async throws {
        var added = false
        do {
            _ = try await library.mergeConversations(ids, audio: { track, id in
                if id == gaining, !added {
                    added = true
                    await library.acquireLock()
                    _ = try await library.ingest(try self.file("extra.wav"), into: gaining, provenance: .file(source: .imported, duration: 30))
                    library.releaseLock()
                }
                return try await library.audioURL(for: track, in: id)
            }, photo: { photo, id in try await library.photoURL(for: photo, in: id) }, context: context)
            XCTFail("merged")
        } catch {
            XCTAssertEqual(error as? ConversationMergeError, .changed)
        }
    }

    func testBehaviorAMergeThatStopsPartwayLeavesTheSurvivorAsItWasUntilItIsAskedForAgain() async throws {
        let library = try await open()
        let standup = try await conversation(library, "Standup", at: start, said: "Morning everyone")
        let planning = try await conversation(library, "Planning", at: start.addingTimeInterval(3_600), said: "Budget review first")
        let review = try await conversation(library, "Review", at: start.addingTimeInterval(7_200), said: "Retro notes")
        library.update(standup) { $0.status = .ready; $0.errorMessage = "Summary stopped" }
        try await stoppedPartway(library, [standup, planning, review], gaining: review)

        // The copies are in the survivor (found again by their bytes), out of sight.
        let survivor = try XCTUnwrap(library.meeting(standup))
        XCTAssertEqual(survivor.tracks.count, 3)
        XCTAssertEqual(survivor.status, .ready, "still the summarized conversation it was")
        XCTAssertEqual(survivor.errorMessage, "Summary stopped")
        XCTAssertTrue(survivor.removedTracks.isEmpty, "nothing to put back in Info › Audio")
        XCTAssertEqual(survivor.presentTracks.count, 1, "and out of its transcript and processing")
        XCTAssertEqual(survivor.tracks.filter(\.isPendingMerge).count, 2)
        XCTAssertNotNil(library.meeting(planning))
        // Nor is it worth a warning that the same recording is in two conversations.
        let remote = root.appendingPathComponent("Remote")
        let engine = try LibrarySyncEngine(localRoot: library.rootURL, remoteRoot: remote, deviceID: "A", replica: SyncReplicaConfiguration())
        let pass = try await engine.synchronize(meetings: library.meetings)
        XCTAssertFalse(pass.warnings.contains("The same recording is in more than one conversation. They stay separate."), "\(pass.warnings)")

        // Asked for again, it finishes with the copies it made, and nothing doubled.
        _ = try await merge([standup, planning, review], in: library)
        let merged = try XCTUnwrap(library.meeting(standup))
        XCTAssertEqual(merged.tracks.count, 4)
        XCTAssertEqual(merged.presentTracks.count, 4)
        XCTAssertFalse(merged.tracks.contains(where: \.isPendingMerge))
        XCTAssertEqual(merged.tracks.first { $0.mergedFrom == planning }?.alignment?.offset, 60)
        XCTAssertNil(merged.tracks.first { $0.mergedFrom == planning }?.removal)
        XCTAssertEqual(merged.revisions.filter { $0.kind == ConversationMerge.revisionField(planning) }.count, 1)
        XCTAssertEqual(merged.notes, "Standup notes\n\nPlanning notes\n\nReview notes")
    }

    func testBehaviorAMergeAskedForAgainAfterTheFoldBeforeTheTrashOnlyFinishesTheTrash() async throws {
        let library = try await open()
        let standup = try await conversation(library, "Standup", at: start, said: "Morning everyone")
        let planning = try await conversation(library, "Planning", at: start.addingTimeInterval(3_600), said: "Budget review first")
        _ = try await merge([standup, planning], in: library)
        let merged = try XCTUnwrap(library.meeting(standup))

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

    func testBehaviorARecordingThatMovedElsewhereWhileFilesCameLeavesItsCopyOutOfSightForTheMergeOfWhereItWent() async throws {
        let library = try await open()
        let standup = try await conversation(library, "Standup", at: start, said: "Morning everyone")
        let planning = try await conversation(library, "Planning", at: start.addingTimeInterval(3_600), said: "Budget review first")
        await library.acquireLock()
        _ = try await library.ingest(try file("whiteboard.wav"), into: planning, provenance: .file(source: .imported, duration: 30))
        library.releaseLock()
        let elsewhere = UUID()
        let movedBytes = try XCTUnwrap(library.meeting(planning)?.tracks.first?.sha256)
        var served = 0
        _ = try await library.mergeConversations([standup, planning], audio: { track, id in
            served += 1
            // Another device moved the first recording out while the second was fetched.
            if served == 2 { library.update(planning) { $0.tracks[0].removal = RecordingRemoval(removedAt: self.start, movedTo: elsewhere) } }
            return try await library.audioURL(for: track, in: id)
        }, photo: { photo, id in try await library.photoURL(for: photo, in: id) }, context: context)

        let merged = try XCTUnwrap(library.meeting(standup))
        XCTAssertEqual(merged.presentTracks.count, 2, "the survivor's own and the one that stayed")
        XCTAssertEqual(merged.presentTracks.last?.mergedFrom, planning)
        XCTAssertTrue(merged.removedTracks.isEmpty, "nothing to put back")
        XCTAssertEqual(merged.tracks.filter(\.isPendingMerge).count, 1, "the copy of the one that moved waits, out of sight, to be found by its bytes")
        XCTAssertEqual(merged.tracks.first(where: \.isPendingMerge)?.sha256, movedBytes)
    }

    func testBehaviorARecordingMovedOutOfTheSurvivorComesBackWhenItsConversationIsMergedIn() async throws {
        let library = try await open()
        let standup = try await conversation(library, "Standup", at: start, said: "Morning everyone")
        let trackID = try XCTUnwrap(library.meeting(standup)?.tracks.first?.id)
        let moved = try await library.moveRecordingToNewConversation(trackID, from: standup, audio: { try await library.audioURL(for: $0, in: standup) },
                                                                      undoManager: nil, at: start)
        XCTAssertTrue(try XCTUnwrap(library.meeting(standup)).tracks[0].isMovedOut)
        library.update(standup) { $0.date = self.start.addingTimeInterval(-1) }  // the earlier one stays

        _ = try await merge([standup, moved], in: library)
        let merged = try XCTUnwrap(library.meeting(standup))
        XCTAssertEqual(merged.tracks.count, 1, "its own recording, once")
        XCTAssertNil(merged.tracks[0].removal, "back in the conversation")
        XCTAssertTrue(merged.removedTracks.isEmpty)
        XCTAssertEqual(merged.revisions.filter { $0.field == "source:\(trackID.uuidString):put-back" }.map(\.newValue), ["Put back the Microphone recording"])
        XCTAssertEqual(merged.unifiedTranscript.map(\.text), ["Morning everyone"], "its transcript with it")
        XCTAssertTrue(library.trashedMeetingIDs().contains(moved))
    }

    // MARK: Privacy

    func testBehaviorAPersonalConversationMakesTheMergedConversationPersonal() async throws {
        for (survivorPlacement, foldedPlacement, expected): (LibraryPlacement?, LibraryPlacement?, LibraryPlacement?) in [
            (.work, .personal, .personal), (.personal, .work, .personal), (nil, .personal, .personal), (.work, .work, .work), (.work, nil, .work),
        ] {
            let library = try await open()
            let standup = try await conversation(library, "Standup", at: start, said: "Morning everyone")
            let planning = try await conversation(library, "Planning", at: start.addingTimeInterval(3_600), said: "Budget review first")
            library.setPlacement([standup], survivorPlacement)
            library.setPlacement([planning], foldedPlacement)
            let personal = [standup, planning].contains { library.meeting($0)?.effectivePlacement == .personal }
            _ = try await merge([standup, planning], in: library)
            XCTAssertEqual(library.meeting(standup)?.effectivePlacement, expected, "\(String(describing: survivorPlacement)) + \(String(describing: foldedPlacement))")
            XCTAssertEqual(personal, expected == .personal)
            root = makeTemporaryFolder("DaybookMerge")
        }
    }

    // MARK: Two devices

    func testBehaviorTwoDevicesThatMergeTheSameConversationsEndWithOneResult() async throws {
        let library = try await open()
        let standup = try await conversation(library, "Standup", at: start, said: "Morning everyone")
        let planning = try await conversation(library, "Planning", at: start.addingTimeInterval(3_600), said: "Budget review first", photo: true)
        let overlap = try await conversation(library, "Planning on iPhone", at: start.addingTimeInterval(3_660), said: "Hiring after lunch")
        library.update(planning) { $0.timedNotes = nil }
        try await library.flushDurably()
        // The other device holds the same library, then each merges it, as two devices (or a retry before sync) would.
        let other = root.appendingPathComponent("Other")
        try FileManager.default.copyItem(at: library.rootURL, to: other)
        let second = LibraryController(rootURL: other, sync: nil)
        try await second.load()
        let base = try XCTUnwrap(library.meeting(standup))
        let ids = [standup, planning, overlap]
        for device in [library, second] {
            _ = try await device.mergeConversations(ids, audio: { track, id in try await device.audioURL(for: track, in: id) },
                                                    photo: { photo, id in try await device.photoURL(for: photo, in: id) },
                                                    context: context, at: start)
        }
        let a = try XCTUnwrap(library.meeting(standup)), b = try XCTUnwrap(second.meeting(standup))
        XCTAssertEqual(a.tracks, b.tracks, "the same copies, with the same IDs")
        XCTAssertEqual(a.timedNotes, b.timedNotes)
        XCTAssertEqual(a.revisions.map(\.id), b.revisions.map(\.id))
        XCTAssertEqual(a.photos?.map(\.id), b.photos?.map(\.id))

        let joined = MeetingMerge.merge(base: base, local: a, remote: b)
        XCTAssertEqual(joined.warnings, [], "no conflict to keep in History")
        XCTAssertEqual(joined.meeting.tracks.count, 3, "each recording once")
        XCTAssertEqual(joined.meeting.revisions.filter { $0.kind == ConversationMerge.revisionField(planning) }.count, 1)
        XCTAssertEqual(joined.meeting.photos?.count, 1)
        XCTAssertEqual(joined.meeting.highlights.count, a.highlights.count)
        XCTAssertEqual(joined.meeting.timedNotes, a.timedNotes)
        XCTAssertFalse(joined.meeting.revisions.contains { if case .sync = $0.kind { return true } else { return false } })
    }

    // MARK: Waiting

    func testBehaviorItWaitsForARecordingMadeAlongsideAndForOneARecorderMakesNow() async throws {
        let library = try await open()
        let standup = try await conversation(library, "Standup", at: start, said: "Morning everyone")
        let planning = try await conversation(library, "Planning", at: start.addingTimeInterval(3_600), said: "Budget review first")
        let awaited = AwaitedRecording(deviceName: "Alex’s iPhone", deviceKind: "daybook.phone", since: start)
        let waiting: (Meeting) -> ConversationActions.Context = { meeting in
            ConversationActions.Context(platform: .mac, status: meeting.id == planning ? .awaitingRecordings([awaited]) : ProcessingStatus(meeting))
        }
        await assertRefused({ try await self.merge([standup, planning], in: library, context: waiting) }, .busy("Planning"))
        XCTAssertEqual(waiting(try XCTUnwrap(library.meeting(planning))).mergeBusy, "Waiting for a recording")
        // Another device's recording of it, known only as it syncs (`status`).
        library.update(planning) { $0.status = .recording }
        await assertRefused({ try await self.merge([standup, planning], in: library) }, .busy("Planning"))
        XCTAssertEqual(library.meeting(standup)?.tracks.count, 1, "nothing changed")
        let groups = ConversationActions.batch([standup, planning], in: library.meetings, context: .init(platform: .mac))
        XCTAssertEqual(groups.flatMap(\.actions).first { $0.id == .merge }?.availability, .unavailable("Recording now"))
    }

    func testBehaviorMergeIsOffForTheConversationsAMergeIsWorkingOnAndASecondOneWaits() async throws {
        let library = try await open()
        let standup = try await conversation(library, "Standup", at: start, said: "Morning everyone")
        let planning = try await conversation(library, "Planning", at: start.addingTimeInterval(3_600), said: "Budget review first")
        let gate = Gate()
        let first = Task { @MainActor in
            try await library.mergeConversations([standup, planning], audio: { track, id in
                await gate.wait()
                return try await library.audioURL(for: track, in: id)
            }, photo: { photo, id in try await library.photoURL(for: photo, in: id) }, context: self.context)
        }
        while library.mergingIDs.isEmpty { await Task.yield() }
        XCTAssertEqual(library.mergingIDs, [standup, planning])
        let groups = ConversationActions.batch([standup, planning], in: library.meetings, context: .init(platform: .mac), merging: library.mergingIDs)
        XCTAssertEqual(groups.flatMap(\.actions).first { $0.id == .merge }?.availability, .unavailable("Merging now"))
        await assertRefused({ try await self.merge([planning, standup], in: library) }, .busy("Standup"))
        gate.open()
        let survivor = try await first.value
        XCTAssertEqual(survivor, standup)
        XCTAssertTrue(library.mergingIDs.isEmpty)
        XCTAssertEqual(library.meeting(standup)?.tracks.count, 2, "merged once")
    }

    // MARK: Files that came meanwhile

    func testBehaviorAPhotoAddedToAFoldedConversationWhileFilesCameIsNotLeftBehind() async throws {
        let library = try await open()
        let standup = try await conversation(library, "Standup", at: start, said: "Morning everyone")
        let planning = try await conversation(library, "Planning", at: start.addingTimeInterval(3_600), said: "Budget review first")
        var added = false
        do {
            _ = try await library.mergeConversations([standup, planning], audio: { track, id in
                if !added {
                    added = true
                    _ = await library.importPhotos([try self.png()], into: planning, timing: PhotoTimingInput(capturedAt: self.start, time: 20))
                }
                return try await library.audioURL(for: track, in: id)
            }, photo: { photo, id in try await library.photoURL(for: photo, in: id) }, context: context)
            XCTFail("merged without its photo")
        } catch {
            XCTAssertEqual(error as? ConversationMergeError, .changed)
        }
        XCTAssertNotNil(library.meeting(planning), "nothing was lost")
        _ = try await merge([standup, planning], in: library)
        XCTAssertEqual(library.meeting(standup)?.photos?.count, 1, "the next try carries it")
    }

    // MARK: What a folded conversation holds

    func testBehaviorAFoldedConversationsEchoRemovedCopyAndRemovedAndMovedRecordingsAreCarriedAsTheyAre() async throws {
        let library = try await open()
        let standup = try await conversation(library, "Standup", at: start, said: "Morning everyone")
        let planning = try await conversation(library, "Planning", at: start.addingTimeInterval(3_600), said: "Budget review first")
        let original = try XCTUnwrap(library.meeting(planning)?.tracks.first)
        // The microphone's echo-removed copy, a recording the person removed, and one moved to a conversation of its own.
        await library.acquireLock()
        let derived = try await library.ingest(try file("derived.wav"), into: planning, provenance: .file(source: .microphone, duration: 60))
        let removed = try await library.ingest(try file("removed.wav"), into: planning, provenance: .file(source: .imported, duration: 20))
        let away = try await library.ingest(try file("away.wav"), into: planning, provenance: .file(source: .imported, duration: 20))
        library.releaseLock()
        let derivedID = try XCTUnwrap(derived.track?.id), removedID = try XCTUnwrap(removed.track?.id), awayID = try XCTUnwrap(away.track?.id)
        let destination = UUID()
        library.update(planning) { meeting in
            meeting.tracks[meeting.tracks.firstIndex { $0.id == derivedID }!].derivedFrom = original.id
            meeting.tracks[meeting.tracks.firstIndex { $0.id == derivedID }!].processing = "echo-removed"
            meeting.tracks[meeting.tracks.firstIndex { $0.id == removedID }!].removal = RecordingRemoval(removedAt: self.start)
            meeting.tracks[meeting.tracks.firstIndex { $0.id == awayID }!].removal = RecordingRemoval(removedAt: self.start, movedTo: destination)
        }
        _ = try await merge([standup, planning], in: library)
        let merged = try XCTUnwrap(library.meeting(standup))
        let copyOfOriginal = try XCTUnwrap(merged.tracks.first { $0.mergedFrom == planning && $0.sha256 == original.sha256 })
        let copyOfDerived = try XCTUnwrap(merged.tracks.first { $0.sha256 == derived.track?.sha256 })
        XCTAssertEqual(copyOfDerived.derivedFrom, copyOfOriginal.id, "the echo-removed copy is still made from its original, which is its copy now")
        XCTAssertEqual(copyOfDerived.processing, "echo-removed")
        XCTAssertEqual(copyOfDerived.alignment?.offset, copyOfOriginal.alignment?.offset, "placed after the standup with it")
        let copyOfRemoved = try XCTUnwrap(merged.tracks.first { $0.sha256 == removed.track?.sha256 })
        XCTAssertEqual(merged.removedTracks.map(\.id), [copyOfRemoved.id], "still removed, and can be put back")
        XCTAssertNil(copyOfRemoved.removal?.movedTo)
        XCTAssertNil(merged.tracks.first { $0.sha256 == away.track?.sha256 }, "the moved one is in its conversation, not carried")
        XCTAssertEqual(merged.presentTracks.count, 3)
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

/// Holds work at a point until the test lets it go.
@MainActor
private final class Gate {
    private var isOpen = false
    func open() { isOpen = true }
    func wait() async { while !isOpen { await Task.yield() } }
}
