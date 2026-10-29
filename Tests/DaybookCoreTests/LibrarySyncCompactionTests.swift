import XCTest
@testable import DaybookCore

/// Compaction (LibrarySyncCompaction.swift): settings versions that aren't heads and deleted conversations' history go at
/// once; a live conversation's history goes once every device seen lately has acknowledged a proposal; a device back after
/// its history went merges its own changes against its stored base; earlier Daybooks stop at the compacted manifest. iCloud
/// is a temporary folder (`SimulatedICloud`), iCloud Keychain a `MemoryLibraryKeyStore`.
final class LibrarySyncCompactionTests: XCTestCase {
    private var root: URL!
    private var cloud: SimulatedICloud!
    private var keychain: MemoryLibraryKeyStore!
    private var remote: URL { root.appendingPathComponent("iCloud") }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookCompactionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cloud = SimulatedICloud()
        keychain = MemoryLibraryKeyStore()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func mac(_ name: String = "Mac", compaction: SyncCompactionPolicy? = .eager, sealed: Bool = false) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .eager, device: SyncDeviceIdentity(deviceClass: .mac, displayName: "\(name) Studio", canProcess: true),
            cloud: cloud.files, keyStore: keychain, sealsNewLibrary: sealed, compaction: compaction))
    }
    private func phone(_ name: String = "Phone") throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .onDemand, device: SyncDeviceIdentity(deviceClass: .phone, displayName: "Pocket", canProcess: false),
            cloud: cloud.files, keyStore: keychain, sealsNewLibrary: false))
    }
    /// A pass supplying everything the device's library holds (and `metadata`), applied and acknowledged.
    @discardableResult
    private func pass(_ engine: LibrarySyncEngine, _ name: String, _ extra: [Meeting] = [], metadata: Data? = nil) async throws -> SyncResult {
        let store = try MeetingStore(rootURL: local(name))
        let held = try await store.list()
        let supplied = held.filter { meeting in !extra.contains { $0.id == meeting.id } } + extra
        let result = try await engine.synchronize(meetings: supplied, libraryMetadata: metadata)
        for meeting in result.meetings { try await store.save(meeting) }
        for id in result.deletedMeetingIDs where FileManager.default.fileExists(atPath: local(name).appendingPathComponent("Meetings/\(id)").path) {
            _ = try await store.moveToTrash(id)
        }
        try await engine.acknowledge(result.checkpointID)
        return result
    }
    /// Changes a conversation in the device's library, as an edit there would, without syncing.
    @discardableResult
    private func edit(_ name: String, _ id: UUID, _ change: (inout Meeting) -> Void) async throws -> Meeting {
        let store = try MeetingStore(rootURL: local(name))
        let all = try await store.list()
        var meeting = try XCTUnwrap(all.first { $0.id == id })
        change(&meeting)
        try await store.save(meeting)
        return meeting
    }
    private func held(_ name: String, _ id: UUID) async throws -> Meeting {
        let all = try await MeetingStore(rootURL: local(name)).list()
        return try XCTUnwrap(all.first { $0.id == id }, "\(name) holds it")
    }
    private func files(_ directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent(directory).path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }
    private func manifest() throws -> SyncManifest { try SyncManifest.decode(Data(contentsOf: remote.appendingPathComponent("daybook-sync.json"))) }
    private func settings(_ name: String) -> Data { Data(#"{"folders":[{"name":"\#(name)"}]}"#.utf8) }
    /// The bytes of every file in the sync folder, by path.
    private func remoteTree() throws -> [String: Data] {
        var tree: [String: Data] = [:]
        let base = remote.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: remote, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            tree[String(url.standardizedFileURL.path.dropFirst(base.count + 1))] = try Data(contentsOf: url)
        }
        return tree
    }

    // MARK: Settings

    func testSettingsVersionsThatAreNotHeadsGoAndEveryDeviceStillMerges() async throws {
        let mac = try mac(), phone = try phone()
        try await pass(mac, "Mac", metadata: settings("First"))
        try await pass(phone, "Phone", metadata: settings("First"))
        // The phone falls behind while the Mac changes the library's settings again and again.
        for index in 2...9 { try await pass(mac, "Mac", metadata: settings("Mac \(index)")) }
        XCTAssertEqual(files("Metadata").count, 1, "only the head is left")
        XCTAssertEqual(try manifest().schemaVersion, SyncManifest.compactedSchemaVersion)
        XCTAssertNotNil(try manifest().compaction)
        XCTAssertLessThanOrEqual(files("Compaction").count, 2, "commits are consolidated")
        let report = await mac.compactionReport
        XCTAssertNotNil(report)

        // The phone, whose last applied version is long gone, publishes a change against it and takes the Mac's head: it
        // waits for nothing.
        let onPhone = try await pass(phone, "Phone", metadata: settings("Phone"))
        XCTAssertEqual(onPhone.pendingDownloads, 0)
        XCTAssertEqual(onPhone.warnings, [])
        XCTAssertEqual(onPhone.metadataVersions.count, 2, "the Mac's head and the phone's change, concurrent")
        let onMac = try await pass(mac, "Mac", metadata: settings("Mac 9"))
        XCTAssertEqual(onMac.pendingDownloads, 0)
        XCTAssertEqual(Set(onMac.metadataVersions), [settings("Mac 9"), settings("Phone")])
    }

    // MARK: Conversations

    /// A conversation edited many times on the Mac: its history goes only after the phone has acknowledged a proposal, up
    /// to the proposal's root; then the next proposal's. Afterwards an edit on either merges with no conflict.
    func testAConversationsHistoryGoesOnceEveryDeviceHasAcknowledged() async throws {
        let mac = try mac(), phone = try phone()
        let meeting = Meeting(title: "Weekly")
        try await pass(mac, "Mac", [meeting])
        try await pass(phone, "Phone")
        for index in 1...5 { try await edit("Mac", meeting.id) { $0.setNotes("Draft \(index)") }; try await pass(mac, "Mac") }
        XCTAssertEqual(files("Events").count, 6)
        // Proposed once there was history: the root is the head then, after the first edit.
        let proposed = await mac.pendingProposal
        let proposal = try XCTUnwrap(proposed)
        XCTAssertEqual(proposal.record.roots?.count, 1)
        // Until the phone acknowledges it, nothing of the conversation goes.
        try await pass(mac, "Mac")
        XCTAssertEqual(files("Events").count, 6)

        try await pass(phone, "Phone")
        let phoneAck = await phone.state.compactionAck
        XCTAssertEqual(phoneAck, proposal.id)
        // What came before the root goes; a new proposal names the head now.
        try await pass(mac, "Mac")
        XCTAssertEqual(files("Events").count, 5)
        let proposedNext = await mac.pendingProposal
        let next = try XCTUnwrap(proposedNext)
        XCTAssertNotEqual(next.id, proposal.id)
        try await pass(phone, "Phone")
        try await pass(mac, "Mac")
        XCTAssertEqual(files("Events").count, 1, "only the root is left")
        let pruned = await mac.prunedIDs
        XCTAssertEqual(pruned.count, 5)

        // An edit on the phone, against the root, and one on the Mac after it: an ordinary sequence, no conflicts.
        try await edit("Phone", meeting.id) { $0.title = "Weekly sync" }
        let fromPhone = try await pass(phone, "Phone")
        XCTAssertEqual(fromPhone.publishedEvents, 1)
        let onMac = try await pass(mac, "Mac")
        XCTAssertEqual(onMac.warnings, [])
        let merged = try await held("Mac", meeting.id)
        XCTAssertEqual(merged.title, "Weekly sync"); XCTAssertEqual(merged.notes, "Draft 5")
        XCTAssertEqual(merged.revisions.filter { $0.field.hasPrefix("conflict") }.count, 0)
    }

    /// The phone's edit, made before it saw the Mac's later ones and slow to reach iCloud, is concurrent with the root the
    /// Mac proposed. The phone never acknowledges a proposal it would publish against; once its edit arrives, the merge
    /// still has its common ancestor, and both changes are kept with no conflict.
    func testAConcurrentEditKeepsItsMergeBase() async throws {
        let mac = try mac(), phone = try phone()
        let meeting = Meeting(title: "Planning")
        try await pass(mac, "Mac", [meeting])
        try await pass(phone, "Phone")
        try await edit("Phone", meeting.id) { $0.setNotes("Phone notes") }
        try await pass(phone, "Phone")
        // iCloud hasn't brought the phone's edit to the Mac yet.
        let before = Set(files("Events"))
        let phoneEdit = try XCTUnwrap(before.first { name in
            guard let data = try? Data(contentsOf: remote.appendingPathComponent("Events/\(name)")) else { return false }
            return String(decoding: data, as: UTF8.self).contains("Phone notes")
        })
        try cloud.withhold(remote.appendingPathComponent("Events/\(phoneEdit)"))
        for index in 1...4 { try await edit("Mac", meeting.id) { $0.title = "Planning \(index)" }; try await pass(mac, "Mac") }
        let proposal = await mac.pendingProposal
        XCTAssertNotNil(proposal)
        try cloud.deliver(remote.appendingPathComponent("Events/\(phoneEdit)"))

        // The phone applies both and stays behind the proposal's root: it doesn't acknowledge.
        try await pass(phone, "Phone")
        let phoneAck = await phone.state.compactionAck
        XCTAssertNil(phoneAck)
        // The Mac sees two heads: nothing of the conversation goes, and the merge has its common ancestor.
        let onMac = try await pass(mac, "Mac")
        XCTAssertEqual(onMac.warnings, [])
        let merged = try await held("Mac", meeting.id)
        XCTAssertEqual(merged.title, "Planning 4"); XCTAssertEqual(merged.notes, "Phone notes")
        XCTAssertTrue(files("Events").contains(phoneEdit))
        let pruned = await mac.prunedIDs
        XCTAssertTrue(pruned.isEmpty, "nothing of a conversation with two heads goes")
        // A new proposal leaves it out until someone edits it again.
        let next = await mac.pendingProposal
        XCTAssertNotEqual(next?.id, proposal?.id)
        XCTAssertNil(next?.record.roots?[meeting.id.uuidString])
        let onPhone = try await pass(phone, "Phone")
        XCTAssertEqual(onPhone.warnings, [])
        let onPhoneMerged = try await held("Phone", meeting.id)
        XCTAssertEqual(onPhoneMerged.title, "Planning 4"); XCTAssertEqual(onPhoneMerged.notes, "Phone notes")
    }

    /// The phone was away for more than 30 days, so the Mac compacted without it, pruning what the phone had last applied.
    /// The phone's edit made while away is merged against the base it stored, and published as an ordinary edit.
    func testADeviceBackAfterItsHistoryWentMergesItsChangesAgainstItsBase() async throws {
        let mac = try mac(), phone = try phone()
        let meeting = Meeting(title: "Retro")
        try await pass(mac, "Mac", [meeting])
        try await pass(phone, "Phone")
        // The phone goes away; a month later, the Mac carries on alone.
        let later = Date().addingTimeInterval(31 * 24 * 60 * 60)
        await mac.setCompactionClock({ later })
        for index in 1...3 { try await edit("Mac", meeting.id) { $0.title = "Retro \(index)" }; try await pass(mac, "Mac") }
        try await pass(mac, "Mac")
        let pruned = await mac.prunedIDs
        XCTAssertEqual(pruned.count, 3, "the phone isn't waited for")
        XCTAssertEqual(files("Events").count, 1)

        // Back, with an edit made while away.
        try await edit("Phone", meeting.id) { $0.setNotes("Written offline") }
        let back = try await pass(phone, "Phone")
        XCTAssertEqual(back.warnings, [])
        XCTAssertEqual(back.publishedEvents, 0, "merged first, published next pass")
        let rebased = try await held("Phone", meeting.id)
        XCTAssertEqual(rebased.title, "Retro 3"); XCTAssertEqual(rebased.notes, "Written offline")
        let published = try await pass(phone, "Phone")
        XCTAssertEqual(published.publishedEvents, 1)
        let onMac = try await pass(mac, "Mac")
        XCTAssertEqual(onMac.warnings, [])
        let merged = try await held("Mac", meeting.id)
        XCTAssertEqual(merged.title, "Retro 3"); XCTAssertEqual(merged.notes, "Written offline")
        XCTAssertEqual(merged.revisions.filter { $0.field.hasPrefix("conflict") }.count, 0)
    }

    func testADeletedConversationKeepsOnlyItsDeletion() async throws {
        let mac = try mac(), phone = try phone()
        let gone = Meeting(title: "Old"), kept = Meeting(title: "Kept")
        try await pass(mac, "Mac", [gone, kept])
        try await pass(phone, "Phone")
        for index in 1...3 { try await edit("Mac", gone.id) { $0.title = "Old \(index)" }; try await pass(mac, "Mac") }
        try await pass(phone, "Phone")
        _ = try await MeetingStore(rootURL: local("Mac")).moveToTrash(gone.id)
        try await pass(mac, "Mac")
        try await pass(mac, "Mac")
        // The deletion is the only event of the conversation left.
        let pruned = await mac.prunedIDs
        XCTAssertEqual(pruned.count, 4)
        // The phone, unchanged since, applies the deletion; nothing is kept as a new conversation.
        let onPhone = try await pass(phone, "Phone")
        XCTAssertTrue(onPhone.deletedMeetingIDs.contains(gone.id))
        XCTAssertEqual(onPhone.warnings, [])
        XCTAssertEqual(onPhone.pendingDownloads, 0)
        let left = try await MeetingStore(rootURL: local("Phone")).list()
        XCTAssertEqual(Set(left.map(\.id)), [kept.id])
    }

    // MARK: Encrypted libraries

    /// In an encrypted library, compaction records are sealed like everything else, and a rotation moves them to the new
    /// key, so the old one can be retired and removed.
    func testAnEncryptedLibraryCompactsWithSealedRecordsThatFollowTheKey() async throws {
        let mac = try mac(), phone = try phone()
        let meeting = Meeting(title: "Zanzibar offsite")
        try await pass(mac, "Mac", [meeting], metadata: settings("Before"))
        try await pass(phone, "Phone")
        // Compacted before it's encrypted: plaintext records, which go once sealed ones replace them.
        for index in 1...3 { try await pass(mac, "Mac", metadata: settings("Before \(index)")) }
        XCTAssertFalse(files("Compaction").isEmpty)
        let first = try await mac.enableSealing(recovery: RecoveryKey.generate())
        try await pass(mac, "Mac", metadata: settings("Marmalade"))
        try await pass(phone, "Phone")
        for index in 1...3 {
            try await edit("Mac", meeting.id) { $0.setNotes("Quokka \(index)") }
            try await pass(mac, "Mac", metadata: settings("Marmalade \(index)"))
        }
        try await pass(phone, "Phone")
        try await pass(mac, "Mac", metadata: settings("Marmalade 3"))
        try await pass(phone, "Phone")
        try await pass(mac, "Mac", metadata: settings("Marmalade 3"))
        let manifest = try manifest()
        XCTAssertTrue(manifest.isSealed); XCTAssertTrue(manifest.isCompacted)
        XCTAssertEqual(manifest.schemaVersion, SyncManifest.compactedSchemaVersion)
        XCTAssertTrue(files("Compaction").isEmpty, "no plaintext records")
        XCTAssertFalse(files("Sealed/Compaction").isEmpty)
        let pruned = await mac.prunedIDs
        XCTAssertFalse(pruned.isEmpty)
        for (path, bytes) in try remoteTree() where path.hasPrefix("Sealed/Compaction/") {
            XCTAssertEqual(SealedObject.header(of: bytes)?.kind, .compaction)
            for marker in ["Zanzibar", "Quokka", "Marmalade", meeting.id.uuidString] {
                XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(marker), "\(marker) in \(path)")
            }
        }
        let fresh = try await pass(try self.phone("Fresh"), "Fresh")
        XCTAssertEqual(fresh.pendingDownloads, 0); XCTAssertEqual(fresh.warnings, [])
        XCTAssertEqual(fresh.meetings.first?.notes, "Quokka 3")

        // A new key: the records follow it, so nothing still needs the old one once it's retired.
        let start = Date()
        await mac.setSealerClock { start }
        let second = try await mac.rotateKey(now: start)
        try await pass(mac, "Mac", metadata: settings("Marmalade 3"))
        try await pass(phone, "Phone")
        try await pass(mac, "Mac", metadata: settings("Marmalade 3"))
        for name in files("Sealed/Compaction") {
            let header = try XCTUnwrap(SealedObject.header(of: Data(contentsOf: remote.appendingPathComponent("Sealed/Compaction/\(name)"))))
            XCTAssertEqual(header.keyID, second.id, "Sealed/Compaction/\(name) is still under the old key")
        }
        XCTAssertNotEqual(first.id, second.id)
    }

    // MARK: Measured

    /// A synthetic library like the owner's: 20 speaker profiles with 24 voiceprints each in every settings version (about
    /// 1 KB per voiceprint), many settings versions, and conversations relabelled a few times each. The sync folder before
    /// and after compaction, and a new device's first pass. `DAYBOOK_COMPACTION_MEASURE=1` runs it at full size and prints
    /// the numbers (docs/validation.md).
    func testCompactionShrinksASyntheticLibrary() async throws {
        let full = ProcessInfo.processInfo.environment["DAYBOOK_COMPACTION_MEASURE"] == "1"
        let base = root!
        for sealed in [false, true] {
            root = base.appendingPathComponent(sealed ? "Encrypted" : "Plaintext")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await measure(sealed: sealed, settingsVersions: full ? 200 : 12, conversations: full ? 100 : 8, relabels: 3, report: full)
        }
        root = base
    }

    private func measure(sealed: Bool, settingsVersions: Int, conversations: Int, relabels: Int, report: Bool) async throws {
        let mac = try mac(compaction: nil, sealed: sealed), phone = try phone()
        let meetings = (0..<conversations).map { Meeting(title: "Conversation \($0)") }
        try await pass(mac, "Mac", meetings, metadata: voiceprintSettings(0))
        try await pass(phone, "Phone")
        for version in 1...settingsVersions {
            // Each conversation is relabelled a few times along the way (the first speaker-labelling pass, and later ones).
            if version <= relabels {
                for meeting in meetings { try await edit("Mac", meeting.id) { $0.setNotes("Speakers labelled \(version)") } }
            }
            try await pass(mac, "Mac", metadata: voiceprintSettings(version))
        }
        try await pass(phone, "Phone")
        let before = folderSize()
        let freshBefore = try await timedFirstPass("Fresh before")
        let measured = try self.phone("Fresh before")

        // Compaction from here on; every device in use syncs now and then, and so acknowledges what's proposed.
        await mac.setCompactionPolicy(.eager)
        for _ in 0..<4 {
            try await pass(mac, "Mac", metadata: voiceprintSettings(settingsVersions))
            try await pass(phone, "Phone")
            try await pass(measured, "Fresh before")
        }
        try await pass(mac, "Mac", metadata: voiceprintSettings(settingsVersions))
        let after = folderSize()
        let freshAfter = try await timedFirstPass("Fresh after")
        XCTAssertEqual(freshAfter.result.pendingDownloads, 0); XCTAssertEqual(freshAfter.result.warnings, [])
        XCTAssertEqual(freshAfter.result.metadataVersions, [voiceprintSettings(settingsVersions)])
        XCTAssertEqual(Set(freshAfter.result.meetings.map(\.notes)), ["Speakers labelled \(relabels)"])
        XCTAssertEqual(freshAfter.result.meetings.count, conversations)
        XCTAssertLessThan(after.bytes * 4, before.bytes, "\(sealed ? "encrypted" : "plaintext"): \(before) → \(after)")
        // Each conversation's root, the settings head, and a commit or two.
        XCTAssertLessThanOrEqual(after.files, conversations + 3, "\(before) → \(after)")
        if report {
            let mb = { (bytes: Int64) in String(format: "%.1f MB", Double(bytes) / 1_048_576) }
            print("""
            COMPACTION \(sealed ? "encrypted" : "plaintext"): \(settingsVersions) settings versions of \(mb(Int64(voiceprintSettings(0).count))), \
            \(conversations) conversations × \(relabels + 1) events.
              before: \(before.files) journal files, \(mb(before.bytes)); a new device's first pass \(String(format: "%.2f", freshBefore.seconds)) s
              after:  \(after.files) journal files, \(mb(after.bytes)); a new device's first pass \(String(format: "%.2f", freshAfter.seconds)) s
            """)
        }
    }

    /// Library settings with 20 profiles of 24 voiceprints, each about 1 KB (a 256-value half-float vector in base64 and
    /// where it came from), and one folder renamed per version.
    private func voiceprintSettings(_ version: Int) -> Data {
        var voiceprints: [String] = []
        for profile in 0..<20 {
            for print in 0..<24 {
                let vector = Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ profile &* 31 &+ print) }).base64EncodedString()
                voiceprints.append(#"{"id":"vp-\#(profile)-\#(print)","modifiedAt":783000000,"value":{"profileID":"\#(profile)","origin":"named","# +
                    #""vector":{"space":"fluid-community1-embedding","dimensions":256,"half":"\#(vector)"},"speechSeconds":182.4,"recordedAt":783000000}}"#)
            }
        }
        return Data(#"{"folders":[{"name":"Folder \#(version)"}],"voiceprints":[\#(voiceprints.joined(separator: ","))]}"#.utf8)
    }

    private func folderSize() -> (files: Int, bytes: Int64) {
        var files = 0, bytes: Int64 = 0
        for directory in ["Events", "Metadata", "Compaction", "Sealed/Events", "Sealed/Metadata", "Sealed/Compaction"] {
            for name in self.files(directory) {
                files += 1
                bytes += Int64((try? remote.appendingPathComponent("\(directory)/\(name)").resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return (files, bytes)
    }

    private func timedFirstPass(_ name: String) async throws -> (result: SyncResult, seconds: Double) {
        let engine = try phone(name)
        let start = ContinuousClock.now
        let result = try await pass(engine, name)
        let elapsed = ContinuousClock.now - start
        return (result, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    // MARK: Who compacts, and when

    func testCompactionWaitsForEveryRecentDeviceToReadACompactedLibrary() async throws {
        let mac = try mac()
        try await pass(mac, "Mac", metadata: settings("First"))
        // A device seen lately whose Daybook doesn't read compacted libraries.
        let record = """
        {"format":"DaybookDevice","schemaVersion":1,"deviceID":"Old","deviceClass":"phone","displayName":"Old iPhone","canProcess":false,
         "lastSeen":"\(ISO8601DateFormatter().string(from: Date()))","features":["sealed-1"]}
        """
        try Data(record.utf8).write(to: remote.appendingPathComponent("Devices/\(SyncDigest.sha256(data: Data("Old".utf8))).json"))
        for index in 2...4 { try await pass(mac, "Mac", metadata: settings("\(index)")) }
        XCTAssertEqual(files("Metadata").count, 4)
        XCTAssertEqual(try manifest().schemaVersion, 1)
        // A month later it isn't waited for: if it's still on that version, it says to update when it's back.
        let later = Date().addingTimeInterval(31 * 24 * 60 * 60)
        await mac.setCompactionClock({ later })
        try await pass(mac, "Mac", metadata: settings("5"))
        XCTAssertEqual(files("Metadata").count, 1)
        XCTAssertEqual(try manifest().schemaVersion, SyncManifest.compactedSchemaVersion)
    }

    func testOnlyTheMacWithTheSmallestIDCompacts() async throws {
        let first = try mac("A Mac"), second = try mac("B Mac"), phone = try phone()
        try await pass(first, "A Mac", metadata: settings("1"))
        try await pass(second, "B Mac")
        try await pass(phone, "Phone")
        for index in 2...4 { try await pass(second, "B Mac", metadata: settings("B \(index)")) }
        XCTAssertEqual(files("Metadata").count, 4, "B Mac doesn't compact")
        let report = await second.compactionReport
        XCTAssertNil(report)
        try await pass(first, "A Mac")
        XCTAssertEqual(files("Metadata").count, 1)
        let phoneReport = await phone.compactionReport
        XCTAssertNil(phoneReport)
    }

    func testTheStandardPolicyWaitsForEnoughToGain() async throws {
        let mac = try mac(compaction: .standard)
        try await pass(mac, "Mac", metadata: settings("1"))
        for index in 2...6 { try await pass(mac, "Mac", metadata: settings("\(index)")) }
        XCTAssertEqual(files("Metadata").count, 6, "a few small versions aren't worth a commit")
        XCTAssertTrue(files("Compaction").isEmpty)
        XCTAssertEqual(try manifest().schemaVersion, 1, "nothing compacted: earlier versions still sync")
    }

    // MARK: Compatibility

    func testAnEarlierDaybookStopsAtACompactedLibraryAndChangesNothing() async throws {
        let mac = try mac()
        try await pass(mac, "Mac", [Meeting(title: "Kept")], metadata: settings("1"))
        try await pass(mac, "Mac", metadata: settings("2"))
        XCTAssertEqual(try manifest().schemaVersion, SyncManifest.compactedSchemaVersion)
        let before = try remoteTree()
        let legacy = try LegacyLibrarySyncEngine(localRoot: local("Old"), remoteRoot: remote, deviceID: "Old")
        do {
            _ = try await legacy.synchronize(meetings: [Meeting(title: "Made on an old Mac")])
            XCTFail("The version 1 engine synced a compacted library")
        } catch LegacyLibrarySyncError.unsupportedVersion(let version) {
            XCTAssertEqual(version, SyncManifest.compactedSchemaVersion)
        }
        XCTAssertEqual(try remoteTree(), before)
        // The gate: version 3 is a compacted library, plaintext or encrypted; version 4 is a newer Daybook's.
        var manifest = try manifest()
        XCTAssertFalse(manifest.isSealed); XCTAssertTrue(manifest.isCompacted)
        XCTAssertNoThrow(try SyncManifest.checked(manifest))
        manifest.schemaVersion = 4
        XCTAssertThrowsError(try SyncManifest.decode(manifest.encoded())) { XCTAssertEqual($0 as? LibrarySyncError, .unsupportedVersion(4)) }
    }

    /// A pruned entry's file still in the sync folder (deleted later) is left out by every device, and a reader that finds
    /// one deleted before the commit that lists it arrives waits rather than misread the history.
    func testAPrunedEntryIsLeftOutAndAMissingOneWaitsForItsCommit() async throws {
        let mac = try mac(), phone = try phone()
        try await pass(mac, "Mac", metadata: settings("1"))
        try await pass(phone, "Phone")
        // The commit is written, but iCloud hasn't uploaded it yet: the files it lists stay for now.
        cloud.holdUploads(under: remote.appendingPathComponent("Compaction"))
        try await pass(mac, "Mac", metadata: settings("2"))
        XCTAssertEqual(files("Metadata").count, 2, "files a commit lists stay until it's in iCloud")
        XCTAssertEqual(files("Compaction").count, 1)
        let onPhone = try await pass(phone, "Phone")
        XCTAssertEqual(onPhone.pendingDownloads, 0)
        XCTAssertEqual(onPhone.metadataVersions, [settings("2")], "a pruned version is left out though it's still there")
        // Once it's uploaded, they go.
        cloud.holdUploads(under: nil)
        try await pass(mac, "Mac", metadata: settings("2"))
        XCTAssertEqual(files("Metadata").count, 1)

        // A reader that finds a version's parent gone but not yet the commit that says so waits, then carries on.
        let commits = files("Compaction")
        for name in commits { try cloud.withhold(remote.appendingPathComponent("Compaction/\(name)")) }
        let fresh = try self.phone("New Phone")
        let waiting = try await pass(fresh, "New Phone")
        XCTAssertGreaterThan(waiting.pendingDownloads, 0)
        XCTAssertEqual(waiting.metadataVersions, [])
        for name in commits { try cloud.deliver(remote.appendingPathComponent("Compaction/\(name)")) }
        let settled = try await pass(fresh, "New Phone")
        XCTAssertEqual(settled.pendingDownloads, 0)
        XCTAssertEqual(settled.metadataVersions, [settings("2")])
    }
}
