import XCTest
@testable import DaybookCore

final class LibraryPlacementTests: XCTestCase {
    func testLibrariesWrittenBeforePlacementAndDeviceIdentityStillDecode() throws {
        let track = RecordingTrack(source: .soundcore, relativePath: "Originals/a.wav", fileName: "a.wav",
                                   device: DeviceRecordingIdentity(kind: "soundcore.work", serial: "7F3A", recordingID: "1729000000"))
        let meeting = Meeting(title: "Older library", tracks: [track], placement: .personal)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
        object.removeValue(forKey: "placement")
        var tracks = try XCTUnwrap(object["tracks"] as? [[String: Any]])
        for key in ["deviceKind", "deviceSerial", "deviceRecordingID"] { tracks[0].removeValue(forKey: key) }
        object["tracks"] = tracks
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.placement)
        XCTAssertNil(decoded.tracks[0].deviceKind)
        XCTAssertNil(decoded.tracks[0].deviceSerial)
        XCTAssertNil(decoded.tracks[0].deviceRecordingID)
        XCTAssertNil(decoded.tracks[0].device)
    }

    func testPlacementMergesIndependentlyOfOtherEdits() {
        let base = Meeting(title: "Session")
        var local = base; local.placement = .personal
        var remote = base; remote.title = "Session with Dr. Ellis"
        let merged = MeetingMerge.merge(base: base, local: local, remote: remote).meeting
        XCTAssertEqual(merged.placement, .personal)
        XCTAssertEqual(merged.title, "Session with Dr. Ellis")
        XCTAssertEqual(MeetingMerge.merge(base: base, local: remote, remote: local).meeting.placement, .personal)
    }

    func testImportedDeviceRecordingKeepsItsIdentityAcrossReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookPlacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Soundcore-1729000000.wav")
        try Data(repeating: 7, count: 2_048).write(to: source)
        let store = try MeetingStore(rootURL: root)
        let meeting = Meeting(title: "From the recorder")
        try await store.save(meeting)
        let identity = DeviceRecordingIdentity(kind: "soundcore.work", serial: "7F3A", recordingID: "1729000000")
        _ = try await store.importAudio(from: source, into: meeting, source: .soundcore, device: identity)
        let loaded = try await MeetingStore(rootURL: root).load(meeting.id)
        XCTAssertEqual(loaded.tracks.first?.deviceKind, "soundcore.work")
        XCTAssertEqual(loaded.tracks.first?.deviceSerial, "7F3A")
        XCTAssertEqual(loaded.tracks.first?.deviceRecordingID, "1729000000")
        XCTAssertEqual(loaded.tracks.first?.device, identity)
    }

    func testSameBytesFromARecorderRecordItsIdentityOnTheExistingTrack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookPlacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("export.wav")
        try Data(repeating: 3, count: 2_048).write(to: source)
        let store = try MeetingStore(rootURL: root)
        let meeting = Meeting(title: "Exported earlier")
        try await store.save(meeting)
        let first = try await store.importAudio(from: source, into: meeting, source: .imported)
        XCTAssertNil(first.tracks.first?.device)
        let identity = DeviceRecordingIdentity(kind: "recorder.files", recordingID: "file:export.wav|2048")
        let second = try await store.importAudio(from: source, into: first, source: .imported, device: identity)
        XCTAssertEqual(second.tracks.count, 1, "The same bytes stay one recording")
        XCTAssertEqual(second.tracks.first?.device, identity)
    }
}
