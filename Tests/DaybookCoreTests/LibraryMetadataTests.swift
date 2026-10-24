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
    // MARK: Recorder ownership

    private func ownership(_ owner: String, _ name: String, at date: Date, serial: String = "D3200SIM0000001") -> RecorderOwnership {
        RecorderOwnership(kind: "soundcore.work", serial: serial, ownerID: owner, ownerName: name,
                          ownerClass: owner.hasPrefix("phone") ? .phone : .mac, claimedAt: date)
    }

    func testMetadataWrittenBeforeOwnershipStillDecodes() throws {
        let json = #"{"schemaVersion":1,"folders":[],"templates":[],"vocabulary":[]}"#
        let metadata = try JSONDecoder().decode(LibraryMetadata.self, from: Data(json.utf8))
        XCTAssertNil(metadata.recorders)
        XCTAssertTrue(metadata.recorderOwners.isEmpty)
        XCTAssertEqual(metadata.merging(LibraryMetadata()), metadata, "merging two libraries without ownership adds none")
        XCTAssertNil(metadata.merging(LibraryMetadata()).recorders)
    }

    func testOwnershipRoundTripsAndIsFoundBySerial() throws {
        var metadata = LibraryMetadata()
        let record = ownership("phone-1", "Alex’s iPhone", at: earlier)
        metadata.recorders = [.init(id: record.id, value: record, modifiedAt: earlier)]
        let decoded = try JSONDecoder().decode(LibraryMetadata.self, from: JSONEncoder().encode(metadata))
        XCTAssertEqual(decoded, metadata)
        XCTAssertEqual(decoded.recorderOwner(kind: "soundcore.work", serial: "D3200SIM0000001"), record)
        XCTAssertNil(decoded.recorderOwner(kind: "soundcore.work", serial: "OTHER"))
        XCTAssertNil(decoded.recorderOwner(kind: "plaud.notepin", serial: "D3200SIM0000001"))
        XCTAssertEqual(record.id, RecorderOwnership.id(kind: "soundcore.work", serial: "D3200SIM0000001"))
    }

    func testTheLaterClaimWinsAndAReleaseIsKeptAgainstAnOlderClaim() {
        let mac = ownership("mac-1", "Studio Mac", at: earlier)
        let phone = ownership("phone-1", "Alex’s iPhone", at: later)
        var a = LibraryMetadata(), b = LibraryMetadata()
        a.recorders = [.init(id: mac.id, value: mac, modifiedAt: earlier)]
        b.recorders = [.init(id: phone.id, value: phone, modifiedAt: later)]
        XCTAssertEqual(a.merging(b), b.merging(a))
        XCTAssertEqual(a.merging(b).recorderOwners, [phone])

        // The phone lets it go after the Mac's older claim: the release wins, and nobody owns it.
        var released = LibraryMetadata()
        released.recorders = [.init(id: phone.id, value: nil, modifiedAt: Date(timeIntervalSince1970: 300))]
        let merged = a.merging(b).merging(released)
        XCTAssertTrue(merged.recorderOwners.isEmpty)
        XCTAssertEqual(merged.recorders?.count, 1, "the deletion marker is kept so it syncs")
        XCTAssertTrue(merged.merging(a).recorderOwners.isEmpty, "an older claim arriving late doesn't come back")

        // Other recorders and other settings are independent.
        var other = LibraryMetadata()
        let second = ownership("mac-1", "Studio Mac", at: earlier, serial: "SECOND")
        other.recorders = [.init(id: second.id, value: second, modifiedAt: earlier)]
        other.folders = [.init(id: "f", value: LibraryFolder(name: "Work"), modifiedAt: earlier)]
        let combined = merged.merging(other)
        XCTAssertEqual(combined.recorderOwners, [second])
        XCTAssertEqual(combined.folders.count, 1)
    }
}
