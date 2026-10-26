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
        suite = "local.daybook.tests.devices.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookDevices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func environment() -> DeviceEnvironment {
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: root.appendingPathComponent("Staging"))
        environment.soundcoreTransport = { XCTFail("No Bluetooth in hub tests"); return InertSoundcoreTransport() }
        return environment
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
        let other = UserDefaults(suiteName: suite + ".other")!
        defer { other.removePersistentDomain(forName: suite + ".other") }
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

        try await waitUntil("the stable files") { meetings.count == 1 && session.failures.count == 1 }
        XCTAssertEqual(meetings[0].tracks[0].device?.kind, OtherRecorderIntegration.id)
        XCTAssertEqual(meetings[0].tracks[0].device?.recordingID, ImportFolderWatcher.recordingID(sha256: try AudioDigest.sha256(fileURL: good)))
        XCTAssertEqual(session.failures[0].message, "Couldn’t read this file.")
        XCTAssertNil(session.transferProblem, "Folder failures live in Recently imported, not a banner")
        XCTAssertEqual(session.split.imported.count, 1)
        XCTAssertEqual(session.split.new.map(\.fileName), ["notes.m4a"])

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(meetings.count, 1, "Nothing imports twice")

        failNotes = false
        session.retry(session.failures[0])
        try await waitUntil("Try Again") { meetings.count == 2 }
        XCTAssertTrue(session.failures.isEmpty)
        XCTAssertNotNil(files.lastImportDate)
        XCTAssertTrue(files.summary.hasPrefix("Watching") && files.summary.contains("Exports"), files.summary)
        for url in [good, bad] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Originals stay where they are") }

        // Deleting a conversation doesn't bring its file back on its own.
        meetings.removeAll()
        session.libraryChanged([], ready: true)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(meetings.isEmpty)
        XCTAssertEqual(session.newRecordings.count, 2, "It's offered again, for the person to choose")
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
}
