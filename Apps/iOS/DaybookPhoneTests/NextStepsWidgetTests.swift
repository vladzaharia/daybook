import DaybookCore
import DaybookKit
import XCTest

@testable import DaybookPhone

@MainActor
final class NextStepsWidgetTests: XCTestCase {
    func testProjectionIsBoundedGroupedDeterministicAndContainsOnlyAllowedFields() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let idA = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let idB = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let track = RecordingTrack(relativePath: "secret-audio.m4a", fileName: "secret-audio.m4a")
        let transcript = TranscriptSegment(trackID: track.id, start: 0, end: 1, text: "secret-transcript")
        let first = Meeting(
            id: idA, title: "First", date: start.addingTimeInterval(300), notes: "secret-notes",
            tracks: [track], unifiedTranscript: [transcript],
            summary: MeetingSummary(overview: "secret-overview", sections: [.init(heading: "secret-heading", body: "secret-body")],
                                    actionItems: [ActionItem(text: "A1", owner: "secret-owner"),
                                                  ActionItem(text: "completed-secret", completed: true),
                                                  ActionItem(text: "A2"), ActionItem(text: "A3")]))
        let second = Meeting(id: idB, title: "Second", date: first.date,
                             summary: MeetingSummary(overview: "", actionItems: [ActionItem(text: "B1"), ActionItem(text: "B2")]))
        let work = Meeting(title: "Work override", date: start.addingTimeInterval(200), kind: .personal,
                               summary: MeetingSummary(overview: "", actionItems: [ActionItem(text: "C1"), ActionItem(text: "C2")]),
                               placement: .work)
        let older = Meeting(title: "Older", date: start, summary: MeetingSummary(overview: "", actionItems: [ActionItem(text: "D1")]))
        let personal = Meeting(title: "Private", date: start.addingTimeInterval(500),
                               summary: MeetingSummary(overview: "", actionItems: [ActionItem(text: "secret-personal")]),
                               placement: .personal)
        let therapy = Meeting(title: "Therapy", date: start.addingTimeInterval(400), kind: .therapy,
                              summary: MeetingSummary(overview: "", actionItems: [ActionItem(text: "secret-therapy")]))
        let noSummary = Meeting(title: "No summary", date: start.addingTimeInterval(600))
        let meetings = [older, second, personal, work, noSummary, first, therapy]
        let snapshot = SharedNextSteps(meetings: meetings)
        XCTAssertEqual(snapshot, SharedNextSteps(meetings: Array(meetings.reversed())))
        XCTAssertEqual(snapshot.items.map(\.text), ["A1", "A2", "A3", "B1", "B2", "C1"])
        XCTAssertEqual(snapshot.items.map(\.meetingID), [idA, idA, idA, idB, idB, work.id])
        XCTAssertEqual(snapshot.items.map(\.title), ["First", "First", "First", "Second", "Second", "Work override"])
        XCTAssertEqual(snapshot.items.first?.date, first.date)
        XCTAssertEqual(Array(snapshot.items.prefix(1)).map(\.text), ["A1"])
        XCTAssertEqual(Array(snapshot.items.prefix(3)).map(\.text), ["A1", "A2", "A3"])
        for item in snapshot.items {
            XCTAssertEqual(AppDestination(widgetURL: WidgetLink.conversation(item.meetingID).url),
                           .conversation(item.meetingID))
        }

        let container = try temporaryDirectory("next-steps-privacy")
        XCTAssertNil(SharedNextSteps.load(from: container))
        XCTAssertTrue(snapshot.save(to: container))
        XCTAssertEqual(SharedNextSteps.load(from: container), snapshot)
        let data = try Data(contentsOf: SharedNextSteps.cache.snapshotFile(in: container))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["items"])
        let rows = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 6)
        XCTAssertTrue(rows.allSatisfy { Set($0.keys) == ["meetingID", "title", "date", "text"] })
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
        XCTAssertNil(SharedNextSteps.load(from: nil))

        struct Unbounded: Encodable { let items: [SharedNextSteps.Item] }
        let excessive = snapshot.items + snapshot.items
        XCTAssertEqual(SharedNextSteps(excessive).items.count, 6)
        XCTAssertTrue(SharedNextSteps.cache.save(Unbounded(items: excessive), to: container))
        XCTAssertEqual(SharedNextSteps.load(from: container)?.items.count, 6, "a decoded file is bounded too")
    }

    func testBothSnapshotsStayExcludedAcrossReplacementsAndLibraryBackupSettings() throws {
        let container = try temporaryDirectory("both-widget-backups")
        let library = container.appendingPathComponent("library", isDirectory: true)
        let meetings = library.appendingPathComponent("Meetings", isDirectory: true)
        let inbox = container.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        let recent = SharedRecentConversations([.init(id: UUID(), title: "Recent", date: Date())])
        let next = SharedNextSteps([.init(meetingID: UUID(), title: "Private title", date: Date(), text: "Private action")])
        XCTAssertEqual(SharedRecentConversations.cache.cacheDirectory(in: container), SharedNextSteps.cache.cacheDirectory(in: container))
        XCTAssertTrue(recent.save(to: container))
        XCTAssertTrue(next.save(to: container))
        for choice: BackupExclusion.Library in [.whole, .none, .withoutEncryptedFolders] {
            BackupExclusion.apply(libraryRoot: library, inbox: inbox, library: choice)
            XCTAssertTrue(BackupExclusion.isExcluded(SharedNextSteps.cache.cacheDirectory(in: container)))
            XCTAssertTrue(BackupExclusion.isExcluded(SharedNextSteps.cache.snapshotFile(in: container)))
            XCTAssertTrue(BackupExclusion.isExcluded(SharedRecentConversations.cache.snapshotFile(in: container)))
            XCTAssertEqual(SharedNextSteps.load(from: container), next)
            XCTAssertEqual(SharedRecentConversations.load(from: container), recent)
        }
        let updated = SharedNextSteps([.init(meetingID: UUID(), title: "Updated", date: Date(), text: "Updated action")])
        XCTAssertTrue(updated.save(to: container))
        XCTAssertTrue(BackupExclusion.isExcluded(SharedNextSteps.cache.snapshotFile(in: container)))
        XCTAssertTrue(BackupExclusion.isExcluded(SharedNextSteps.cache.cacheDirectory(in: container)))
        XCTAssertEqual(SharedNextSteps.load(from: container), updated)
        XCTAssertEqual(SharedRecentConversations.load(from: container), recent, "replacing one cache must not disturb the other")
    }

    func testUnexcludedSnapshotsAreRefusedAndWriteFailuresAreClosed() throws {
        let container = try temporaryDirectory("next-steps-fail-closed")
        let snapshot = SharedNextSteps([.init(meetingID: UUID(), title: "Title", date: Date(), text: "Action")])
        XCTAssertTrue(snapshot.save(to: container))
        let file = SharedNextSteps.cache.snapshotFile(in: container)
        let directory = SharedNextSteps.cache.cacheDirectory(in: container)
        BackupExclusion.set(file, excluded: false)
        XCTAssertFalse(BackupExclusion.isExcluded(SharedNextSteps.cache.snapshotFile(in: container)))
        XCTAssertNil(SharedNextSteps.load(from: container), "an unexcluded file is not published")
        XCTAssertTrue(snapshot.save(to: container))
        BackupExclusion.set(directory, excluded: false)
        XCTAssertFalse(BackupExclusion.isExcluded(SharedNextSteps.cache.cacheDirectory(in: container)))
        XCTAssertNil(SharedNextSteps.load(from: container), "an unexcluded directory is not published")
        XCTAssertFalse(SharedNextSteps.cache.save(snapshot, to: container, setExcluded: { _ in }),
                       "a reported success without exclusion is not enough")
        XCTAssertTrue(snapshot.save(to: container))
        XCTAssertEqual(SharedNextSteps.load(from: container), snapshot)

        enum ExclusionFailure: Error { case denied }
        let replacement = SharedNextSteps([.init(meetingID: UUID(), title: "Replacement", date: Date(), text: "New action")])
        XCTAssertFalse(SharedNextSteps.cache.save(replacement, to: container, setExcluded: { _ in
            throw ExclusionFailure.denied
        }), "directory exclusion must succeed before a write")
        XCTAssertEqual(SharedNextSteps.load(from: container), snapshot)
        var exclusions = 0
        XCTAssertFalse(SharedNextSteps.cache.save(replacement, to: container, setExcluded: { url in
            exclusions += 1
            guard exclusions < 2 else { throw ExclusionFailure.denied }
            try SharedWidgetCache.setExcluded(&url)
        }), "the temporary file must be excluded before it replaces the snapshot")
        XCTAssertEqual(exclusions, 2)
        XCTAssertEqual(SharedNextSteps.load(from: container), snapshot, "the last good snapshot survives exclusion failure")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["next-steps.json"],
                       "a failed file exclusion removes the temporary plaintext")

        let blocked = try temporaryDirectory("next-steps-directory-blocked")
        try Data("not a directory".utf8).write(to: SharedNextSteps.cache.cacheDirectory(in: blocked))
        XCTAssertFalse(snapshot.save(to: blocked))
        XCTAssertNil(SharedNextSteps.load(from: blocked))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SharedNextSteps.cache.snapshotFile(in: blocked).path))

        let blockedFile = try temporaryDirectory("next-steps-file-blocked")
        try FileManager.default.createDirectory(at: SharedNextSteps.cache.snapshotFile(in: blockedFile), withIntermediateDirectories: true)
        XCTAssertFalse(snapshot.save(to: blockedFile))
        XCTAssertNil(SharedNextSteps.load(from: blockedFile))
        let contents = try FileManager.default.contentsOfDirectory(atPath: SharedNextSteps.cache.cacheDirectory(in: blockedFile).path)
        XCTAssertEqual(contents, ["next-steps.json"], "failed writes leave no temporary plaintext behind")
    }

    func testLoadedLibraryPublishesOnlyVisibleChangesAndDropsPersonalAndTrash() async throws {
        let container = try temporaryDirectory("next-steps-publishing")
        let previous = SharedNextSteps([.init(meetingID: UUID(), title: "Previous", date: Date(), text: "Previous action")])
        XCTAssertTrue(previous.save(to: container))
        var publications: [SharedNextSteps] = []
        var environment = try PhoneAppEnvironment.test(self)
        environment.publishNextSteps = { snapshot in
            publications.append(snapshot)
            snapshot.save(to: container)
        }
        let library = PhoneLibrary(rootURL: try temporaryDirectory("next-steps-library"), installation: "INSTALL-1")
        let model = PhoneAppModel(recorder: RecorderRig().recorder, library: library, posture: DevicePosture(),
                                  options: DebugLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                                  environment: environment)
        await Task.yield()
        XCTAssertFalse(library.controller.isLoaded)
        XCTAssertTrue(publications.isEmpty)
        XCTAssertEqual(SharedNextSteps.load(from: container), previous, "a background launch preserves the last good snapshot")
        try await library.reload()
        try await waitUntil("empty loaded library") { publications.last == SharedNextSteps() }

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let actions = (0..<8).map { ActionItem(text: "Action \($0)", owner: "Owner") }
        let older = Meeting(title: "Older", date: date, summary: MeetingSummary(overview: "Overview", actionItems: actions))
        let newestAction = ActionItem(text: "Newest action")
        let newest = Meeting(title: "Newest", date: date.addingTimeInterval(60),
                             summary: MeetingSummary(overview: "", actionItems: [newestAction]))
        library.controller.add(older)
        library.controller.add(newest)
        try await waitUntil("six grouped actions") {
            publications.last?.items.map(\.text) == ["Newest action", "Action 0", "Action 1", "Action 2", "Action 3", "Action 4"]
        }
        let count = publications.count
        library.controller.update(older.id) {
            $0.notes = "Only in the library"
            $0.summary?.overview = "A different overview"
            $0.summary?.actionItems[0].owner = "Another owner"
            $0.summary?.actionItems[7].text = "Outside the first six"
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(publications.count, count, "notes, owner, overview, and outside-the-limit items do not republish")

        library.controller.setNextStep(newestAction.id, completed: true, in: newest.id)
        try await waitUntil("completed action disappears") {
            publications.last?.items.map(\.text) == ["Action 0", "Action 1", "Action 2", "Action 3", "Action 4", "Action 5"]
        }
        library.controller.setNextStep(newestAction.id, completed: false, in: newest.id)
        try await waitUntil("reopened action returns") { publications.last?.items.first?.text == "Newest action" }
        library.controller.setNextStep(newestAction.id, completed: true, in: newest.id)
        try await waitUntil("action completed again") { publications.last?.items.first?.text == "Action 0" }
        library.controller.update(older.id) {
            $0.title = "Renamed"
            $0.date = date.addingTimeInterval(120)
            $0.summary?.actionItems[0].text = "Edited action"
        }
        try await waitUntil("edited visible metadata") {
            publications.last?.items.first?.title == "Renamed" && publications.last?.items.first?.text == "Edited action"
                && publications.last?.items.first?.date == date.addingTimeInterval(120)
        }
        library.controller.update(older.id) { $0.kind = .therapy }
        try await waitUntil("classified Personal") { publications.last == SharedNextSteps() }
        library.controller.update(older.id) { $0.placement = .work }
        try await waitUntil("explicit Work override") { publications.last?.items.first?.text == "Edited action" }
        let moved = try await library.controller.moveToTrash(older.id)
        XCTAssertTrue(moved)
        try await waitUntil("moved to Trash") { publications.last == SharedNextSteps() }
        XCTAssertEqual(SharedNextSteps.load(from: container), publications.last)
        withExtendedLifetime(model) {}
    }

    func testFailedLibraryLoadKeepsLastGoodNextSteps() async throws {
        let container = try temporaryDirectory("next-steps-failed")
        let previous = SharedNextSteps([.init(meetingID: UUID(), title: "Last known", date: Date(), text: "Last action")])
        XCTAssertTrue(previous.save(to: container))
        var writes = 0
        var environment = try PhoneAppEnvironment.test(self)
        environment.publishNextSteps = { snapshot in
            writes += 1
            snapshot.save(to: container)
        }
        let root = try temporaryDirectory("next-steps-library-blocked").appendingPathComponent("library")
        try Data("not a directory".utf8).write(to: root)
        let library = PhoneLibrary(rootURL: root, installation: "INSTALL-1")
        let model = PhoneAppModel(recorder: RecorderRig().recorder, library: library, posture: DevicePosture(),
                                  options: DebugLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                                  environment: environment)
        await model.launch()
        await Task.yield()
        XCTAssertTrue(model.libraryFailedToOpen)
        XCTAssertFalse(library.controller.isLoaded)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(SharedNextSteps.load(from: container), previous)
    }

    func testNewNoteWidgetURLIsStrictAndCreatesANewNoteEachTime() async throws {
        XCTAssertEqual(WidgetLink.newNote.url.absoluteString, "daybook://new-note")
        let destination = try XCTUnwrap(AppDestination(widgetURL: WidgetLink.newNote.url))
        XCTAssertEqual(destination, .newNote)
        for invalid in ["https://new-note", "daybook://new-note/", "daybook://new-note/extra",
                        "daybook://new-note?x=1", "daybook://new-note#part", "daybook://user@new-note",
                        "daybook://new-note:123", "daybook://new-note-other"] {
            XCTAssertNil(AppDestination(widgetURL: try XCTUnwrap(URL(string: invalid))), invalid)
        }
        let library = PhoneLibrary(rootURL: try temporaryDirectory("new-note-library"), installation: "INSTALL-1")
        let session = ReadingSession()
        XCTAssertFalse(DestinationRouter.go(to: destination, in: session, library: library.controller))
        try await library.reload()
        XCTAssertTrue(DestinationRouter.go(to: destination, in: session, library: library.controller))
        let first = try XCTUnwrap(session.openID)
        XCTAssertEqual(session.focusNotesFor, first)
        let note = try XCTUnwrap(library.controller.meeting(first))
        XCTAssertTrue(note.notes.isEmpty)
        XCTAssertTrue(note.tracks.isEmpty, "opening a note does not record")
        XCTAssertTrue(DestinationRouter.go(to: destination, in: session, library: library.controller))
        let second = try XCTUnwrap(session.openID)
        XCTAssertNotEqual(first, second, "each tap creates a fresh note")
        XCTAssertEqual(session.focusNotesFor, second)
    }
}
