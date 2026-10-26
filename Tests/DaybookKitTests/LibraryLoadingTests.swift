import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// Opening the library isn't all-or-nothing: damaged, unreadable, or newer settings and a
/// conversation that can't be saved at launch are notices, and the conversations still open.
@MainActor
final class LibraryLoadingTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookLoading-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        // Permissions some tests took away are given back so the folder can be removed.
        if let root {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            for path in (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(path).path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func open() async throws -> LibraryController {
        let library = LibraryController(rootURL: root, sync: nil)
        try await library.load()
        XCTAssertTrue(library.isLoaded)
        return library
    }

    private var settingsURL: URL { root.appendingPathComponent("library.json") }
    private var recoveryURL: URL { root.appendingPathComponent("library.recovery.json") }

    /// A library with one conversation and two saved folders.
    private func makeLibrary() async throws -> (conversation: UUID, folders: [String]) {
        let library = try await open()
        let id = library.newMeeting(title: "Kept")
        library.saveFolder(LibraryFolder(name: "Product"))
        await library.flush()
        library.saveFolder(LibraryFolder(name: "Research"))
        await library.flush()
        return (id, library.folders.map(\.name))
    }

    func testSavingSettingsKeepsThePreviousFileAsTheRecoveryCopy() async throws {
        _ = try await makeLibrary()
        let recovered = try JSONDecoder().decode(LibraryMetadata.self, from: Data(contentsOf: recoveryURL))
        XCTAssertEqual(recovered.folders.compactMap(\.value?.name), ["Product"])
    }

    func testDamagedSettingsRecoverFromTheirLastSavedCopy() async throws {
        let (id, _) = try await makeLibrary()
        try Data("{\"folders\": [".utf8).write(to: settingsURL)
        let library = try await open()
        XCTAssertNotNil(library.meeting(id))
        XCTAssertEqual(library.folders.map(\.name), ["Product"], "The last saved copy")
        XCTAssertNotNil(library.notice)
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("library.damaged-") }
        XCTAssertEqual(kept.count, 1, "The damaged file is kept")
    }

    func testAnEntryThisVersionCantReadIsLeftOutInsteadOfClosingTheLibrary() async throws {
        let (id, _) = try await makeLibrary()
        let template = SummaryTemplate(name: "Board update", instructions: "Numbers first.")
        var file = LibraryMetadata()
        file.folders = [.init(id: UUID().uuidString, value: LibraryFolder(name: "Product"))]
        file.templates = [.init(id: template.id, value: template)]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any])
        var templates = try XCTUnwrap(json["templates"] as? [[String: Any]])
        var value = try XCTUnwrap(templates[0]["value"] as? [String: Any])
        // A kind from a newer Daybook now reads (and round-trips) as an unknown kind; an entry whose shape this
        // version can't read at all is the one left out.
        value["name"] = ["not": "a name"]
        templates[0]["value"] = value
        json["templates"] = templates
        try JSONSerialization.data(withJSONObject: json).write(to: settingsURL)
        try FileManager.default.removeItem(at: recoveryURL)
        let library = try await open()
        XCTAssertNotNil(library.meeting(id))
        XCTAssertEqual(library.folders.map(\.name), ["Product"])
        XCTAssertFalse(library.templates.contains { $0.id == template.id })
        // Kept as it was, not dropped: saving settings writes the unreadable entry back unchanged.
        library.saveFolder(LibraryFolder(name: "Research"))
        await library.flush()
        let saved = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertTrue(saved.contains(template.id), "the entry a newer or damaged writer left survives")
    }

    func testSettingsFromANewerDaybookAreReadButNeverOverwritten() async throws {
        let (id, _) = try await makeLibrary()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        json["schemaVersion"] = 2
        let newer = try JSONSerialization.data(withJSONObject: json)
        try newer.write(to: settingsURL)
        let library = try await open()
        XCTAssertNotNil(library.meeting(id))
        XCTAssertEqual(library.folders.map(\.name), ["Product", "Research"])
        library.saveFolder(LibraryFolder(name: "Added here"))
        await library.flush()
        XCTAssertEqual(try Data(contentsOf: settingsURL), newer)
        XCTAssertNil(library.errorMessage)
    }

    func testUnreadableSettingsAreNotMistakenForMissingOnes() async throws {
        let (id, _) = try await makeLibrary()
        let before = try Data(contentsOf: settingsURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settingsURL.path)
        let library = try await open()
        XCTAssertNotNil(library.meeting(id))
        XCTAssertEqual(library.folders.map(\.name), ["Product"], "The recovery copy, read-only")
        library.saveFolder(LibraryFolder(name: "Would overwrite"))
        await library.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
        XCTAssertEqual(try Data(contentsOf: settingsURL), before, "Never overwritten with what could be read")
    }

    func testAnInterruptedConversationThatCantBeSavedStillOpens() async throws {
        let library = try await open()
        let id = library.newMeeting(title: "Was transcribing")
        library.update(id) { $0.status = .transcribing }
        await library.flush()
        let folder = root.appendingPathComponent("Meetings/\(id.uuidString)")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        let reopened = try await open()
        XCTAssertEqual(reopened.meeting(id)?.status, .imported)
        XCTAssertNotNil(reopened.errorMessage, "The failed save is reported")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try await reopened.flushDurably()
        let stored = try await MeetingStore(rootURL: root).load(id)
        XCTAssertEqual(stored.status, .imported, "Retried once the folder can be written")
    }

    func testOnlyWorkThisDeviceWasDoingIsMarkedInterrupted() async throws {
        let library = try await open()
        let own = library.newMeeting(title: "Transcribing here")
        library.update(own) { $0.status = .transcribing }
        await library.flush()
        LibraryController.drainLocalWorkWrites()
        // Another Mac's job, as a sync pass saves it: the status describes that Mac, not this one.
        var remote = Meeting(title: "Transcribing on Studio Mac")
        remote.status = .transcribing
        try await MeetingStore(rootURL: root).save(remote)

        let reopened = try await open()
        XCTAssertEqual(reopened.meeting(own)?.status, .imported)
        XCTAssertNotNil(reopened.meeting(own)?.errorMessage)
        XCTAssertEqual(reopened.meeting(remote.id)?.status, .transcribing, "another device's work is left alone")
        XCTAssertNil(reopened.meeting(remote.id)?.errorMessage)
        await reopened.flush()
        LibraryController.drainLocalWorkWrites()

        // The sweep cleared the record: the reset conversation, now processed elsewhere, isn't swept again.
        var elsewhere = try XCTUnwrap(reopened.meeting(own))
        elsewhere.status = .summarizing
        try await MeetingStore(rootURL: root).save(elsewhere)
        let again = try await open()
        XCTAssertEqual(again.meeting(own)?.status, .summarizing)
    }

    func testALibraryFromBeforeTheRecordResetsEveryInterruptedConversation() async throws {
        var meeting = Meeting(title: "Was transcribing")
        meeting.status = .transcribing
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await MeetingStore(rootURL: root).save(meeting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("local-work.json").path))
        let library = try await open()
        XCTAssertEqual(library.meeting(meeting.id)?.status, .imported)
    }
}
