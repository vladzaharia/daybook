import XCTest
@testable import DaybookCore

/// Merges with no common ancestor: two devices created the same conversation (a multipoint recording,
/// where the phone and the Mac each start the same conversation ID).
final class MeetingMergeTests: XCTestCase {
    private func assertLaws(_ a: Meeting, _ b: Meeting, base: Meeting? = nil, file: StaticString = #filePath, line: UInt = #line) -> Meeting {
        let forward = MeetingMerge.merge(base: base, local: a, remote: b)
        let reverse = MeetingMerge.merge(base: base, local: b, remote: a)
        XCTAssertEqual(forward.meeting, reverse.meeting, "commutative", file: file, line: line)
        XCTAssertEqual(forward.warnings, reverse.warnings, file: file, line: line)
        XCTAssertEqual(MeetingMerge.merge(base: base, local: forward.meeting, remote: forward.meeting).meeting, forward.meeting, "idempotent", file: file, line: line)
        return forward.meeting
    }

    func testAValueSetOnOneSideWinsOverAnUntouchedDefault() {
        let id = UUID(), folder = UUID(), start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // The phone joined: nothing set but its recording.
        let phone = Meeting(id: id, title: "Untitled Conversation", date: start.addingTimeInterval(4), status: .imported)
        var mac = Meeting(id: id, title: "Design review", date: start, kind: .interview, notes: "Decide the launch date", status: .recording,
                          timedNotes: [TimedNote(time: 12, text: "Decide the launch date")], folderID: folder, tags: ["launch"],
                          templateID: "custom-design", placement: .personal)
        mac.summary = MeetingSummary(overview: "Launch planning")
        mac.highlights = [Highlight(time: 30, text: "Date agreed")]
        let merged = assertLaws(phone, mac)
        XCTAssertEqual(merged.title, "Design review")
        XCTAssertEqual(merged.date, start, "the earlier start")
        XCTAssertEqual(merged.kind, .interview)
        XCTAssertEqual(merged.notes, mac.notes)
        XCTAssertEqual(merged.timedNotes, mac.timedNotes)
        XCTAssertEqual(merged.folderID, folder)
        XCTAssertEqual(merged.templateID, "custom-design")
        XCTAssertEqual(merged.placement, .personal)
        XCTAssertEqual(merged.tags, ["launch"])
        XCTAssertEqual(merged.summary, mac.summary)
        XCTAssertEqual(merged.highlights, mac.highlights)
        XCTAssertEqual(merged.status, .recording)
        XCTAssertFalse(merged.revisions.contains { $0.field.hasPrefix("sync:") }, "nothing conflicted")
        XCTAssertTrue(MeetingMerge.merge(base: nil, local: phone, remote: mac).warnings.isEmpty)
    }

    func testNotesMergeParagraphByParagraphInRecordingOrder() {
        let id = UUID()
        let agenda = TimedNote(text: "Agenda: launch")
        var mac = Meeting(id: id, notes: "Agenda: launch\nMac at ten\nMac at fifty")
        mac.timedNotes = [agenda, TimedNote(time: 10, text: "Mac at ten"), TimedNote(time: 50, text: "Mac at fifty")]
        var phone = Meeting(id: id, notes: "Agenda: launch\nPhone at thirty")
        let phoneNote = TimedNote(time: 30, text: "Phone at thirty")
        phone.timedNotes = [TimedNote(text: "Agenda: launch"), phoneNote]
        let merged = assertLaws(mac, phone)
        XCTAssertEqual(merged.notes, "Agenda: launch\nMac at ten\nPhone at thirty\nMac at fifty")
        XCTAssertEqual(merged.timedNotes?.map(\.text), ["Agenda: launch", "Mac at ten", "Phone at thirty", "Mac at fifty"])
        XCTAssertEqual(merged.timedNotes?.first { $0.text == "Phone at thirty" }, phoneNote)
        XCTAssertEqual(merged.paragraphTimes(), [nil, 10, 30, 50])
        XCTAssertFalse(merged.revisions.contains { $0.field.hasPrefix("sync:") })

        // Notes without anchors on either side merge the same way, and stay without anchors.
        let plain = assertLaws(Meeting(id: id, notes: "First thought"), Meeting(id: id, notes: "Second thought\nFirst thought"))
        XCTAssertEqual(plain.notes, "Second thought\nFirst thought", "a side holding every paragraph is kept as written")
        XCTAssertNil(plain.timedNotes)
        let both = assertLaws(Meeting(id: id, notes: "Mac idea"), Meeting(id: id, notes: "Phone idea"))
        XCTAssertEqual(Set(both.notes.components(separatedBy: "\n")), ["Mac idea", "Phone idea"])
    }

    func testOnlyTwoDifferentSetValuesConflict() {
        let id = UUID()
        let a = Meeting(id: id, title: "Mac's name", folderID: UUID(), templateID: "one")
        let b = Meeting(id: id, title: "Phone's name", folderID: UUID(), templateID: "one")
        let merged = assertLaws(a, b)
        let fields = Set(merged.revisions.map(\.field))
        XCTAssertTrue(fields.contains("sync:title"))
        XCTAssertTrue(fields.contains("sync:folder"))
        XCTAssertFalse(fields.contains("sync:template"), "the same value on both sides isn't a conflict")
        XCTAssertEqual(merged.templateID, "one")
    }

    func testPlaceholderTitlesAndDefaultsResolveWithoutAConflict() {
        let id = UUID()
        let merged = assertLaws(Meeting(id: id, title: "Untitled meeting"), Meeting(id: id, title: "Untitled Conversation"))
        XCTAssertTrue(Meeting.isPlaceholderTitle(merged.title))
        XCTAssertFalse(merged.revisions.contains { $0.field.hasPrefix("sync:") })
    }

    func testAudioAlignmentsMergeInTheSameOrderEitherWay() {
        let id = UUID(), t1 = UUID(), t2 = UUID(), t3 = UUID()
        var a = Meeting(id: id), b = Meeting(id: id)
        a.audioAlignments = [TrackAudioAlignment(trackID: t2, referenceTrackID: t1, alignment: nil, measuredAt: Date(timeIntervalSinceReferenceDate: 1))]
        b.audioAlignments = [TrackAudioAlignment(trackID: t3, referenceTrackID: t1, alignment: nil, measuredAt: Date(timeIntervalSinceReferenceDate: 1))]
        let merged = assertLaws(a, b, base: Meeting(id: id))
        XCTAssertEqual(merged.audioAlignments?.count, 2)
    }
}
