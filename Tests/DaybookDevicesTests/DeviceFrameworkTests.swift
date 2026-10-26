import DaybookCore
import Foundation
import XCTest
@testable import DaybookDevices

/// The hardware-agnostic pieces: the queue, retries, estimates, words, problems, and what the
/// library already holds. No hardware, no Bluetooth, no downloads.
final class DeviceFrameworkTests: XCTestCase {
    private func recording(_ offset: Int, seconds: Double = 600, exact: Bool = true) -> DeviceRecording {
        let start = Date(timeIntervalSince1970: 1_780_000_000 + Double(offset))
        return DeviceRecording(id: String(1_780_000_000 + offset), startedAt: start,
                               length: exact ? .exact(seconds) : .estimated(seconds), byteCount: UInt64(seconds * 8_000))
    }

    // MARK: Queue

    func testQueueRunsOneAtATimeOldestFirstWithoutDuplicates() {
        var queue = DeviceImportQueue()
        let added = queue.enqueue([recording(300), recording(100), recording(200), recording(100)], method: .direct)
        XCTAssertEqual(added, ["1780000100", "1780000200", "1780000300"])
        XCTAssertNil(queue.current)
        XCTAssertEqual(queue.startNext()?.id, "1780000100")
        XCTAssertNil(queue.startNext(), "Only one transfer at a time")
        XCTAssertEqual(queue.enqueue([recording(200)], method: .direct), [], "Already waiting")
        XCTAssertEqual(queue.position, 1)
        XCTAssertEqual(queue.total, 3)
        queue.finishCurrent()
        XCTAssertEqual(queue.startNext()?.id, "1780000200")
        XCTAssertEqual(queue.position, 2)
        XCTAssertEqual(queue.fraction(current: 0.5), 1.5 / 3, accuracy: 0.0001)
    }

    func testRecordingsInProgressAreNeverQueued() {
        var queue = DeviceImportQueue()
        var live = recording(1)
        live.isInProgress = true
        XCTAssertEqual(queue.enqueue([live, recording(2)], method: .direct), ["1780000002"])
    }

    func testDisconnectRequeuesAtFrontAndSuspendsUntilReconnect() {
        var queue = DeviceImportQueue()
        queue.enqueue([recording(1), recording(2)], method: .direct)
        _ = queue.startNext()
        queue.failCurrent(requeue: true)
        XCTAssertTrue(queue.isSuspended)
        XCTAssertEqual(queue.waiting.map(\.id), ["1780000001", "1780000002"])
        XCTAssertNil(queue.startNext(), "Waits for the recorder to reconnect")
        queue.resume()
        XCTAssertEqual(queue.startNext()?.id, "1780000001", "The interrupted recording starts over first")
        XCTAssertEqual(queue.failed, 0)
    }

    func testRetryStopAndRemoveByMethod() {
        var queue = DeviceImportQueue()
        queue.enqueue([recording(1), recording(2)], method: .direct)
        queue.enqueue([recording(3)], method: .files)
        _ = queue.startNext()
        queue.retryCurrent()
        XCTAssertEqual(queue.waiting.first?.attempts, 1, "A retry goes back to the front, counted")
        _ = queue.startNext()
        queue.failCurrent(requeue: false)
        XCTAssertEqual(queue.failed, 1)
        queue.remove(method: .files)
        XCTAssertEqual(queue.waiting.map(\.id), ["1780000002"])
        XCTAssertEqual(queue.startNext()?.id, "1780000002")
        XCTAssertEqual(queue.stopCurrent()?.id, "1780000002")
        XCTAssertFalse(queue.isActive)
        queue.enqueue([recording(4)], method: .direct)
        XCTAssertEqual(queue.failed, 0, "A new batch starts fresh")
        queue.stopAll()
        XCTAssertEqual(queue.total, 0)
    }

    func testAttachAndRemainingBytes() {
        var queue = DeviceImportQueue()
        let conversation = UUID()
        queue.enqueue([recording(1, seconds: 10), recording(2, seconds: 20)], method: .direct, attachTo: conversation)
        let current = queue.startNext()
        XCTAssertEqual(current?.attachTo, conversation)
        XCTAssertEqual(queue.remainingBytes(currentReceived: 30_000), 50_000 + 160_000)
    }

    func testRetryPolicyGivesStallsAndIntegrityOneQuietRetry() {
        let policy = DeviceRetryPolicy()
        XCTAssertTrue(policy.shouldRetry(.stalled, attempts: 0))
        XCTAssertTrue(policy.shouldRetry(.integrity("gap"), attempts: 0))
        XCTAssertFalse(policy.shouldRetry(.integrity("gap"), attempts: 1), "Then the person hears about it")
        XCTAssertFalse(policy.shouldRetry(.rejected("no"), attempts: 0))
        XCTAssertFalse(policy.shouldRetry(.disconnected, attempts: 0), "A disconnect waits for the reconnect instead")
    }

    func testTimeLeftNeedsTenSecondsOfSamples() {
        var rate = TransferRateEstimator()
        let start = Date()
        rate.record(bytes: 0, at: start)
        rate.record(bytes: 40_000, at: start.addingTimeInterval(5))
        XCTAssertNil(rate.secondsLeft(remainingBytes: 1_000_000))
        rate.record(bytes: 80_000, at: start.addingTimeInterval(10))
        XCTAssertEqual(rate.secondsLeft(remainingBytes: 80_000) ?? 0, 10, accuracy: 0.001)
        rate.transferFinished()
        rate.record(bytes: 8_000, at: start.addingTimeInterval(11))
        XCTAssertEqual(rate.bytesPerSecond ?? 0, 88_000 / 11, accuracy: 0.001, "The rate carries across a batch")
        XCTAssertEqual(TransferRateEstimator.label(secondsLeft: 372), "about 6 min left")
        XCTAssertEqual(TransferRateEstimator.label(secondsLeft: 20), "less than a minute left")
    }

    // MARK: Words

    func testPhasesDriveTheSameBar() {
        XCTAssertNil(TransferPhase.preparing.fraction, "Indeterminate while preparing")
        XCTAssertEqual(TransferPhase.preparing.label, "Preparing…")
        XCTAssertEqual(TransferPhase.receiving(fraction: 0.646).label, "64%")
        XCTAssertEqual(TransferPhase.receiving(fraction: 1.4).fraction, 1)
        XCTAssertNil(TransferPhase.receiving(fraction: nil).fraction)
        XCTAssertEqual(TransferPhase.finishing.fraction, 1)
    }

    func testLengthsAreExactWhenTheEndIsKnownOtherwiseAbout() {
        let base: UInt32 = 1_780_000_000
        XCTAssertEqual(SoundcoreRecording(id: base, size: 0, endTimestamp: base + 2_880).length, .exact(2_880))
        XCTAssertEqual(RecordingLength.exact(2_880).label, "48 min")
        let estimated = SoundcoreRecording(id: base, size: 1_320 * 8_000).length
        XCTAssertEqual(estimated, .estimated(1_320))
        XCTAssertEqual(estimated.label, "About 22 min")
        XCTAssertEqual(estimated.inlineLabel, "about 22 min")
        XCTAssertTrue(SoundcoreRecording(id: base, size: 80_000, endTimestamp: base - 5).length.isEstimate, "An end before the start")
        XCTAssertEqual(SoundcoreRecording(id: base, size: 80_000, endTimestamp: base + 900_000).length.seconds, 10, "Implausibly long")
        XCTAssertEqual(RecordingLength.estimated(0).label, "Length unknown")
        XCTAssertNil(SoundcoreRecording(id: 12, size: 0).date, "Not a plausible start time")
    }

    func testFileRecordingsDescribeThemselves() {
        let file = DeviceRecording(id: "file:notes.m4a|2048000", startedAt: nil, length: nil, byteCount: 2_048_000, fileName: "notes.m4a")
        XCTAssertEqual(file.title, "notes.m4a")
        XCTAssertTrue(file.detail.contains("MB"))
    }

    func testStorageIsHoursLeft() {
        func storage(_ free: UInt64, total: UInt64 = 8_000_000_000) -> DeviceStatus.Storage {
            .init(freeBytes: free, totalBytes: total, bytesPerHour: SoundcoreRecording.bytesPerHour)
        }
        XCTAssertEqual(storage(28_800_000).hoursLeft, 1, accuracy: 0.0001)
        XCTAssertEqual(StorageFormat.hoursLeft(storage(6_100_000_000)), "About 210 hours left")
        XCTAssertEqual(StorageFormat.hoursLeft(storage(172_800_000)), "About 6 hours left")
        XCTAssertEqual(StorageFormat.hoursLeft(storage(28_800_000)), "About 1 hour left")
        XCTAssertEqual(StorageFormat.hoursLeft(storage(1_000_000)), "Less than an hour left")
        XCTAssertEqual(StorageFormat.room(storage(172_800_000)), "Room for about 6 more hours")
        XCTAssertTrue(StorageFormat.isLow(storage(172_800_000)))
        XCTAssertFalse(StorageFormat.isLow(storage(6_100_000_000)))
        XCTAssertFalse(StorageFormat.isLow(storage(0, total: 0)), "Unknown storage isn't low")
        XCTAssertTrue(StorageFormat.detail(storage(6_100_000_000, total: 7_200_000_000)).hasSuffix("about 210 hours"))
    }

    func testBatterySignalAndSerial() {
        XCTAssertEqual(BatteryFormat.symbol(.init(level: 80)), "battery.75percent")
        XCTAssertEqual(BatteryFormat.symbol(.init(level: 100)), "battery.100percent")
        XCTAssertEqual(BatteryFormat.symbol(.init(level: 10)), "battery.0percent")
        XCTAssertEqual(BatteryFormat.symbol(.init(level: 60, charging: true)), "battery.100percent.bolt")
        XCTAssertTrue(BatteryFormat.isLow(.init(level: 20)))
        XCTAssertFalse(BatteryFormat.isLow(.init(level: 20, charging: true)), "Charging isn't a warning")
        XCTAssertFalse(BatteryFormat.isLow(nil))
        XCTAssertEqual(BatteryFormat.label(.init(level: 60, charging: true)), "60%, charging")
        XCTAssertEqual(BatteryFormat.value(nil), "—")
        XCTAssertEqual(BatteryFormat.accessibilityLabel("Recorder battery", .init(level: 80, charging: true)),
                       "Recorder battery, 80 percent, charging")
        XCTAssertEqual(SignalStrength(rssi: -40).word, "Nearby")
        XCTAssertEqual(SignalStrength(rssi: -66), .inRange)
        XCTAssertEqual(SignalStrength(rssi: -81).word, "Farther away")
        XCTAssertEqual(SignalStrength(rssi: 127), .inRange, "127 means CoreBluetooth has no reading")
        XCTAssertEqual(maskedSerial("D3200A21F07F3A"), "··7F3A")
        XCTAssertEqual(maskedSerial("7F3A"), "7F3A")
    }

    func testDateTitles() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        XCTAssertTrue(DeviceDateFormat.title(now.addingTimeInterval(-3_600), now: now, calendar: calendar, locale: locale).hasPrefix("Today, "))
        XCTAssertTrue(DeviceDateFormat.title(now.addingTimeInterval(-86_400), now: now, calendar: calendar, locale: locale).hasPrefix("Yesterday, "))
        let older = DeviceDateFormat.title(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar, locale: locale)
        XCTAssertFalse(older.hasPrefix("Today") || older.hasPrefix("Yesterday"))
        XCTAssertEqual(DeviceDateFormat.updated(now.addingTimeInterval(-30), now: now), "Updated just now")
        XCTAssertTrue(DeviceDateFormat.updated(now.addingTimeInterval(-600), now: now).hasPrefix("as of "))
    }

    /// Every problem says what happened and what is safe, with at most two actions and no jargon.
    func testProblemsKeepToTheBannerRules() {
        for issue in SoundcoreIssue.allCases {
            let problem = issue.problem
            XCTAssertLessThanOrEqual(problem.actions.count, 2)
            XCTAssertFalse(problem.title.isEmpty || problem.message.isEmpty)
            for word in ["dBm", "BLE", "GATT", "packet", "checksum", "Experimental"] {
                XCTAssertFalse((problem.title + problem.message).contains(word), "\(issue) mentions \(word)")
            }
        }
        XCTAssertEqual(SoundcoreIssue.disconnectedDuringImport.actions, [.reconnect, .dismiss])
        XCTAssertTrue(SoundcoreIssue.integrity.message.contains("still on your Soundcore"))
        XCTAssertEqual(SoundcoreIssue.from(SoundcoreError.disconnected, transferring: true), .disconnectedDuringImport)
        XCTAssertEqual(SoundcoreIssue.from(SoundcoreError.incompleteTransfer, transferring: true), .integrity)
        XCTAssertEqual(SoundcoreIssue.from(SoundcoreError.timedOut, transferring: false), .connectTimeout)
        XCTAssertEqual(DeviceTransferError(soundcore: SoundcoreError.disconnected), .disconnected)
        XCTAssertEqual(DeviceTransferError(soundcore: SoundcoreError.stalled), .stalled)
        if case .integrity = DeviceTransferError(soundcore: SoundcoreError.corruptAudio) {} else { XCTFail("Decode errors are integrity failures") }
    }

    // MARK: What the library holds

    func testLinksFollowKindSerialAndPartialCaptures() {
        func track(_ id: String, kind: String = "soundcore.work", serial: String? = "AAAA") -> RecordingTrack {
            RecordingTrack(source: .soundcore, relativePath: "Originals/\(id).wav", fileName: "\(id).wav",
                           device: DeviceRecordingIdentity(kind: kind, serial: serial, recordingID: id))
        }
        let full = Meeting(title: "Full", tracks: [track("1")])
        let live = Meeting(title: "Live", tracks: [track(DeviceLibraryLinks.partialID("2"))])
        let both = Meeting(title: "Both", tracks: [track(DeviceLibraryLinks.partialID("3")), track("3")])
        let otherRecorder = Meeting(title: "Other unit", tracks: [track("4", serial: "BBBB")])
        let export = Meeting(title: "Export", tracks: [track("5", serial: nil)])
        let otherKind = Meeting(title: "Folder", tracks: [track("1", kind: "recorder.files")])
        let mac = Meeting(title: "Mac", tracks: [RecordingTrack(source: .microphone, relativePath: "Originals/m.wav", fileName: "m.wav")])
        let links = DeviceLibraryLinks(meetings: [full, live, both, otherRecorder, export, otherKind, mac], kind: "soundcore.work", serial: "AAAA")
        XCTAssertEqual(links.imported, ["1": full.id, "3": both.id, "5": export.id])
        XCTAssertEqual(links.partial, ["2": live.id], "A Listen Live portion isn't the whole recording")
        XCTAssertEqual(links.recent.count, 5)

        let recordings = (1...5).map { recording($0) }.map { DeviceRecording(id: String($0.id.suffix(1)), startedAt: $0.startedAt) }
        let split = DeviceRecordingSplit(recordings: recordings, links: links)
        XCTAssertEqual(split.new.map(\.id), ["4", "2"], "Newest first; another unit's recording is new here")
        XCTAssertEqual(split.imported.map(\.id), ["5", "3", "1"])
    }

    func testSplitHoldsTheRecordingInProgressApart() {
        var now = recording(9)
        now.isInProgress = true
        let split = DeviceRecordingSplit(recordings: [recording(1), now, recording(1)], links: DeviceLibraryLinks())
        XCTAssertEqual(split.inProgress?.id, now.id)
        XCTAssertEqual(split.new.map(\.id), [recording(1).id], "Duplicates once")
    }

    func testOverlapsOnlyWithConversationsRecordedOnThisMac() {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        func meeting(_ title: String, offset: TimeInterval, duration: TimeInterval, source: AudioSource) -> Meeting {
            Meeting(title: title, date: start.addingTimeInterval(offset),
                    tracks: [RecordingTrack(source: source, relativePath: "Originals/x.wav", fileName: "x.wav", duration: duration)])
        }
        let meetings = [
            meeting("Design review", offset: 600, duration: 3_600, source: .microphone),
            meeting("Short overlap", offset: -300, duration: 400, source: .systemAudio),
            meeting("Imported file", offset: 0, duration: 3_600, source: .imported),
            meeting("Later", offset: 5_000, duration: 600, source: .microphone)
        ]
        let overlaps = DeviceOverlap.find(start: start, duration: 4_320, in: meetings)
        XCTAssertEqual(overlaps.map(\.title), ["Design review", "Short overlap"], "Most overlap first")
        XCTAssertTrue(DeviceOverlap.find(start: start, duration: 0, in: meetings).isEmpty)
    }

    func testSnapshotKeepsLastConfirmedValues() {
        var snapshot = SoundcoreSnapshot(deviceID: UUID(), name: "soundcore Work")
        let when = Date(timeIntervalSince1970: 1_780_000_000)
        snapshot.apply(SoundcoreDeviceInfo(microphoneBattery: 80, caseBattery: 60, caseCharging: true, firmware: "2.1.4",
                                           serial: "D3200A21F07F3A", totalBytes: 7_200_000_000, freeBytes: 6_100_000_000), at: when)
        snapshot.apply(SoundcoreDeviceInfo(microphoneBattery: 70), at: when.addingTimeInterval(60))
        XCTAssertEqual(snapshot.info?.microphoneBattery, 70)
        XCTAssertEqual(snapshot.info?.caseBattery, 60)
        XCTAssertEqual(snapshot.info?.freeBytes, 6_100_000_000, "A push without storage keeps the storage it knew")
        XCTAssertEqual(snapshot.info?.firmware, "2.1.4")
        XCTAssertEqual(snapshot.statusUpdatedAt, when.addingTimeInterval(60))
        XCTAssertEqual(snapshot.displayName, "soundcore Work ··7F3A")
    }

    @MainActor
    func testLinksAreRebuiltOnlyWhenTheDevicesTracksChange() {
        let kind = SoundcoreWorkIntegration().kind
        let session = DeviceSession(device: ConfiguredDevice(id: "links", kind: kind), kind: kind, connections: [],
                                    defaults: UserDefaults(suiteName: "links-\(UUID().uuidString)")!)
        let soundcore = DeviceRecordingIdentity(kind: kind.id, serial: "AAAA", recordingID: "1780000000")
        var meetings = [
            Meeting(title: "Soundcore", tracks: [RecordingTrack(source: .soundcore, relativePath: "a", fileName: "a.wav", device: soundcore)]),
            Meeting(title: "Mac", tracks: [RecordingTrack(source: .microphone, relativePath: "b", fileName: "b.m4a")])
        ]
        session.libraryChanged(meetings, ready: true)
        XCTAssertEqual(session.links.imported["1780000000"], meetings[0].id)
        let rebuilds = session.linkRebuilds

        // Edits elsewhere in the library (a title, notes, another conversation's audio) cost nothing.
        meetings[1].title = "Renamed"
        meetings[0].title = "Also renamed"
        meetings.append(Meeting(title: "Another", tracks: [RecordingTrack(source: .microphone, relativePath: "c", fileName: "c.m4a")]))
        let index = DeviceLibraryIndex(meetings: meetings)
        session.libraryChanged(meetings, index: index, ready: true)
        XCTAssertEqual(session.linkRebuilds, rebuilds)
        XCTAssertEqual(session.links.imported["1780000000"], meetings[0].id)

        // Its own recordings arriving, or leaving, rebuild them.
        let next = DeviceRecordingIdentity(kind: kind.id, serial: "AAAA", recordingID: "1780003600")
        meetings[2].tracks.append(RecordingTrack(source: .soundcore, relativePath: "d", fileName: "d.wav", device: next))
        session.libraryChanged(meetings, ready: true)
        XCTAssertEqual(session.linkRebuilds, rebuilds + 1)
        XCTAssertEqual(session.links.imported["1780003600"], meetings[2].id)
        meetings.remove(at: 0)
        session.libraryChanged(meetings, ready: true)
        XCTAssertNil(session.links.imported["1780000000"])
        XCTAssertEqual(DeviceLibraryLinks(tracks: DeviceLibraryIndex(meetings: meetings).tracks(kind: kind.id)),
                       DeviceLibraryLinks(meetings: meetings, kind: kind.id))
    }

    @MainActor
    func testARecordingsStartIsReadFromItsIdentityInOnePlace() {
        let kind = SoundcoreWorkIntegration.id
        XCTAssertEqual(DeviceRecordingStart.date(of: DeviceRecordingIdentity(kind: kind, recordingID: "1780000000")),
                       Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(DeviceRecordingStart.date(of: DeviceRecordingIdentity(kind: kind, recordingID: "1780000000~live")),
                       Date(timeIntervalSince1970: 1_780_000_000), "a Listen Live portion starts with its recording")
        XCTAssertNil(DeviceRecordingStart.date(of: DeviceRecordingIdentity(kind: kind, recordingID: "12")), "not a plausible time")
        XCTAssertNil(DeviceRecordingStart.date(of: DeviceRecordingIdentity(kind: OtherRecorderIntegration.id, recordingID: "1780000000")))
        XCTAssertNil(DeviceRecordingStart.date(of: DeviceRecordingIdentity(kind: kind, recordingID: "file:ZOOM0009.WAV|58200000")))
        XCTAssertEqual(DeviceLibraryLinks.wholeRecordingID("1780000000~live"), "1780000000")
        XCTAssertEqual(DeviceLibraryLinks.wholeRecordingID("1780000000"), "1780000000")
    }

    func testCatalogDeclaresMethodsInPreferenceOrder() async {
        await MainActor.run {
            let soundcore = DeviceCatalog.kind(SoundcoreWorkIntegration.id)
            XCTAssertEqual(soundcore?.methods.map(\.kind), [.direct, .files, .account])
            XCTAssertEqual(soundcore?.implementedMethods.map(\.kind), [.direct, .files], "Accounts are declared, never implemented")
            XCTAssertEqual(soundcore?.preferredMethod?.kind, .direct, "Bluetooth is the primary path")
            let other = DeviceCatalog.kind(OtherRecorderIntegration.id)
            XCTAssertEqual(other?.methods.map(\.kind), [.files])
            XCTAssertEqual(other?.allowsMultiple, true)
            XCTAssertEqual(soundcore?.allowsMultiple, false)
            for kind in DeviceCatalog.kinds {
                XCTAssertFalse(kind.name.isEmpty || kind.systemImage.isEmpty)
                XCTAssertFalse(kind.summary.contains("Experimental"))
            }
        }
    }
}
