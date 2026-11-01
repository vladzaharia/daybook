import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// The summary's Markdown is split one way for both apps' pages and the iPhone's tap-through to evidence; search
/// snippets read as words; and the search's matches are found the same way everywhere.
final class SummaryMarkdownTests: XCTestCase {
    func testBehaviorBlocksSplitParagraphsItemsAndHeadings() {
        let source = """
        The beta ships on the 14th.
        It's gated on the fix.

        ## Decisions
        - Keep the **14th**.
        * The fix is the gate.
        • Support is ready.
        1. Post a status
        2) Book the review
        """
        XCTAssertEqual(SummaryMarkdown.blocks(source), [
            .paragraph("The beta ships on the 14th.\nIt's gated on the fix."),
            .heading("Decisions"),
            .item(marker: "•", text: "Keep the **14th**."),
            .item(marker: "•", text: "The fix is the gate."),
            .item(marker: "•", text: "Support is ready."),
            .item(marker: "1.", text: "Post a status"),
            .item(marker: "2)", text: "Book the review"),
        ])
        XCTAssertEqual(SummaryMarkdown.blocks(source), SummaryMarkdown.parse(source), "the cached parse is the parse")
        XCTAssertEqual(SummaryMarkdown.blocks("").count, 0)
        XCTAssertEqual(SummaryMarkdown.Block.item(marker: "•", text: "Hi").text, "Hi")
    }

    func testBehaviorASummarySnippetReadsAsWordsWithItsMatch() throws {
        let snippet = "Decided. - Keep the **14th** as the beta date."
        let match = try XCTUnwrap(snippet.range(of: "14th"))
        let hit = SearchHit(meetingID: UUID(), field: .summary, snippet: snippet, match: match, segmentID: nil, speaker: nil, time: nil, matchCount: 1)
        let shown = hit.displaySnippet
        XCTAssertEqual(shown.text, "Decided. Keep the 14th as the beta date.")
        XCTAssertEqual(shown.match.map { String(shown.text[$0]) }, "14th")
        let transcript = SearchHit(meetingID: UUID(), field: .transcript, snippet: "- not a list", match: nil, segmentID: nil, speaker: nil,
                                   time: nil, matchCount: 1)
        XCTAssertEqual(transcript.displaySnippet.text, "- not a list", "only a summary is Markdown")
        XCTAssertEqual(SearchHit.plainText(fromMarkdown: "- First\n__Second__"), "First\nSecond")
    }

    func testBehaviorFindRangesFindEveryMatchWithoutRegardToCaseOrAccents() {
        let text = "Café notes: the CAFE opens at nine; café again."
        let ranges = FindRanges.ranges(in: text, query: " cafe ")
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["Café", "CAFE", "café"])
        XCTAssertTrue(FindRanges.ranges(in: text, query: "  ").isEmpty)
        let styled = AttributedString(text)
        XCTAssertEqual(FindRanges.ranges(in: styled, query: "cafe").count, 3)
        XCTAssertTrue(FindRanges.ranges(in: styled, query: "tea").isEmpty)
    }

    func testBehaviorEvidenceFindsThePassageALineCameFrom() {
        let track = UUID()
        func segment(_ start: Double, _ speaker: String, _ text: String) -> TranscriptSegment {
            TranscriptSegment(trackID: track, start: start, end: start + 4, text: text, speakerID: speaker)
        }
        let passages = [segment(0, "a", "Let's hold the fourteenth for the beta release."),
                        segment(5, "b", "I'll post a status update about the conflict fix on Thursday."),
                        segment(10, "c", "Release notes are on me, including the Markdown export.")]
        var meeting = Meeting(title: "Weekly", unifiedTranscript: passages,
                              speakers: [Speaker(id: "a", name: "Maya"), Speaker(id: "b", name: "Daniel"), Speaker(id: "c", name: "Priya")])
        meeting.updatedAt = Date(timeIntervalSinceReferenceDate: 1)
        let index = SummaryEvidenceIndex.cached(for: meeting)
        XCTAssertEqual(index.segment(for: "Post a status update on the conflict fix", owner: "Daniel"), passages[1].id)
        XCTAssertEqual(index.segment(for: "Finish the release notes, including Markdown export", owner: "Priya"), passages[2].id)
        XCTAssertNil(index.segment(for: "Good"), "a weak match finds nothing rather than something wrong")
        XCTAssertNil(index.segment(for: ""))

        // A newer version of the conversation gets a new index.
        meeting.unifiedTranscript[1].text = "Lunch is on Friday."
        meeting.updatedAt = Date(timeIntervalSinceReferenceDate: 2)
        XCTAssertNil(SummaryEvidenceIndex.cached(for: meeting).segment(for: "Post a status update on the conflict fix", owner: "Daniel"))
        XCTAssertEqual(SummaryEvidenceIndex.words("The drafted notes"), ["draft", "note"])
    }
}
