import AVFoundation
import XCTest
@testable import DaybookCore

/// A temporary folder standing in for iCloud Drive. An object can be evicted to a `.name.icloud` placeholder,
/// or withheld as if its device had not uploaded it yet. It reappears only when the test (or a requested
/// download, unless downloads are held) delivers it. No real iCloud account is involved.
final class SimulatedICloud: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]
    private var requests: [String] = []
    private var dropped: [String] = []
    private var notUploaded: Set<String> = []
    private var holding = false
    private var fraction: Double?
    private var onRequest: (@Sendable (URL) -> Void)?

    static func placeholder(_ url: URL) -> URL { url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud") }

    func evict(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try Data().write(to: Self.placeholder(url))
        lock.withLock { stored[url.path] = data }
    }
    func withhold(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        lock.withLock { stored[url.path] = data }
    }
    func deliver(_ url: URL) throws {
        guard let data = lock.withLock({ stored.removeValue(forKey: url.path) }) else { return }
        try data.write(to: url)
        try? FileManager.default.removeItem(at: Self.placeholder(url))
    }
    func holdDownloads(_ hold: Bool) { lock.withLock { holding = hold } }
    func reportFraction(_ value: Double?) { lock.withLock { fraction = value } }
    func whenDownloadRequested(_ hook: (@Sendable (URL) -> Void)?) { lock.withLock { onRequest = hook } }
    func setUploaded(_ url: URL, _ uploaded: Bool) { lock.withLock { if uploaded { notUploaded.remove(url.path) } else { notUploaded.insert(url.path) } } }
    var downloadRequests: [String] { lock.withLock { requests } }
    var droppedLocalCopies: [String] { lock.withLock { dropped } }

    var files: SyncCloudFiles {
        SyncCloudFiles(
            requestDownload: { [self] url in
                let (deliverNow, hook) = lock.withLock { () -> (Bool, (@Sendable (URL) -> Void)?) in
                    requests.append(url.path)
                    return (!holding && stored[url.path] != nil, onRequest)
                }
                hook?(url)
                if deliverNow { try deliver(url) }
            },
            downloadFraction: { [self] _ in lock.withLock { fraction } },
            isUploaded: { [self] url in
                let present = FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: Self.placeholder(url).path)
                return present && lock.withLock { !notUploaded.contains(url.path) }
            },
            evictLocalCopy: { [self] url in lock.withLock { dropped.append(url.path) } })
    }
}

private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []
    func append(_ item: Value) { lock.withLock { items.append(item) } }
    var values: [Value] { lock.withLock { items } }
}

final class LibrarySyncReplicaTests: XCTestCase {
    private var root: URL!
    private var cloud: SimulatedICloud!
    private var remote: URL { root.appendingPathComponent("iCloud") }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name) }
    private let fast = AudioFetchOptions(pollInterval: .milliseconds(5), timeout: .seconds(10))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookReplicaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cloud = SimulatedICloud()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func mac(_ name: String = "Mac", canProcess: Bool = true) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .eager, device: SyncDeviceIdentity(deviceClass: .mac, displayName: "\(name) Studio", canProcess: canProcess), cloud: cloud.files))
    }
    private func phone(_ name: String = "Phone", budget: UInt64? = nil) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .onDemand, device: SyncDeviceIdentity(deviceClass: .phone, displayName: "Pocket", canProcess: false),
            audioCache: budget.map { AudioCachePolicy(budgetBytes: $0) }, cloud: cloud.files))
    }
    private func apply(_ result: SyncResult, to name: String, using engine: LibrarySyncEngine) async throws {
        let store = try MeetingStore(rootURL: local(name))
        for meeting in result.meetings { try await store.save(meeting) }
        for id in result.deletedMeetingIDs where FileManager.default.fileExists(atPath: local(name).appendingPathComponent("Meetings/\(id)").path) {
            _ = try await store.moveToTrash(id)
        }
        try await engine.acknowledge(result.checkpointID)
    }
    @discardableResult
    private func pass(_ engine: LibrarySyncEngine, _ name: String, _ meetings: [Meeting] = []) async throws -> SyncResult {
        let result = try await engine.synchronize(meetings: meetings)
        try await apply(result, to: name, using: engine)
        return result
    }
    /// A recording made on `name` (synthetic bytes; sync never decodes audio) in a new or existing meeting.
    private func record(_ bytes: Data, on name: String, into meeting: Meeting, ext: String = "wav", source: AudioSource = .microphone) async throws -> Meeting {
        let file = root.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try bytes.write(to: file)
        return try await MeetingStore(rootURL: local(name)).importAudio(from: file, into: meeting, source: source)
    }
    private func audioBytes(_ count: Int, seed: UInt8) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }
    private func blob(_ track: RecordingTrack) -> URL { remote.appendingPathComponent("Blobs/\(track.sha256)") }
    private func localAudio(_ name: String, _ meetingID: UUID, _ track: RecordingTrack) -> URL {
        local(name).appendingPathComponent("Meetings/\(meetingID.uuidString)/\(track.relativePath)")
    }
    private func temporaryFiles(_ name: String, _ meetingID: UUID) -> [String] {
        let originals = local(name).appendingPathComponent("Meetings/\(meetingID.uuidString)/Originals")
        return ((try? FileManager.default.contentsOfDirectory(atPath: originals.path)) ?? []).filter { $0.hasPrefix(".") }
    }
    private func writeM4A(to url: URL, seconds: Double = 1.5) throws {
        let rate = 16_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) { samples[index] = 0.2 * sin(2 * .pi * 440 * Float(index) / Float(rate)) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        file.close()
    }

    // MARK: On-demand policy

    func testOnDemandReplicaAppliesConversationsWithoutAudioAndAcknowledges() async throws {
        let mac = try mac(), phone = try phone()
        var meeting = try await record(audioBytes(4096, seed: 1), on: "Mac", into: Meeting(title: "Design review"))
        meeting.tracks[0].duration = 1800
        meeting.tracks[0].device = DeviceRecordingIdentity(kind: "soundcore.work", serial: "SN-1", recordingID: "rec-7")
        let track = meeting.tracks[0]
        meeting.transcripts = [TrackTranscript(trackID: track.id, segments: [.init(trackID: track.id, start: 0, end: 4, text: "Ship the beta")])]
        meeting.unifiedTranscript = meeting.transcripts[0].segments
        meeting.setSummary(MeetingSummary(overview: "Decided to ship the beta"))
        meeting.setNotes("Bring the prototype")
        let published = try await pass(mac, "Mac", [meeting]).meetings[0]
        // A second conversation whose recording hasn't even reached the folder yet.
        let hallway = try await record(audioBytes(2048, seed: 2), on: "Mac", into: Meeting(title: "Hallway"))
        let second = try await pass(mac, "Mac", [published, hallway])
        let pending = try XCTUnwrap(second.meetings.first { $0.id == hallway.id })
        try cloud.evict(blob(track))
        try cloud.withhold(blob(pending.tracks[0]))
        cloud.holdDownloads(true)

        // An eager replica waits for audio, as before.
        let eager = try LibrarySyncEngine(localRoot: local("OtherMac"), remoteRoot: remote, deviceID: "OtherMac", replica: .init(cloud: cloud.files))
        let waiting = try await eager.synchronize(meetings: [])
        XCTAssertTrue(waiting.meetings.isEmpty); XCTAssertGreaterThan(waiting.pendingDownloads, 0)
        let requestsBeforePhone = cloud.downloadRequests

        let pulled = try await phone.synchronize(meetings: [])
        XCTAssertEqual(Set(pulled.meetings.map(\.id)), [published.id, pending.id])
        // The complete snapshot: valid track with SHA-256, duration, and provenance, plus every text artifact.
        XCTAssertEqual(pulled.meetings.first { $0.id == published.id }, published)
        XCTAssertEqual(pulled.pendingDownloads, 0); XCTAssertEqual(pulled.warnings, []); XCTAssertFalse(pulled.hasMoreWork)
        XCTAssertEqual(pulled.notLocalAudio, [published.id: [track.id], pending.id: [pending.tracks[0].id]])
        XCTAssertEqual(pulled.changedMeetingIDs, [published.id, pending.id])
        XCTAssertEqual(cloud.downloadRequests, requestsBeforePhone, "An on-demand pull never asks iCloud for audio")
        XCTAssertFalse(FileManager.default.fileExists(atPath: localAudio("Phone", published.id, track).path))

        try await apply(pulled, to: "Phone", using: phone)
        XCTAssertEqual(phone.audioAvailability(for: published), [track.id: .notLocal])
        let saved = try await MeetingStore(rootURL: local("Phone")).load(published.id)
        XCTAssertEqual(saved, published)

        // The acknowledgement held without audio: a restarted phone has nothing new, and its next edit
        // descends from the Mac's event instead of looking concurrent.
        let restarted = try self.phone()
        let savedPending = try await MeetingStore(rootURL: local("Phone")).load(pending.id)
        let again = try await restarted.synchronize(meetings: [saved, savedPending])
        XCTAssertEqual(again.changedMeetingIDs, []); XCTAssertEqual(again.publishedEvents, 0); XCTAssertEqual(again.pendingDownloads, 0)
        try await restarted.acknowledge(again.checkpointID)
        var edited = saved; edited.setNotes("Bring the prototype and the budget")
        let afterEdit = try await pass(restarted, "Phone", [edited])
        XCTAssertEqual(afterEdit.publishedEvents, 1); XCTAssertEqual(afterEdit.warnings, [])
        let onMac = try await mac.synchronize(meetings: [published, pending])
        let macCopy = try XCTUnwrap(onMac.meetings.first { $0.id == published.id })
        XCTAssertEqual(macCopy.notes, edited.notes); XCTAssertEqual(macCopy.tracks, published.tracks)
        XCTAssertFalse(macCopy.revisions.contains { $0.field.hasPrefix("sync:") })
    }

    // MARK: Fetch on demand

    func testFetchRequestsDownloadReportsProgressAndInstallsVerifiedAudio() async throws {
        let mac = try mac(), phone = try phone()
        let bytes = audioBytes(1_100_000, seed: 3) // three 512 KB copy chunks
        let meeting = try await pass(mac, "Mac", [try await record(bytes, on: "Mac", into: Meeting(title: "Standup"))]).meetings[0]
        let track = meeting.tracks[0], object = blob(track)
        try await pass(phone, "Phone")
        try cloud.evict(object)
        cloud.holdDownloads(true); cloud.reportFraction(0.4)

        let events = Recorder<AudioFetchProgress>()
        let cloud = self.cloud!
        let installed = try await phone.fetchAudio(for: track, in: meeting.id, options: fast) { progress in
            events.append(progress)
            // iCloud finishes the download after a couple of checks.
            if events.values.filter({ $0.phase == .downloading }).count == 2 { try? cloud.deliver(object) }
        }
        XCTAssertEqual(installed, localAudio("Phone", meeting.id, track))
        XCTAssertEqual(try Data(contentsOf: installed), bytes)
        XCTAssertEqual(cloud.downloadRequests, [object.path])
        let phases = events.values.map(\.phase)
        XCTAssertEqual(phases.first, .downloading); XCTAssertEqual(events.values.first?.fractionCompleted, 0.4)
        XCTAssertEqual(phases.last, .installed); XCTAssertEqual(events.values.last?.fractionCompleted, 1)
        let copying = events.values.filter { $0.phase == .copying }
        XCTAssertGreaterThanOrEqual(copying.count, 3)
        XCTAssertEqual(copying.map(\.completedBytes), copying.map(\.completedBytes).sorted())
        XCTAssertEqual(copying.last?.completedBytes, Int64(bytes.count)); XCTAssertEqual(copying.last?.totalBytes, Int64(bytes.count))
        XCTAssertEqual(cloud.droppedLocalCopies, [object.path], "The library copy is kept; iCloud's duplicate is released")
        XCTAssertEqual(phone.audioAvailability(for: meeting), [track.id: .local])
        let cached = await phone.cachedAudio()
        XCTAssertEqual(cached.map(\.origin), [.fetched]); XCTAssertEqual(cached.first?.bytes, UInt64(bytes.count))
        XCTAssertEqual(temporaryFiles("Phone", meeting.id), [])

        // Already local and verified: immediate, no new download.
        let repeated = Recorder<AudioFetchProgress>()
        _ = try await phone.fetchAudio(for: track, in: meeting.id, options: fast) { repeated.append($0) }
        XCTAssertEqual(repeated.values.map(\.phase), [.installed]); XCTAssertEqual(cloud.downloadRequests.count, 1)
        let next = try await phone.synchronize(meetings: [meeting])
        XCTAssertEqual(next.notLocalAudio, [:]); XCTAssertEqual(next.publishedEvents, 0)
    }

    func testFetchCancellationAndTimeoutLeaveNothingPartial() async throws {
        let mac = try mac(), phone = try phone()
        let bytes = audioBytes(600_000, seed: 4) // two 512 KB copy chunks
        let meeting = try await pass(mac, "Mac", [try await record(bytes, on: "Mac", into: Meeting())]).meetings[0]
        let track = meeting.tracks[0], object = blob(track)
        try await pass(phone, "Phone")

        // Still uploading from the Mac: the fetch waits, then stops cleanly when cancelled or timed out.
        try cloud.withhold(object)
        let waiting = expectation(description: "waiting for upload")
        waiting.assertForOverFulfill = false
        let task = Task { try await phone.fetchAudio(for: track, in: meeting.id, options: fast) { if $0.phase == .waitingForUpload { waiting.fulfill() } } }
        await fulfillment(of: [waiting], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Fetch ignored cancellation") } catch is CancellationError { }
        do {
            _ = try await phone.fetchAudio(for: track, in: meeting.id, options: AudioFetchOptions(pollInterval: .milliseconds(5), timeout: .milliseconds(30)))
            XCTFail("Fetch didn't time out")
        } catch AudioFetchError.notUploadedYet { }

        // Cancelled midway through the copy: no partial file in the library.
        try cloud.deliver(object)
        let copying = Task {
            try await phone.fetchAudio(for: track, in: meeting.id, options: fast) { progress in
                if progress.phase == .copying { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await copying.value; XCTFail("Copy ignored cancellation") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: localAudio("Phone", meeting.id, track).path))
        XCTAssertEqual(temporaryFiles("Phone", meeting.id), [])
        XCTAssertEqual(phone.audioAvailability(for: meeting), [track.id: .notLocal])
        let cached = await phone.cachedAudio()
        XCTAssertEqual(cached, [])

        let url = try await phone.fetchAudio(for: track, in: meeting.id, options: fast)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testFetchRejectsCorruptObjectWithoutInstallingOrWarningDuringSync() async throws {
        let mac = try mac(), phone = try phone()
        let bytes = audioBytes(64_000, seed: 5)
        let meeting = try await pass(mac, "Mac", [try await record(bytes, on: "Mac", into: Meeting())]).meetings[0]
        let track = meeting.tracks[0], object = blob(track)
        try await pass(phone, "Phone")
        var damaged = bytes; damaged[100] ^= 0xff
        try damaged.write(to: object)

        // Sync never judges audio on an on-demand replica.
        let quiet = try await phone.synchronize(meetings: [meeting])
        XCTAssertEqual(quiet.warnings, []); XCTAssertEqual(quiet.pendingDownloads, 0)
        try await phone.acknowledge(quiet.checkpointID)

        do { _ = try await phone.fetchAudio(for: track, in: meeting.id, options: fast); XCTFail("Installed corrupt audio") }
        catch let error as AudioFetchError { XCTAssertEqual(error, .integrityMismatch(track.fileName)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: localAudio("Phone", meeting.id, track).path))
        XCTAssertEqual(temporaryFiles("Phone", meeting.id), [])
        var forged = track; forged.sha256 = "not-a-hash"
        do { _ = try await phone.fetchAudio(for: forged, in: meeting.id, options: fast); XCTFail("Accepted an invalid reference") }
        catch AudioFetchError.invalidTrack { }
        var escaping = track; escaping.relativePath = "Originals/../../outside.wav"
        do { _ = try await phone.fetchAudio(for: escaping, in: meeting.id, options: fast); XCTFail("Accepted an unsafe path") }
        catch AudioFetchError.invalidTrack { }

        try bytes.write(to: object)
        let url = try await phone.fetchAudio(for: track, in: meeting.id, options: fast)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    // MARK: Eviction

    func testEvictionRespectsBudgetLeastRecentlyPlayedFirstAndNeverUnuploadedOriginals() async throws {
        let mac = try mac(), phone = try phone()
        var fromMac: [Meeting] = []
        for (index, title) in ["A", "B", "C", "Kept"].enumerated() {
            fromMac.append(try await record(audioBytes(100_000, seed: UInt8(10 + index)), on: "Mac", into: Meeting(title: title)))
        }
        fromMac = try await pass(mac, "Mac", fromMac).meetings
        try await pass(phone, "Phone")
        func meeting(_ title: String) -> Meeting { fromMac.first { $0.title == title }! }
        for title in ["A", "B", "C", "Kept"] { try await phone.fetchAudio(for: meeting(title).tracks[0], in: meeting(title).id, options: fast) }

        // Recorded on the phone: one published but not yet uploaded by iCloud, one never published.
        let recorded = try await record(audioBytes(100_000, seed: 20), on: "Phone", into: Meeting(title: "On the train"), ext: "m4a")
        let synced = try await pass(phone, "Phone", [recorded]).meetings.first { $0.id == recorded.id }!
        cloud.setUploaded(blob(synced.tracks[0]), false)
        let unpublished = try await record(audioBytes(100_000, seed: 21), on: "Phone", into: Meeting(title: "Not synced"))
        // The object behind "Kept" disappears from the folder: the phone's copy might be the only one left.
        try FileManager.default.removeItem(at: blob(meeting("Kept").tracks[0]))

        let base = Date(timeIntervalSince1970: 1_000_000)
        await phone.noteAudioPlayed(trackID: synced.tracks[0].id, in: synced.id, at: base)                   // oldest, but not uploaded
        await phone.noteAudioPlayed(trackID: meeting("Kept").tracks[0].id, in: meeting("Kept").id, at: base.addingTimeInterval(1))
        await phone.noteAudioPlayed(trackID: meeting("B").tracks[0].id, in: meeting("B").id, at: base.addingTimeInterval(2))
        await phone.noteAudioPlayed(trackID: meeting("C").tracks[0].id, in: meeting("C").id, at: base.addingTimeInterval(3))
        await phone.noteAudioPlayed(trackID: meeting("A").tracks[0].id, in: meeting("A").id, at: base.addingTimeInterval(4))
        let tracked = await phone.cachedAudio()
        XCTAssertEqual(tracked.count, 5)
        XCTAssertEqual(tracked.first { $0.meetingID == synced.id }?.origin, .recordedHere)

        await phone.setAudioCachePolicy(AudioCachePolicy(budgetBytes: 350_000))
        let report = try await phone.evictAudio()
        XCTAssertEqual(report.evicted.map(\.meetingID), [meeting("B").id, meeting("C").id])
        XCTAssertEqual(report.bytesFreed, 200_000); XCTAssertEqual(report.bytesInUse, 300_000); XCTAssertTrue(report.isWithinBudget)
        for title in ["B", "C"] { XCTAssertEqual(phone.audioAvailability(for: meeting(title)).values.first, .notLocal) }
        for title in ["A", "Kept"] { XCTAssertEqual(phone.audioAvailability(for: meeting(title)).values.first, .local) }
        XCTAssertEqual(phone.audioAvailability(for: synced).values.first, .local, "Least recently played, but not uploaded yet")
        for title in ["A", "B", "C"] { XCTAssertTrue(FileManager.default.fileExists(atPath: blob(meeting(title).tracks[0]).path)) }

        // A tight budget: the playing track is protected and nothing else can go yet.
        await phone.setAudioCachePolicy(AudioCachePolicy(budgetBytes: 50_000))
        let protected = try await phone.evictAudio(protecting: [meeting("A").tracks[0].id])
        XCTAssertEqual(protected.evicted, []); XCTAssertFalse(protected.isWithinBudget)
        // Once iCloud has the phone's recording, it can go too; its object stays in the folder.
        cloud.setUploaded(blob(synced.tracks[0]), true)
        let uploaded = try await phone.evictAudio(protecting: [meeting("A").tracks[0].id])
        XCTAssertEqual(uploaded.evicted.map(\.meetingID), [synced.id]); XCTAssertEqual(uploaded.evicted.first?.origin, .recordedHere)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob(synced.tracks[0]).path))
        let unprotected = try await phone.evictAudio()
        XCTAssertEqual(unprotected.evicted.map(\.meetingID), [meeting("A").id]); XCTAssertEqual(unprotected.bytesInUse, 100_000)
        XCTAssertEqual(phone.audioAvailability(for: meeting("Kept")).values.first, .local, "Never evicts what may be the only copy")
        XCTAssertEqual(phone.audioAvailability(for: unpublished).values.first, .local, "Never touches an unpublished original")

        // Evicted tracks still publish intact (by reference), and audio comes back on demand.
        var renamed = try await MeetingStore(rootURL: local("Phone")).load(meeting("B").id)
        renamed.title = "B, renamed on the phone"
        let published = try await pass(phone, "Phone", [renamed])
        XCTAssertEqual(published.publishedEvents, 1); XCTAssertEqual(published.warnings, [])
        let onMac = try await mac.synchronize(meetings: fromMac)
        XCTAssertEqual(onMac.meetings.first { $0.id == renamed.id }?.tracks, meeting("B").tracks)
        XCTAssertEqual(onMac.meetings.first { $0.id == renamed.id }?.title, renamed.title)
        let back = try await phone.fetchAudio(for: meeting("B").tracks[0], in: meeting("B").id, options: fast)
        XCTAssertEqual(try Data(contentsOf: back), audioBytes(100_000, seed: 11))
    }

    // MARK: Upload from the phone

    func testPhoneRecordedM4APublishesBesideRemoteOnlyAudioAndArrivesOnEagerMac() async throws {
        let mac = try mac(), phone = try phone()
        let macBytes = audioBytes(48_000, seed: 30)
        let shared = try await pass(mac, "Mac", [try await record(macBytes, on: "Mac", into: Meeting(title: "Interview"))]).meetings[0]
        try await pass(phone, "Phone")
        XCTAssertEqual(phone.audioAvailability(for: shared).values.first, .notLocal)

        // The phone records into the same conversation while holding none of the Mac's audio.
        let m4a = root.appendingPathComponent("Phone recording.m4a")
        try writeM4A(to: m4a)
        let phoneStore = try MeetingStore(rootURL: local("Phone"))
        let recorded = try await phoneStore.importAudio(from: m4a, into: try await phoneStore.load(shared.id), source: .microphone)
        let phoneTrack = try XCTUnwrap(recorded.tracks.first { $0.relativePath.hasSuffix(".m4a") })
        let uploaded = try await pass(phone, "Phone", [recorded])
        XCTAssertEqual(uploaded.publishedEvents, 1); XCTAssertEqual(uploaded.warnings, []); XCTAssertEqual(uploaded.pendingUploads, 0)
        XCTAssertEqual(uploaded.notLocalAudio, [shared.id: [shared.tracks[0].id]])
        XCTAssertEqual(try Data(contentsOf: blob(phoneTrack)), try Data(contentsOf: m4a))
        let cached = await phone.cachedAudio()
        XCTAssertEqual(cached.map(\.origin), [.recordedHere])

        let pulled = try await pass(mac, "Mac", [shared])
        let arrived = try XCTUnwrap(pulled.meetings.first { $0.id == shared.id })
        XCTAssertEqual(pulled.warnings, []); XCTAssertEqual(pulled.pendingDownloads, 0)
        XCTAssertEqual(Set(arrived.tracks.map(\.id)), [shared.tracks[0].id, phoneTrack.id])
        XCTAssertEqual(arrived.tracks.first { $0.id == shared.tracks[0].id }, shared.tracks[0], "The Mac's track is unchanged")
        let macCopy = localAudio("Mac", shared.id, phoneTrack)
        XCTAssertEqual(macCopy.pathExtension, "m4a")
        XCTAssertEqual(try Data(contentsOf: macCopy), try Data(contentsOf: m4a))
        XCTAssertEqual(try Data(contentsOf: localAudio("Mac", shared.id, shared.tracks[0])), macBytes)
        let decoded = try AVAudioFile(forReading: macCopy)
        XCTAssertGreaterThan(decoded.length, 16_000); XCTAssertEqual(decoded.fileFormat.sampleRate, 16_000)
    }

    // MARK: Presence

    func testPresenceRecordsAreListedThrottledAndVersioned() async throws {
        let phone = try phone()
        try await pass(phone, "Phone")
        var devices = try await phone.knownDevices()
        XCTAssertEqual(devices.map(\.id), ["Phone"]); XCTAssertTrue(devices[0].isCurrentDevice)
        XCTAssertNil(devices.latestProcessor, "No Mac has synced this library yet")
        XCTAssertFalse(devices.hasPeersWithoutPresence)

        let mac = try mac()
        try await pass(mac, "Mac")
        let file = remote.appendingPathComponent("Devices/\(AudioDigest.sha256(data: Data("Mac".utf8))).json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["format"] as? String, "DaybookDevice"); XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["deviceClass"] as? String, "mac"); XCTAssertEqual(json["canProcess"] as? Bool, true)
        XCTAssertEqual(json["audioPolicy"] as? String, "eager"); XCTAssertNotNil(ISO8601DateFormatter().date(from: json["lastSeen"] as? String ?? ""))

        devices = try await phone.knownDevices()
        let seenMac = try XCTUnwrap(devices.latestProcessor)
        XCTAssertEqual(seenMac.id, "Mac"); XCTAssertEqual(seenMac.deviceClass, .mac); XCTAssertEqual(seenMac.displayName, "Mac Studio")
        XCTAssertEqual(seenMac.audioPolicy, .eager); XCTAssertFalse(seenMac.isCurrentDevice)
        XCTAssertLessThan(abs(try XCTUnwrap(seenMac.lastSeen).timeIntervalSinceNow), 60)

        // Throttled: an immediate second pass doesn't rewrite; an identity change does.
        let before = try Data(contentsOf: file)
        try await pass(mac, "Mac")
        XCTAssertEqual(try Data(contentsOf: file), before)
        await mac.updateDevice(SyncDeviceIdentity(deviceClass: .mac, displayName: "Mac Studio", canProcess: false))
        try await pass(mac, "Mac")
        XCTAssertNotEqual(try Data(contentsOf: file), before)

        // Another Mac last seen two hours ago, a clock running ahead, a future class, a newer format, and junk.
        func write(_ object: [String: Any], id: String) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: remote.appendingPathComponent("Devices/\(AudioDigest.sha256(data: Data(id.utf8))).json"))
        }
        let formatter = ISO8601DateFormatter()
        try write(["format": "DaybookDevice", "schemaVersion": 1, "deviceID": "Office", "deviceClass": "mac", "displayName": "Office iMac",
                   "canProcess": true, "lastSeen": formatter.string(from: Date().addingTimeInterval(-7200)), "futureField": ["ignored": true]], id: "Office")
        try write(["format": "DaybookDevice", "schemaVersion": 1, "deviceID": "Watch", "deviceClass": "watch", "displayName": "Wrist",
                   "canProcess": false, "lastSeen": formatter.string(from: Date().addingTimeInterval(3600))], id: "Watch")
        try write(["format": "DaybookDevice", "schemaVersion": 2, "deviceID": "Future", "deviceClass": "mac", "displayName": "Next",
                   "canProcess": true, "lastSeen": formatter.string(from: Date())], id: "Future")
        try write(["format": "DaybookDevice", "schemaVersion": 1, "deviceID": "Spoofed", "deviceClass": "mac", "displayName": "Wrong file",
                   "canProcess": true, "lastSeen": formatter.string(from: Date())], id: "Someone else")
        try Data("not json".utf8).write(to: remote.appendingPathComponent("Devices/\(String(repeating: "e", count: 64)).json"))
        try Data("{}".utf8).write(to: remote.appendingPathComponent("Devices/notes.txt"))

        devices = try await phone.knownDevices()
        XCTAssertEqual(Set(devices.map(\.id)), ["Phone", "Mac", "Office", "Watch"])
        let office = try XCTUnwrap(devices.latestProcessor)
        XCTAssertEqual(office.id, "Office"); XCTAssertEqual(office.lastSeen!.timeIntervalSinceNow, -7200, accuracy: 5)
        let watch = try XCTUnwrap(devices.first { $0.id == "Watch" })
        XCTAssertEqual(watch.deviceClass, .other); XCTAssertLessThanOrEqual(watch.lastSeen!, Date(), "Clock skew is clamped to now")
        XCTAssertEqual(devices.first { $0.id == "Mac" }?.canProcess, false)
    }

    func testARecordingMacsActivityShowsInItsPresenceWithoutAPassAndExpires() async throws {
        let mac = try mac(), phone = try phone()
        try await pass(mac, "Mac"); try await pass(phone, "Phone")
        let conversation = UUID(), start = Date()
        try await mac.publishActivity(SyncDeviceActivity(recordingConversationID: conversation, since: start,
            recorders: [.init(kind: "soundcore.work", serial: "S1", isRecording: true, recordingID: "r-1", startedAt: start)]))
        let devices = try await phone.knownDevices()
        let studio = try XCTUnwrap(devices.first { $0.id == "Mac" })
        XCTAssertTrue(studio.isRecording())
        XCTAssertEqual(studio.activity?.recordingConversationID, conversation)
        XCTAssertEqual(studio.activity?.recorders?.first?.serial, "S1")
        XCTAssertEqual(devices.recordingMac()?.id, "Mac")
        XCTAssertNotNil(studio.lastSeen, "written now, though no pass ran")
        // Nobody renews it: after its expiry it no longer says recording.
        let expiry = try XCTUnwrap(studio.activity?.expiresAt)
        XCTAssertFalse(studio.isRecording(at: expiry.addingTimeInterval(1)))
        // Stopping clears it at once.
        try await mac.publishActivity(nil)
        let after = try await phone.knownDevices()
        XCTAssertFalse(after.contains { $0.isRecording() })
        // An activity a newer Daybook wrote differently doesn't hide the device.
        let file = remote.appendingPathComponent("Devices/\(AudioDigest.sha256(data: Data("Mac".utf8))).json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["activity"] = ["recordingConversationID": 42, "mode": "holographic"]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let tolerant = try await phone.knownDevices()
        XCTAssertNotNil(tolerant.first { $0.id == "Mac" }?.lastSeen)
        XCTAssertNil(tolerant.first { $0.id == "Mac" }?.activity)
    }

    func testASettingsOnlyPassAppliesRecorderOwnershipWithoutTouchingConversations() async throws {
        let mac = try mac(), phone = try phone()
        let meeting = Meeting(title: "Being recorded on the Mac")
        try await pass(mac, "Mac", [meeting]); try await pass(phone, "Phone")
        var onPhone = meeting; onPhone.title = "Renamed on the phone"
        try await pass(phone, "Phone", [onPhone])
        var settings = LibraryMetadata()
        settings.recorders = [.init(id: RecorderOwnership.id(kind: "soundcore.work", serial: "S1"),
                                    value: RecorderOwnership(kind: "soundcore.work", serial: "S1", ownerID: "Phone", ownerName: "iPhone", ownerClass: .phone))]
        let phoneSettings = try JSONEncoder().encode(settings)
        let published = try await phone.synchronize(meetings: [onPhone], libraryMetadata: phoneSettings)
        try await phone.acknowledge(published.checkpointID)
        // The Mac is recording: it takes the settings, and the conversation waits.
        let busy = try await mac.synchronize(meetings: [meeting], libraryMetadata: try JSONEncoder().encode(LibraryMetadata()), scope: .metadataOnly)
        XCTAssertTrue(busy.meetings.isEmpty); XCTAssertTrue(busy.deletedMeetingIDs.isEmpty)
        XCTAssertTrue(busy.metadataVersions.contains(phoneSettings))
        try await mac.acknowledge(busy.checkpointID)
        let later = try await mac.synchronize(meetings: [meeting])
        XCTAssertEqual(later.meetings.first?.title, "Renamed on the phone", "a full pass afterwards brings the conversation")
        XCTAssertEqual(later.publishedEvents, 0)
    }

    func testOlderReplicaIgnoresPresenceAndSyncsWithOnDemandPhone() async throws {
        let mac = try mac(), phone = try phone()
        let macBytes = audioBytes(32_000, seed: 40)
        let fromMac = try await pass(mac, "Mac", [try await record(macBytes, on: "Mac", into: Meeting(title: "Planning"))]).meetings[0]
        try await pass(phone, "Phone")
        let m4a = root.appendingPathComponent("memo.m4a")
        try writeM4A(to: m4a, seconds: 1)
        var memo = try await MeetingStore(rootURL: local("Phone")).importAudio(from: m4a, into: Meeting(title: "Voice memo"), source: .microphone)
        memo.highlights.append(Highlight(time: 0.5, text: "Bookmark"))
        var annotated = try await MeetingStore(rootURL: local("Phone")).load(fromMac.id)
        annotated.setNotes("Notes typed on the phone")
        try await pass(phone, "Phone", [annotated, memo])
        // Files a future Daybook might add beside the journal.
        try JSONSerialization.data(withJSONObject: ["format": "DaybookDevice", "schemaVersion": 9, "deviceID": "Next"])
            .write(to: remote.appendingPathComponent("Devices/\(AudioDigest.sha256(data: Data("Next".utf8))).json"))
        try FileManager.default.createDirectory(at: remote.appendingPathComponent("Requests"), withIntermediateDirectories: true)
        try Data("{\"future\":true}".utf8).write(to: remote.appendingPathComponent("Requests/\(String(repeating: "a", count: 64)).json"))
        func snapshot(_ directory: String) throws -> [String: Data] {
            let url = remote.appendingPathComponent(directory)
            return try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: url.path).map { ($0, try Data(contentsOf: url.appendingPathComponent($0))) })
        }
        let devicesBefore = try snapshot("Devices"), requestsBefore = try snapshot("Requests")

        // The shipped version 1 engine, running as an older Mac.
        let old = try LegacyLibrarySyncEngine(localRoot: local("OldMac"), remoteRoot: remote, deviceID: "OldMac")
        let received = try await old.synchronize(meetings: [])
        XCTAssertEqual(received.warnings, []); XCTAssertEqual(received.pendingDownloads, 0)
        XCTAssertEqual(received.meetings.first { $0.id == fromMac.id }?.notes, "Notes typed on the phone")
        XCTAssertEqual(received.meetings.first { $0.id == fromMac.id }?.tracks, fromMac.tracks)
        let memoOnOldMac = try XCTUnwrap(received.meetings.first { $0.id == memo.id })
        XCTAssertEqual(memoOnOldMac.highlights.map(\.text), ["Bookmark"])
        XCTAssertEqual(try Data(contentsOf: localAudio("OldMac", memo.id, memoOnOldMac.tracks[0])), try Data(contentsOf: m4a))
        XCTAssertEqual(try Data(contentsOf: localAudio("OldMac", fromMac.id, fromMac.tracks[0])), macBytes)
        let oldStore = try MeetingStore(rootURL: local("OldMac"))
        for meeting in received.meetings { try await oldStore.save(meeting) }
        try await old.acknowledge(received.checkpointID)
        var retitled = memoOnOldMac; retitled.title = "Voice memo, titled on the old Mac"
        let oldEdit = try await old.synchronize(meetings: [retitled])
        XCTAssertEqual(oldEdit.publishedEvents, 1); XCTAssertEqual(oldEdit.warnings, [])
        XCTAssertEqual(try snapshot("Devices"), devicesBefore); XCTAssertEqual(try snapshot("Requests"), requestsBefore)

        let back = try await phone.synchronize(meetings: [])
        XCTAssertEqual(back.warnings, [])
        XCTAssertEqual(back.meetings.first { $0.id == memo.id }?.title, retitled.title)
        let devices = try await phone.knownDevices()
        XCTAssertEqual(Set(devices.map(\.id)), ["Phone", "Mac", "OldMac"], "Unknown versions are skipped")
        XCTAssertTrue(devices.hasPeersWithoutPresence)
        let oldMac = try XCTUnwrap(devices.first { $0.id == "OldMac" })
        XCTAssertNil(oldMac.deviceClass); XCTAssertNil(oldMac.lastSeen)
        let macView = try await mac.synchronize(meetings: [])
        XCTAssertEqual(macView.warnings, []); XCTAssertEqual(macView.meetings.first { $0.id == memo.id }?.title, retitled.title)
    }

    // MARK: Mixed replicas

    func testEagerAndOnDemandReplicasEditTheSameMeetingConcurrentlyWithoutLoss() async throws {
        let mac = try mac(), phone = try phone()
        var base = try await record(audioBytes(24_000, seed: 50), on: "Mac", into: Meeting(title: "Weekly", notes: "Base"))
        base = try await pass(mac, "Mac", [base]).meetings[0]
        try await pass(phone, "Phone")
        let macTrack = base.tracks[0]

        // Both edit the same snapshot before seeing each other.
        var onMac = base
        onMac.title = "Q3 planning"
        onMac.transcripts = [TrackTranscript(trackID: macTrack.id, segments: [.init(trackID: macTrack.id, start: 1, end: 3, text: "Budget first")])]
        onMac.setNotes("Mac notes")
        let phoneStore = try MeetingStore(rootURL: local("Phone"))
        let room = root.appendingPathComponent("room.m4a")
        try writeM4A(to: room)
        var onPhone = try await phoneStore.importAudio(from: room, into: try await phoneStore.load(base.id), source: .microphone)
        onPhone.highlights.append(Highlight(time: 12, text: "Decision"))
        onPhone.tags = ["work"]
        onPhone.setNotes("Phone notes")
        let phoneTrack = try XCTUnwrap(onPhone.tracks.first { $0.id != macTrack.id })

        try await pass(phone, "Phone", [onPhone])
        let macMerged = try await pass(mac, "Mac", [onMac])
        let phoneMerged = try await pass(phone, "Phone", [try await phoneStore.load(base.id)])
        let macFinal = try await pass(mac, "Mac", [try await MeetingStore(rootURL: local("Mac")).load(base.id)])
        XCTAssertEqual(macMerged.meetings, phoneMerged.meetings)
        XCTAssertEqual(macFinal.meetings, phoneMerged.meetings)
        let merged = try XCTUnwrap(phoneMerged.meetings.first)
        XCTAssertEqual(merged.title, "Q3 planning"); XCTAssertEqual(merged.transcripts, onMac.transcripts)
        XCTAssertEqual(merged.highlights.map(\.text), ["Decision"]); XCTAssertEqual(merged.tags, ["work"])
        XCTAssertEqual(merged.tracks.map(\.id).sorted { $0.uuidString < $1.uuidString }, [macTrack.id, phoneTrack.id].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(merged.tracks.first { $0.id == macTrack.id }, macTrack)
        XCTAssertEqual(merged.tracks.first { $0.id == phoneTrack.id }, phoneTrack)
        let conflict = try XCTUnwrap(merged.revisions.first { $0.field == "sync:notes" })
        XCTAssertTrue((conflict.oldValue + conflict.newValue).contains("Mac notes"))
        XCTAssertTrue((conflict.oldValue + conflict.newValue).contains("Phone notes"))
        // The Mac holds every original; the phone holds what it recorded and fetches the rest on demand.
        XCTAssertEqual(try Data(contentsOf: localAudio("Mac", base.id, phoneTrack)), try Data(contentsOf: room))
        XCTAssertEqual(phone.audioAvailability(for: merged), [macTrack.id: .notLocal, phoneTrack.id: .local])
        XCTAssertEqual(phoneMerged.notLocalAudio, [base.id: [macTrack.id]])
        XCTAssertEqual(macMerged.notLocalAudio, [:])
    }

    // MARK: Phone cadence

    func testBoundedPassesDeferWorkHonorCancellationAndDetectRemoteChanges() async throws {
        let mac = try mac(), phone = try phone()
        let meetings = (0..<5).map { Meeting(title: "Meeting \($0)", notes: "Notes \($0)") }
        try await pass(mac, "Mac", meetings)

        var passes = 0, applied = Set<UUID>()
        repeat {
            let result = try await phone.synchronize(meetings: [], limits: SyncPassLimits(maxJournalReads: 2))
            XCTAssertEqual(result.warnings, []); XCTAssertEqual(result.pendingDownloads, 0)
            applied.formUnion(result.changedMeetingIDs)
            try await apply(result, to: "Phone", using: phone)
            passes += 1
            if !result.hasMoreWork { break }
            XCTAssertEqual(result.deferredItems, 5 - 2 * passes)
        } while passes < 10
        XCTAssertEqual(passes, 3); XCTAssertEqual(applied, Set(meetings.map(\.id)))

        let settled = await phone.hasRemoteChanges()
        XCTAssertFalse(settled)
        let deleted = meetings[0].id
        let macDelete = try await mac.synchronize(meetings: Array(meetings.dropFirst()), deletedMeetingIDs: [deleted])
        try await mac.acknowledge(macDelete.checkpointID)
        let changed = await phone.hasRemoteChanges()
        XCTAssertTrue(changed)
        let deletion = try await pass(phone, "Phone")
        XCTAssertTrue(deletion.deletedMeetingIDs.contains(deleted))
        let quiet = await phone.hasRemoteChanges()
        XCTAssertFalse(quiet)

        // A relaunched phone in a zero-time background window: nothing read, nothing republished, more to do.
        let eventCount = try FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent("Events").path).count
        let relaunched = try self.phone()
        let starved = try await relaunched.synchronize(meetings: [], limits: SyncPassLimits(timeBudget: .zero))
        XCTAssertTrue(starved.hasMoreWork); XCTAssertEqual(starved.publishedEvents, 0); XCTAssertTrue(starved.meetings.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent("Events").path).count, eventCount)

        // Cancelled mid-pass (while iCloud is asked for a journal entry): no acknowledgement, offered again later.
        var edited = meetings[1]; edited.setNotes("Edited on the Mac")
        let published = try await mac.synchronize(meetings: [edited])
        try await mac.acknowledge(published.checkpointID)
        let listed = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: remote.appendingPathComponent("Events"), includingPropertiesForKeys: nil)
            .first { (try? String(contentsOf: $0, encoding: .utf8))?.contains("Edited on the Mac") == true })
        try cloud.evict(remote.appendingPathComponent("Events/\(listed.lastPathComponent)"))
        cloud.whenDownloadRequested { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let fresh = try self.phone()
        let cancelled = Task { try await fresh.synchronize(meetings: []) }
        do { _ = try await cancelled.value; XCTFail("Pass ignored cancellation") } catch is CancellationError { }
        cloud.whenDownloadRequested(nil)
        let retried = try await fresh.synchronize(meetings: [])
        XCTAssertEqual(retried.meetings.first { $0.id == edited.id }?.notes, "Edited on the Mac")
        XCTAssertTrue(retried.changedMeetingIDs.contains(edited.id))
    }

    func testPartialJournalReadNeverRollsBackAppliedConversationsOrMetadata() async throws {
        let mac = try mac(), phone = try phone()
        let first = try await mac.synchronize(meetings: [Meeting(title: "Retro", notes: "First")], libraryMetadata: Data("folders v1".utf8))
        try await apply(first, to: "Mac", using: mac)
        var edited = first.meetings[0]; edited.setNotes("Second")
        try await apply(try await mac.synchronize(meetings: [edited], libraryMetadata: Data("folders v2".utf8)), to: "Mac", using: mac)
        let synced = try await phone.synchronize(meetings: [])
        XCTAssertEqual(synced.meetings.map(\.notes), ["Second"]); XCTAssertEqual(synced.metadataVersions, [Data("folders v2".utf8)])
        try await apply(synced, to: "Phone", using: phone)

        // After a relaunch, iCloud has evicted the newest entries and is slow to bring them back.
        func journal(_ directory: String, containing match: (Data) -> Bool) throws -> URL {
            let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent(directory).path)
                .first { match(FileManager.default.contents(atPath: remote.appendingPathComponent("\(directory)/\($0)").path) ?? Data()) })
            return remote.appendingPathComponent("\(directory)/\(name)")
        }
        let newestEvent = try journal("Events") { String(decoding: $0, as: UTF8.self).contains("Second") }
        let newestMetadata = try journal("Metadata") { String(decoding: $0, as: UTF8.self).contains(Data("folders v2".utf8).base64EncodedString()) }
        cloud.holdDownloads(true)
        try cloud.evict(newestEvent); try cloud.evict(newestMetadata)
        let relaunched = try self.phone()
        let partial = try await relaunched.synchronize(meetings: [])
        XCTAssertEqual(partial.meetings, [], "The older snapshot is never offered over the applied one")
        XCTAssertEqual(partial.metadataVersions, [], "Nor older library metadata")
        XCTAssertEqual(partial.pendingDownloads, 2)
        try await relaunched.acknowledge(partial.checkpointID)

        try cloud.deliver(newestEvent); try cloud.deliver(newestMetadata)
        let current = try await MeetingStore(rootURL: local("Phone")).load(edited.id)
        let complete = try await relaunched.synchronize(meetings: [current])
        XCTAssertEqual(complete.publishedEvents, 0); XCTAssertEqual(complete.changedMeetingIDs, [])
        XCTAssertEqual(complete.metadataVersions, [Data("folders v2".utf8)])
        try await relaunched.acknowledge(complete.checkpointID)
        var later = current; later.setNotes("Third, typed on the phone")
        try await pass(relaunched, "Phone", [later])
        let onMac = try await mac.synchronize(meetings: [edited])
        XCTAssertEqual(onMac.meetings.first?.notes, later.notes)
        XCTAssertFalse(onMac.meetings.first?.revisions.contains { $0.field.hasPrefix("sync:") } ?? true, "Still a sequential edit")
    }

    func testSyncDigestMatchesAudioDigest() throws {
        // Block-boundary sizes against the reference implementation, then streaming across 1 MB reads.
        for count in [0, 1, 55, 56, 63, 64, 65, 1000] {
            let data = audioBytes(count, seed: 60)
            XCTAssertEqual(SyncDigest.sha256(data: data), AudioDigest.sha256(data: data), "\(count) bytes")
        }
        let large = audioBytes(2_100_000, seed: 61)
        let file = root.appendingPathComponent("digest.bin")
        try large.write(to: file)
        XCTAssertEqual(try SyncDigest.sha256(fileURL: file), SyncDigest.sha256(data: large))
    }
}
