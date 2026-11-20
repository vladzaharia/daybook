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

    func testBehaviorAnEditIsStampedAfterTheValueItReplacesWhenThisClockIsBehind() throws {
        let folder = LibraryFolder(name: "Work")
        let stored = LibraryValue(id: folder.id.uuidString, value: folder, modifiedAt: later)
        let renamed = LibraryValue.edit(folder.id.uuidString, value: LibraryFolder(id: folder.id, name: "Projects"), replacing: stored, at: earlier)
        XCTAssertEqual(renamed.modifiedAt, later.addingTimeInterval(0.001))
        var mine = LibraryMetadata(), theirs = LibraryMetadata()
        mine.folders = [renamed]; theirs.folders = [stored]
        XCTAssertEqual(mine.merging(theirs).folders.first?.value?.name, "Projects")
        XCTAssertEqual(theirs.merging(mine).folders.first?.value?.name, "Projects")

        let deleted = LibraryValue.edit(folder.id.uuidString, value: nil, replacing: renamed, at: earlier)
        XCTAssertTrue(deleted.isDeletion)
        XCTAssertGreaterThan(deleted.modifiedAt, renamed.modifiedAt)

        let now = later.addingTimeInterval(60)
        XCTAssertEqual(LibraryValue.edit(folder.id.uuidString, value: folder, replacing: stored, at: now).modifiedAt, now, "A clock ahead of the stamp is used as it is")
        XCTAssertEqual(LibraryValue<LibraryFolder>.edit("new", value: folder, replacing: nil, at: earlier).modifiedAt, earlier)
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

    // MARK: The library's choices

    private func language(_ code: String?, at date: Date) -> LibraryMetadata {
        var metadata = LibraryMetadata()
        metadata.choices = [.init(id: LibraryChoice.Name.transcriptionLanguage.rawValue, value: LibraryChoice(selection: code), modifiedAt: date)]
        return metadata
    }

    /// xdev-settings-08: the transcription language is the library's, merged like its other settings, the later change
    /// winning whichever device merges first; Automatic chosen later wins over a language.
    func testTheTranscriptionLanguageMergesLikeOtherSettingsTheLaterChangeWinning() throws {
        let german = language("de", at: earlier), automatic = language(nil, at: later)
        XCTAssertEqual(german.merging(automatic), automatic.merging(german))
        XCTAssertNil(german.merging(automatic).transcriptionLanguage, "Automatic, chosen later")
        XCTAssertNotNil(german.merging(automatic).choice(.transcriptionLanguage), "a choice, not a library without one")
        XCTAssertEqual(language("fr", at: later).merging(german).transcriptionLanguage, "fr")

        // Other settings are independent of it.
        var folders = LibraryMetadata()
        folders.folders = [.init(id: "f", value: LibraryFolder(name: "Work"), modifiedAt: later)]
        let combined = german.merging(folders)
        XCTAssertEqual(combined.transcriptionLanguage, "de")
        XCTAssertEqual(combined.folders.count, 1)

        // It round-trips, and Automatic is stored as a choice with nothing chosen.
        let decoded = try JSONDecoder().decode(LibraryMetadata.self, from: JSONEncoder().encode(automatic))
        XCTAssertEqual(decoded, automatic)
        let json = String(decoding: try JSONEncoder().encode(language("de", at: earlier)), as: UTF8.self)
        XCTAssertTrue(json.contains(#""id":"transcriptionLanguage""#), json)
        XCTAssertTrue(json.contains(#""selection":"de""#), json)
    }

    func testSettingsWrittenBeforeTheLanguageDecodeWithoutOne() throws {
        let json = #"{"schemaVersion":1,"folders":[],"templates":[],"vocabulary":[]}"#
        let metadata = try JSONDecoder().decode(LibraryMetadata.self, from: Data(json.utf8))
        XCTAssertNil(metadata.choices)
        XCTAssertNil(metadata.choice(.transcriptionLanguage), "no device has chosen one")
        XCTAssertNil(metadata.transcriptionLanguage)
        XCTAssertNil(metadata.merging(LibraryMetadata()).choices, "merging two libraries without one adds none")
        XCTAssertEqual(metadata.merging(language("de", at: earlier)).transcriptionLanguage, "de")
    }

    /// A Daybook from before the setting keeps it as a key it doesn't know and merges it item by item as well
    /// (`SyncJSONValue.mergedLibrarySetting`), so a library edited on an older device still ends on the later choice.
    func testAnEarlierVersionMergesTheLanguageItDoesntKnowTheSameWay() throws {
        func unknown(_ metadata: LibraryMetadata) throws -> SyncJSONValue {
            let object = try JSONDecoder().decode([String: SyncJSONValue].self, from: JSONEncoder().encode(metadata))
            return try XCTUnwrap(object["choices"])
        }
        let german = try unknown(language("de", at: earlier)), french = try unknown(language("fr", at: later))
        let merged = SyncJSONValue.mergedLibrarySetting(german, french)
        XCTAssertEqual(merged, SyncJSONValue.mergedLibrarySetting(french, german))
        XCTAssertEqual(merged, french)
    }

    /// A choice a newer Daybook wrote in a shape this version can't read is Automatic here, kept, and written back as it
    /// came; the library still has a choice, so a carried-over language doesn't replace it.
    func testALanguageInANewerShapeTravelsOnUnchanged() throws {
        let json = #"{"schemaVersion":1,"folders":[],"templates":[],"vocabulary":[],"choices":[{"id":"transcriptionLanguage","modifiedAt":0,"value":{"selection":["de","en"]}}]}"#
        let metadata = try JSONDecoder().decode(LibraryMetadata.self, from: Data(json.utf8))
        XCTAssertNil(metadata.transcriptionLanguage)
        XCTAssertNotNil(metadata.choice(.transcriptionLanguage))
        XCTAssertTrue(metadata.hasUnreadableValues)
        let again = try JSONDecoder().decode(LibraryMetadata.self, from: JSONEncoder().encode(metadata))
        XCTAssertEqual(again, metadata, "written back as it came")
    }

    // MARK: The profile that is the person

    private func owner(_ profile: UUID?, at date: Date) -> LibraryMetadata {
        var metadata = LibraryMetadata()
        metadata.choices = [.init(id: LibraryChoice.Name.ownerProfile.rawValue, value: LibraryChoice(selection: profile?.uuidString), modifiedAt: date)]
        return metadata
    }

    func testBehaviorTheOwnerProfileMergesTheLaterChangeWinningAndRoundTrips() throws {
        let first = UUID(), second = UUID()
        let a = owner(first, at: earlier), b = owner(second, at: later), none = owner(nil, at: later)
        XCTAssertEqual(a.merging(b), b.merging(a))
        XCTAssertEqual(a.merging(b).ownerProfileSelection, second)
        XCTAssertNil(a.merging(none).ownerProfileSelection, "cleared later")
        XCTAssertNotNil(a.merging(none).choice(.ownerProfile))
        XCTAssertEqual(try JSONDecoder().decode(LibraryMetadata.self, from: JSONEncoder().encode(b)), b)
        // Independent of the transcription language.
        XCTAssertEqual(a.merging(language("de", at: later)).ownerProfileSelection, first)
        XCTAssertEqual(a.merging(language("de", at: later)).transcriptionLanguage, "de")
    }

    /// An older Daybook doesn't know the name, and keeps and merges the record as it would any choice.
    func testBehaviorAChoiceNameThisVersionDoesNotKnowIsKeptAndMerged() throws {
        var future = LibraryMetadata()
        future.choices = [.init(id: "someFutureChoice", value: LibraryChoice(selection: "x"), modifiedAt: later)]
        let combined = owner(UUID(), at: earlier).merging(future)
        XCTAssertEqual(combined.choices?.count, 2)
        XCTAssertEqual(combined.choices?.first { $0.id == "someFutureChoice" }?.value?.selection, "x")
        XCTAssertNil(combined.transcriptionLanguage)
        let decoded = try JSONDecoder().decode(LibraryMetadata.self, from: JSONEncoder().encode(combined))
        XCTAssertEqual(decoded.choices?.count, 2)
    }

    func testBehaviorTheOwnerProfileResolvesThroughMergesAndIsNilOnceDeleted() throws {
        let mine = SpeakerProfile(id: UUID(), name: "Vlad"), same = SpeakerProfile(id: UUID(), name: "Vlad Z")
        var metadata = owner(mine.id, at: earlier)
        metadata.speakerProfiles = [mine, same].map { .init(id: $0.id.uuidString, value: $0, modifiedAt: earlier) }
        XCTAssertEqual(metadata.ownerProfileID, mine.id)
        XCTAssertTrue(metadata.mergeSpeakerProfile(mine.id, into: same.id, at: later))
        XCTAssertEqual(metadata.ownerProfileID, same.id, "the merged profile resolves to its target")
        XCTAssertEqual(metadata.ownerProfileSelection, mine.id)
        let stored = try XCTUnwrap(metadata.speakerProfiles?.first { $0.id == same.id.uuidString })
        metadata.speakerProfiles = (metadata.speakerProfiles ?? []).filter { $0.id != same.id.uuidString } + [.edit(same.id.uuidString, value: nil, replacing: stored, at: later)]
        XCTAssertNil(metadata.ownerProfileID, "a deleted profile is no one")
        XCTAssertNil(owner(UUID(), at: earlier).ownerProfileID, "a profile that isn't known here either")
    }
}
