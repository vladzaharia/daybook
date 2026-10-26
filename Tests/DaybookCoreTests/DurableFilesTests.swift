import XCTest
@testable import DaybookCore

/// The durability barrier: what the store wrote since the last one is remembered, flushed, and
/// forgotten; durable writes leave a complete, user-only file and nothing else.
final class DurableFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Durable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testTheBarrierFlushesWhatAnImportWroteThenForgetsIt() async throws {
        let store = try MeetingStore(rootURL: root.standardizedFileURL)
        let source = root.appendingPathComponent("voice.wav")
        try Data("captured audio".utf8).write(to: source)
        let meeting = try await store.importAudio(from: source, into: Meeting(title: "Capture"))
        let folder = root.standardizedFileURL.appendingPathComponent("Meetings/\(meeting.id.uuidString)", isDirectory: true)
        let original = try await store.audioURL(for: meeting.tracks[0], in: meeting.id)
        let pending = await store.unsynchronizedWrites.map(\.standardizedFileURL.path)
        for expected in [original, original.deletingLastPathComponent(), folder.appendingPathComponent("meeting.json"),
                         folder.appendingPathComponent("meeting.recovery.json"), folder, folder.deletingLastPathComponent(),
                         root.standardizedFileURL] {
            XCTAssertTrue(pending.contains(expected.standardizedFileURL.path), "\(expected.lastPathComponent) is flushed at the barrier")
        }
        try await store.synchronizeWrites()
        let after = await store.unsynchronizedWrites
        XCTAssertTrue(after.isEmpty)
        // Moving to the Trash is part of the next barrier, so an acknowledged deletion can't come back.
        try await store.moveToTrash(meeting.id)
        let trashed = await store.unsynchronizedWrites.map(\.lastPathComponent)
        XCTAssertTrue(trashed.contains("Meetings") && trashed.contains("Trash"))
        try await store.synchronizeWrites()
    }

    func testADurableWriteReplacesTheFileCompletelyAndLeavesNothingBehind() throws {
        let file = root.appendingPathComponent("checkpoint.json")
        try Data("old".utf8).write(to: file)
        try DurableFiles.write(Data("new contents".utf8), to: file)
        XCTAssertEqual(try Data(contentsOf: file), Data("new contents".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["checkpoint.json"])
    }

    func testSynchronizingSkipsWhatNoLongerExists() throws {
        let file = root.appendingPathComponent("kept.json")
        try Data("kept".utf8).write(to: file)
        XCTAssertNoThrow(try DurableFiles.synchronize([root.appendingPathComponent("moved-away.json"), file, root]))
    }
}
