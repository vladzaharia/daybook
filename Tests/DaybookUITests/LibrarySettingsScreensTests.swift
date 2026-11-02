import DaybookKit
import Foundation
import XCTest
@testable import DaybookUI

/// Summary Templates and Vocabulary, the screens both apps share: what saving as you type writes, what a delete
/// asks first, and that every vocabulary change can be undone and redone. Each test opens its own library in a
/// temporary folder.
@MainActor
final class LibrarySettingsScreensTests: XCTestCase {
    private func makeLibrary() async throws -> LibraryController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibrarySettingsScreensTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = LibraryController(rootURL: root, sync: nil)
        try await library.load()
        addTeardownBlock {
            await library.flush()
            try? FileManager.default.removeItem(at: root)
        }
        return library
    }

    // MARK: Templates

    func testBehaviorANewTemplateIsSavedUntitledAndItsEditorStartsWithAnEmptyName() async throws {
        let library = try await makeLibrary()
        let templates = TemplateLibrary(library: library)
        let created = templates.newTemplate()
        XCTAssertEqual(templates.template(created.id)?.name, "Untitled Template", "saved at once, so it saves as you type")
        XCTAssertEqual(templates.sections.yours.map(\.id), [created.id])
        var draft = try XCTUnwrap(templates.draft(created.id))
        XCTAssertEqual(draft.template.name, "", "the prompt says Untitled Template; typing names it")
        XCTAssertFalse(templates.save(&draft), "an untouched new template writes nothing")
    }

    func testBehaviorSavingAsYouTypeWritesOnlyWhatChanged() async throws {
        let library = try await makeLibrary()
        let templates = TemplateLibrary(library: library)
        var draft = try XCTUnwrap(templates.draft(templates.newTemplate().id))
        draft.template.name = "Board update"
        XCTAssertTrue(templates.save(&draft))
        XCTAssertEqual(templates.template(draft.id)?.name, "Board update")
        XCTAssertFalse(templates.save(&draft), "the same draft again is no new save, so nothing syncs for it")
        draft.template.name = "   "
        XCTAssertTrue(templates.save(&draft))
        XCTAssertEqual(templates.template(draft.id)?.name, "Untitled Template", "a blank name is saved as Untitled Template")
    }

    func testBehaviorAnUntouchedDraftDoesntRevertAnEditFromAnotherDevice() async throws {
        let library = try await makeLibrary()
        let templates = TemplateLibrary(library: library)
        let builtIn = try XCTUnwrap(templates.sections.builtIn.first)
        var draft = try XCTUnwrap(templates.draft(builtIn.id), "the Mac's window opens on the first built-in")
        // Another device's edit arrives through sync while the editor is open.
        var remote = builtIn
        remote.instructions += " Keep it under a page."
        library.saveTemplate(remote)
        let synced = try XCTUnwrap(templates.template(builtIn.id))

        // Choosing another template, closing the window, or leaving the iPhone's editor saves the draft.
        XCTAssertFalse(templates.save(&draft), "nothing the person changed, so nothing is written")
        XCTAssertEqual(templates.template(builtIn.id), synced, "the other device's edit stays, and nothing newer syncs over it")

        // The editor takes the edit in, so it shows what the library has.
        XCTAssertTrue(draft.catchUp(to: synced))
        XCTAssertEqual(draft.template.instructions, remote.instructions)
        XCTAssertEqual(draft.base, synced)
        XCTAssertFalse(templates.save(&draft))
        XCTAssertFalse(draft.catchUp(to: synced), "once is enough")
    }

    func testBehaviorSavingWritesOnlyTheFieldsThePersonChanged() async throws {
        let library = try await makeLibrary()
        let templates = TemplateLibrary(library: library)
        let created = templates.newTemplate()
        var draft = try XCTUnwrap(templates.draft(created.id))
        draft.template.name = "Board update"
        // Meanwhile another device wrote the instructions.
        var remote = try XCTUnwrap(templates.template(created.id))
        remote.instructions = "Lead with the numbers."
        library.saveTemplate(remote)

        XCTAssertTrue(templates.save(&draft))
        let saved = try XCTUnwrap(templates.template(created.id))
        XCTAssertEqual(saved.name, "Board update", "what the person typed")
        XCTAssertEqual(saved.instructions, "Lead with the numbers.", "and the other device's edit, kept")
        XCTAssertEqual(draft.base, saved, "the draft caught up with what was saved")
        XCTAssertEqual(draft.template.instructions, "Lead with the numbers.", "so the editor shows it")

        // An edit synced to a field the person is typing in leaves their words in the editor.
        draft.template.name = "Board update, Q3"
        var renamed = saved
        renamed.name = "Board"
        renamed.kind = .interview
        library.saveTemplate(renamed)
        XCTAssertTrue(draft.catchUp(to: try XCTUnwrap(templates.template(created.id))))
        XCTAssertEqual(draft.template.name, "Board update, Q3")
        XCTAssertEqual(draft.template.kind, .interview, "what they haven't touched follows the library")
        XCTAssertTrue(templates.save(&draft))
        XCTAssertEqual(templates.template(created.id)?.name, "Board update, Q3")
        XCTAssertEqual(templates.template(created.id)?.kind, .interview)
    }

    func testBehaviorADraftOfADeletedTemplateIsntBroughtBack() async throws {
        let library = try await makeLibrary()
        let templates = TemplateLibrary(library: library)
        var draft = try XCTUnwrap(templates.draft(templates.newTemplate().id))
        templates.delete(draft.template)
        draft.template.instructions = "Typed after another device deleted it"
        XCTAssertFalse(templates.save(&draft))
        XCTAssertNil(templates.template(draft.id))
        XCTAssertTrue(templates.sections.yours.isEmpty)
    }

    func testBehaviorEditedBuiltInsRestoreAndCopiesKeepTheShownName() async throws {
        let library = try await makeLibrary()
        let templates = TemplateLibrary(library: library)
        var builtIn = try XCTUnwrap(templates.draft(try XCTUnwrap(templates.sections.builtIn.first).id))
        builtIn.template.instructions += " Keep it under a page."
        templates.save(&builtIn)
        XCTAssertTrue(try XCTUnwrap(templates.template(builtIn.id)).isEdited)
        let original = try XCTUnwrap(templates.restore(builtIn.template))
        XCTAssertFalse(original.isEdited)
        XCTAssertEqual(original, SummaryTemplate.builtIns.first)

        templates.delete(original)
        XCTAssertNotNil(templates.template(original.id), "a built-in can't be deleted")

        let untitled = templates.newTemplate()
        var blank = untitled
        blank.name = ""
        let copy = templates.duplicate(blank)
        XCTAssertNotEqual(copy.id, untitled.id)
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertTrue(copy.name.hasPrefix("Untitled Template"), copy.name)
    }

    // MARK: Vocabulary

    func testBehaviorEveryVocabularyChangeCanBeUndoneAndRedone() async throws {
        let library = try await makeLibrary()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let editor = VocabularyEditor(library: library, undoManager: undo)

        undo.beginUndoGrouping()
        XCTAssertEqual(editor.add(GlossaryTerm(term: "  Daybook ", approved: true)), "Daybook")
        undo.endUndoGrouping()
        let id = try XCTUnwrap(library.glossary.first?.id)
        XCTAssertEqual(undo.undoActionName, "Add Term")

        undo.beginUndoGrouping()
        XCTAssertEqual(editor.respell(id, as: "day book, daybook"), "day book, daybook")
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        XCTAssertEqual(editor.describe(id, as: "The app "), "The app")
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        XCTAssertEqual(editor.rename(id, to: "   "), "Daybook", "a blank name keeps the spelling")
        XCTAssertEqual(editor.rename(id, to: "DayBook"), "DayBook")
        undo.endUndoGrouping()

        undo.undo()
        XCTAssertEqual(editor.term(id)?.term, "Daybook")
        undo.undo()
        XCTAssertEqual(editor.term(id)?.definition, "")
        undo.undo()
        XCTAssertEqual(editor.term(id)?.aliases, [])
        undo.undo()
        XCTAssertNil(editor.term(id), "Add Term undone")
        undo.redo()
        XCTAssertEqual(editor.term(id)?.term, "Daybook", "and redone")

        undo.beginUndoGrouping()
        editor.delete([id])
        undo.endUndoGrouping()
        XCTAssertTrue(library.glossary.isEmpty)
        XCTAssertEqual(undo.undoActionName, "Delete Term")
        undo.undo()
        XCTAssertEqual(editor.term(id)?.term, "Daybook", "a deleted term comes back")
    }

    func testBehaviorEditTermSavesOnlyWhatThePersonChanged() async throws {
        let library = try await makeLibrary()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let editor = VocabularyEditor(library: library, undoManager: undo)
        let source = UUID()
        library.saveGlossaryTerm(GlossaryTerm(term: "Kubernetes", approved: false, sourceMeetingIDs: [source]))
        // Edit Term opens on the term.
        let opened = try XCTUnwrap(library.glossary.first)

        // Meanwhile another device gives it a meaning, and a summary finds it in another conversation.
        var remote = opened
        remote.definition = "Container orchestration"
        let other = UUID()
        remote.sourceMeetingIDs.append(other)
        library.saveGlossaryTerm(remote)
        let beforeSave = try XCTUnwrap(editor.term(opened.id))

        // The person changes only its other spellings, and saves.
        var edited = opened
        edited.aliases = GlossaryTerm.aliases(from: "k8s, kube")
        undo.beginUndoGrouping()
        XCTAssertTrue(editor.save(edited, openedAs: opened))
        undo.endUndoGrouping()
        let saved = try XCTUnwrap(editor.term(opened.id))
        XCTAssertEqual(saved.aliases, ["k8s", "kube"], "what the person typed")
        XCTAssertEqual(saved.definition, "Container orchestration", "and the other device's meaning, kept")
        XCTAssertEqual(saved.sourceMeetingIDs, [source, other], "and the conversation the summary found it in")
        XCTAssertEqual(undo.undoActionName, "Edit Term")

        undo.undo()
        XCTAssertEqual(editor.term(opened.id), beforeSave, "undo puts back the copy from just before the save, the synced meaning with it")
        undo.redo()
        XCTAssertEqual(editor.term(opened.id)?.aliases, ["k8s", "kube"])
        XCTAssertEqual(editor.term(opened.id)?.definition, "Container orchestration")

        XCTAssertFalse(editor.save(edited, openedAs: opened), "the library already has the change, so nothing new is written")
        library.removeGlossaryTerm(opened.id)
        XCTAssertFalse(editor.save(edited, openedAs: opened))
        XCTAssertNil(editor.term(opened.id), "a term deleted meanwhile isn't brought back")
    }

    func testBehaviorDeletingATermLimitedToAConversationAsksFirst() async throws {
        let library = try await makeLibrary()
        let editor = VocabularyEditor(library: library, undoManager: nil)
        let everywhere = GlossaryTerm(term: "Daybook", approved: true)
        let gone = GlossaryTerm(term: "Kubernetes", approved: false, sourceMeetingIDs: [UUID()])
        editor.add(everywhere)
        library.saveGlossaryTerm(gone)
        XCTAssertFalse(editor.deletingAsks([everywhere.id]), "undo puts it back; nothing to ask")
        XCTAssertTrue(editor.deletingAsks([gone.id]))
        XCTAssertTrue(editor.deletingAsks([everywhere.id, gone.id]))
        XCTAssertNil(editor.deleteConsequence([gone.id]), "its conversation is gone")
        XCTAssertEqual(editor.limitedScope(of: everywhere), .none)
    }

    func testBehaviorUsedInMovesATermBetweenItsConversationAndAll() async throws {
        let library = try await makeLibrary()
        let editor = VocabularyEditor(library: library, undoManager: nil)
        let source = UUID()
        let scoped = GlossaryTerm(term: "Kubernetes", approved: false, sourceMeetingIDs: [source])
        library.saveGlossaryTerm(scoped)
        editor.use(scoped.id, everywhere: true)
        XCTAssertEqual(editor.term(scoped.id)?.approved, true)
        XCTAssertEqual(editor.term(scoped.id)?.sourceMeetingIDs, [source], "it still knows where it came from")
        editor.use(scoped.id, everywhere: false)
        XCTAssertEqual(editor.term(scoped.id)?.approved, false)

        let typed = GlossaryTerm(term: "Daybook", approved: true)
        editor.add(typed)
        editor.use(typed.id, everywhere: false)
        XCTAssertEqual(editor.term(typed.id)?.approved, true, "a term typed in has no conversation to be limited to")
        XCTAssertEqual(editor.rows(matching: "kube").map(\.term), ["Kubernetes"])
        XCTAssertEqual(editor.rows(matching: "").map(\.term), ["Daybook", "Kubernetes"])
    }

    // MARK: Acknowledgements

    func testBehaviorTheNoticesFileReadsAsHeadingsTableAndLicenseTexts() throws {
        let markdown = try String(contentsOf: Self.repository.appendingPathComponent("THIRD_PARTY_NOTICES.md"), encoding: .utf8)
        let blocks = NoticesDocument.blocks(markdown)
        XCTAssertEqual(blocks.first, .heading("Third-party notices"))
        XCTAssertTrue(blocks.contains { if case .code(let text) = $0 { return text.contains("OpenMDW License Agreement") }; return false },
                      "the models' license texts ship on both apps")
        let software = SoftwareNotices(notices: markdown, packages: [])
        let libraries = software.libraries
        XCTAssertTrue(libraries.contains { $0.name.hasPrefix("FluidAudio") && $0.license == "Apache-2.0" }, "\(libraries)")
        XCTAssertFalse(libraries.contains { $0.name.contains("---") }, "the header's rule isn't a library")
    }

    func testBehaviorEachPackagesLicenseAndNoticeAreFoundByTheirCopiedNames() {
        XCTAssertEqual(SoftwareNotices.packageFile("swift-transformers-LICENSE.txt")?.package, "swift-transformers")
        XCTAssertEqual(SoftwareNotices.packageFile("swift-crypto-NOTICE.txt")?.kind, .notice)
        XCTAssertEqual(SoftwareNotices.packageFile("yyjson-LICENSE-MIT.txt")?.package, "yyjson")
        XCTAssertEqual(SoftwareNotices.packageFile("mlx-swift-LICENSE.md.txt")?.package, "mlx-swift")
        XCTAssertNil(SoftwareNotices.packageFile("README.txt"))
        XCTAssertNil(SoftwareNotices.packageFile("LICENSE.txt"), "a file with no package")

        let packages = SoftwareNotices.packages([("swift-crypto", .init(kind: .notice, text: "N")), ("FluidAudio", .init(kind: .license, text: "A")),
                                                 ("swift-crypto", .init(kind: .license, text: "L"))])
        XCTAssertEqual(packages.map(\.name), ["FluidAudio", "swift-crypto"])
        XCTAssertEqual(packages.last?.files.map(\.kind), [.license, .notice], "a license before its notice")
    }

    func testBehaviorAPackagedBundlesNoticesAreRead() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("Notices-\(UUID().uuidString).bundle", isDirectory: true)
        let licenses = bundle.appendingPathComponent("Contents/Resources/Licenses", isDirectory: true)
        try FileManager.default.createDirectory(at: licenses, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: bundle) }
        try "# Third-party notices".write(to: bundle.appendingPathComponent("Contents/Resources/ThirdPartyNotices.md"), atomically: true, encoding: .utf8)
        try "MIT".write(to: licenses.appendingPathComponent("FluidAudio-LICENSE.txt"), atomically: true, encoding: .utf8)
        try "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>test.notices</string></dict></plist>"
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        let notices = SoftwareNotices.load(from: try XCTUnwrap(Bundle(url: bundle)))
        XCTAssertEqual(notices.notices, "# Third-party notices")
        XCTAssertEqual(notices.packages, [.init(name: "FluidAudio", files: [.init(kind: .license, text: "MIT")])])
        XCTAssertTrue(SoftwareNotices(notices: nil, packages: []).isEmpty)
    }

    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
