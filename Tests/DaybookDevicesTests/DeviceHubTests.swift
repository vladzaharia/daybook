import AVFoundation
import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookDevices

/// Configured devices: setup, persistence, removal, migration from the single-folder era, and the
/// files method end to end through a device's queue.
@MainActor
final class DeviceHubTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var root: URL!

    override func setUp() async throws {
        suite = makeTestSuite("local.daybook.tests.devices")
        defaults = UserDefaults(suiteName: suite)
        root = makeTemporaryFolder("DaybookDevices")
    }

    private func environment() -> DeviceEnvironment {
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: root.appendingPathComponent("Staging"))
        environment.soundcoreTransport = { XCTFail("No Bluetooth in hub tests"); return InertSoundcoreTransport() }
        return environment
    }

    func testStartingRemovesAudioAKilledImportLeftStagedButNothingElse() throws {
        let staging = root.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let earlier = Date().addingTimeInterval(-600)
        func file(_ name: String, modified: Date) throws -> URL {
            let url = staging.appendingPathComponent(name)
            try Data(repeating: 1, count: 64).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            return url
        }
        let killedImport = try file("Soundcore-1780000000-ab12cd34.wav", modified: earlier)
        let killedListen = try file("Soundcore-Live-1780000600-ef56ab78.wav", modified: earlier)
        let notOurs = try file("Interview.wav", modified: earlier)
        let notAudio = try file("Soundcore-notes.txt", modified: earlier)

        let hub = DeviceHub(environment: environment())
        // A transfer of this run, staged after the hub was made.
        let current = try file("Soundcore-1780001200-00aa11bb.wav", modified: Date().addingTimeInterval(5))
        hub.start()
        let fileManager = FileManager.default
        XCTAssertFalse(fileManager.fileExists(atPath: killedImport.path))
        XCTAssertFalse(fileManager.fileExists(atPath: killedListen.path))
        XCTAssertTrue(fileManager.fileExists(atPath: current.path), "a transfer under way keeps its file")
        XCTAssertTrue(fileManager.fileExists(atPath: notOurs.path), "only Daybook's own staged audio")
        XCTAssertTrue(fileManager.fileExists(atPath: notAudio.path))
        XCTAssertTrue(DeviceHub.removeLeftoverStaging(in: root.appendingPathComponent("Missing"), olderThan: Date()).isEmpty)
    }

    func testSetupJoinsTheSidebarOnlyOnceAMethodIsSetUp() throws {
        let hub = DeviceHub(environment: environment())
        XCTAssertFalse(hub.hasDevices)
        let kind = OtherRecorderIntegration().kind
        let pending = try XCTUnwrap(hub.beginSetup(kind))
        XCTAssertTrue(hub.sessions.isEmpty, "Not in the sidebar until a method is set up")
        hub.cancelSetup()
        XCTAssertNil(hub.pendingSetup)
        XCTAssertTrue(DeviceHub(environment: environment()).devices.isEmpty, "A cancelled setup leaves nothing behind")

        let again = try XCTUnwrap(hub.beginSetup(kind))
        XCTAssertNotEqual(again.id, pending.id)
        try again.files?.watch(root)
        hub.commitSetup()
        XCTAssertEqual(hub.devices.map(\.kindID), [OtherRecorderIntegration.id])

        let relaunched = DeviceHub(environment: environment())
        XCTAssertEqual(relaunched.devices.map(\.id), [again.id], "Configured devices persist")
        relaunched.start()
        XCTAssertEqual(relaunched.sessions.first?.files?.folder?.standardizedFileURL, root.standardizedFileURL, "Its folder is restored")
        relaunched.shutDown()
        hub.shutDown()
    }

    /// A stored device this build can't read (a newer build's method, a damaged entry) doesn't empty the list:
    /// the others load, the unreadable one is written back as it was, and a copy of what was stored is kept.
    func testBehaviorADeviceThatCantBeReadDoesNotCostTheOthers() throws {
        let other = OtherRecorderIntegration().kind
        let added = Date(timeIntervalSince1970: 1_780_000_000)
        var known = ConfiguredDevice(id: "zoom", kind: other, name: "Zoom H1n", addedAt: added)
        known.importsAutomatically = false
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(known)) as? [String: Any])
        // A newer build's method among the turned-off ones: left out, not fatal.
        encoded["disabledMethods"] = ["usb"]
        // An older build's device: only its identity and name.
        let older: [String: Any] = ["id": "old", "kindID": SoundcoreWorkIntegration.id, "name": "Soundcore Work"]
        let damaged: [String: Any] = ["name": "No identity"]
        let original = try JSONSerialization.data(withJSONObject: [encoded, older, damaged])
        defaults.set(original, forKey: DeviceHub.storageKey)

        let hub = DeviceHub(environment: environment())
        XCTAssertEqual(hub.devices.map(\.id), ["zoom", "old"])
        let zoom = try XCTUnwrap(hub.devices.first)
        XCTAssertEqual(zoom.name, "Zoom H1n")
        XCTAssertFalse(zoom.importsAutomatically)
        XCTAssertTrue(zoom.disabledMethods.isEmpty)
        XCTAssertEqual(zoom.addedAt, added)
        XCTAssertEqual(zoom.automaticImportsSince, added)
        let old = try XCTUnwrap(hub.devices.last)
        XCTAssertTrue(old.importsAutomatically, "defaults for what an older build didn't store")
        XCTAssertNil(old.alsoRecordsWithMac)
        XCTAssertEqual(defaults.data(forKey: StoredDevices.backupKey(DeviceHub.storageKey)), original, "what was stored, kept")

        // Adding a device writes the list back with the unreadable entry as it was.
        let session = try XCTUnwrap(hub.beginSetup(other))
        try session.files?.watch(root)
        hub.commitSetup()
        let written = try XCTUnwrap(defaults.data(forKey: DeviceHub.storageKey))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [[String: Any]])
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries.last?["name"] as? String, "No identity", "kept for a build that can read it")
        XCTAssertEqual(DeviceHub(environment: environment()).devices.map(\.id), ["zoom", "old", session.id])
        hub.shutDown()
    }

    /// Every setting a device stores reads back as it was written, so a save and a launch never reset one.
    func testBehaviorEveryStoredSettingReadsBackAsWritten() throws {
        var phone = ConfiguredDevice(id: "phone", kind: DaybookPhoneIntegration().kind, name: "Pocket iPhone",
                                     addedAt: Date(timeIntervalSince1970: 1_780_000_000))
        phone.disabledMethods = [.files]
        phone.importsAutomatically = false
        phone.automaticImportsSince = Date(timeIntervalSince1970: 1_780_100_000)
        phone.alsoRecordsWithMac = false
        phone.recordAlongOffOwed = true
        phone.fastTransferForLongRecordings = false
        let data = try StoredDevices().encoded([phone])
        let read = StoredDevices(data, knownKinds: [DaybookPhoneIntegration.id])
        XCTAssertEqual(read.devices, [phone])
        XCTAssertEqual(read.devices.first?.recordAlongOffOwed, true)

        // Through the hub, as a relaunch reads it.
        defaults.set(data, forKey: DeviceHub.storageKey)
        let hub = DeviceHub(environment: environment())
        XCTAssertEqual(hub.devices, [phone])
        hub.shutDown()
    }

    /// A stored list that isn't a list at all is kept aside, and the hub starts with none.
    func testBehaviorAStoredListThatCantBeReadIsKeptAside() throws {
        let garbage = Data("{not json".utf8)
        defaults.set(garbage, forKey: DeviceHub.storageKey)
        let hub = DeviceHub(environment: environment())
        XCTAssertTrue(hub.devices.isEmpty)
        XCTAssertEqual(defaults.data(forKey: StoredDevices.backupKey(DeviceHub.storageKey)), garbage)
        hub.shutDown()
    }

    /// A device of a kind this build doesn't know (a newer build's, such as a Plaud) reads fine but has nothing to run
    /// it: it isn't shown, and it's written back as it was when another device is renamed or added, so a build that
    /// knows the kind gets it back.
    func testBehaviorADeviceOfAKindThisBuildDoesntKnowSurvivesSaves() throws {
        let other = OtherRecorderIntegration().kind
        let zoom = ConfiguredDevice(id: "zoom", kind: other, name: "Zoom H1n", addedAt: Date(timeIntervalSince1970: 1_780_000_000))
        let encodedZoom = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(zoom)) as? [String: Any])
        let plaud: [String: Any] = ["id": "plaud", "kindID": "plaud.note", "name": "Plaud Note", "pairing": ["serial": "PN-1"]]
        let original = try JSONSerialization.data(withJSONObject: [encodedZoom, plaud])
        defaults.set(original, forKey: DeviceHub.storageKey)

        let hub = DeviceHub(environment: environment())
        XCTAssertEqual(hub.devices.map(\.id), ["zoom"])
        XCTAssertEqual(defaults.data(forKey: StoredDevices.backupKey(DeviceHub.storageKey)), original, "what was stored, kept")
        hub.rename("zoom", to: "Zoom H1n Field")
        let session = try XCTUnwrap(hub.beginSetup(other))
        try session.files?.watch(root)
        hub.commitSetup()
        hub.shutDown()

        let written = try XCTUnwrap(defaults.data(forKey: DeviceHub.storageKey))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["id"] as? String }, ["zoom", session.id, "plaud"])
        let kept = try XCTUnwrap(entries.last)
        XCTAssertEqual(kept as NSDictionary, plaud as NSDictionary, "written back as it was, its own fields too")
        XCTAssertEqual(entries.first?["name"] as? String, "Zoom H1n Field")

        // A build that knows the kind.
        let saved = DeviceCatalog.integrations
        DeviceCatalog.integrations = saved + [PlaudIntegration()]
        defer { DeviceCatalog.integrations = saved }
        let later = DeviceHub(environment: environment())
        XCTAssertEqual(later.devices.map(\.id), ["zoom", session.id, "plaud"])
        XCTAssertEqual(later.session("plaud")?.device.name, "Plaud Note")
        later.shutDown()
    }

    /// The copy of a list that couldn't all be read is made once: later launches find the same entry, written back
    /// with every save, and add no copy and replace none.
    func testBehaviorTheCopyOfAListThatCantAllBeReadIsMadeOnce() throws {
        let other = OtherRecorderIntegration().kind
        let zoom = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ConfiguredDevice(id: "zoom", kind: other))))
        let original = try JSONSerialization.data(withJSONObject: [zoom, ["id": "newer", "kindID": "plaud.note"]])
        defaults.set(original, forKey: DeviceHub.storageKey)
        func copies() -> [String] {
            defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(DeviceHub.storageKey + ".unreadable") }.sorted()
        }

        let first = DeviceHub(environment: environment())
        first.rename("zoom", to: "Zoom H1n")
        first.shutDown()
        XCTAssertEqual(copies(), [StoredDevices.backupKey(DeviceHub.storageKey)])
        for _ in 0..<3 { DeviceHub(environment: environment()).shutDown() }
        XCTAssertEqual(copies(), [StoredDevices.backupKey(DeviceHub.storageKey)], "one copy, however many launches")
        XCTAssertEqual(defaults.data(forKey: StoredDevices.backupKey(DeviceHub.storageKey)), original, "the first one found")
    }

    /// A kind a later build knows, for the test above.
    private struct PlaudIntegration: DeviceIntegration {
        var kind: DeviceKind {
            DeviceKind(id: "plaud.note", name: "Plaud Note", shortName: "Plaud", vendor: "Plaud", systemImage: "mic",
                       summary: "A recorder for tests.", methods: OtherRecorderIntegration().kind.methods, audioSource: .imported,
                       allowsMultiple: true)
        }
        func makeConnection(_ method: ConnectionMethodKind, for device: ConfiguredDevice, environment: DeviceEnvironment) -> (any DeviceConnection)? {
            nil
        }
    }

    func testOneSoundcorePerMacButManyOtherRecorders() throws {
        let hub = DeviceHub(environment: environment())
        let soundcore = SoundcoreWorkIntegration().kind
        let first = try XCTUnwrap(hub.beginSetup(soundcore))
        try first.files?.watch(root)
        hub.commitSetup()
        XCTAssertTrue(hub.beginSetup(soundcore) === first, "Setting up Soundcore again adds to the existing device")

        let other = OtherRecorderIntegration().kind
        for _ in 0..<2 {
            let session = try XCTUnwrap(hub.beginSetup(other))
            try session.files?.watch(root)
            hub.commitSetup()
        }
        XCTAssertEqual(hub.devices.map(\.name), ["Soundcore Work", "Other Recorder", "Other Recorder 2"])
        hub.rename(hub.sessions[1].id, to: "  Zoom H1n ")
        XCTAssertEqual(hub.sessions[1].device.name, "Zoom H1n")

        hub.forget(.files, of: first.id)
        XCTAssertNil(hub.session(first.id), "A device goes when its last method does")
        hub.remove(hub.sessions[0].id)
        XCTAssertEqual(DeviceHub(environment: environment()).devices.map(\.name), ["Other Recorder 2"])
        hub.shutDown()
    }

    func testTheSingleFolderAndRecorderOfEarlierVersionsBecomeDevices() throws {
        let bookmark = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: "importFolderBookmark")
        defaults.set(["\(root.path)/notes.m4a|2048|1780000000.0"], forKey: "importedFileFingerprints")
        defaults.set("soundcore", forKey: "importFolderSource")
        let recorderID = UUID()
        defaults.set(try JSONSerialization.data(withJSONObject: ["deviceID": recorderID.uuidString, "name": "soundcore Work", "serial": "D3200X"]),
                     forKey: "soundcoreRememberedRecorder")
        defaults.set(true, forKey: "soundcoreImportsWhenConnected")
        defaults.set(false, forKey: "soundcoreConnectsOverBluetooth")

        let hub = DeviceHub(environment: environment())
        XCTAssertEqual(hub.devices.count, 1, "One Soundcore with both methods")
        let device = try XCTUnwrap(hub.devices.first)
        XCTAssertEqual(device.kindID, SoundcoreWorkIntegration.id)
        XCTAssertTrue(device.importsAutomatically)
        XCTAssertFalse(device.isEnabled(.direct), "Bluetooth stays off if it was off")
        let session = try XCTUnwrap(hub.sessions.first)
        session.files?.activate()
        XCTAssertTrue(session.files?.wasImported("file:notes.m4a|2048") == true, "Already-imported files stay imported")
        let direct = try XCTUnwrap(session.direct as? SoundcoreConnection)
        XCTAssertEqual(direct.isEnabled, false)
        direct.activate()
        XCTAssertEqual(direct.remembered?.deviceID, recorderID)
        for key in DeviceHubMigration.Legacy.all { XCTAssertNil(defaults.object(forKey: key), "\(key) is moved, not copied") }
        hub.shutDown()

        // Another recorder's folder becomes an Other Recorder.
        removeTestSuiteAtTeardown(suite + ".other")
        let other = UserDefaults(suiteName: suite + ".other")!
        other.set(bookmark, forKey: "importFolderBookmark")
        other.set("imported", forKey: "importFolderSource")
        var env = environment()
        env.defaults = other
        XCTAssertEqual(DeviceHub(environment: env).devices.map(\.kindID), [OtherRecorderIntegration.id])
    }

    /// The files method through a device's queue: stable files import on their own, once; a file
    /// that fails gets Try Again; the folder's files are never moved or deleted.
    func testFolderImportsNewFilesOnceAndRetriesFailures() async throws {
        let folder = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let good = folder.appendingPathComponent("meeting.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        try AVAudioFile(forWriting: good, settings: format.settings).write(from: buffer)
        let bad = folder.appendingPathComponent("notes.m4a")
        try Data(repeating: 1, count: 64).write(to: bad)
        try Data("not audio".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        // Written long enough ago to count as finished; one that can't be read is listed after a while, to say why.
        try Self.writtenAgo(600, good, bad)

        let kind = OtherRecorderIntegration().kind
        let device = ConfiguredDevice(id: "folder", kind: kind)
        let env = environment()
        let files = ImportFolderWatcher(storage: env.storage(for: device, method: .files), interval: .milliseconds(100))
        let session = DeviceSession(device: device, kind: kind, connections: [files], defaults: defaults)
        var meetings: [Meeting] = []
        var failNotes = true
        session.importer = { [weak session] url, identity, attachTo, source in
            if failNotes && url.lastPathComponent == "notes.m4a" { throw DaybookError.invalidAudio(url.lastPathComponent) }
            let meeting = Meeting(title: url.lastPathComponent, tracks: [RecordingTrack(source: source, relativePath: "Originals/a",
                                                                                         fileName: url.lastPathComponent, device: identity)])
            meetings.append(meeting)
            session?.libraryChanged(meetings, ready: true)
            return meeting.id
        }
        session.libraryChanged([], ready: true)
        try files.watch(folder)
        defer { session.shutDown() }

        try await waitUntil("the stable files") { meetings.count == 1 && session.failures.count == 1 && session.lastBatch != nil }
        // Its notification opens the conversation the one recording went into.
        XCTAssertEqual(session.lastBatch, .init(count: 1, destination: .conversation(meetings[0].id)))
        XCTAssertEqual(meetings[0].tracks[0].device?.kind, OtherRecorderIntegration.id)
        XCTAssertEqual(meetings[0].tracks[0].device?.recordingID, ImportFolderWatcher.recordingID(sha256: try AudioDigest.sha256(fileURL: good)))
        XCTAssertEqual(session.failures[0].message, "Couldn’t read this file.")
        XCTAssertNil(session.transferProblem, "Folder failures live in Recently imported, not a banner")
        XCTAssertEqual(session.split.imported.count, 1)
        XCTAssertEqual(session.split.new.map(\.fileName), ["notes.m4a"])

        try await settle(files, session)
        XCTAssertEqual(meetings.count, 1, "Nothing imports twice")

        failNotes = false
        session.retry(session.failures[0])
        try await waitUntil("Try Again") { meetings.count == 2 && session.lastBatch?.destination == .conversation(meetings[1].id) }
        XCTAssertTrue(session.failures.isEmpty)
        XCTAssertNotNil(files.lastImportDate)
        XCTAssertTrue(files.summary.hasPrefix("Watching") && files.summary.contains("Exports · Last import "), files.summary)
        for url in [good, bad] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Originals stay where they are") }

        // Deleting a conversation doesn't bring its file back on its own.
        meetings.removeAll()
        session.libraryChanged([], ready: true)
        try await settle(files, session)
        XCTAssertTrue(meetings.isEmpty)
        XCTAssertEqual(session.newRecordings.count, 2, "It's offered again, for the person to choose")
    }

    /// Sets files' modification dates `seconds` back, as a file finished that long ago.
    private static func writtenAgo(_ seconds: TimeInterval, _ urls: URL...) throws {
        for url in urls {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
        }
    }

    /// A file counts once it's finished: unchanged across two looks, last written at least 30 seconds ago (a slow writer
    /// pausing between looks isn't done), and readable as audio, though one that still can't be read after five minutes
    /// is listed so its import can say why.
    func testBehaviorAFolderFileCountsOnlyOnceItsWriterIsDone() async throws {
        let folder = root.appendingPathComponent("Slow", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        let fresh = folder.appendingPathComponent("fresh.wav")
        try AVAudioFile(forWriting: fresh, settings: format.settings).write(from: buffer)
        let settled = folder.appendingPathComponent("settled.wav")
        try AVAudioFile(forWriting: settled, settings: format.settings).write(from: buffer)
        // An M4A whose index hasn't been written yet: its bytes aren't a readable container.
        let partial = folder.appendingPathComponent("partial.m4a")
        try Data(repeating: 7, count: 512).write(to: partial)
        let abandoned = folder.appendingPathComponent("abandoned.m4a")
        try Data(repeating: 9, count: 512).write(to: abandoned)
        try Self.writtenAgo(45, settled, partial)
        try Self.writtenAgo(400, abandoned)

        let device = ConfiguredDevice(id: "slow", kind: OtherRecorderIntegration().kind)
        let files = ImportFolderWatcher(storage: environment().storage(for: device, method: .files), interval: .seconds(3600))
        defer { files.shutDown() }
        try files.watch(folder)
        await files.scan()
        await files.scan()
        XCTAssertEqual(Set(files.recordings.compactMap(\.fileName)), ["settled.wav", "abandoned.m4a"],
                       "written moments ago, or not yet readable, it waits; unreadable for minutes, it's listed to say why")

        // The fresh file's writer has been quiet for long enough now.
        try Self.writtenAgo(31, fresh)
        await files.scan()
        await files.scan()
        XCTAssertTrue(files.recordings.contains { $0.fileName == "fresh.wav" })
        XCTAssertFalse(files.recordings.contains { $0.fileName == "partial.m4a" })
        XCTAssertTrue(ImportFolderWatcher.isReadableAudio(settled))
        XCTAssertFalse(ImportFolderWatcher.isReadableAudio(partial))
    }

    /// The watcher looks again (twice: a file counts once it's unchanged across two looks), the session acts on what
    /// it saw, and whatever that queued has run: a moment in which something that shouldn't import would have.
    private func settle(_ files: ImportFolderWatcher, _ session: DeviceSession) async throws {
        await files.scan()
        await files.scan()
        for _ in 0..<10 { await Task.yield() }
        try await waitUntil("the queue to be idle") { !session.queue.isActive }
    }

    func testDifferentFoldersWithEqualFileNamesAndSizesUseContentIdentity() async throws {
        let device = ConfiguredDevice(id: "collision", kind: OtherRecorderIntegration().kind)
        let files = ImportFolderWatcher(storage: environment().storage(for: device, method: .files), interval: .seconds(3600))
        defer { files.shutDown() }
        var ids: [String] = []
        for (folderName, bytes) in [("first", "aaaa"), ("second", "bbbb")] {
            let folder = root.appendingPathComponent(folderName)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(bytes.utf8).write(to: folder.appendingPathComponent("recording.wav"))
            try Data(bytes.utf8).write(to: folder.appendingPathComponent("copy.wav"))
            try Self.writtenAgo(600, folder.appendingPathComponent("recording.wav"), folder.appendingPathComponent("copy.wav"))
            try files.watch(folder)
            await files.scan()
            await files.scan()
            let recording = try XCTUnwrap(files.recordings.first)
            XCTAssertEqual(files.recordings.count, 1, "Copies of the same bytes share one recording identity")
            XCTAssertFalse(files.wasImported(recording.id))
            XCTAssertEqual(files.automaticImports(links: .init(), since: .distantPast, excluding: []).count, 1)
            files.didImport(recording)
            ids.append(recording.id)
        }
        XCTAssertNotEqual(ids[0], ids[1])
    }

    /// The folder is listed, read, and hashed off the main actor (in iCloud Drive a file provider can be slow), and
    /// only plain values come back to it.
    func testBehaviorAFolderIsSurveyedOffTheMainActor() async throws {
        let folder = root.appendingPathComponent("Survey", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: folder.appendingPathComponent("b.wav"))
        try Data(repeating: 2, count: 32).write(to: folder.appendingPathComponent("a.m4a"))
        try Data("notes".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        try Data().write(to: folder.appendingPathComponent(".c.mp3.icloud"))
        try Data().write(to: folder.appendingPathComponent("empty.wav"))

        let survey = try await Task.detached { ImportFolderWatcher.survey(folder) }.value.get()
        XCTAssertEqual(survey.files.map(\.name), ["a.m4a", "b.wav"], "audio only, in path order, nothing empty")
        XCTAssertEqual(survey.waitingForICloud, 1, "a placeholder still in iCloud, asked to download")
        let file = survey.files[1]
        XCTAssertEqual(file.fingerprint.size, 64)
        let digest = await Task.detached { ImportFolderWatcher.digest(of: file.url, unchangedFrom: file.fingerprint) }.value
        XCTAssertEqual(digest, try AudioDigest.sha256(fileURL: file.url))
        try Data(repeating: 4, count: 65).write(to: file.url)
        let changed = await Task.detached { ImportFolderWatcher.digest(of: file.url, unchangedFrom: file.fingerprint) }.value
        XCTAssertNil(changed, "a file that changed since it was looked at isn't taken as it was")

        let gone = await Task.detached { ImportFolderWatcher.survey(folder.appendingPathComponent("Gone")) }.value
        if case .failure(.missing) = gone {} else { XCTFail("a folder that isn't there is missing: \(gone)") }
    }

    func testMissingFolderIsAProblemWithChooseFolder() async throws {
        let folder = root.appendingPathComponent("Gone", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let device = ConfiguredDevice(id: "gone", kind: OtherRecorderIntegration().kind)
        let files = ImportFolderWatcher(storage: environment().storage(for: device, method: .files), interval: .milliseconds(100))
        try files.watch(folder)
        defer { files.shutDown() }
        try FileManager.default.removeItem(at: folder)
        try await waitUntil("the missing folder") { files.problem != nil }
        XCTAssertEqual(files.state, .unavailable)
        XCTAssertEqual(files.problem?.actions, [.chooseFolder])
    }

    /// In the App Sandbox a bookmark made before can stop working: the folder is still named, and Choose Folder… starts
    /// where it was.
    func testAFolderThatCantBeOpenedAnyMoreIsNamedAndOfferedAgain() throws {
        let folder = root.appendingPathComponent("Recorder Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let device = ConfiguredDevice(id: "regrant", kind: OtherRecorderIntegration().kind)
        let storage = environment().storage(for: device, method: .files)
        let first = ImportFolderWatcher(storage: storage, interval: .seconds(3600))
        try first.watch(folder)
        first.shutDown()
        XCTAssertNotNil(storage.data(ImportFolderWatcher.Keys.location), "a plain bookmark beside the scoped one")

        storage.set(Data("not a bookmark".utf8), ImportFolderWatcher.Keys.bookmark)
        let relaunched = ImportFolderWatcher(storage: storage, interval: .seconds(3600))
        relaunched.activate()
        defer { relaunched.shutDown() }
        XCTAssertEqual(relaunched.problem, ImportFolderWatcher.accessLost)
        XCTAssertNil(relaunched.folder)
        XCTAssertEqual(relaunched.lastKnownFolder?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        XCTAssertEqual(relaunched.suggestedFolder?.lastPathComponent, "Recorder Exports")
        XCTAssertTrue(relaunched.summary.contains("Recorder Exports"), relaunched.summary)

        try relaunched.watch(folder)
        XCTAssertNil(relaunched.problem)
        XCTAssertNil(relaunched.lastKnownFolder)
    }

    func testFolderHelpers() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(ImportFolderWatcher.displayPath(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Daybook Import")),
                       "iCloud Drive › Daybook Import")
        XCTAssertEqual(ImportFolderWatcher.displayPath(home.appendingPathComponent("Documents/Recorder")), "Documents › Recorder")
        XCTAssertEqual(ImportFolderWatcher.displayPath(URL(fileURLWithPath: "/Volumes/Card/Audio")), "Card › Audio")
        XCTAssertTrue(ImportFolderWatcher.isAudio("rec_2026-10-22.MP3"))
        XCTAssertFalse(ImportFolderWatcher.isAudio("notes.txt"))
        XCTAssertEqual(ImportFolderWatcher.placeholderOriginalName(".notes.m4a.icloud"), "notes.m4a")
        XCTAssertNil(ImportFolderWatcher.placeholderOriginalName(".DS_Store"))
        XCTAssertEqual(ImportFolderWatcher.failureMessage(DaybookError.invalidAudio("x")), "Couldn’t read this file.")
        XCTAssertEqual(ImportFolderWatcher.failureMessage(DaybookError.libraryUnavailable), "Couldn’t import this file.")
    }

    /// In the App Sandbox the process's home is the container; folders are named from the person's own home.
    func testFolderPathsAreNamedFromThePersonsHomeNotTheContainer() {
        let home = URL(fileURLWithPath: "/Users/dana", isDirectory: true)
        XCTAssertEqual(ImportFolderWatcher.displayPath(URL(fileURLWithPath: "/Users/dana/Documents/Recorder"), home: home), "Documents › Recorder")
        XCTAssertEqual(ImportFolderWatcher.displayPath(URL(fileURLWithPath: "/Users/dana/Library/Mobile Documents/com~apple~CloudDocs/Daybook Import"),
                                                       home: home), "iCloud Drive › Daybook Import")
        XCTAssertEqual(ImportFolderWatcher.displayPath(URL(fileURLWithPath: "/Users/sam/Music/Exports"), home: home), "Music › Exports")
    }
}
