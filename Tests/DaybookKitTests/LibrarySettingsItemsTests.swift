import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// What Summary Templates, Vocabulary, and About say about each item, once for both apps: a template's symbol,
/// purpose, and Edited; where a term is used and what a search finds; the privacy statement and the version; and
/// which models each device credits.
final class LibrarySettingsItemsTests: XCTestCase {
    // MARK: Templates

    func testBehaviorATemplateSaysWhatItsForWithoutThePurposeLabel() throws {
        let meeting = try XCTUnwrap(SummaryTemplate.builtIns.first { $0.id == "general" })
        XCTAssertFalse(meeting.purpose.hasPrefix("Purpose"), meeting.purpose)
        XCTAssertTrue(meeting.purpose.first?.isUppercase == true, meeting.purpose)
        XCTAssertEqual(SummaryTemplate(name: "Board", instructions: "lead with the numbers.\nThen risks.").purpose, "Lead with the numbers.")
        XCTAssertEqual(SummaryTemplate(name: "Empty", instructions: "").purpose, "", "no line for no instructions")
    }

    func testBehaviorEachTemplateHasOneSymbol() throws {
        XCTAssertEqual(try XCTUnwrap(SummaryTemplate.builtIns.first { $0.id == "planning" }).systemImage, "calendar")
        XCTAssertEqual(SummaryTemplate(name: "Mine", kind: .oneOnOne, instructions: "").systemImage, "doc.text", "yours are documents")
        for template in SummaryTemplate.builtIns { XCTAssertFalse(template.systemImage.isEmpty, template.id) }
        XCTAssertEqual(MeetingKind.templateKinds.count, MeetingKind.allCases.count - 1)
        XCTAssertFalse(MeetingKind.templateKinds.contains(.auto))
    }

    func testBehaviorABuiltInIsEditedOnlyWhenItDiffersFromItsOriginal() throws {
        var builtIn = try XCTUnwrap(SummaryTemplate.builtIns.first)
        XCTAssertFalse(builtIn.isEdited, "a saved copy identical to the original isn't edited")
        builtIn.updatedAt = Date(timeIntervalSince1970: 1)
        XCTAssertFalse(builtIn.isEdited, "saving it again changes nothing it says")
        builtIn.instructions += " Keep it short."
        XCTAssertTrue(builtIn.isEdited)
        XCTAssertFalse(SummaryTemplate(name: "Mine", instructions: "x").isEdited, "yours are never edited")
    }

    func testBehaviorTemplatesListBuiltInsInOrderThenYoursByName() throws {
        let yours = [SummaryTemplate(name: "zeta", instructions: ""), SummaryTemplate(name: "", instructions: ""),
                     SummaryTemplate(name: "Alpha 10", instructions: ""), SummaryTemplate(name: "Alpha 9", instructions: "")]
        let sections = SummaryTemplate.sections(SummaryTemplate.catalog(templates: yours))
        XCTAssertEqual(sections.builtIn.map(\.id), SummaryTemplate.builtIns.map(\.id))
        XCTAssertEqual(sections.yours.map(\.displayName), ["Alpha 9", "Alpha 10", TemplateWords.untitled, "zeta"])
        XCTAssertEqual(SummaryTemplate.untitled().name, "Untitled Template")
        XCTAssertFalse(SummaryTemplate.untitled().isBuiltIn)
    }

    func testBehaviorDeletingATemplateSaysWhatHappensToItsConversations() {
        let template = SummaryTemplate(name: "  ", instructions: "")
        XCTAssertEqual(TemplateWords.deleteTitle(template), "Delete “Untitled Template”?")
        XCTAssertEqual(TemplateWords.deleteConsequence, "Conversations that used it switch to Automatic.")
    }

    // MARK: Vocabulary

    func testBehaviorATermFromAConversationIsUsedThereUntilChosenForAll() {
        let sync = Meeting(title: "Weekly product sync")
        let other = Meeting(title: "Offsite")
        let scoped = GlossaryTerm(term: "Kubernetes", approved: false, sourceMeetingIDs: [sync.id])
        XCTAssertEqual(scoped.scope(in: [other, sync]), .conversation(sync.id, title: "Weekly product sync"))
        XCTAssertEqual(scoped.scope(in: [other, sync]).words, "Only “Weekly product sync”")
        XCTAssertTrue(scoped.scope(in: [sync]).isLimited)
        XCTAssertTrue(scoped.canChangeScope)

        let gone = GlossaryTerm(term: "Ximena", approved: false, sourceMeetingIDs: [UUID()])
        XCTAssertEqual(gone.scope(in: [sync]), .none)
        XCTAssertEqual(gone.scope(in: [sync]).words, "No conversations")

        var approved = scoped
        approved.approved = true
        XCTAssertEqual(approved.scope(in: [sync]), .all)
        XCTAssertTrue(approved.canChangeScope, "it can go back to its conversation")
        let typed = GlossaryTerm(term: "Daybook", approved: true)
        XCTAssertEqual(typed.scope(in: [sync]).words, "All conversations")
        XCTAssertFalse(typed.canChangeScope, "a term typed in has no conversation to be limited to")
    }

    func testBehaviorSearchFindsATermByItsSpellingsAndMeaning() {
        let term = GlossaryTerm(term: "Daybook", aliases: ["day book"], definition: "The meeting app")
        XCTAssertTrue(term.matches("dayb"))
        XCTAssertTrue(term.matches("DAY BOOK"))
        XCTAssertTrue(term.matches("meeting"), "its meaning, on both apps")
        XCTAssertTrue(term.matches("  "))
        XCTAssertFalse(term.matches("kubernetes"))
    }

    func testBehaviorOtherSpellingsAreOneFieldSeparatedByCommas() {
        XCTAssertEqual(GlossaryTerm.aliases(from: " day book, daybook ,, Day Book, k8s"), ["day book", "daybook", "k8s"],
                       "each once, without blanks")
        XCTAssertEqual(GlossaryTerm(term: "Daybook", aliases: ["day book", "daybook"]).aliasesText, "day book, daybook")
        XCTAssertEqual(VocabularyWords.otherSpellings, "Other spellings", "short enough for a page of the open Duo")
    }

    func testBehaviorDeletingATermLimitedToAConversationSaysWhatItLoses() {
        let sync = Meeting(title: "Weekly product sync")
        XCTAssertEqual(VocabularyWords.deleteConsequence([.conversation(sync.id, title: sync.title)]),
                       "“Weekly product sync” won’t use it when it’s transcribed again.")
        XCTAssertNil(VocabularyWords.deleteConsequence([.all]))
        XCTAssertNil(VocabularyWords.deleteConsequence([.none]), "nothing to lose where the conversation is gone")
        XCTAssertEqual(VocabularyWords.deleteConsequence([.conversation(sync.id, title: "A"), .conversation(UUID(), title: "B")]),
                       "Their conversations won’t use them when they’re transcribed again.")
        XCTAssertEqual(VocabularyWords.deleteTitle([GlossaryTerm(term: "Kubernetes")]), "Delete “Kubernetes”?")
        XCTAssertEqual(VocabularyWords.deleteTerms(3), "Delete 3 Terms")
    }

    func testBehaviorTheVocabularyCountsEveryTermOnBothApps() {
        let sync = UUID()
        let terms = [GlossaryTerm(term: "Daybook", approved: true),
                     GlossaryTerm(term: "Kubernetes", approved: false, sourceMeetingIDs: [sync]),
                     GlossaryTerm(term: "Helm", approved: false, sourceMeetingIDs: [sync])]
        XCTAssertEqual(SettingsWords.vocabulary(terms), "3 terms", "a term used in one conversation is still a term")
        XCTAssertEqual(SettingsWords.vocabulary([]), "No terms yet")
        XCTAssertEqual(SettingsWords.vocabulary(Array(terms.prefix(1))), "1 term")
    }

    // MARK: About

    func testBehaviorThePrivacyStatementIsTrueWhenSyncIsOff() {
        XCTAssertTrue(PrivacyWords.statement.contains("when sync is on"), "never 'in your iCloud' for a library that doesn't sync")
        XCTAssertTrue(PrivacyWords.statement.hasPrefix("Recordings, notes, and transcripts stay on your devices"))
    }

    func testBehaviorBothAppsSayTheVersionTheSameWay() {
        XCTAssertEqual(AboutWords.version(["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]), "Version 0.1.0 (1)")
        XCTAssertEqual(AboutWords.version(["CFBundleShortVersionString": "2.0"]), "Version 2.0")
        XCTAssertEqual(AboutWords.version(["CFBundleShortVersionString": "2.0", "CFBundleVersion": "2.0"]), "Version 2.0")
        XCTAssertNil(AboutWords.version(nil), "a development build says nothing")
        XCTAssertNil(AboutWords.version(["CFBundleVersion": "1"]))
    }

    func testBehaviorEachDeviceCreditsWhatItCanUseAndWhatsBehindResults() {
        let catalog = ModelCatalog.builtIn
        XCTAssertEqual(ModelAcknowledgements.entries(from: catalog, usable: nil, meetings: []), ModelAcknowledgements.list(from: catalog),
                       "a Mac credits its whole catalog")
        var summarized = Meeting(title: "Planning")
        summarized.setSummary(MeetingSummary(overview: "Plans", modelID: "qwen2.5/3b-4bit", createdAt: Date(timeIntervalSince1970: 1)))
        let phone = ModelAcknowledgements.entries(from: catalog, usable: ["whisper/base"], meetings: [summarized])
        XCTAssertEqual(phone.map(\.title), ["Qwen 2.5", "Whisper"], "what it can use, and the model behind a result made on a Mac")
        XCTAssertEqual(ModelAcknowledgements.entries(from: catalog, usable: [], meetings: []), [], "nothing to credit")
        let vision = ModelAcknowledgements.list(from: catalog).first { $0.title == "Apple Vision" }
        XCTAssertNil(vision?.otherModels, "a family of one model isn't named twice")
    }
}
