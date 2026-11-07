import DaybookCore
import DaybookKit
import XCTest

@testable import DaybookPhone

@MainActor
final class RecentConversationsWidgetTests: XCTestCase {
  func testSnapshotIsBoundedNewestFirstAndContainsOnlyAllowedMetadata() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var meetings = (0..<9).map { index in
      Meeting(
        title: "Conversation \(index)", date: start.addingTimeInterval(Double(index) * 60),
        notes: "Never publish these private notes")
    }
    meetings[8].placement = .personal
    meetings[7].kind = .therapy
    // An explicit Work placement overrides the detected Personal kind, as it does in Spotlight.
    meetings[6].kind = .personal
    meetings[6].placement = .work

    let snapshot = SharedRecentConversations(meetings: meetings)
    XCTAssertEqual(snapshot.conversations.map(\.id), [6, 5, 4, 3, 2, 1].map { meetings[$0].id })
    XCTAssertEqual(
      snapshot.conversations.map(\.title), [6, 5, 4, 3, 2, 1].map { meetings[$0].title })
    XCTAssertEqual(snapshot.conversations.first?.date, meetings[6].date)
    XCTAssertFalse(
      snapshot.conversations.contains { $0.id == meetings[7].id || $0.id == meetings[8].id })

    let container = try temporaryDirectory("recent-conversations")
    XCTAssertNil(
      SharedRecentConversations.load(from: container),
      "not loaded yet is distinct from an empty library")
    XCTAssertTrue(snapshot.save(to: container))
    XCTAssertEqual(SharedRecentConversations.load(from: container), snapshot)
    let data = try Data(contentsOf: SharedRecentConversations.cache.snapshotFile(in: container))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(Set(json.keys), ["conversations"])
    let rows = try XCTUnwrap(json["conversations"] as? [[String: Any]])
    XCTAssertTrue(rows.allSatisfy { Set($0.keys) == ["id", "title", "date"] })
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Never publish"))

    let tooMany = meetings.map {
      SharedRecentConversations.Conversation(id: $0.id, title: $0.title, date: $0.date)
    }
    XCTAssertEqual(SharedRecentConversations(tooMany).conversations.count, 6)
  }

  func testLegacyPreferenceIsRemovedWithoutBeingUsedAsSnapshot() throws {
    let defaults = makeTestDefaults("recent-conversations-legacy")
    defaults.set(
      Data("old title-bearing cache".utf8), forKey: SharedRecentConversations.legacyDefaultsKey)
    XCTAssertTrue(SharedRecentConversations.removeLegacySnapshot(from: defaults))
    XCTAssertNil(defaults.object(forKey: SharedRecentConversations.legacyDefaultsKey))
    XCTAssertFalse(SharedRecentConversations.removeLegacySnapshot(from: defaults))
    XCTAssertNil(SharedRecentConversations.load(from: nil))
  }

  func testSnapshotCacheStaysExcludedWithEncryptedLibraryExcluded() throws {
    let container = try temporaryDirectory("recent-conversations-backup")
    let library = container.appendingPathComponent("library", isDirectory: true)
    let meetings = library.appendingPathComponent("Meetings", isDirectory: true)
    let inbox = container.appendingPathComponent("inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
    let snapshot = SharedRecentConversations([
      .init(id: UUID(), title: "Private title", date: Date())
    ])
    XCTAssertTrue(snapshot.save(to: container))

    BackupExclusion.apply(libraryRoot: library, inbox: inbox, library: .withoutEncryptedFolders)
    XCTAssertTrue(BackupExclusion.isExcluded(meetings))
    XCTAssertTrue(
      BackupExclusion.isExcluded(SharedRecentConversations.cache.cacheDirectory(in: container)))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: SharedRecentConversations.cache.snapshotFile(in: container).path))
    XCTAssertTrue(BackupExclusion.isExcluded(SharedRecentConversations.cache.snapshotFile(in: container)))
    XCTAssertEqual(SharedRecentConversations.load(from: container), snapshot)

    let updated = SharedRecentConversations([.init(id: UUID(), title: "Updated", date: Date())])
    XCTAssertTrue(updated.save(to: container))
    XCTAssertTrue(
      BackupExclusion.isExcluded(SharedRecentConversations.cache.cacheDirectory(in: container)))
    XCTAssertTrue(BackupExclusion.isExcluded(SharedRecentConversations.cache.snapshotFile(in: container)))
    XCTAssertEqual(SharedRecentConversations.load(from: container), updated)
  }

  func testSnapshotIsNotWrittenWhenCacheDirectoryCannotBeCreated() throws {
    let container = try temporaryDirectory("recent-conversations-blocked")
    let directory = SharedRecentConversations.cache.cacheDirectory(in: container)
    try Data("not a directory".utf8).write(to: directory)
    let snapshot = SharedRecentConversations([.init(id: UUID(), title: "Private", date: Date())])
    XCTAssertFalse(snapshot.save(to: container))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: SharedRecentConversations.cache.snapshotFile(in: container).path))
    XCTAssertNil(SharedRecentConversations.load(from: container))
  }

  func testSnapshotReportsWriteFailure() throws {
    let container = try temporaryDirectory("recent-conversations-write-failure")
    let file = SharedRecentConversations.cache.snapshotFile(in: container)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    let snapshot = SharedRecentConversations([.init(id: UUID(), title: "Private", date: Date())])
    XCTAssertFalse(snapshot.save(to: container))
    XCTAssertNil(SharedRecentConversations.load(from: container))
  }

  func testLoadedLibraryPublishesChangesButNotUnloadedOrUnrelatedContent() async throws {
    let container = try temporaryDirectory("recent-conversations-snapshot")
    let previous = SharedRecentConversations([.init(id: UUID(), title: "Previous", date: Date())])
    XCTAssertTrue(previous.save(to: container))
    var publications: [SharedRecentConversations] = []
    var environment = try PhoneAppEnvironment.test(self)
    environment.publishRecentConversations = { snapshot in
      publications.append(snapshot)
      snapshot.save(to: container)
    }
    let library = PhoneLibrary(
      rootURL: try temporaryDirectory("library"), installation: "INSTALL-1")
    let model = PhoneAppModel(
      recorder: RecorderRig().recorder, library: library, posture: DevicePosture(),
      options: DebugLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
      environment: environment)
    await Task.yield()
    XCTAssertFalse(library.controller.isLoaded)
    XCTAssertTrue(publications.isEmpty)
    XCTAssertEqual(
      SharedRecentConversations.load(from: container), previous,
      "a background launch preserves the last snapshot")

    try await library.reload()
    try await waitUntil("empty loaded library") { publications.last == SharedRecentConversations() }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let older = library.controller.newMeeting(title: "Older", date: start)
    let newer = library.controller.newMeeting(title: "Newer", date: start.addingTimeInterval(60))
    let privateID = library.controller.newMeeting(
      title: "Private", date: start.addingTimeInterval(120), placement: .personal)
    try await waitUntil("recent rows") {
      publications.last?.conversations.map(\.id) == [newer, older]
    }

    library.controller.update(older) {
      $0.title = "Renamed"
      $0.date = start.addingTimeInterval(180)
    }
    try await waitUntil("renamed and reordered") {
      publications.last?.conversations.map(\.id) == [older, newer]
        && publications.last?.conversations.first?.title == "Renamed"
    }
    let beforeNotes = publications.count
    library.controller.update(older) { $0.notes = "Only in the library" }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(
      publications.count, beforeNotes, "content changes don't reload a metadata-only snapshot")

    library.controller.update(older) { $0.placement = .personal }
    try await waitUntil("made Personal") { publications.last?.conversations.map(\.id) == [newer] }
    library.controller.update(privateID) { $0.placement = .work }
    try await waitUntil("moved to Work") {
      publications.last?.conversations.map(\.id) == [privateID, newer]
    }
    let moved = try await library.controller.moveToTrash(privateID)
    XCTAssertTrue(moved)
    try await waitUntil("moved to Trash") { publications.last?.conversations.map(\.id) == [newer] }
    XCTAssertEqual(SharedRecentConversations.load(from: container), publications.last)
    let session = ReadingSession()
    session.open(newer)
    let trashed = try XCTUnwrap(
      AppDestination(widgetURL: WidgetLink.conversation(privateID).url))
    XCTAssertTrue(DestinationRouter.go(to: trashed, in: session, library: library.controller))
    XCTAssertEqual(session.place, .library(.section(.all)))
    XCTAssertFalse(session.reading)

    library.controller.update(newer) { $0.kind = .therapy }
    try await waitUntil("classified Personal") { publications.last == SharedRecentConversations() }
    withExtendedLifetime(model) {}
  }

  func testFailedLibraryLoadKeepsTheLastSnapshot() async throws {
    let container = try temporaryDirectory("recent-conversations-failed")
    let previous = SharedRecentConversations([.init(id: UUID(), title: "Last known", date: Date())])
    XCTAssertTrue(previous.save(to: container))
    var writes = 0
    var environment = try PhoneAppEnvironment.test(self)
    environment.publishRecentConversations = { snapshot in
      writes += 1
      snapshot.save(to: container)
    }
    let root = try temporaryDirectory("blocked").appendingPathComponent("library")
    try Data("not a directory".utf8).write(to: root)
    let library = PhoneLibrary(rootURL: root, installation: "INSTALL-1")
    let model = PhoneAppModel(
      recorder: RecorderRig().recorder, library: library, posture: DevicePosture(),
      options: DebugLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
      environment: environment)
    await model.launch()
    await Task.yield()
    XCTAssertTrue(model.libraryFailedToOpen)
    XCTAssertFalse(library.controller.isLoaded)
    XCTAssertEqual(writes, 0)
    XCTAssertEqual(SharedRecentConversations.load(from: container), previous)
  }

  func testWidgetLinksRouteExactlyAndWaitForTheLibrary() async throws {
    let id = UUID()
    XCTAssertEqual(AppDestination(widgetURL: WidgetLink.library.url), .library)
    XCTAssertEqual(
      AppDestination(widgetURL: WidgetLink.conversation(id).url), .conversation(id))
    for invalid in [
      "https://conversation/\(id)", "daybook://conversation/not-a-uuid",
      "daybook://conversation/\(id)/extra",
      "daybook://library/extra", "daybook://library?other=1", "daybook://user@library",
      "daybook://unknown",
    ] {
      XCTAssertNil(AppDestination(widgetURL: try XCTUnwrap(URL(string: invalid))), invalid)
    }

    let library = PhoneLibrary(
      rootURL: try temporaryDirectory("library"), installation: "INSTALL-1")
    let session = ReadingSession()
    let requested = try XCTUnwrap(
      AppDestination(widgetURL: WidgetLink.conversation(id).url))
    XCTAssertFalse(
      DestinationRouter.go(to: requested, in: session, library: library.controller),
      "wait until the library loads")
    try await library.reload()
    library.controller.add(Meeting(id: id, title: "The exact conversation"))
    XCTAssertTrue(DestinationRouter.go(to: requested, in: session, library: library.controller))
    XCTAssertEqual(session.openID, id)

    let missing = try XCTUnwrap(
      AppDestination(widgetURL: WidgetLink.conversation(UUID()).url))
    XCTAssertTrue(DestinationRouter.go(to: missing, in: session, library: library.controller))
    XCTAssertFalse(session.reading)
    XCTAssertEqual(
      session.place, .library(.section(.all)),
      "a deleted or not-yet-synced ID returns to the library")
  }
}
