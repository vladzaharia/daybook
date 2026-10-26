import XCTest
@testable import DaybookCore

/// Photos through the sync journal between independent temporary libraries and a shared temporary
/// folder, as the other sync tests do: no iCloud account, no camera, synthetic images only.
final class LibrarySyncPhotoTests: XCTestCase {
    private var root: URL!
    private var remote: URL { root.appendingPathComponent("Remote") }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookPhotoSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func apply(_ result: SyncResult, to name: String, using engine: LibrarySyncEngine) async throws {
        let store = try MeetingStore(rootURL: local(name))
        for meeting in result.meetings { try await store.save(meeting) }
        for id in result.deletedMeetingIDs { _ = try? await store.moveToTrash(id) }
        try await engine.acknowledge(result.checkpointID)
    }

    /// A conversation on Mac A with a recording and one photo taken during it.
    private func meetingWithPhoto(named name: String = "A") async throws -> (Meeting, MeetingPhoto, Data) {
        let store = try MeetingStore(rootURL: local(name))
        let audio = root.appendingPathComponent("audio.wav")
        try Data("original audio bytes".utf8).write(to: audio)
        var meeting = try await store.importAudio(from: audio, into: Meeting(title: "Whiteboard session"), source: .microphone, offset: 0)
        let bytes = SyntheticPhotos.data(.jpeg, seed: 3, exifDate: "2026:10:24 10:15:00", offset: "+02:00")
        let file = try SyntheticPhotos.write(bytes, named: "IMG_0001.JPG", in: root.appendingPathComponent("Camera"))
        let photo = try await store.storePhoto(from: file, in: meeting, capturedAt: Date(timeIntervalSince1970: 1_792_829_700),
                                               capturedAtSource: .camera, time: 42, origin: PhotoOrigin(kind: PhotoOrigin.macKind))
        meeting.addPhoto(photo)
        try await store.save(meeting)
        return (meeting, photo, bytes)
    }

    func testPhotosRoundTripAsContentAddressedBlobsWithTheirTiming() async throws {
        let (meeting, photo, bytes) = try await meetingWithPhoto()
        let a = try LibrarySyncEngine(localRoot: local("A"), remoteRoot: remote, deviceID: "A")
        let b = try LibrarySyncEngine(localRoot: local("B"), remoteRoot: remote, deviceID: "B")
        let published = try await a.synchronize(meetings: [meeting])
        try await apply(published, to: "A", using: a)
        // The original is one object named by its SHA-256, listed in the event's assets.
        let blob = remote.appendingPathComponent("Blobs/\(photo.sha256)")
        XCTAssertEqual(try Data(contentsOf: blob), bytes)
        let events = try FileManager.default.contentsOfDirectory(at: remote.appendingPathComponent("Events"), includingPropertiesForKeys: nil)
        let assets = try events.flatMap { url -> [[String: Any]] in
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            return object?["assets"] as? [[String: Any]] ?? []
        }
        XCTAssertTrue(assets.contains { $0["relativePath"] as? String == photo.relativePath && $0["sha256"] as? String == photo.sha256 })

        // Mac B (eager) copies and verifies the photo before the conversation applies.
        let pulled = try await b.synchronize(meetings: [])
        XCTAssertFalse(pulled.hasPendingTransfers)
        let arrived = try XCTUnwrap(pulled.meetings.first { $0.id == meeting.id })
        XCTAssertEqual(arrived.photo(photo.id), photo, "timing, origin, and capture date travel with it")
        XCTAssertEqual(arrived.timelineTime(of: photo), 42)
        let copy = local("B").appendingPathComponent("Meetings/\(meeting.id)/\(photo.relativePath)")
        XCTAssertEqual(try Data(contentsOf: copy), bytes, "byte for byte")
        try await apply(pulled, to: "B", using: b)

        // A deletion on B arrives on A as a deletion; the file stays on both.
        var edited = arrived
        edited.removePhoto(photo.id)
        try await MeetingStore(rootURL: local("B")).save(edited)
        let pushed = try await b.synchronize(meetings: [edited])
        try await apply(pushed, to: "B", using: b)
        let back = try await a.synchronize(meetings: [try await MeetingStore(rootURL: local("A")).load(meeting.id)])
        XCTAssertTrue(try XCTUnwrap(back.meetings.first { $0.id == meeting.id }).photo(photo.id)?.isRemoved == true)
        try await apply(back, to: "A", using: a)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local("A").appendingPathComponent("Meetings/\(meeting.id)/\(photo.relativePath)").path))
    }

    func testThePhoneAppliesAtOnceAndFetchesAPhotoToShowIt() async throws {
        let (meeting, photo, bytes) = try await meetingWithPhoto()
        let mac = try LibrarySyncEngine(localRoot: local("A"), remoteRoot: remote, deviceID: "A")
        try await apply(try await mac.synchronize(meetings: [meeting]), to: "A", using: mac)
        let phone = try LibrarySyncEngine(localRoot: local("Phone"), remoteRoot: remote, deviceID: "Phone",
                                          replica: .phone(displayName: "Alex's iPhone"))
        let pulled = try await phone.synchronize(meetings: [])
        XCTAssertEqual(pulled.pendingDownloads, 0, "a photo not on the phone is a normal state")
        let arrived = try XCTUnwrap(pulled.meetings.first)
        XCTAssertFalse(phone.isPhotoLocal(photo, in: meeting.id))
        try await apply(pulled, to: "Phone", using: phone)
        let url = try await phone.fetchPhoto(photo, in: meeting.id)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(phone.isPhotoLocal(photo, in: meeting.id))

        // A photo taken on the phone uploads like its recordings and arrives on the Mac.
        let store = try MeetingStore(rootURL: local("Phone"))
        var edited = try await store.load(meeting.id)
        XCTAssertEqual(edited.photos, arrived.photos)
        let phoneBytes = SyntheticPhotos.data(.heic, seed: 5)
        let file = try SyntheticPhotos.write(phoneBytes, named: "Photo.heic", in: root.appendingPathComponent("PhoneCamera"))
        let taken = try await store.storePhoto(from: file, in: edited, capturedAt: Date(), capturedAtSource: .camera,
                                               origin: PhotoOrigin(kind: "daybook.iphone", serial: "install-1", name: "Alex's iPhone"))
        edited.addPhoto(taken)
        try await store.save(edited)
        try await apply(try await phone.synchronize(meetings: [edited]), to: "Phone", using: phone)
        let onMac = try await mac.synchronize(meetings: [try await MeetingStore(rootURL: local("A")).load(meeting.id)])
        let merged = try XCTUnwrap(onMac.meetings.first)
        XCTAssertEqual(Set(merged.photos?.map(\.id) ?? []), [photo.id, taken.id])
        XCTAssertEqual(try Data(contentsOf: local("A").appendingPathComponent("Meetings/\(meeting.id)/\(taken.relativePath)")), phoneBytes)
        XCTAssertEqual(merged.photo(taken.id)?.origin?.name, "Alex's iPhone")
    }

    func testAPhotoWhoseObjectHasNotArrivedHoldsTheConversationOnAMacLikeAudio() async throws {
        let (meeting, photo, _) = try await meetingWithPhoto()
        let a = try LibrarySyncEngine(localRoot: local("A"), remoteRoot: remote, deviceID: "A")
        try await apply(try await a.synchronize(meetings: [meeting]), to: "A", using: a)
        let blob = remote.appendingPathComponent("Blobs/\(photo.sha256)")
        let saved = try Data(contentsOf: blob)
        try FileManager.default.removeItem(at: blob)
        let b = try LibrarySyncEngine(localRoot: local("B"), remoteRoot: remote, deviceID: "B")
        let waiting = try await b.synchronize(meetings: [])
        XCTAssertTrue(waiting.meetings.isEmpty)
        XCTAssertGreaterThan(waiting.pendingDownloads, 0)
        try await b.acknowledge(waiting.checkpointID)
        try saved.write(to: blob)
        let arrived = try await b.synchronize(meetings: [])
        XCTAssertEqual(arrived.meetings.first?.photo(photo.id)?.sha256, photo.sha256)
    }
}
