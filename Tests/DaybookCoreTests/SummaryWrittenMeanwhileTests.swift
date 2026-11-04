import DaybookCore
import XCTest

/// A summary being written while the person names speakers: the names follow into it, as they do into one already
/// there, and only a change in what it reads makes it be written again (docs/architecture.md, "Speakers and profiles").
final class SummaryWrittenMeanwhileTests: XCTestCase {
    private func meeting() -> Meeting {
        var meeting = Meeting(title: "Planning", date: Date(timeIntervalSince1970: 1_800_000_000), notes: "Ship on Friday")
        meeting.speakers = [Speaker(id: "run:S1", name: "Speaker 1"), Speaker(id: "run:S2", name: "Dana")]
        return meeting
    }

    func testARenameIsntAChangeInWhatTheSummaryReads() {
        let written = meeting()
        var now = written
        now.renameSpeaker(id: "run:S1", name: "Priya")
        XCTAssertFalse(now.summaryInputsChanged(since: written))
        now.speakers[0].embedding = [0.1, 0.2]
        XCTAssertFalse(now.summaryInputsChanged(since: written), "Nor is a voice")
    }

    func testWhatWasSaidWrittenOrChosenIs() {
        let written = meeting()
        var notes = written
        notes.notes += " and Monday"
        var speakers = written
        speakers.speakers.append(Speaker(id: "run:S3", name: "Speaker 3"))
        var bookmark = written
        bookmark.highlights.append(Highlight(time: 3))
        var template = written
        template.templateID = "oneOnOne"
        for (changed, what) in [(notes, "notes"), (speakers, "a speaker"), (bookmark, "a bookmark"), (template, "the template")] {
            XCTAssertTrue(changed.summaryInputsChanged(since: written), what)
        }
    }

    func testNamesGivenMeanwhileFollowIntoTheSummaryAsOneVersion() {
        let written = meeting()
        var now = written
        now.renameSpeaker(id: "run:S1", name: "Priya")
        now.renameSpeaker(id: "run:S2", name: "Dana Lee")
        let versions = now.revisions.count
        now.setSummary(MeetingSummary(title: "Plan", overview: "Speaker 1 and Dana agreed on Friday."), writtenFrom: written)
        XCTAssertEqual(now.summary?.overview, "Priya and Dana agreed on Friday.",
                       "Daybook's label follows; a name the person gave is theirs, as when nothing is being written")
        XCTAssertEqual(now.revisions.count, versions + 1, "One summary in Version History")
        XCTAssertEqual(now.speakers.map(\.name), ["Priya", "Dana Lee"])
    }
}
