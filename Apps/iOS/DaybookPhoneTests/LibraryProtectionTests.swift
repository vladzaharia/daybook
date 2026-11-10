import DaybookCaptions
import DaybookCore
import DaybookKit
import XCTest
@testable import DaybookPhone

/// "Protect while iPhone is locked" (`LibraryProtection`, `PhoneAppModel+Protection.swift`): each kind of file's class
/// on and off, switching that goes on where a killed run stopped, and what reads the library in the background (loading
/// it, sync, recovery, Spotlight, the widgets' snapshots, backups' rules) waiting for a pretend unlock instead of failing.
///
/// The simulator neither locks nor applies data protection through Foundation (every file reads class C there), so the
/// classes are given and read through the file system (`ProtectionClass`, as the iPhone keeps them), a pretend iPhone
/// (`PretendLock`) stands in for a locked one, and files made unreadable for ones a locked iPhone can't open. Temporary
/// libraries and synthetic audio.
@MainActor
final class LibraryProtectionTests: XCTestCase {
    // MARK: Classes

    /// A library with one of every kind of file: a conversation's text, its audio recorded here and from a recorder, a
    /// photo, its highlights; the settings; sync's bases, sealing record, and courier ledger; saved captions, and those of
    /// a recording in progress; the stops owed to Macs; and a recording in progress in staging.
    private struct Tree {
        let root: URL
        let meeting = UUID(), recording = UUID()
        let paths: [String]
        var hereAudio: String { "Meetings/\(meeting.uuidString)/Originals/here.m4a" }
        var exemptions: LibraryProtection.Exemptions {
            LibraryProtection.Exemptions(skipped: ["LiveCaptions/\(recording.uuidString)"], madeHere: [hereAudio])
        }

        init(root: URL) throws {
            self.root = root
            let folder = "Meetings/\(meeting.uuidString)"
            paths = ["\(folder)/meeting.json", "\(folder)/meeting.recovery.json", "\(folder)/Originals/here.m4a",
                     "\(folder)/Originals/recorder.wav", "\(folder)/Originals/Photos/photo.jpg", "\(folder)/Originals/here.highlights-ab.json",
                     "library.json", "glossary.json", "local-work.json", "owed-stops.json",
                     "Sync/lib-dev.json", "Sync/Bases/lib-dev/\(meeting.uuidString).json", "Sync/sealing.json",
                     "Sync/Courier/outbox.json", "Sync/Inbox/lib/Blobs/abcdef",
                     "LiveCaptions/\(meeting.uuidString).json", "LiveCaptions/\(recording.uuidString).\(UUID().uuidString).json",
                     "Staging/\(recording.uuidString)/part-0.m4a", "Trash/\(UUID().uuidString)/meeting.json"]
            for path in paths {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("\(path)".utf8).write(to: url)
            }
        }

        func url(_ path: String) -> URL { root.appendingPathComponent(path) }
        func path(ending suffix: String) -> String { paths.first { $0.hasSuffix(suffix) }! }
    }

    private func protector(_ root: URL, defaults: UserDefaults, exemptions: LibraryProtection.Exemptions = .init(),
                           widgets: URL? = nil) -> LibraryProtector {
        let protector = LibraryProtector(libraryRoot: root, widgets: widgets, defaults: defaults)
        protector.exemptions = { exemptions }
        return protector
    }

    private func classOf(_ tree: Tree, _ suffix: String) -> FileProtectionType? { ProtectionClass.of(tree.url(tree.path(ending: suffix))) }

    /// On, text is class A and audio and photos class B; the files that say how things stand stay class C, and a
    /// recording in progress, with its captions, is left as it is. Off, it's as before: text class C, saved captions
    /// class B, audio class C but for what was recorded here, which stays class B as it was filed.
    func testBehaviorEachKindOfFileTakesItsClassOnAndTodaysOff() async throws {
        let tree = try Tree(root: try temporaryDirectory("library"))
        let staged = tree.url(tree.path(ending: "part-0.m4a"))
        try ProtectionClass.set(.completeUnlessOpen, on: staged)
        let inProgress = tree.url(tree.paths.first { $0.hasPrefix("LiveCaptions/\(tree.recording.uuidString)") }!)
        try ProtectionClass.set(.completeUnlessOpen, on: inProgress)
        let defaults = makeTestDefaults("LibraryProtectionTests")
        let protector = protector(tree.root, defaults: defaults, exemptions: tree.exemptions)
        XCTAssertTrue(protector.isSettled(protects: false), "never switched: the classes are off's")
        XCTAssertFalse(protector.isSettled(protects: true))

        protector.protect(true)
        await protector.settle()
        XCTAssertTrue(protector.isSettled(protects: true))
        XCTAssertNil(protector.progress, "no bar once it's through")
        for text in ["/meeting.json", "meeting.recovery.json", "highlights-ab.json", "library.json", "glossary.json", "local-work.json",
                     "Sync/lib-dev.json", "lib-dev/\(tree.meeting.uuidString).json", "LiveCaptions/\(tree.meeting.uuidString).json"] {
            XCTAssertEqual(classOf(tree, text), .complete, text)
        }
        XCTAssertEqual(ProtectionClass.of(tree.url(tree.paths.last!)), .complete, "a conversation in the Trash")
        for media in ["here.m4a", "recorder.wav", "photo.jpg", "Blobs/abcdef"] {
            XCTAssertEqual(classOf(tree, media), .completeUnlessOpen, media)
        }
        for state in ["owed-stops.json", "sealing.json", "outbox.json"] {
            XCTAssertEqual(classOf(tree, state), .completeUntilFirstUserAuthentication, "\(state): read and written while locked")
        }
        for file in [PhoneLibrary.broughtInFile, PhoneAppModel.owedStopsFile] {
            XCTAssertTrue(LibraryProtection.stateFiles.contains(file), "\(file): read as Daybook starts, perhaps locked")
        }
        XCTAssertEqual(ProtectionClass.of(inProgress), .completeUnlessOpen, "a recording in progress's captions: written while locked")
        XCTAssertEqual(ProtectionClass.of(staged), .completeUnlessOpen, "staging is the recording's own")
        // Folders take their files' class, so what's made in them later does too.
        XCTAssertEqual(ProtectionClass.of(tree.root), .complete)
        XCTAssertEqual(ProtectionClass.of(tree.url("Meetings/\(tree.meeting.uuidString)")), .complete)
        XCTAssertEqual(ProtectionClass.of(tree.url("Meetings/\(tree.meeting.uuidString)/Originals")), .completeUnlessOpen)
        XCTAssertEqual(ProtectionClass.of(tree.url("Staging")), .completeUnlessOpen, "never the library's class A")
        XCTAssertEqual(ProtectionClass.of(tree.url("Sync/Courier")), .completeUntilFirstUserAuthentication)

        protector.protect(false)
        await protector.settle()
        XCTAssertTrue(protector.isSettled(protects: false))
        for text in ["/meeting.json", "library.json", "Sync/lib-dev.json", "highlights-ab.json"] {
            XCTAssertEqual(classOf(tree, text), .completeUntilFirstUserAuthentication, text)
        }
        XCTAssertEqual(classOf(tree, "LiveCaptions/\(tree.meeting.uuidString).json"), .completeUnlessOpen, "saved captions, as before")
        XCTAssertEqual(classOf(tree, "here.m4a"), .completeUnlessOpen, "recorded here: as it was filed")
        XCTAssertEqual(classOf(tree, "recorder.wav"), .completeUntilFirstUserAuthentication)
        XCTAssertEqual(ProtectionClass.of(tree.root), .completeUntilFirstUserAuthentication)
        XCTAssertEqual(ProtectionClass.of(staged), .completeUnlessOpen)
    }

    /// What a save makes after the switch takes the class of its folder (text class A, audio class B), and a file a save
    /// made with another class gets the library's shortly after (`keep`), but never while a pretend iPhone is locked.
    func testBehaviorWhatsMadeAfterTheSwitchTakesTheLibrarysClass() async throws {
        let tree = try Tree(root: try temporaryDirectory("library"))
        var locked = false
        let protector = protector(tree.root, defaults: makeTestDefaults("LibraryProtectionTests"), exemptions: tree.exemptions)
        protector.isAvailable = { !locked }
        protector.keepDelay = .zero
        protector.protect(true)
        await protector.settle()

        let folder = tree.url("Meetings/\(tree.meeting.uuidString)")
        let note = folder.appendingPathComponent("new.json")
        try Data("{}".utf8).write(to: note)
        XCTAssertEqual(ProtectionClass.of(note), .complete, "made in a class A folder")
        let audio = folder.appendingPathComponent("Originals/new.m4a")
        try Data("audio".utf8).write(to: audio)
        XCTAssertEqual(ProtectionClass.of(audio), .completeUnlessOpen, "made among the audio")

        // A save that came out class C (a temporary file made elsewhere, renamed into place).
        let saved = tree.url(tree.path(ending: "/meeting.json"))
        try ProtectionClass.set(.completeUntilFirstUserAuthentication, on: saved)
        locked = true
        protector.keep(now: true)
        await protector.settle()
        XCTAssertEqual(ProtectionClass.of(saved), .completeUntilFirstUserAuthentication, "nothing changes while locked")
        locked = false
        protector.keep()
        await protector.settle()
        XCTAssertEqual(ProtectionClass.of(saved), .complete, "given the library's class")
    }

    /// Switching notes each part of the library as it's through: a run stopped partway (Daybook killed) goes on where it
    /// stopped at the next launch, doing only what's left, and one waiting for a pretend unlock goes on once unlocked.
    func testBehaviorSwitchingResumesWhereAKilledRunStopped() async throws {
        let root = try temporaryDirectory("library")
        let tree = try Tree(root: root)
        for _ in 0..<4 {
            let other = root.appendingPathComponent("Meetings/\(UUID().uuidString)/meeting.json")
            try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: other)
        }
        let defaults = makeTestDefaults("LibraryProtectionTests")
        let units = LibraryProtection.units(libraryRoot: root, widgets: nil).map(\.name)
        XCTAssertEqual(units.filter { $0.hasPrefix("Meetings/") }.count, 5, "a conversation at a time")
        XCTAssertFalse(units.contains { $0.hasPrefix("Staging/") }, "a recording in progress is never a part")

        let first = protector(root, defaults: defaults, exemptions: tree.exemptions)
        var started: [String] = []
        first.willProtect = { unit in
            started.append(unit)
            if started.count == 4 { first.stop() }
        }
        first.protect(true)
        try await waitUntil("killed partway") { started.count == 4 && !first.isRunning }
        let record = try XCTUnwrap(LibraryProtector.record(in: defaults))
        XCTAssertEqual(record.done.count, 3, "three parts through, the fourth cut short")
        XCTAssertFalse(record.finished)
        XCTAssertTrue(record.protects)

        // The next launch, locked at first.
        var locked = true
        let second = protector(root, defaults: defaults, exemptions: tree.exemptions)
        second.isAvailable = { !locked }
        second.untilAvailable = { while locked { try? await Task.sleep(for: .milliseconds(10)) } }
        var resumed: [String] = []
        second.willProtect = { resumed.append($0) }
        XCTAssertFalse(second.isSettled(protects: true))
        second.resume()
        try await waitUntil("the bar shows how far it came") { (second.progress ?? 0) > 0 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(resumed, [], "nothing while locked")
        locked = false
        await second.settle()
        XCTAssertEqual(resumed, Array(units.dropFirst(3)), "only what's left, from the part cut short")
        XCTAssertTrue(second.isSettled(protects: true))
        XCTAssertEqual(classOf(tree, "/meeting.json"), .complete)
        for unit in units where unit.hasPrefix("Meetings/") {
            XCTAssertEqual(ProtectionClass.of(root.appendingPathComponent("\(unit)/meeting.json")), .complete, unit)
        }
    }

    /// Backups' rules keep working: re-protecting a file or folder keeps it out of backups, and rules asked for while a
    /// pretend iPhone is locked are applied once it's unlocked.
    func testBehaviorBackupExclusionKeepsWorkingWithTheClass() async throws {
        let tree = try Tree(root: try temporaryDirectory("library"))
        for path in ["Meetings", "library.json"] { BackupExclusion.set(tree.url(path), excluded: true) }
        let protector = protector(tree.root, defaults: makeTestDefaults("LibraryProtectionTests"), exemptions: tree.exemptions)
        protector.protect(true)
        await protector.settle()
        XCTAssertEqual(ProtectionClass.of(tree.url("library.json")), .complete)
        XCTAssertTrue(BackupExclusion.isExcluded(tree.url("Meetings")), "a folder keeps its exclusion")
        XCTAssertTrue(BackupExclusion.isExcluded(tree.url("library.json")), "a file keeps its exclusion")

        let lock = PretendLock(locked: false)
        let model = try makeModel(lock: lock, protects: true)
        try await model.library.reload()
        lock.lock()
        model.settings.includesLibraryInBackups = false
        model.applyBackupExclusion()
        XCTAssertFalse(BackupExclusion.isExcluded(model.library.rootURL), "waits while locked")
        lock.unlock()
        XCTAssertTrue(BackupExclusion.isExcluded(model.library.rootURL), "applied once unlocked")
    }

    // MARK: Waiting for the unlock

    private func makeModel(lock: PretendLock, protects: Bool, rig: RecorderRig? = nil, sync: Bool = false,
                           configure: (inout PhoneAppEnvironment) -> Void = { _ in }) throws -> PhoneAppModel {
        let rig = rig ?? RecorderRig()
        var environment = try PhoneAppEnvironment.test(self)
        environment.protectedData = lock.protectedData
        configure(&environment)
        let root = try temporaryDirectory("library")
        var controller: LibrarySyncController?
        if sync {
            controller = LibrarySyncController(localRoot: root, defaults: environment.defaults)
            controller?.replica = PhoneSync.replica(displayName: "Test iPhone", budget: 1_000_000_000)
            controller?.syncDebounce = nil
        }
        let settings = PhoneSettings(defaults: environment.defaults)
        settings.protectsWhileLocked = protects
        let model = PhoneAppModel(recorder: rig.recorder, library: PhoneLibrary(rootURL: root, sync: controller, installation: "INSTALL-1"),
                                  posture: DevicePosture(), options: DebugLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                                  environment: environment, settings: settings)
        if protects { model.protectionChanged() }
        return model
    }

    /// While it's on and the iPhone is locked, the library never loads (it would read a conversation that's there as one
    /// that isn't), yet a recording starts, shows its Live Activity and the widgets' state, and stops; once unlocked, the
    /// library loads and the recording is filed.
    func testBehaviorTheLibraryWaitsForTheUnlockAndARecordingStillStartsAndStops() async throws {
        let rig = RecorderRig()
        let lock = PretendLock(locked: true)
        let model = try makeModel(lock: lock, protects: true, rig: rig)
        XCTAssertTrue(model.libraryKeptLocked)
        XCTAssertFalse(model.libraryReadable)
        let loading = Task { try await model.library.reload() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.library.controller.isLoaded, "never loaded while locked")

        try await model.startRecording()
        rig.pump(2)
        XCTAssertEqual(model.recorder.state, .recording, "recording needs only its staging")
        XCTAssertFalse(model.library.controller.isLoaded)
        let state = model.activityState()
        XCTAssertEqual(state.phase, .recording, "the Live Activity reads nothing from the library")
        model.publish()
        XCTAssertEqual(model.sharedState.published?.phase, .recording, "nor do the widgets' recording state")
        let id = try XCTUnwrap(model.recorder.captureID)
        try await model.stopRecording()
        XCTAssertEqual(model.waitsForUnlock(id), true)

        lock.unlock()
        try await loading.value
        XCTAssertTrue(model.library.controller.isLoaded, "loaded once unlocked")
        try await waitUntil("filed once unlocked") { model.lastFiling != nil && model.waitsForUnlock(id) == nil }
        guard case .saved(let filed, _)? = model.lastFiling else { return XCTFail("filed: \(String(describing: model.lastFiling))") }
        XCTAssertEqual(filed, id)
        XCTAssertEqual(model.library.controller.meeting(id)?.tracks.first?.duration ?? 0, 2, accuracy: 0.05)
    }

    /// Sync waits: a pass asked for while it's on and the iPhone is locked doesn't run, and runs once unlocked. Off, it
    /// runs while locked, as before.
    func testBehaviorSyncWaitsForTheUnlockInsteadOfFailing() async throws {
        let lock = PretendLock(locked: false)
        let model = try makeModel(lock: lock, protects: true, sync: true)
        try await model.library.reload()
        try model.sync.connect(toFolder: try temporaryDirectory("container"), monitor: false)
        await model.protector.settle()
        lock.lock()
        await model.sync.synchronize(.remote)
        XCTAssertEqual(model.sync.passes, 0, "no pass while locked")
        XCTAssertEqual(model.sync.waitingForUnlock, .remote)
        XCTAssertNil(model.sync.lastError, "nothing failed")

        lock.unlock()
        try await waitUntil("the pass runs once unlocked") { model.sync.passes == 1 }
        XCTAssertNil(model.sync.waitingForUnlock)

        model.settings.protectsWhileLocked = false
        model.protectionChanged()
        await model.protector.settle()
        lock.lock()
        await model.sync.synchronize(.manual)
        XCTAssertEqual(model.sync.passes, 2, "off: it syncs while locked, as before")
    }

    /// Recovery while it's on and the iPhone is locked reads nothing and loads nothing; once unlocked, the library loads
    /// and the recording is filed.
    func testBehaviorRecoveryWaitsForTheUnlockInsteadOfFailing() async throws {
        let lock = PretendLock(locked: true)
        let model = try makeModel(lock: lock, protects: true)
        let folder = model.library.stagingURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let part = folder.appendingPathComponent(CaptureSegment.fileName(index: 0))
        let frames = try CaptureFiles.writeClosedSegment(to: part, seconds: 1, frequency: 440)
        var journal = PhoneCaptureJournal(id: UUID(), title: "Left while locked", createdAt: Date(), format: CaptureFiles.format)
        journal.segments = [CaptureSegment(index: 0, fileName: part.lastPathComponent, startOffset: 0, frameCount: frames, closed: false,
                                           firstSampleHostTime: 0, clockAnchors: [], notes: nil)]
        try journal.write(to: folder)

        await model.recoverLeftovers()
        XCTAssertTrue(model.recoveryWaitsForUnlock)
        XCTAssertFalse(model.library.controller.isLoaded)
        XCTAssertNil(model.notice, "nothing failed")

        lock.unlock()
        try await waitUntil("recovered once unlocked") { model.library.controller.meeting(journal.id) != nil }
        XCTAssertFalse(model.recoveryWaitsForUnlock)
    }

    /// Spotlight moves to an index kept as the library is when it's turned on (the one it leaves is emptied), and what
    /// changes while the iPhone is locked is listed once it's unlocked.
    func testBehaviorSpotlightMovesToTheProtectedIndexAndWaitsForTheUnlock() async throws {
        let lock = PretendLock(locked: false)
        var plain: [String] = [], protected: [String] = []
        let model = try makeModel(lock: lock, protects: false) { environment in
            environment.spotlight = ConversationIndex.Indexer(isActive: true, index: { plain += $0.map(\.title) }, remove: { _ in },
                                                              removeAll: { plain.append("removed all") })
            environment.spotlightWhileLocked = ConversationIndex.Indexer(isActive: true, index: { protected += $0.map(\.title) },
                                                                         remove: { _ in }, removeAll: { protected.append("removed all") })
        }
        try await model.library.reload()
        model.library.controller.newMeeting(title: "Pricing review", date: Date())
        try await waitUntil("listed in Spotlight's index") { plain.contains("Pricing review") }

        model.settings.protectsWhileLocked = true
        model.protectionChanged()
        try await waitUntil("listed in the protected index") { protected.contains("Pricing review") }
        XCTAssertEqual(plain.last, "removed all", "the index it left is emptied")

        lock.lock()
        model.library.controller.newMeeting(title: "Hiring sync", date: Date())
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(protected.contains("Hiring sync"), "nothing written while locked")
        lock.unlock()
        try await waitUntil("listed once unlocked") { protected.contains("Hiring sync") }
    }

    /// The widgets' snapshots: written class A while it's on, held while the iPhone is locked and written once it's
    /// unlocked; a widget that finds one locked away says so rather than reading it as missing.
    func testBehaviorWidgetSnapshotsWaitForTheUnlockAndReadAsLockedNotMissing() async throws {
        let container = try temporaryDirectory("group")
        let snapshot = SharedRecentConversations([.init(id: UUID(), title: "Pricing review", date: Date())])
        XCTAssertTrue(snapshot.save(to: container, protects: true))
        let file = SharedRecentConversations.cache.snapshotFile(in: container)
        XCTAssertEqual(ProtectionClass.of(file), .complete)
        XCTAssertEqual(ProtectionClass.of(SharedRecentConversations.cache.cacheDirectory(in: container)), .complete)
        guard case .value(let read) = SharedRecentConversations.read(from: container) else { return XCTFail("readable while unlocked") }
        XCTAssertEqual(read, snapshot)

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        guard case .locked = SharedRecentConversations.read(from: container) else { return XCTFail("there, but locked away") }
        XCTAssertNil(SharedRecentConversations.load(from: container), "never handed over")
        guard case .missing = SharedNextSteps.read(from: container) else { return XCTFail("one never written is missing") }
        XCTAssertGreaterThan(SharedWidgetCache.lockedRetry, 0)

        let lock = PretendLock(locked: false)
        var published: [[String]] = []
        let model = try makeModel(lock: lock, protects: true) { environment in
            environment.publishRecentConversations = { published.append($0.conversations.map(\.title)) }
        }
        try await model.library.reload()
        try await waitUntil("published once loaded") { published.count == 1 }
        lock.lock()
        model.library.controller.newMeeting(title: "Hiring sync", date: Date())
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(published.count, 1, "held while locked")
        lock.unlock()
        XCTAssertEqual(published.last, ["Hiring sync"], "written once unlocked")
    }

    /// Saved captions are filed class A while it's on, and a recording's as it goes stay the store's class B.
    func testBehaviorSavedCaptionsAreFiledWithTheLibrarysClass() throws {
        let lock = PretendLock(locked: false)
        let model = try makeModel(lock: lock, protects: false)
        XCTAssertEqual(model.captions.store.filedProtection, LiveCaptionStore.defaultProtection)
        model.settings.protectsWhileLocked = true
        model.protectionChanged()
        XCTAssertEqual(model.captions.store.filedProtection, .complete)
        XCTAssertEqual(model.captions.store.protection, .completeUnlessOpen, "written while locked as it records")
        XCTAssertTrue(model.processor.conditions.keepsLibraryLocked)
        model.settings.protectsWhileLocked = false
        model.protectionChanged()
        XCTAssertEqual(model.captions.store.filedProtection, LiveCaptionStore.defaultProtection)
    }
}
