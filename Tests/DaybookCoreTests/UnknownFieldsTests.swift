import XCTest
@testable import DaybookCore

/// Fields a newer Daybook adds to a conversation or to library settings survive this version: kept on
/// reading, written back after an edit made here, and merged key by key (docs/icloud-sync.md, "Newer
/// versions"). Synthetic future fields only.
final class UnknownFieldsTests: XCTestCase {
    private let track = UUID(), photo = UUID(), section = UUID(), action = UUID(), mark = UUID()

    /// A conversation with something of everything that carries its own keys.
    private func meeting() -> Meeting {
        var meeting = Meeting(title: "Design review", notes: "Agenda")
        meeting.tracks = [RecordingTrack(id: track, source: .microphone, relativePath: "Originals/mic.caf", fileName: "mic.caf", duration: 60, offset: 0)]
        meeting.highlights = [Highlight(id: mark, time: 12, text: "Decision")]
        meeting.summary = MeetingSummary(kind: .general, title: "Review", overview: "We agreed.",
                                         sections: [SummarySection(id: section, heading: "Decisions", body: "Ship it.")],
                                         actionItems: [ActionItem(id: action, text: "Write the notes", owner: "Alex")])
        meeting.photos = [MeetingPhoto(id: photo, relativePath: "Originals/Photos/\(photo.uuidString).jpg", fileName: "IMG_1.jpg",
                                       sha256: "abc", capturedAt: Date(timeIntervalSince1970: 1_800_000_000))]
        return meeting
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    /// The conversation as a newer Daybook wrote it: a key of its own on the conversation and on each
    /// thing inside it.
    private func future(_ meeting: Meeting) throws -> Meeting {
        var json = try object(meeting)
        json["mood"] = "focused"
        json["agenda"] = ["items": ["Budget", "Launch"], "locked": true]
        func change(_ key: String, _ edit: (inout [String: Any]) -> Void) {
            var list = json[key] as! [[String: Any]]
            edit(&list[0])
            json[key] = list
        }
        change("tracks") { $0["spatial"] = ["azimuth": 42.5] }
        change("highlights") { $0["color"] = "mint" }
        change("photos") { $0["faces"] = [["x": 1, "y": 2]] }
        var summary = json["summary"] as! [String: Any]
        summary["tone"] = "warm"
        var sections = summary["sections"] as! [[String: Any]]
        sections[0]["layout"] = "grid"
        summary["sections"] = sections
        var items = summary["actionItems"] as! [[String: Any]]
        items[0]["due"] = 1_800_086_400
        summary["actionItems"] = items
        json["summary"] = summary
        return try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testFieldsANewerDaybookAddsSurviveEditsMadeHere() throws {
        var edited = try future(meeting())
        XCTAssertEqual(edited.unknownFields["mood"], .string("focused"))
        // Edits this version makes, to the conversation and to what's inside it.
        edited.title = "Design review, renamed"
        edited.setNotes("Agenda\nBudget agreed")
        edited.tracks[0].offset = 1.5
        edited.highlights[0].text = "Decision, edited"
        edited.summary?.actionItems[0].completed = true
        edited.summary?.sections[0].body = "Ship it Friday."
        edited.setPhotoCaption(photo, caption: "Whiteboard")
        edited.tracks.append(RecordingTrack(source: .soundcore, relativePath: "Originals/r.wav", fileName: "r.wav"))

        let written = try object(edited)
        XCTAssertEqual(written["mood"] as? String, "focused")
        XCTAssertEqual((written["agenda"] as? [String: Any])?["items"] as? [String], ["Budget", "Launch"])
        XCTAssertEqual((written["agenda"] as? [String: Any])?["locked"] as? Bool, true)
        let tracks = try XCTUnwrap(written["tracks"] as? [[String: Any]])
        XCTAssertEqual((tracks[0]["spatial"] as? [String: Any])?["azimuth"] as? Double, 42.5)
        XCTAssertEqual(tracks[0]["offset"] as? Double, 1.5)
        XCTAssertNil(tracks[1]["spatial"], "a recording added here has none")
        XCTAssertEqual((written["highlights"] as? [[String: Any]])?.first?["color"] as? String, "mint")
        XCTAssertNotNil((written["photos"] as? [[String: Any]])?.first?["faces"])
        XCTAssertEqual((written["photos"] as? [[String: Any]])?.first?["caption"] as? String, "Whiteboard")
        let summary = try XCTUnwrap(written["summary"] as? [String: Any])
        XCTAssertEqual(summary["tone"] as? String, "warm")
        XCTAssertEqual((summary["sections"] as? [[String: Any]])?.first?["layout"] as? String, "grid")
        XCTAssertEqual((summary["actionItems"] as? [[String: Any]])?.first?["due"] as? Int, 1_800_086_400)
        XCTAssertEqual((summary["actionItems"] as? [[String: Any]])?.first?["completed"] as? Bool, true)

        // Read back, it's the same conversation, newer fields and all.
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(edited)), edited)
    }

    func testAConversationThisVersionWroteHasNoExtraKeysAndEncodesTheSameEachTime() throws {
        let original = meeting()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(Meeting.self, from: first)
        XCTAssertTrue(decoded.unknownFields.isEmpty)
        XCTAssertTrue(decoded.tracks[0].unknownFields.isEmpty && decoded.summary?.unknownFields.isEmpty == true)
        XCTAssertEqual(try encoder.encode(decoded), first)
        let keys = Set(try object(original).keys)
        XCTAssertFalse(keys.contains("unknownFields"), "nothing new is written")
    }

    func testAMergeKeepsANewerFieldOnlyOneCopyHas() throws {
        let base = meeting()
        let newer = try future(base)
        var older = base
        older.notes = "Agenda\nEdited on the other device"
        older.updatedAt = base.updatedAt.addingTimeInterval(5)
        let merged = MeetingMerge.merge(base: base, local: newer, remote: older).meeting
        XCTAssertEqual(merged.unknownFields["mood"], .string("focused"), "added on one side")
        XCTAssertEqual(merged.notes, "Agenda\nEdited on the other device")
        XCTAssertEqual(MeetingMerge.merge(base: base, local: older, remote: newer).meeting, merged, "commutative")
        XCTAssertEqual(MeetingMerge.merge(base: base, local: merged, remote: merged).meeting, merged, "idempotent")
        XCTAssertFalse(merged.revisions.contains { $0.field.hasPrefix("sync:") }, "no conflict")

        // With no common ancestor, the same.
        let unrelated = MeetingMerge.merge(base: nil, local: newer, remote: older).meeting
        XCTAssertEqual(unrelated.unknownFields["mood"], .string("focused"))
        XCTAssertEqual(MeetingMerge.merge(base: nil, local: older, remote: newer).meeting, unrelated)
    }

    func testANewerFieldChangedOnOneSideOrBothMergesDeterministically() throws {
        let base = try future(meeting())
        var calm = base, tense = base
        calm.unknownFields = UnknownFields(base.unknownFields.values.merging(["mood": .string("calm")]) { $1 })
        tense.unknownFields = UnknownFields(base.unknownFields.values.merging(["mood": .string("tense")]) { $1 })
        XCTAssertEqual(MeetingMerge.merge(base: base, local: calm, remote: base).meeting.unknownFields["mood"], .string("calm"),
                       "changed on one side")
        var removed = base
        removed.unknownFields = UnknownFields(base.unknownFields.values.filter { $0.key != "mood" })
        XCTAssertNil(MeetingMerge.merge(base: base, local: base, remote: removed).meeting.unknownFields["mood"], "removed on one side")

        let one = MeetingMerge.merge(base: base, local: calm, remote: tense), other = MeetingMerge.merge(base: base, local: tense, remote: calm)
        XCTAssertEqual(one.meeting, other.meeting, "the same whichever side is which")
        XCTAssertEqual(one.meeting.unknownFields["mood"], .string("tense"), "the greater encoding")
        let kept = try XCTUnwrap(one.meeting.revisions.first { $0.field == "sync:unknown:mood" })
        XCTAssertEqual([kept.oldValue, kept.newValue], ["\"calm\"", "\"tense\""], "the other value stays in History")
        XCTAssertEqual(one.meeting.unknownFields["agenda"], base.unknownFields["agenda"], "other keys untouched")
    }

    func testAPhotosNewerFieldsMergeWithTheRestOfIt() throws {
        let base = try future(meeting())
        var captioned = base, analysed = base
        captioned.setPhotoCaption(photo, caption: "Whiteboard")
        var faces = analysed.photos![0].unknownFields.values
        faces["faces"] = .array([])
        analysed.photos![0].unknownFields = UnknownFields(faces)
        let merged = MeetingMerge.merge(base: base, local: captioned, remote: analysed).meeting
        XCTAssertEqual(merged.photos?.first?.caption, "Whiteboard")
        XCTAssertEqual(merged.photos?.first?.unknownFields["faces"], .array([]))
        XCTAssertEqual(MeetingMerge.merge(base: base, local: analysed, remote: captioned).meeting.photos, merged.photos)
    }

    func testLibrarySettingsKeepNewerFieldsAndMergeANewerListItemByItem() throws {
        var metadata = LibraryMetadata()
        metadata.folders = [LibraryValue(id: "f", value: LibraryFolder(name: "Clients"), modifiedAt: Date(timeIntervalSince1970: 100))]
        metadata.templates = [LibraryValue(id: "t", value: SummaryTemplate(id: "t", name: "Retro", instructions: "Keep it short."),
                                           modifiedAt: Date(timeIntervalSince1970: 100))]
        metadata.recorders = [LibraryValue(id: "soundcore.work|S1", value: RecorderOwnership(kind: "soundcore.work", serial: "S1", ownerID: "mac",
                                                                                          ownerName: "Studio Mac", ownerClass: .mac))]
        var json = try object(metadata)
        func addKey(_ list: String, _ key: String, _ value: Any) {
            var items = json[list] as! [[String: Any]]
            var value0 = items[0]["value"] as! [String: Any]
            value0[key] = value
            items[0]["value"] = value0
            items[0]["modifiedBy"] = "mac"
            json[list] = items
        }
        addKey("folders", "color", "teal")
        addKey("templates", "audience", "team")
        addKey("recorders", "battery", 80)
        // A newer list of per-item records, as library settings keep them.
        json["people"] = [["id": "p1", "modifiedAt": 100, "value": ["name": "Priya"]]]
        var decoded = try JSONDecoder().decode(LibraryMetadata.self, from: JSONSerialization.data(withJSONObject: json))
        decoded.folders[0].value?.name = "Clients, renamed"
        let written = try object(decoded)
        let folder = try XCTUnwrap((written["folders"] as? [[String: Any]])?.first)
        XCTAssertEqual(folder["modifiedBy"] as? String, "mac")
        XCTAssertEqual((folder["value"] as? [String: Any])?["color"] as? String, "teal")
        XCTAssertEqual((folder["value"] as? [String: Any])?["name"] as? String, "Clients, renamed")
        XCTAssertEqual(((written["templates"] as? [[String: Any]])?.first?["value"] as? [String: Any])?["audience"] as? String, "team")
        XCTAssertEqual(((written["recorders"] as? [[String: Any]])?.first?["value"] as? [String: Any])?["battery"] as? Int, 80)
        XCTAssertEqual((written["people"] as? [[String: Any]])?.first?["id"] as? String, "p1")

        // Two devices each changed the newer list: merged item by item, the later change winning.
        var mine = decoded, theirs = decoded
        mine.unknownFields = UnknownFields(["people": .array([
            .object(["id": .string("p1"), "modifiedAt": .number(200), "value": .object(["name": .string("Priya S.")])]),
            .object(["id": .string("p2"), "modifiedAt": .number(150), "value": .object(["name": .string("Sam")])]),
        ])])
        theirs.unknownFields = UnknownFields(["people": .array([
            .object(["id": .string("p1"), "modifiedAt": .number(120), "value": .object(["name": .string("Priya")])]),
            .object(["id": .string("p3"), "modifiedAt": .number(160)]),
        ])])
        let merged = mine.merging(theirs)
        XCTAssertEqual(merged, theirs.merging(mine), "the same whichever side is which")
        guard case .array(let people)? = merged.unknownFields["people"] else { return XCTFail("\(merged.unknownFields)") }
        XCTAssertEqual(people.count, 3)
        XCTAssertEqual(people.first, .object(["id": .string("p1"), "modifiedAt": .number(200), "value": .object(["name": .string("Priya S.")])]))
        XCTAssertEqual(merged.merging(merged), merged, "idempotent")
    }
}
