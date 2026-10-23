import XCTest
@testable import DaybookCore

final class LibraryMetadataTests: XCTestCase {
    private let earlier = Date(timeIntervalSince1970: 100)
    private let later = Date(timeIntervalSince1970: 200)

    func testNewerFolderRenameWinsRegardlessOfMergeOrder() throws {
        let folder = LibraryFolder(name: "Work")
        var local = LibraryMetadata(), remote = LibraryMetadata()
        local.folders = [.init(id: folder.id.uuidString, value: folder, modifiedAt: earlier)]
        remote.folders = [.init(id: folder.id.uuidString, value: .init(id: folder.id, name: "Projects"), modifiedAt: later)]
        XCTAssertEqual(local.merging(remote), remote.merging(local))
        XCTAssertEqual(try XCTUnwrap(local.merging(remote).folders.first?.value).name, "Projects")
    }

    func testDeletionSurvivesOldDeviceAndSerialization() throws {
        let folder = LibraryFolder(name: "Deleted")
        var oldDevice = LibraryMetadata(), deletion = LibraryMetadata()
        oldDevice.folders = [.init(id: folder.id.uuidString, value: folder, modifiedAt: earlier)]
        deletion.folders = [.init(id: folder.id.uuidString, value: nil, modifiedAt: later)]
        let saved = try JSONDecoder().decode(LibraryMetadata.self, from: JSONEncoder().encode(deletion.merging(oldDevice)))
        let result = saved.merging(oldDevice)
        XCTAssertEqual(result.folders.count, 1)
        XCTAssertNil(result.folders[0].value)
        XCTAssertEqual(result.folders[0].modifiedAt, later)
        XCTAssertEqual(result, result.merging(oldDevice))
    }

    func testIntentionalRecreationAfterDeletionWins() {
        let folder = LibraryFolder(name: "Restored")
        var deleted = LibraryMetadata(), recreated = LibraryMetadata()
        deleted.folders = [.init(id: folder.id.uuidString, value: nil, modifiedAt: earlier)]
        recreated.folders = [.init(id: folder.id.uuidString, value: folder, modifiedAt: later)]
        XCTAssertEqual(deleted.merging(recreated).folders.first?.value, folder)
    }

    func testDeletionWinsEqualClockAgainstEveryMetadataType() {
        let folder = LibraryFolder(name: "Folder")
        let template = SummaryTemplate.builtIns[0]
        let term = GlossaryTerm(term: "Daybook")
        var values = LibraryMetadata(), deleted = LibraryMetadata()
        values.folders = [.init(id: folder.id.uuidString, value: folder, modifiedAt: earlier)]
        values.templates = [.init(id: template.id, value: template, modifiedAt: earlier)]
        values.vocabulary = [.init(id: term.id.uuidString, value: term, modifiedAt: earlier)]
        deleted.folders = [.init(id: folder.id.uuidString, value: nil, modifiedAt: earlier)]
        deleted.templates = [.init(id: template.id, value: nil, modifiedAt: earlier)]
        deleted.vocabulary = [.init(id: term.id.uuidString, value: nil, modifiedAt: earlier)]
        XCTAssertEqual(values.merging(deleted), deleted)
        XCTAssertEqual(deleted.merging(values), deleted)
    }

    func testIndependentLibraryEditsSurviveAndEnvelopeTimestampIsAuthoritative() {
        var local = LibraryMetadata(), remote = LibraryMetadata()
        let folder = LibraryFolder(name: "Team")
        var oldTemplate = SummaryTemplate.builtIns[0]
        oldTemplate.updatedAt = Date(timeIntervalSince1970: 999)
        var newTemplate = oldTemplate
        newTemplate.name = "Changed on another Mac"
        newTemplate.updatedAt = earlier
        local.templates = [.init(id: oldTemplate.id, value: oldTemplate, modifiedAt: earlier)]
        local.folders = [.init(id: folder.id.uuidString, value: folder, modifiedAt: later)]
        remote.templates = [.init(id: newTemplate.id, value: newTemplate, modifiedAt: later)]
        let term = GlossaryTerm(term: "Architecture", approved: true)
        remote.vocabulary = [.init(id: term.id.uuidString, value: term, modifiedAt: later)]
        let result = local.merging(remote)
        XCTAssertEqual(result.folders.first?.value, folder)
        XCTAssertEqual(result.templates.first?.value, newTemplate)
        XCTAssertEqual(result.vocabulary.first?.value, term)
    }

    func testEqualClockEditsConvergeAndMergeAssociatively() {
        let id = UUID()
        func version(_ name: String) -> LibraryMetadata {
            var metadata = LibraryMetadata()
            metadata.folders = [.init(id: id.uuidString, value: .init(id: id, name: name), modifiedAt: earlier)]
            return metadata
        }
        let a = version("A"), b = version("B"), c = version("C")
        XCTAssertEqual(a.merging(b), b.merging(a))
        XCTAssertEqual(a.merging(b).merging(c), a.merging(b.merging(c)))
        XCTAssertEqual(a.merging(b).merging(c), c.merging(b).merging(a))
    }
}
