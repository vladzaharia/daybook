import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// What both apps call a conversation's template, written once (`TemplateWords`): the template menu's first item
/// carries the guess, and the colophon names the template the library resolves, else that item.
@MainActor
final class TemplateWordsTests: XCTestCase {
    func testBehaviorTheAutomaticItemCarriesTheSummarysGuess() {
        var meeting = Meeting(title: "Sync")
        XCTAssertEqual(TemplateWords.automatic(for: meeting), "Automatic", "no summary to guess from")
        XCTAssertEqual(TemplateWords.automatic(for: nil), "Automatic", "a conversation that's gone")
        meeting.summary = MeetingSummary(kind: .auto, title: "Sync", overview: "Done")
        XCTAssertEqual(TemplateWords.automatic(for: meeting), "Automatic", "a summary that didn't guess")
        meeting.summary?.kind = .general
        XCTAssertEqual(TemplateWords.automatic(for: meeting), "Automatic (Meeting)")
        meeting.summary?.kind = .oneOnOne
        XCTAssertEqual(TemplateWords.automatic(for: meeting), "Automatic (1:1)")
    }

    func testBehaviorTheColophonNamesTheResolvedTemplateElseTheAutomaticItem() {
        var meeting = Meeting(title: "Sync")
        meeting.summary = MeetingSummary(kind: .general, title: "Sync", overview: "Done")
        XCTAssertEqual(TemplateWords.title(for: meeting, resolved: nil), "Automatic (Meeting)")
        let interview = SummaryTemplate.resolved(id: "interview", kind: .auto, templates: [])
        XCTAssertEqual(TemplateWords.title(for: meeting, resolved: interview), interview.name)
        XCTAssertEqual(TemplateWords.title(for: Meeting(title: "Quiet"), resolved: nil), "Automatic")
    }

    /// As the pages ask it: through the library's choice for the conversation (`LibraryController.resolvedTemplate`).
    func testBehaviorTheLibrarysChoiceIsTheOneNamed() async throws {
        let library = LibraryController(rootURL: makeTemporaryFolder("DaybookTemplateWords"), sync: nil)
        try await library.load()
        var meeting = Meeting(title: "Hiring loop")
        meeting.summary = MeetingSummary(kind: .general, title: "Hiring loop", overview: "Done")
        library.add(meeting)
        func title() throws -> String {
            let current = try XCTUnwrap(library.meeting(meeting.id))
            return TemplateWords.title(for: current, resolved: library.resolvedTemplate(for: current))
        }
        XCTAssertEqual(try title(), "Automatic (Meeting)", "Automatic, with the summary's guess")
        XCTAssertTrue(library.chooseTemplate("interview", for: meeting.id))
        XCTAssertEqual(try title(), SummaryTemplate.resolved(id: "interview", kind: .auto, templates: library.templates).name)
        XCTAssertTrue(library.chooseTemplate("auto", for: meeting.id))
        XCTAssertEqual(try title(), "Automatic (Meeting)")
    }
}
