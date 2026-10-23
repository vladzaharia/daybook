import XCTest
@testable import DaybookCore

final class SummaryTemplateTests: XCTestCase {
    func testBuiltInsHaveStableUniqueIDsAndUsefulInstructions() {
        XCTAssertEqual(SummaryTemplate.builtIns.count, 12)
        XCTAssertEqual(Set(SummaryTemplate.builtIns.map(\.id)).count, 12)
        XCTAssertTrue(SummaryTemplate.builtIns.allSatisfy { !$0.name.isEmpty && $0.instructions.count > 100 })
        XCTAssertTrue(SummaryTemplate.builtIns.contains { $0.id == "therapy-reflection" && $0.kind == .therapy })
    }

    func testEditedBuiltInOverridesOriginalAndNewestDuplicateWins() {
        var old = SummaryTemplate.builtIns[0]
        old.instructions = "Earlier instructions"; old.updatedAt = Date(timeIntervalSince1970: 100)
        var newer = old
        newer.instructions = "My preferred format"; newer.updatedAt = Date(timeIntervalSince1970: 200)
        let catalog = SummaryTemplate.catalog(templates: [newer, old])
        XCTAssertEqual(catalog.count, 12)
        XCTAssertEqual(catalog.first(where: { $0.id == newer.id })?.instructions, "My preferred format")
    }

    func testExplicitTemplateSelectionOverridesInferredMeetingKind() {
        let template = SummaryTemplate.resolved(id: "decision-memo", kind: .scrum, templates: [])
        XCTAssertEqual(template.id, "decision-memo")
    }

    func testMissingDeletedTemplateFallsBackToConversationType() {
        XCTAssertEqual(SummaryTemplate.resolved(id: "deleted-custom", kind: .therapy, templates: []).id, "therapy-reflection")
        XCTAssertEqual(SummaryTemplate.resolved(id: nil, kind: .auto, templates: []).id, "general")
    }

    func testEveryConversationTypeHasADefaultTemplate() {
        for kind in MeetingKind.allCases where kind != .auto {
            XCTAssertEqual(SummaryTemplate.resolved(id: nil, kind: kind, templates: []).kind, kind)
        }
    }

    func testDuplicatingCreatesIndependentEditableIdentity() {
        let original = SummaryTemplate.builtIns[0]
        var duplicate = original.duplicated()
        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertFalse(duplicate.isBuiltIn)
        XCTAssertEqual(duplicate.instructions, original.instructions)
        duplicate.instructions = "Edited copy"
        let catalog = SummaryTemplate.catalog(templates: [duplicate])
        XCTAssertEqual(catalog.count, 13)
        XCTAssertEqual(catalog.first(where: { $0.id == original.id })?.instructions, original.instructions)
    }

    func testCustomTemplateRoundTripPreservesUnicodeAndMultilineInstructions() throws {
        let template = SummaryTemplate(name: "考えと振り返り", kind: .personal, instructions: "Purpose: reflection\n\nQuestions:\n• What changed?\n• What matters?")
        XCTAssertEqual(try JSONDecoder().decode(SummaryTemplate.self, from: JSONEncoder().encode(template)), template)
    }
}
