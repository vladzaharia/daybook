import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// What both apps' search fields suggest, and what a result row says about where it found the words.
final class LibrarySearchSuggestionsTests: XCTestCase {
    private func meeting(_ title: String, speakers: [String], tags: [String] = []) -> Meeting {
        var meeting = Meeting(title: title)
        meeting.speakers = speakers.enumerated().map { Speaker(id: "S\($0.offset)", name: $0.element) }
        meeting.tags = tags
        return meeting
    }

    func testBehaviorNothingTypedSuggestsEveryTagThenEveryPersonButNeverMeOrAnUnnamedSpeaker() {
        let meetings = [meeting("Sync", speakers: ["Maya", "Me", "Speaker 2", "daniel"]), meeting("1:1", speakers: ["Maya", "Priya"])]
        let tokens = LibrarySearchSuggestions.tokens(for: "", tags: ["beta", "launch"], meetings: meetings)
        XCTAssertEqual(tokens, [.tag("beta"), .tag("launch"), .speaker("daniel"), .speaker("Maya"), .speaker("Priya")])
    }

    func testBehaviorAHashSuggestsTagsOnlyAndTypingNarrowsBothToWhatStartsWithIt() {
        let meetings = [meeting("Sync", speakers: ["Maya", "Mark"])]
        XCTAssertEqual(LibrarySearchSuggestions.tokens(for: "#", tags: ["beta", "Marketing"], meetings: meetings),
                       [.tag("beta"), .tag("Marketing")])
        XCTAssertEqual(LibrarySearchSuggestions.tokens(for: "#ma", tags: ["beta", "Marketing"], meetings: meetings), [.tag("Marketing")])
        XCTAssertEqual(LibrarySearchSuggestions.tokens(for: "ma", tags: ["beta", "Marketing"], meetings: meetings),
                       [.tag("Marketing"), .speaker("Mark"), .speaker("Maya")], "a tag and the people whose names start with it")
        XCTAssertEqual(LibrarySearchSuggestions.tokens(for: "Mä", tags: [], meetings: [meeting("x", speakers: ["Mäx"])]), [.speaker("Mäx")])
    }

    func testBehaviorATokenAlreadyChosenIsntSuggestedAgainWhateverItsCase() {
        let meetings = [meeting("Sync", speakers: ["Maya"])]
        XCTAssertEqual(LibrarySearchSuggestions.tokens(for: "", tags: ["Beta"], meetings: meetings, chosen: [.tag("beta"), .speaker("MAYA")]), [])
    }

    func testBehaviorAHashTagTypedWholeWithItsSpaceBecomesTheLibrarysToken() {
        XCTAssertEqual(LibrarySearchSuggestions.promotedTag(in: "#launch ", tags: ["Launch"]), .tag("Launch"))
        XCTAssertNil(LibrarySearchSuggestions.promotedTag(in: "#launch", tags: ["Launch"]), "not until the space")
        XCTAssertNil(LibrarySearchSuggestions.promotedTag(in: "#lau ", tags: ["Launch"]), "only a whole tag")
        XCTAssertNil(LibrarySearchSuggestions.promotedTag(in: "launch ", tags: ["Launch"]))
    }

    func testBehaviorATokenShowsItsWordsWithOneGlyphOnBothApps() {
        XCTAssertEqual(SearchToken.tag("beta").symbol, "tag")
        XCTAssertEqual(SearchToken.speaker("Maya").symbol, "person")
        XCTAssertEqual(SearchToken.tag("beta").text, "beta")
    }

    func testBehaviorAResultSaysWhereItFoundTheWordsAndMarksATitleMatchInTheTitle() throws {
        var weekly = Meeting(title: "Weekly product sync")
        let segment = TranscriptSegment(trackID: UUID(), start: 12, end: 15, text: "The pricing page moves.", speakerID: "S0")
        weekly.speakers = [Speaker(id: "S0", name: "Maya")]
        weekly.unifiedTranscript = [segment]
        weekly.summary = MeetingSummary(kind: .general, overview: "Agreed.",
                                        sections: [SummarySection(heading: "Decisions", body: "- The annual plan leads the **page**.")])

        let title = try XCTUnwrap(LibrarySearch.hits(in: [weekly], text: "product", tokens: [], scope: .all).first)
        XCTAssertEqual(title.location, "Title")
        XCTAssertFalse(title.showsSnippet, "the title itself is marked")
        let range = try XCTUnwrap(title.titleMatch(in: weekly.title))
        XCTAssertEqual(String(weekly.title[range]), "product")

        let summary = try XCTUnwrap(LibrarySearch.hits(in: [weekly], text: "annual", tokens: [], scope: .all).first)
        XCTAssertEqual(summary.location, "Summary")
        XCTAssertEqual(summary.displaySnippet.text, "The annual plan leads the page.", "a summary's Markdown reads as words")
        XCTAssertNil(summary.titleMatch(in: weekly.title))

        let transcript = try XCTUnwrap(LibrarySearch.hits(in: [weekly], text: "pricing", tokens: [], scope: .all).first)
        XCTAssertEqual(transcript.location, "Transcript · Maya · 0:12")
        XCTAssertEqual(transcript.locationSymbol, "quote.bubble")

        let tagged = try XCTUnwrap(LibrarySearch.hits(in: [weekly], text: "", tokens: [], scope: .all).first)
        XCTAssertEqual(tagged.location, "Conversation", "found by its tags or people alone")
        XCTAssertTrue(tagged.showsSnippet)
        XCTAssertEqual(LibraryWords.captionLocation(start: 72), "Live captions · tentative · 1:12")
    }
}
