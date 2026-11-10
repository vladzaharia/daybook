import DaybookTestSupport
import XCTest
@testable import DaybookCore

/// An encrypted library's settings stay out of iPhone backups (`MeetingStore.excludeSettingsFromBackup`,
/// `GlossaryStore.excludeFromBackup`). The mark belongs to the file and every save replaces the file, so each save
/// marks its new file before the rename puts it in place.
final class SettingsBackupExclusionTests: XCTestCase {
    var root: URL!
    override func setUp() {
        root = makeTemporaryFolder("DaybookTests")
    }

    /// Read afresh: a URL keeps the resource values it read once.
    private func isExcluded(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: root.appendingPathComponent(name).path)
        return (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }

    private func hiddenFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }
    }

    func testEverySaveOfTheLibrarysSettingsStaysOutOfBackups() async throws {
        let store = try MeetingStore(rootURL: root)
        store.excludeSettingsFromBackup(true)
        // The first save writes both files; each later one swaps a new file in, the one it replaces becoming the recovery copy.
        for _ in 0..<3 {
            try await store.saveLibraryMetadata(LibraryMetadata())
            XCTAssertTrue(isExcluded("library.json"))
            XCTAssertTrue(isExcluded("library.recovery.json"))
        }
        XCTAssertEqual(try hiddenFiles(), [], "no temporary file is left")

        let glossary = try GlossaryStore(rootURL: root)
        glossary.excludeFromBackup(true)
        for definition in ["A notebook", "A meeting workspace"] {
            try await glossary.save([GlossaryTerm(term: "Daybook", definition: definition, approved: true)])
            XCTAssertTrue(isExcluded("glossary.json"))
            XCTAssertTrue(isExcluded("glossary.recovery.json"))
        }
        let terms = try await glossary.list()
        XCTAssertEqual(terms.map(\.definition), ["A meeting workspace"])
        XCTAssertEqual(try hiddenFiles(), [])
    }

    func testSettingsSavedBeforeTheRuleAreMarkedWhenTheirCopyIsReplaced() async throws {
        let store = try MeetingStore(rootURL: root)
        try await store.saveLibraryMetadata(LibraryMetadata())
        XCTAssertFalse(isExcluded("library.json"), "off unless the iPhone turns it on")
        XCTAssertFalse(isExcluded("library.recovery.json"))

        store.excludeSettingsFromBackup(true)
        try await store.saveLibraryMetadata(LibraryMetadata())
        XCTAssertTrue(isExcluded("library.json"))
        XCTAssertTrue(isExcluded("library.recovery.json"), "the file the save replaced, saved before the rule, is marked as it becomes the copy")

        store.excludeSettingsFromBackup(false)
        try await store.saveLibraryMetadata(LibraryMetadata())
        XCTAssertFalse(isExcluded("library.json"), "turned off, the next save goes back in")
    }

    func testADamagedSettingsFileKeptAsideStaysOutToo() async throws {
        let first = try MeetingStore(rootURL: root)
        try await first.saveLibraryMetadata(LibraryMetadata())
        try Data("{ not json".utf8).write(to: root.appendingPathComponent("library.json"))

        let store = try MeetingStore(rootURL: root)
        store.excludeSettingsFromBackup(true)
        let loaded = await store.loadLibraryMetadata()
        XCTAssertTrue(loaded.isWritable)
        let damaged = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("library.damaged-") }
        XCTAssertEqual(damaged.count, 1)
        XCTAssertTrue(isExcluded(damaged[0]))
        XCTAssertTrue(isExcluded("library.json"), "recovered from its copy, the new file is marked too")
    }
}
