import DaybookKit
import DaybookUI
import UIKit
import XCTest
@testable import DaybookPhone

/// A phone and a Mac sharing one library through a temporary folder standing in for the iCloud
/// container: the phone replica's wiring (on-demand audio, presence, bounded passes, status), live
/// library updates, Mac presence, and the sync-backed audio provider.
@MainActor
final class SyncServicesTests: XCTestCase {
    func testARecordingUploadsAtOnceAndAMacsChangesArriveLive() async throws {
        let container = try temporaryDirectory("container")
        let phone = try await makePhone(container)
        XCTAssertEqual(phone.sync.statusLine, "Waiting to sync")
        await phone.sync.synchronize(.launch)
        XCTAssertEqual(phone.sync.statusLine, "Up to date")
        let presenceBefore = MacPresence.resolve(connectedMac: nil, devices: phone.sync.devices, syncAvailable: true,
                                                 syncReason: nil, devicesListed: phone.sync.devicesListed)
        XCTAssertEqual(presenceBefore, .noMac)
        XCTAssertEqual(presenceBefore.waitingLine(), "No Mac has synced this library yet")

        let filed = try await record(into: phone)
        XCTAssertEqual(filed.request?.mode, .newAudio)
        try await waitUntil("the change is counted") { phone.sync.localChanges > 0 }
        XCTAssertEqual(phone.sync.statusLine, "1 change waiting to sync")
        await phone.sync.synchronize(.filed)
        XCTAssertEqual(phone.sync.statusLine, "Up to date")
        XCTAssertEqual(phone.sync.localChanges, 0)
        let blobs = try FileManager.default.contentsOfDirectory(atPath: container.appendingPathComponent("Blobs").path)
        XCTAssertEqual(blobs, [filed.meeting.tracks[0].sha256], "the recording's audio is in the container after one pass")
        let me = try XCTUnwrap(phone.sync.devices.first(where: \.isCurrentDevice))
        XCTAssertEqual(me.deviceClass, .phone)
        XCTAssertEqual(me.audioPolicy, .onDemand)

        // A Mac syncs: it gets the conversation with its audio and the request, and announces itself.
        let mac = try await makeMac(container)
        let applied = await mac.synchronize()
        XCTAssertEqual(applied?.acknowledged, true)
        let onMac = try XCTUnwrap(mac.meeting(filed.meeting.id))
        XCTAssertEqual(onMac.openProcessingRequests.map(\.mode), [.newAudio])
        let macAudio = try await mac.audioURL(for: onMac.tracks[0], in: onMac.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: macAudio.path))

        // The Mac renames it; the phone's next pass applies it, and views reading the library follow.
        mac.rename(onMac.id, to: "Design review, agreed")
        await mac.flush()
        await assertPass(mac)
        let revision = phone.library.revision
        await phone.sync.synchronize(.remote)
        XCTAssertEqual(phone.library.conversations.first?.title, "Design review, agreed")
        try await waitUntil("observers are told") { phone.library.revision != revision }
        XCTAssertTrue(phone.sync.lastReceived.contains(onMac.id))

        let presence = MacPresence.resolve(connectedMac: nil, devices: phone.sync.devices, syncAvailable: true,
                                           syncReason: nil, devicesListed: phone.sync.devicesListed)
        guard case .seen(let name, let seen) = presence else { return XCTFail("expected the Mac's presence, got \(presence)") }
        XCTAssertEqual(name, "Studio Mac")
        XCTAssertEqual(presence.waitingLine(now: seen.addingTimeInterval(60)), "Waiting for Studio Mac")
        let later = seen.addingTimeInterval(2 * 3_600 + 5)
        XCTAssertEqual(presence.waitingLine(now: later), "Waiting for your Mac · \(RecorderStatusWords.lastSeen(seen, now: later))",
                       "dated as every row dates a device's absence")

        // Nothing changed on either side: the timer's check lists the journal and runs no pass.
        let passes = phone.sync.passes
        await phone.sync.synchronize(.timer)
        XCTAssertEqual(phone.sync.passes, passes)
        // A change on the Mac is noticed by the same check.
        mac.setTags(onMac.id, text: "design")
        await mac.flush()
        await assertPass(mac)
        await phone.sync.synchronize(.timer)
        XCTAssertEqual(phone.sync.passes, passes + 1)
        XCTAssertEqual(phone.library.controller.meeting(onMac.id)?.tags, ["design"])
    }

    func testAnEncryptedLibraryWaitsForItsKeyAndSaysSo() async throws {
        let container = try temporaryDirectory("container")
        let macKeys = MemoryLibraryKeyStore()
        let mac = try await makeMac(container, keyStore: macKeys)
        await assertPass(mac)
        try await XCTUnwrap(mac.sync).enableEncryption()
        _ = mac.newMeeting(title: "Encrypted on the Mac")
        await mac.flush()
        await assertPass(mac)

        // iCloud Keychain hasn't brought the key here yet.
        let phoneKeys = MemoryLibraryKeyStore()
        let phone = try await makePhone(container, keyStore: phoneKeys)
        await phone.sync.synchronize(.launch)
        XCTAssertEqual(phone.sync.encryption, .waitingForKey)
        XCTAssertEqual(phone.sync.statusLine, "Waiting for this library’s key", "As the Mac's iCloud row says it")
        XCTAssertFalse(phone.sync.isUpToDate)
        XCTAssertTrue(phone.library.conversations.isEmpty)

        // It arrives: the next pass reads the library.
        for key in macKeys.allKeys { try phoneKeys.store(key) }
        await phone.sync.synchronize(.manual)
        XCTAssertTrue(phone.sync.encryption.isOn)
        XCTAssertEqual(phone.sync.statusLine, "Up to date")
        XCTAssertEqual(phone.library.conversations.map(\.title), ["Encrypted on the Mac"])
    }

    func testStatusSaysWhySyncCantRun() async throws {
        let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "INSTALL-1")
        let sync = PhoneSync(library: library.controller)
        XCTAssertFalse(sync.isConnected)
        XCTAssertEqual(sync.statusLine, "Not available in this build", "as the Mac's iCloud row says it")
        XCTAssertEqual(sync.iCloud, .unavailableInThisBuild)
        await sync.synchronize(.manual)
        XCTAssertEqual(sync.passes, 0)
        let presence = MacPresence.resolve(connectedMac: nil, devices: [], syncAvailable: false,
                                           syncReason: CloudAvailability.signedOutMessage,
                                           devicesListed: false)
        XCTAssertEqual(presence.summary(), "Sign in to iCloud to sync your library.")
        XCTAssertEqual(MacPresence.resolve(connectedMac: "Studio Mac", devices: [], syncAvailable: false, syncReason: "x", devicesListed: false),
                       .connected(name: "Studio Mac"), "a Mac on the link is present whatever iCloud says")
    }

    func testAMacThatChecksInWithoutProcessingIsNamedNotCalledEarlier() {
        let now = Date()
        let mac = KnownSyncDevice(id: "mac", deviceClass: .mac, displayName: "Studio Mac", canProcess: false, lastSeen: now)
        let phone = KnownSyncDevice(id: "phone", deviceClass: .phone, displayName: "iPhone", lastSeen: now, isCurrentDevice: true)
        // A device known only from the journal: an old identity, or one that hasn't checked in yet.
        let journalOnly = KnownSyncDevice(id: "old")
        let presence = MacPresence.resolve(connectedMac: nil, devices: [mac, phone, journalOnly], syncAvailable: true,
                                           syncReason: nil, devicesListed: true)
        XCTAssertEqual(presence, .notProcessing(name: "Studio Mac", lastSeen: now))
        XCTAssertEqual(presence.macName, "Studio Mac")
        XCTAssertFalse(presence.isMacAround, "It won't transcribe, so nothing waits on it")
        XCTAssertEqual(presence.summary(now: now), "Studio Mac isn’t set up to transcribe. Finish in Daybook › Settings on Studio Mac.")
        // Without any Mac presence, a journal-only device is still read as an earlier Daybook.
        XCTAssertEqual(MacPresence.resolve(connectedMac: nil, devices: [phone, journalOnly], syncAvailable: true,
                                           syncReason: nil, devicesListed: true), .olderMac)
        // A Mac that processes wins over one that doesn't.
        let processor = KnownSyncDevice(id: "studio", deviceClass: .mac, displayName: "Mini", canProcess: true, lastSeen: now.addingTimeInterval(-60))
        XCTAssertEqual(MacPresence.resolve(connectedMac: nil, devices: [mac, processor, phone], syncAvailable: true,
                                           syncReason: nil, devicesListed: true), .seen(name: "Mini", lastSeen: now.addingTimeInterval(-60)))
    }

    func testAMacWhosePresenceSaysItsRecordingIsNamedAsRecording() {
        let now = Date()
        let activity = SyncDeviceActivity(recordingConversationID: UUID(), since: now.addingTimeInterval(-300), expiresAt: now.addingTimeInterval(60))
        let studio = KnownSyncDevice(id: "studio", deviceClass: .mac, displayName: "Studio Mac", canProcess: true, lastSeen: now, activity: activity)
        let presence = MacPresence.resolve(connectedMac: nil, devices: [studio], syncAvailable: true, syncReason: nil, devicesListed: true, now: now)
        XCTAssertEqual(presence, .recording(name: "Studio Mac", lastSeen: now))
        XCTAssertEqual(presence.summary(now: now), "Studio Mac is recording.")
        XCTAssertEqual(presence.waitingLine(now: now), "Waiting for Studio Mac, which is recording")
        XCTAssertTrue(presence.isMacAround)
        // Once the activity expires it's an ordinary sighting again; the link, when it's there, wins.
        XCTAssertEqual(MacPresence.resolve(connectedMac: nil, devices: [studio], syncAvailable: true, syncReason: nil, devicesListed: true,
                                           now: now.addingTimeInterval(120)), .seen(name: "Studio Mac", lastSeen: now))
        XCTAssertEqual(MacPresence.resolve(connectedMac: "Studio Mac", devices: [studio], syncAvailable: true, syncReason: nil, devicesListed: true,
                                           now: now), .connected(name: "Studio Mac"))
    }

    func testBoundedPassesContinueUntilTheJournalIsRead() async throws {
        let container = try temporaryDirectory("container")
        let mac = try await makeMac(container)
        for index in 0..<5 { mac.newMeeting(title: "Meeting \(index)") }
        await mac.flush()
        await assertPass(mac)
        let phone = try await makePhone(container)
        phone.sync.isForeground = false   // no automatic continuation; drive it here
        // A pass that may read only two journal entries at a time leaves work for the next.
        let applied = await phone.library.controller.synchronize(limits: SyncPassLimits(maxJournalReads: 2))
        XCTAssertEqual(applied?.hasMoreWork, true)
        XCTAssertLessThan(phone.library.conversations.count, 5)
        for _ in 0..<5 where phone.library.conversations.count < 5 { await phone.sync.synchronize(.manual) }
        XCTAssertEqual(phone.library.conversations.count, 5)
        XCTAssertFalse(phone.sync.hasMoreWork)
    }

    func testAnEditDuringAPassIsSyncedRightAfterAndAPullJoinsThePass() async throws {
        let container = try temporaryDirectory("container")
        let gate = PassGate()
        let phone = try await makePhone(container, cloud: SyncCloudFiles(requestDownload: { _ in gate.hold() }, isUploaded: { _ in true }))
        await phone.sync.synchronize(.launch)
        let id = phone.library.controller.newMeeting(title: "Before")
        await phone.library.controller.flush()
        await phone.sync.synchronize(.edit)
        let passes = phone.sync.passes
        // An entry still in iCloud makes the next pass wait on its download, which the test holds.
        try Data().write(to: container.appendingPathComponent("Events/.\(String(repeating: "c", count: 64)).json.icloud"))
        let running = Task { await phone.sync.synchronize(.edit) }
        try await waitUntil("the pass to reach iCloud") { gate.entered }
        phone.library.controller.rename(id, to: "Renamed during the pass")
        // Pull to refresh meanwhile joins the pass rather than finding it busy.
        let refresh = Task { await phone.sync.synchronize(.manual) }
        gate.release()
        await running.value
        await refresh.value
        XCTAssertGreaterThanOrEqual(phone.sync.passes, passes + 2, "the pass, then one more for the edit made during it")
        XCTAssertEqual(phone.sync.localChanges, 0)
        let events = try FileManager.default.contentsOfDirectory(at: container.appendingPathComponent("Events"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let titles = try events.compactMap { url -> String? in
            ((try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["snapshot"] as? [String: Any])?["title"] as? String
        }
        XCTAssertTrue(titles.contains("Renamed during the pass"), "the edit made during the pass was published")
    }

    // MARK: Audio provider

    func testACancelledBackgroundPassDoesNotStartOrPublish() async throws {
        let container = try temporaryDirectory("container")
        let phone = try await makePhone(container, name: "Cancelled background sync")
        phone.library.controller.newMeeting(title: "Still local")
        try await phone.library.controller.flushDurably()
        let pass = Task { await phone.sync.synchronize(.backgroundRefresh) }
        pass.cancel()
        await pass.value
        XCTAssertEqual(phone.sync.passes, 0)
        XCTAssertFalse(phone.sync.isSyncing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.appendingPathComponent("Events").path))
        await phone.sync.synchronize(.manual)
        XCTAssertEqual(phone.sync.passes, 1)
    }

    func testAudioDownloadsOnDemandWithProgressAndCanBeCancelled() async throws {
        let container = try temporaryDirectory("container")
        let recorder = try await makePhone(container, name: "Recording iPhone")
        let filed = try await record(into: recorder)
        await recorder.sync.synchronize(.filed)
        let track = filed.meeting.tracks[0]
        do { let availability = await recorder.audio.availability(of: track, in: filed.meeting.id); XCTAssertEqual(availability, .local, "recorded here") }

        // Another iPhone has the conversation at once, but not its audio.
        let reader = try await makePhone(container, name: "Reading iPhone")
        await reader.sync.synchronize(.launch)
        XCTAssertNotNil(reader.library.controller.meeting(filed.meeting.id))
        do { let availability = await reader.audio.availability(of: track, in: filed.meeting.id); XCTAssertEqual(availability, .downloadable(bytes: nil)) }

        // Cancelled while the recording isn't in the container: nothing is installed.
        let blob = container.appendingPathComponent("Blobs/\(track.sha256)")
        let aside = container.appendingPathComponent("aside")
        try FileManager.default.moveItem(at: blob, to: aside)
        var phases: [AudioFetchProgress.Phase] = []
        let waiting = Task { try await reader.audio.localAudio(for: track, in: filed.meeting.id) { phases.append($0.phase) } }
        try await waitUntil("waiting for the upload") { phases.contains(.waitingForUpload) }
        XCTAssertNotNil(reader.audio.downloads[track.id])
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("a cancelled download returns nothing")
        } catch is CancellationError {}
        do { let availability = await reader.audio.availability(of: track, in: filed.meeting.id); XCTAssertEqual(availability, .downloadable(bytes: nil)) }
        XCTAssertNil(reader.audio.downloads[track.id])

        // Back in the container: it downloads with progress, verified, and plays from the library.
        try FileManager.default.moveItem(at: aside, to: blob)
        var fractions: [Double] = []
        let url = try await reader.audio.localAudio(for: track, in: filed.meeting.id) { fractions.append($0) }
        XCTAssertEqual(fractions.last, 1)
        XCTAssertEqual(fractions, fractions.sorted(), "progress only moves forward")
        XCTAssertEqual(try AudioDigest.sha256(fileURL: url), track.sha256)
        do { let availability = await reader.audio.availability(of: track, in: filed.meeting.id); XCTAssertEqual(availability, .local) }
        let size = UInt64((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        try await waitUntil("the download is counted", state: { "\(reader.audio.usage)" }) { reader.audio.usage.downloadedBytes == size }
    }

    func testDownloadedAudioStaysWithinTheBudgetAndCanBeCleared() async throws {
        let container = try temporaryDirectory("container")
        let recorder = try await makePhone(container, name: "Recording iPhone")
        let first = try await record(into: recorder, title: "First", seconds: 3)
        let second = try await record(into: recorder, title: "Second", seconds: 3)
        await recorder.sync.synchronize(.filed)

        // Room for about one recording.
        let size = UInt64((try FileManager.default.attributesOfItem(atPath: container.appendingPathComponent("Blobs/\(first.meeting.tracks[0].sha256)").path)[.size] as? NSNumber)?.int64Value ?? 0)
        let reader = try await makePhone(container, name: "Reading iPhone", budget: size + size / 2)
        reader.audio.keepWindow = 0
        reader.audio.playingWindow = 0
        await reader.sync.synchronize(.launch)
        _ = try await reader.audio.localAudio(for: first.meeting.tracks[0], in: first.meeting.id) { _ in }
        _ = try await reader.audio.localAudio(for: second.meeting.tracks[0], in: second.meeting.id) { _ in }
        // The least recently played went back to iCloud to make room for the one just played.
        do { let availability = await reader.audio.availability(of: first.meeting.tracks[0], in: first.meeting.id); XCTAssertEqual(availability, .downloadable(bytes: nil)) }
        do { let availability = await reader.audio.availability(of: second.meeting.tracks[0], in: second.meeting.id); XCTAssertEqual(availability, .local) }
        try await waitUntil("what's here is counted within the budget", state: { "\(reader.audio.usage)" }) {
            reader.audio.usage.bytes > 0 && reader.audio.usage.bytes <= size + size / 2
        }

        // Clear Downloaded Audio removes downloads only; the recording phone keeps what it recorded.
        let freed = await reader.audio.clearDownloaded()
        XCTAssertGreaterThan(freed, 0)
        do { let availability = await reader.audio.availability(of: second.meeting.tracks[0], in: second.meeting.id); XCTAssertEqual(availability, .downloadable(bytes: nil)) }
        XCTAssertEqual(reader.audio.usage.bytes, 0)
        _ = await recorder.audio.clearDownloaded()
        do { let availability = await recorder.audio.availability(of: first.meeting.tracks[0], in: first.meeting.id); XCTAssertEqual(availability, .local) }
    }

    func testBehaviorPlayingDoesNotWaitForStorageToBeMeasuredAndAnOlderMeasureNeverReplacesANewer() async throws {
        let container = try temporaryDirectory("container")
        let recorder = try await makePhone(container, name: "Recording iPhone")
        let filed = try await record(into: recorder)
        await recorder.sync.synchronize(.filed)
        let reader = try await makePhone(container, name: "Reading iPhone")
        reader.audio.keepWindow = 0
        reader.audio.playingWindow = 0
        // The first walk of the library is held once it has measured: the one for the conversation that arrives.
        let arrival = PassGate()
        reader.audio.measure = { root, downloaded in
            let report = LibraryStorageReport.measure(libraryRoot: root, downloaded: downloaded)
            arrival.hold()
            return report
        }
        await reader.sync.synchronize(.launch)
        try await waitUntil("the arrival is being measured") { arrival.entered }

        // Playing downloads and returns while the library is still being measured; the download is counted shortly after.
        let track = filed.meeting.tracks[0]
        let url = try await reader.audio.localAudio(for: track, in: filed.meeting.id) { _ in }
        XCTAssertEqual(reader.audio.usage.downloadedBytes, 0, "playing didn't wait for a measure")
        let size = UInt64((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        XCTAssertGreaterThan(size, 0)
        try await waitUntil("the download is counted", state: { "\(reader.audio.usage)" }) { reader.audio.usage.downloadedBytes == size }
        arrival.release()

        // A measure started before Clear Downloaded Audio and finished after it doesn't bring the downloads back.
        let stale = PassGate()
        reader.audio.measure = { root, downloaded in
            let report = LibraryStorageReport.measure(libraryRoot: root, downloaded: downloaded)
            stale.hold()
            return report
        }
        let earlier = Task { await reader.audio.refreshUsage() }
        try await waitUntil("the earlier measure has counted the download") { stale.entered }
        let freed = await reader.audio.clearDownloaded()
        XCTAssertEqual(freed, size)
        XCTAssertEqual(reader.audio.usage.downloadedBytes, 0)
        stale.release()
        await earlier.value
        XCTAssertEqual(reader.audio.usage.downloadedBytes, 0, "the earlier measure counted downloads that are gone")
        XCTAssertEqual(reader.audio.usage.bytes, 0)
        XCTAssertEqual(reader.audio.report?.downloadedAudio, 0)

        // Setting the budget brings the audio within it, and doesn't wait for a measure either.
        let budget = PassGate()
        reader.audio.measure = { root, downloaded in
            budget.hold()
            return LibraryStorageReport.measure(libraryRoot: root, downloaded: downloaded)
        }
        await reader.audio.setBudget(1_000_000_000)
        XCTAssertFalse(budget.entered, "setting the budget didn't wait for a measure")
        budget.release()
        try await waitUntil("what's here is measured again") { budget.entered }
    }

    func testAFiledRecordingGoesToTheCourierAndAStuckSendIsShown() async throws {
        let container = try temporaryDirectory("container")
        let service = InMemoryCourierService()
        service.failure = .network
        // The courier's clock runs 20 minutes behind, so what it takes has been waiting that long.
        let phone = try await makePhone(container) { directory in
            InMemoryCourier(service: service, directory: directory, deviceID: "Test iPhone", clock: { Date().addingTimeInterval(-20 * 60) })
        }
        try await waitUntil("the courier to start") { phone.sync.courier.availability == .available }
        await phone.sync.synchronize(.launch)
        let filed = try await record(into: phone)
        await phone.sync.synchronize(.filed)
        await phone.sync.controller?.finishCourierSends()
        try await waitUntil("the files to wait") { phone.sync.courier.waitingToSend > 0 }
        let waiting = phone.sync.courier.waitingToSend
        XCTAssertEqual(phone.sync.statusLine, "Waiting to send \(waiting) items to your Mac")
        XCTAssertFalse(phone.sync.isUpToDate)

        // The network returns: the recording's audio goes, and the line says what's true again.
        service.failure = nil
        let courier = try XCTUnwrap(phone.sync.controller?.courier)
        await courier.flush()
        try await waitUntil("the send") { phone.sync.courier.waitingToSend == 0 }
        XCTAssertEqual(phone.sync.statusLine, "Up to date")
        XCTAssertTrue(service.fileIDs.contains { $0.hasSuffix(".Blobs.\(filed.meeting.tracks[0].sha256)") })
    }

    // MARK: Settings › iCloud

    func testBehaviorAChangedICloudAccountPausesUntilThePersonSyncsWithThisAccount() async throws {
        let container = try temporaryDirectory("account-container")
        let defaults = makeTestDefaults("SyncServicesTests")
        let account = TestICloudAccount(identity: Data("account-a".utf8))
        let available = { CloudAvailability.available(container.appendingPathComponent("Documents/Daybook", isDirectory: true)) }

        // This iPhone syncs the library with account A.
        let first = try await makeAccountPhone(container: container, defaults: defaults, account: account)
        await first.connect(availability: available)
        XCTAssertTrue(first.isConnected)
        XCTAssertEqual(first.iCloud, .connected)

        // Next launch, another account is signed in: sync waits for the person, and says so as the Mac does.
        account.identity = Data("account-b".utf8)
        let sync = try await makeAccountPhone(container: container, defaults: defaults, account: account)
        await sync.connect(availability: available)
        XCTAssertFalse(sync.isConnected)
        XCTAssertEqual(sync.iCloud, .accountChanged)
        XCTAssertEqual(sync.connection, .unavailable("This library synced with a different iCloud account."))
        XCTAssertEqual(sync.statusLine, "Sync paused")
        XCTAssertNotEqual(sync.statusLine, "iCloud isn’t available for Daybook right now. Try again in a moment.")
        let shown = sync.shown()
        XCTAssertTrue(shown.needsAttention)
        XCTAssertEqual(shown.symbol, "exclamationmark.icloud")
        XCTAssertEqual(SyncProblem.accountChanged.text, "This library synced with a different iCloud account.")
        // Trying again finds the same account: still paused, never stuck on "try again later".
        await sync.connect(availability: available)
        XCTAssertEqual(sync.iCloud, .accountChanged)

        // Sync with This Account: the library syncs with the account signed in now.
        await sync.useCurrentAccount(availability: available)
        XCTAssertTrue(sync.isConnected)
        XCTAssertEqual(sync.iCloud, .connected)
        XCTAssertNil(sync.shown().problem)
        XCTAssertFalse(sync.needsAttention)
        XCTAssertNotEqual(sync.statusLine, "Sync paused")
    }

    func testBehaviorAudioOnThisIPhoneIsCountedWithoutSyncAndFollowsNewRecordings() async throws {
        let root = try temporaryDirectory("phone-unsynced")
        let defaults = makeTestDefaults("SyncServicesTests")
        let controller = LibrarySyncController(localRoot: root, defaults: defaults)
        controller.syncDebounce = nil
        let library = PhoneLibrary(rootURL: root, sync: controller, installation: UUID().uuidString)
        try await library.reload()
        let sync = PhoneSync(library: library.controller)
        XCTAssertFalse(sync.isConnected, "iCloud isn't on")
        let audio = SyncAudioProvider(library: library, sync: sync, budget: 1_000_000_000)
        // Launch sets the budget, which measures what's here without launch waiting for it.
        let launch = PassGate()
        audio.measure = { root, downloaded in
            launch.hold()
            return LibraryStorageReport.measure(libraryRoot: root, downloaded: downloaded)
        }
        await audio.setBudget(1_000_000_000)
        XCTAssertFalse(launch.entered, "launch didn't wait for the library to be measured")
        launch.release()
        try await waitUntil("what's here is measured") { audio.report != nil }
        XCTAssertEqual(audio.usage.bytes, 0)
        XCTAssertEqual(StatusSheetModel.audioOnThisIPhone(bytes: audio.usage.bytes), "No audio on this iPhone")

        // A recording made here: it's counted, without anyone asking, and said as audio on this iPhone.
        let phone = PhoneRig(library: library, sync: sync, audio: audio)
        let filed = try await record(into: phone, seconds: 3)
        let url = try await library.audioURL(for: filed.meeting.tracks[0], in: filed.meeting.id)
        let size = UInt64((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        XCTAssertGreaterThan(size, 0)
        try await waitUntil("the new recording is counted") { audio.usage.bytes >= size }
        XCTAssertEqual(audio.usage.downloadedBytes, 0, "nothing downloads without sync")
        XCTAssertNotEqual(StatusSheetModel.audioOnThisIPhone(bytes: audio.usage.bytes), "No audio on this iPhone")
        let report = try XCTUnwrap(audio.report)
        XCTAssertEqual(UInt64(report.audio), audio.usage.bytes)
        XCTAssertNil(report.downloadedAudio, "downloads aren't told apart without sync")
        XCTAssertGreaterThan(report.conversations, 0, "its transcript and notes are the rest")
        XCTAssertEqual(StorageScreen.breakdown(bytes: audio.usage.bytes, downloaded: 0), "Recorded on this iPhone")
    }

    func testBehaviorIcloudBeingFullIsSaidBeforeWhatWaitsToUpload() async throws {
        let container = try temporaryDirectory("container")
        let service = InMemoryCourierService()
        service.failure = .storageFull
        let phone = try await makePhone(container) { directory in
            InMemoryCourier(service: service, directory: directory, deviceID: "Test iPhone", clock: { Date().addingTimeInterval(-20 * 60) })
        }
        try await waitUntil("the courier to start") { phone.sync.courier.availability == .available }
        await phone.sync.synchronize(.launch)
        _ = try await record(into: phone)
        await phone.sync.synchronize(.filed)
        await phone.sync.controller?.finishCourierSends()
        try await waitUntil("iCloud to refuse it") { phone.sync.courier.storageFull }
        XCTAssertTrue(phone.sync.isStorageFull)
        XCTAssertEqual(phone.sync.statusLine, "iCloud storage is full", "as the Mac says it")
        XCTAssertEqual(phone.sync.shown().problem, .storageFull)
        XCTAssertEqual(ICloudSyncShown.problemText(.storageFull, managesStorage: false),
                       "iCloud storage is full. Free up space in Settings › Apple Account › iCloud.",
                       "nothing on the iPhone opens iCloud's storage, so its problem line says where")
        XCTAssertTrue(phone.sync.needsAttention)
        XCTAssertFalse(phone.sync.isUpToDate)
    }

    func testBehaviorTheRecoveryKeyCopiesForThisIPhoneOnlyAndExpires() {
        let key = RecoveryKey.generate()
        var copied: [(String, Duration?)] = []
        let services = ScreenServices(presentDetails: { _, _ in }, copyLocally: { text, expiresIn in copied.append((text, expiresIn)) })
        RecoveryKeyView.copy(key, services: services)
        XCTAssertEqual(copied.map(\.0), [key.text], "through the app's local copy, never `UIPasteboard.general.string`")
        XCTAssertEqual(copied.first?.1, .seconds(120))
        let now = Date()
        let options = LocalCopy.options(expiresIn: RecoveryKeyView.copyLifetime, now: now)
        XCTAssertEqual(options[.localOnly] as? Bool, true, "never Universal Clipboard")
        XCTAssertEqual(options[.expirationDate] as? Date, now.addingTimeInterval(120), "gone after two minutes")
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        LocalCopy.copy(key.text, expiresIn: RecoveryKeyView.copyLifetime, to: pasteboard)
        XCTAssertEqual(pasteboard.string, key.text)
    }

    /// A phone library on a fake iCloud container and `account`, as the app wires it, sharing `defaults` (where the
    /// account a library synced with is kept) across launches.
    private func makeAccountPhone(container: URL, defaults: UserDefaults, account: TestICloudAccount) async throws -> PhoneSync {
        let root = try temporaryDirectory("phone-account")
        let environment = SyncContainerEnvironment(containerIdentifier: "iCloud.test.daybook", hasEntitlement: { _ in true },
                                                   accountIdentity: { account.identity }, accountSignedIn: { true },
                                                   resolveContainer: { _ in container }, retryInterval: .milliseconds(20))
        let controller = LibrarySyncController(localRoot: root, defaults: defaults, environment: environment)
        controller.replica = PhoneSync.replica(displayName: "Test iPhone", budget: 1_000_000_000)
        controller.syncDebounce = nil
        let library = PhoneLibrary(rootURL: root, sync: controller, installation: UUID().uuidString)
        try await library.reload()
        accountPhones.append(library)
        return PhoneSync(library: library.controller)
    }

    /// Libraries the account tests made, kept for the test's length.
    private var accountPhones: [PhoneLibrary] = []
}

/// The iCloud account a fake container reports.
private final class TestICloudAccount: @unchecked Sendable {
    private let lock = NSLock()
    private var _identity: Data?
    init(identity: Data?) { _identity = identity }
    var identity: Data? {
        get { lock.withLock { _identity } }
        set { lock.withLock { _identity = newValue } }
    }
}

/// An iPhone library connected to a folder standing in for the container, as the app wires it.
@MainActor
struct PhoneRig {
    let library: PhoneLibrary
    let sync: PhoneSync
    let audio: SyncAudioProvider
}

@MainActor
extension XCTestCase {
    /// `courier` makes it send what its passes write, as the app does with CloudKit (tests use `InMemoryCourier`).
    /// `identityStore` stands in for the keychain item two apps on one iPhone share.
    func makePhone(_ container: URL, name: String = "Test iPhone", budget: UInt64 = 1_000_000_000, cloud: SyncCloudFiles = .system,
                   courier: ((URL) -> any SyncCourier)? = nil, keyStore: (any LibraryKeyStore)? = nil,
                   defaults: UserDefaults? = nil, identityStore: SyncDeviceIdentityStore? = nil) async throws -> PhoneRig {
        let root = try temporaryDirectory("phone-\(name)")
        let defaults = defaults ?? makeTestDefaults("SyncServicesTests")
        let controller = LibrarySyncController(localRoot: root, defaults: defaults, identityStore: identityStore)
        controller.replica = PhoneSync.replica(displayName: name, budget: budget, cloud: cloud)
        controller.replica.keyStore = keyStore
        // Tests run every pass themselves; an edit's automatic pass would race them.
        controller.syncDebounce = nil
        if let courier {
            controller.courier = courier(root.appendingPathComponent("Sync/Courier", isDirectory: true))
            controller.courierRole = .send
        }
        let library = PhoneLibrary(rootURL: root, sync: controller, installation: UUID().uuidString)
        try await library.reload()
        let sync = PhoneSync(library: library.controller)
        try sync.connect(toFolder: container, monitor: false)
        let audio = SyncAudioProvider(library: library, sync: sync, budget: budget,
                                      options: AudioFetchOptions(pollInterval: .milliseconds(20), timeout: .seconds(10)))
        return PhoneRig(library: library, sync: sync, audio: audio)
    }

    /// One pass on a test Mac's library, which must apply and acknowledge.
    func assertPass(_ library: LibraryController, file: StaticString = #filePath, line: UInt = #line) async {
        let applied = await library.synchronize()
        XCTAssertEqual(applied?.acknowledged, true, library.sync?.statusText ?? "", file: file, line: line)
    }

    /// A Mac with models: an eager replica that writes presence.
    func makeMac(_ container: URL, name: String = "Studio Mac", keyStore: (any LibraryKeyStore)? = nil) async throws -> LibraryController {
        let root = try temporaryDirectory("mac-\(name)")
        let defaults = makeTestDefaults("SyncServicesTests")
        let controller = LibrarySyncController(localRoot: root, defaults: defaults)
        controller.replica = .mac(displayName: name, canProcess: true)
        controller.replica.keyStore = keyStore
        controller.syncDebounce = nil
        let library = LibraryController(rootURL: root, sync: controller)
        try await library.load()
        try controller.connect(to: container, monitorChanges: false)
        return library
    }

    /// Records `seconds` of tone and files it, as Stop does.
    func record(into phone: PhoneRig, title: String = "Design review", seconds: TimeInterval = 4) async throws -> PhoneLibrary.Filed {
        let rig = RecorderRig()
        let id = UUID()
        try await rig.recorder.start(in: phone.library.stagingURL.appendingPathComponent(id.uuidString), id: id, title: title)
        rig.pump(1)
        rig.recorder.editNotes("Decisions")
        rig.pump(seconds - 1)
        rig.recorder.addBookmark()
        return try await phone.library.fileRecording(try await rig.stop())
    }
}

/// Holds the first cloud-provider call until released; later ones pass straight through.
private final class PassGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var held = false, _entered = false
    var entered: Bool { lock.withLock { _entered } }
    func hold() {
        let first = lock.withLock { () -> Bool in defer { held = true; _entered = true }; return !held }
        if first { _ = semaphore.wait(timeout: .now() + 10) }
    }
    func release() { semaphore.signal() }
}
