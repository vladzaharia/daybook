import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// "Is this audio already here?" is answered from the digests in memory: the library's metadata
/// files aren't read again, and only a conversation that claims the bytes has its original hashed.
@MainActor
final class LibraryImportLookupTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookLookup-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ name: String, _ contents: String) throws -> URL {
        let folder = root.appendingPathComponent("Incoming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testFindsTheConversationHoldingTheBytesWithoutReadingTheLibraryAgain() async throws {
        let library = LibraryController(rootURL: root, sync: nil)
        try await library.load()
        let audio = try file("memo.m4a", "voice memo bytes")
        let holder = library.newMeeting(title: "Holder")
        let other = library.newMeeting(title: "Other")
        await library.acquireLock()
        _ = try await library.ingest(audio, into: holder, provenance: .file(source: .imported))
        _ = try await library.ingest(try file("other.m4a", "other bytes"), into: other, provenance: .file(source: .imported))
        library.releaseLock()
        await library.flush()
        // Damage the other conversation's metadata: reading the whole library would recover and rewrite it.
        let otherFolder = root.appendingPathComponent("Meetings/\(other.uuidString)")
        try Data("{damaged".utf8).write(to: otherFolder.appendingPathComponent("meeting.json"))

        let found = try await library.existingMeeting(containingAudioAt: audio)
        XCTAssertEqual(found?.id, holder)
        XCTAssertEqual(try Data(contentsOf: otherFolder.appendingPathComponent("meeting.json")), Data("{damaged".utf8),
                       "No other conversation's file was read or rewritten")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: otherFolder.path).contains { $0.hasPrefix("meeting.corrupt-") })
        let missing = try await library.existingMeeting(containingAudioAt: try file("new.m4a", "never imported"))
        XCTAssertNil(missing)
    }

    func testAStaleDigestDoesNotHideAMissingOriginal() async throws {
        let library = LibraryController(rootURL: root, sync: nil)
        try await library.load()
        let audio = try file("memo.m4a", "voice memo bytes")
        let id = library.newMeeting(title: "Holder")
        await library.acquireLock()
        let ingested = try await library.ingest(audio, into: id, provenance: .file(source: .imported))
        library.releaseLock()
        let original = try await library.audioURL(for: XCTUnwrap(ingested.track), in: id)
        try FileManager.default.removeItem(at: original)
        let found = try await library.existingMeeting(containingAudioAt: audio)
        XCTAssertNil(found, "The bytes must be imported again")
    }
}
