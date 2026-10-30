import DaybookKit
import XCTest
@testable import DaybookPhone

/// What iPhone backups hold: never copies Daybook can rebuild, and the library only while Settings ›
/// Storage › Include in iPhone Backups is on.
@MainActor
final class BackupExclusionTests: XCTestCase {
    func testRebuildableCopiesStayOutAndTheLibraryFollowsTheSetting() throws {
        let base = try temporaryDirectory()
        let root = base.appendingPathComponent("Daybook", isDirectory: true)
        let inbox = base.appendingPathComponent("Documents/Inbox", isDirectory: true)
        let meeting = UUID()
        let folders = ["Sync/Inbox", "Sync/Courier/Outbox", "Staging/Imports", "Staging/\(UUID().uuidString)", "Meetings/\(meeting.uuidString)/Audio"]
        for folder in folders { try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let downloaded = BackupExclusion.audioURL(meetingID: meeting, relativePath: "Audio/fetched.m4a", libraryRoot: root)
        let recordedHere = BackupExclusion.audioURL(meetingID: meeting, relativePath: "Audio/recorded.m4a", libraryRoot: root)
        try Data("a".utf8).write(to: downloaded)
        try Data("b".utf8).write(to: recordedHere)
        XCTAssertEqual(downloaded.path, root.appendingPathComponent("Meetings/\(meeting.uuidString)/Audio/fetched.m4a").path)

        let settings = PhoneSettings(defaults: makeTestDefaults("BackupExclusionTests"))
        XCTAssertTrue(settings.includesLibraryInBackups, "on unless turned off")
        BackupExclusion.apply(libraryRoot: root, inbox: inbox, includesLibrary: settings.includesLibraryInBackups)
        BackupExclusion.set(downloaded, excluded: true)   // as `excludeDownloads` does for fetched audio

        for folder in ["Sync/Inbox", "Sync/Courier", "Staging/Imports"] {
            XCTAssertTrue(BackupExclusion.isExcluded(root.appendingPathComponent(folder)), folder)
        }
        XCTAssertTrue(BackupExclusion.isExcluded(inbox))
        XCTAssertTrue(BackupExclusion.isExcluded(downloaded))
        XCTAssertFalse(BackupExclusion.isExcluded(root))
        XCTAssertFalse(BackupExclusion.isExcluded(recordedHere), "a recording made here is an original")
        XCTAssertFalse(BackupExclusion.isExcluded(root.appendingPathComponent("Meetings")))

        settings.includesLibraryInBackups = false
        BackupExclusion.apply(libraryRoot: root, inbox: inbox, includesLibrary: settings.includesLibraryInBackups)
        XCTAssertTrue(BackupExclusion.isExcluded(root), "the whole library stays out")

        settings.includesLibraryInBackups = true
        BackupExclusion.apply(libraryRoot: root, inbox: inbox, includesLibrary: settings.includesLibraryInBackups)
        XCTAssertFalse(BackupExclusion.isExcluded(root))
        XCTAssertTrue(BackupExclusion.isExcluded(root.appendingPathComponent("Sync/Courier")), "rebuildable copies stay out either way")
    }

    func testAnEncryptedLibraryKeepsItsConversationsOutUnlessIncluded() throws {
        let base = try temporaryDirectory()
        let root = base.appendingPathComponent("Daybook", isDirectory: true)
        let inbox = base.appendingPathComponent("Documents/Inbox", isDirectory: true)
        let kept = ["Meetings", "Trash", "Sync", "LiveCaptions"]
        for folder in kept + ["Sync/Courier", "Sync/Inbox", "Staging", "Devices"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        func excluded(_ folder: String) -> Bool { BackupExclusion.isExcluded(root.appendingPathComponent(folder)) }

        // How the choices combine.
        XCTAssertEqual(BackupExclusion.library(includesLibrary: true, encrypted: false, includesEncryptedLibrary: false), .whole)
        XCTAssertEqual(BackupExclusion.library(includesLibrary: false, encrypted: false, includesEncryptedLibrary: true), .none)
        XCTAssertEqual(BackupExclusion.library(includesLibrary: true, encrypted: true, includesEncryptedLibrary: false), .withoutEncryptedFolders,
                       "on for the plaintext library doesn't carry over")
        XCTAssertEqual(BackupExclusion.library(includesLibrary: false, encrypted: true, includesEncryptedLibrary: false), .none,
                       "off for the plaintext library still keeps the whole folder out")
        XCTAssertEqual(BackupExclusion.library(includesLibrary: false, encrypted: true, includesEncryptedLibrary: true), .whole,
                       "turned on for the encrypted library, it's included")
        let settings = PhoneSettings(defaults: makeTestDefaults("BackupExclusionTests"))
        XCTAssertFalse(settings.includesEncryptedLibraryInBackups, "off unless turned on")

        BackupExclusion.apply(libraryRoot: root, inbox: inbox, library: .withoutEncryptedFolders)
        for folder in kept { XCTAssertTrue(excluded(folder), folder) }
        XCTAssertFalse(BackupExclusion.isExcluded(root), "the library folder itself stays in")
        XCTAssertFalse(excluded("Staging")); XCTAssertFalse(excluded("Devices"))
        XCTAssertTrue(excluded("Sync/Courier")); XCTAssertTrue(BackupExclusion.isExcluded(inbox))

        BackupExclusion.apply(libraryRoot: root, inbox: inbox, library: .whole)
        for folder in kept { XCTAssertFalse(excluded(folder), folder) }
        XCTAssertTrue(excluded("Sync/Courier"), "rebuildable copies stay out either way")
        XCTAssertTrue(excluded("Sync/Inbox"))

        BackupExclusion.apply(libraryRoot: root, inbox: inbox, library: .none)
        XCTAssertTrue(BackupExclusion.isExcluded(root))
    }

    func testApplyingToALibraryThatDoesNotExistYetChangesNothing() throws {
        let base = try temporaryDirectory()
        let root = base.appendingPathComponent("Fresh", isDirectory: true)
        BackupExclusion.apply(libraryRoot: root, inbox: base.appendingPathComponent("Inbox"), includesLibrary: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "nothing is created")
    }
}
