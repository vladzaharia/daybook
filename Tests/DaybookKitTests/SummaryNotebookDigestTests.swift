import DaybookCore
import XCTest
@testable import DaybookKit

/// A summary knows what the notebook gave it, so a page's reading that arrives afterwards shows it out of date.
final class SummaryNotebookDigestTests: XCTestCase {
    private typealias Pages = NotebookTestPages

    /// A conversation with one page: not read yet when `read` is false.
    private func meeting(pageID: UUID, read: Bool) -> Meeting {
        var meeting = Meeting(title: "Launch", speakers: [Speaker(id: "alex", name: "Alex")])
        meeting.unifiedTranscript = [TranscriptSegment(trackID: UUID(), start: 0, end: 8, text: "Let's start.", speakerID: "alex")]
        var page = Pages.page(pageID, [Pages.passage(pageID, key: "a", words: "ask about budget", time: 20)])
        if !read { page.reading = nil }
        meeting.pages = [page]
        return meeting
    }

    func testBehaviorASummaryRecordsTheNotebookItWasWrittenFrom() {
        let id = UUID()
        let written = meeting(pageID: id, read: false)
        var current = written
        current.setSummary(MeetingSummary(overview: "Launch."), writtenFrom: written)
        XCTAssertEqual(current.summary?.notebookDigest, written.notebookDigest)
        XCTAssertFalse(current.summaryNotebookChanged)
    }

    func testBehaviorAReadingArrivingAfterTheSummaryMarksItOutOfDateUntilItIsWrittenAgain() {
        let id = UUID()
        let unread = meeting(pageID: id, read: false)
        var current = unread
        current.setSummary(MeetingSummary(overview: "Launch."), writtenFrom: unread)
        XCTAssertFalse(current.summaryNotebookChanged, "No change")
        // The reading syncs in.
        current.pages = meeting(pageID: id, read: true).pages
        XCTAssertTrue(current.summaryNotebookChanged)
        XCTAssertTrue(current.summaryNotebookChanged, "Still, until it is written again")
        // Written again from what it has now: current, and again when nothing changes.
        let reread = current
        current.setSummary(MeetingSummary(overview: "Launch, with the page."), writtenFrom: reread)
        XCTAssertFalse(current.summaryNotebookChanged)
    }

    func testBehaviorASummaryRunThatFindsNoReadingDoesNotQueueItselfAgain() {
        let id = UUID()
        let unread = meeting(pageID: id, read: false)
        // The page is still unread when the run ends: what it was written from is what there is, so neither the in-run check
        // (`summaryInputsChanged`) nor the stored digest asks for another.
        var after = unread
        after.setSummary(MeetingSummary(overview: "Launch."), writtenFrom: unread)
        XCTAssertFalse(after.summaryInputsChanged(since: unread))
        XCTAssertFalse(after.summaryNotebookChanged)
        // A reading landing during the run is the in-run check's.
        var during = unread
        during.pages = meeting(pageID: id, read: true).pages
        XCTAssertTrue(during.summaryInputsChanged(since: unread))
    }

    func testBehaviorASummaryWithoutADigestIsNotOutOfDate() throws {
        let id = UUID()
        var current = meeting(pageID: id, read: true)
        current.setSummary(MeetingSummary(overview: "Launch."))
        XCTAssertNil(current.summary?.notebookDigest)
        XCTAssertFalse(current.summaryNotebookChanged)
        // Decoded from data written before the digest was kept.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        var summary = try XCTUnwrap(object["summary"] as? [String: Any])
        XCTAssertNil(summary["notebookDigest"], "Nothing is written when there is none")
        summary["notebookDigest"] = nil
        object["summary"] = summary
        let old = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.summary?.notebookDigest)
        XCTAssertFalse(old.summaryNotebookChanged)
    }

    func testBehaviorTheDigestSurvivesAnEncodeAndDecode() throws {
        let id = UUID()
        let written = meeting(pageID: id, read: true)
        var current = written
        current.setSummary(MeetingSummary(overview: "Launch."), writtenFrom: written)
        let again = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(again.summary?.notebookDigest, written.notebookDigest)
    }

    func testBehaviorMergingKeepsTheDigestWithItsSummaryOnBothDevices() {
        let id = UUID()
        let unread = meeting(pageID: id, read: false)
        var base = unread
        base.setSummary(MeetingSummary(overview: "Launch.", createdAt: Date(timeIntervalSince1970: 1_000)), writtenFrom: unread)
        // Another device read the page and summarized again.
        var remote = base
        remote.pages = meeting(pageID: id, read: true).pages
        let reread = remote
        remote.setSummary(MeetingSummary(overview: "Launch, with the page.", createdAt: Date(timeIntervalSince1970: 2_000)), writtenFrom: reread)
        remote.updatedAt = Date(timeIntervalSince1970: 2_000)
        for (local, other) in [(base, remote), (remote, base)] {
            let merged = MeetingMerge.merge(base: base, local: local, remote: other).meeting
            XCTAssertEqual(merged.summary?.overview, "Launch, with the page.")
            XCTAssertEqual(merged.summary?.notebookDigest, reread.notebookDigest)
            XCTAssertFalse(merged.summaryNotebookChanged, "Both devices agree it is current")
        }
    }

    func testBehaviorTheColophonSaysTheNotebookChangedOnlyWhenItDid() {
        let summary = MeetingSummary(overview: "Launch.")
        let words = DeviceWords.mac(id: "mac")
        XCTAssertFalse(SummaryColophon(summary, thisDeviceID: "mac", words: words).line.contains("Notebook changed"))
        XCTAssertTrue(SummaryColophon(summary, thisDeviceID: "mac", words: words, notebookChanged: true).line.hasSuffix("Notebook changed"))
    }
}
