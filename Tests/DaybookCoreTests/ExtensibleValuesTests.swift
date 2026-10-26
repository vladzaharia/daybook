import XCTest
@testable import DaybookCore

/// Synced enums written by a newer Daybook (docs/icloud-sync.md, "Newer versions").
final class ExtensibleValuesTests: XCTestCase {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: SyncEncoding.data(value)) as? [String: Any])
    }

    private func meetingJSON(kind: String = "general", status: String = "ready", placement: String? = nil,
                             source: String = "microphone", mode: String = "newAudio", stage: String? = "transcribing") throws -> Data {
        let track = UUID(), meeting = UUID()
        var object: [String: Any] = [
            "schemaVersion": 1, "id": meeting.uuidString, "title": "Planning", "date": 700_000_000.0, "updatedAt": 700_000_100.0,
            "kind": kind, "notes": "", "tracks": [[
                "id": track.uuidString, "source": source, "relativePath": "Originals/a.wav", "fileName": "a.wav",
                "createdAt": 700_000_000.0, "sha256": "",
            ]], "transcripts": [], "unifiedTranscript": [], "alignmentReports": [[
                "trackID": track.uuidString, "method": "audio", "offset": 0.0, "rate": 1.0, "matchedAnchors": 0, "explanation": "",
            ]], "revisions": [], "highlights": [], "speakers": [], "status": status,
            "processingRequests": [[
                "id": UUID().uuidString, "meetingID": meeting.uuidString, "mode": mode,
                "requestedBy": ["id": "phone", "name": "iPhone"], "createdAt": 700_000_000.0,
                "claim": ["device": ["id": "mac", "name": "Mac"], "claimedAt": 700_000_000.0, "heartbeat": 700_000_000.0,
                          "expiresAt": 700_000_600.0].merging(stage.map { ["stage": $0] } ?? [:]) { a, _ in a },
            ]],
        ]
        if let placement { object["placement"] = placement }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testKnownValuesEncodeExactlyAsBareEnumsDid() throws {
        let data = try meetingJSON()
        let meeting = try JSONDecoder().decode(Meeting.self, from: data)
        XCTAssertNil(meeting.placement)
        let encoded = try json(meeting)
        XCTAssertNil(encoded["placement"], "an absent optional stays absent, never null")
        XCTAssertEqual(encoded["kind"] as? String, "general")
        XCTAssertTrue(NSDictionary(dictionary: encoded).isEqual(to: try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])),
                      "decoding and encoding a meeting written before changes nothing")
        var placed = meeting
        placed.placement = .personal
        XCTAssertEqual(try json(placed)["placement"] as? String, "personal")
    }

    func testUnknownValuesReadAsFallbacksAndAreWrittenBackUnchanged() throws {
        let data = try meetingJSON(kind: "workshop", status: "queued", placement: "family", source: "watch", mode: "translate", stage: "translating")
        var meeting = try JSONDecoder().decode(Meeting.self, from: data)
        XCTAssertEqual(meeting.kind, .auto)
        XCTAssertEqual(meeting.status, .imported)
        XCTAssertNil(meeting.placement)
        XCTAssertEqual(meeting.tracks[0].source, .imported)
        let request = try XCTUnwrap(meeting.processingRequests?.first)
        XCTAssertFalse(request.isUnderstood)
        XCTAssertNil(request.claim?.stage)
        XCTAssertFalse(request.isClaimable(by: .init(id: "other", name: "Other Mac"), at: Date(timeIntervalSinceReferenceDate: 800_000_000)),
                       "a request this version can't read is never claimed here")
        // An unrelated edit here keeps every value the newer device wrote.
        meeting.notes = "Edited on an older Mac"
        let encoded = try json(meeting)
        XCTAssertEqual(encoded["kind"] as? String, "workshop")
        XCTAssertEqual(encoded["status"] as? String, "queued")
        XCTAssertEqual(encoded["placement"] as? String, "family")
        XCTAssertEqual((encoded["tracks"] as? [[String: Any]])?.first?["source"] as? String, "watch")
        let encodedRequest = try XCTUnwrap((encoded["processingRequests"] as? [[String: Any]])?.first)
        XCTAssertEqual(encodedRequest["mode"] as? String, "translate")
        XCTAssertEqual((encodedRequest["claim"] as? [String: Any])?["stage"] as? String, "translating")
        // Choosing a value here replaces it.
        meeting.kind = .interview
        meeting.placement = .work
        XCTAssertEqual(try json(meeting)["kind"] as? String, "interview")
        XCTAssertEqual(try json(meeting)["placement"] as? String, "work")
    }

    func testAnOlderDevicesUnrelatedEditDoesNotOverwriteANewerValueInAMerge() throws {
        let newer = try JSONDecoder().decode(Meeting.self, from: try meetingJSON(kind: "workshop", status: "queued"))
        // The older device decoded the newer snapshot and edited the notes; it encodes the same raw values back.
        var older = try JSONDecoder().decode(Meeting.self, from: SyncEncoding.data(newer))
        older.notes = "Older device's notes"
        var later = newer
        later.title = "Renamed on the newer device"
        let merged = MeetingMerge.merge(base: newer, local: later, remote: older).meeting
        XCTAssertEqual(merged.$kind.rawValue, "workshop")
        XCTAssertEqual(merged.$status.rawValue, "queued")
        XCTAssertEqual(merged.notes, "Older device's notes")
        XCTAssertEqual(merged.title, "Renamed on the newer device")
    }

    func testLibrarySettingsFromANewerVersionStayReadable() throws {
        var metadata = LibraryMetadata()
        metadata.recorders = [.init(id: "soundcore.work|S1", value: RecorderOwnership(kind: "soundcore.work", serial: "S1", ownerID: "watch",
                                                                                     ownerName: "Watch", ownerClass: .other))]
        var object = try json(metadata)
        var recorders = try XCTUnwrap(object["recorders"] as? [[String: Any]])
        var value = try XCTUnwrap(recorders[0]["value"] as? [String: Any])
        value["ownerClass"] = "watch"
        recorders[0]["value"] = value
        object["recorders"] = recorders
        object["templates"] = [["id": "custom-1", "modifiedAt": 700_000_000.0, "value": [
            "id": "custom-1", "name": "Workshop", "kind": "workshop", "instructions": "", "updatedAt": 700_000_000.0]]]
        let decoded = try JSONDecoder().decode(LibraryMetadata.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.recorderOwners.first?.ownerClass, .other)
        XCTAssertEqual(decoded.templates.first?.value?.kind, .auto)
        let again = try json(decoded)
        XCTAssertEqual((((again["recorders"] as? [[String: Any]])?.first?["value"]) as? [String: Any])?["ownerClass"] as? String, "watch")
        XCTAssertEqual((((again["templates"] as? [[String: Any]])?.first?["value"]) as? [String: Any])?["kind"] as? String, "workshop")
    }

    func testASettingInAShapeThisVersionCantReadTravelsOnUnchanged() throws {
        var metadata = LibraryMetadata()
        metadata.folders = [.init(id: "readable", value: LibraryFolder(name: "Readable"))]
        var object = try json(metadata)
        var folders = try XCTUnwrap(object["folders"] as? [[String: Any]])
        folders.append(["id": "future", "modifiedAt": 700_000_000.0, "value": ["name": ["en": "Later"], "color": 3]])
        object["folders"] = folders
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(LibraryMetadata.self, from: data)
        XCTAssertEqual(decoded.folders.compactMap(\.value).map(\.name), ["Readable"])
        XCTAssertTrue(decoded.hasUnreadableValues)
        let future = try XCTUnwrap(decoded.folders.first { $0.id == "future" })
        XCTAssertFalse(future.isDeletion, "a value this version can't read isn't a deletion")
        // Merged with this device's own settings and written again, it is exactly as it came.
        var here = LibraryMetadata()
        here.folders = [.init(id: "local", value: LibraryFolder(name: "Local"))]
        let merged = here.merging(decoded)
        let again = try XCTUnwrap((try json(merged)["folders"] as? [[String: Any]])?.first { $0["id"] as? String == "future" })
        XCTAssertTrue(NSDictionary(dictionary: again).isEqual(to: folders.last!))
        XCTAssertEqual(merged.folders.count, 3)
    }
}
