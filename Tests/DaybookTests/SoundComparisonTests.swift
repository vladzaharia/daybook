import DaybookCore
@testable import DaybookKit
import Foundation
import XCTest
@testable import Daybook

/// Comparing a recording's sound: an aligner that fails, or work cancelled with its job, is a
/// failure to try again later, never "no match" (which would mark the recording checked for good).
@MainActor
final class SoundComparisonTests: XCTestCase {
    private struct Unreadable: LocalizedError { var errorDescription: String? { "The recording can’t be read yet." } }

    func testAFailedOrCancelledComparisonIsNotNoMatch() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        let reference = try rig.audio("reference.wav", frequency: 440)
        let id = try await rig.macConversation("Standup", at: Date(), seconds: 1, audio: reference)
        let other = try rig.audio("other.wav", frequency: 660)

        rig.state.sources.alignAudio = { _, _, _, _ in throw Unreadable() }
        let failed = await rig.state.compareSound(of: other, duration: 1, in: id, clockOffset: nil, reliableClock: false)
        guard case .failed(let reason) = failed else { return XCTFail("Expected a failure, got \(failed)") }
        XCTAssertEqual(reason, "The recording can’t be read yet.")

        // Comparing takes a while; the job is paused meanwhile.
        rig.state.sources.alignAudio = { _, _, _, _ in
            while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
            throw CancellationError()
        }
        let comparing = Task { await rig.state.compareSound(of: other, duration: 1, in: id, clockOffset: nil, reliableClock: false) }
        try await Task.sleep(for: .milliseconds(50))
        comparing.cancel()
        guard case .failed = await comparing.value else { return XCTFail("A cancelled comparison isn't a result") }

        rig.state.sources.alignAudio = { _, _, _, _ in nil }
        guard case .noMatch = await rig.state.compareSound(of: other, duration: 1, in: id, clockOffset: nil, reliableClock: false) else {
            return XCTFail("No alignment is still no match")
        }
    }

    /// The clocks put a recorder 100 s in; it's really 700 s in (a recorder's clock set ten minutes wrong). The search
    /// around the prior (±120 s) finds nothing, so the whole overlap is searched, and that's kept only when it's as
    /// sure as a match that joins a conversation.
    func testAClockPriorTenMinutesOffIsFoundBySearchingTheWholeOverlap() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        let reference = try rig.audio("reference.wav", frequency: 440)
        let id = try await rig.macConversation("Standup", at: Date(), seconds: 3_600, audio: reference)
        let other = try rig.audio("other.wav", frequency: 660)
        let truth: TimeInterval = 700
        let searches = Searches()
        func aligner(wholeOverlapConfidence: Double) -> AudioAlignmentFunction {
            { _, _, expected, radius in
                searches.add(expected)
                // As AudioAligner does: a search around a prior sees only its radius.
                if let expected, abs(expected - truth) > radius { return nil }
                return AudioAlignment(offset: truth, confidence: expected == nil ? wholeOverlapConfidence : 0.9)
            }
        }
        rig.state.sources.alignAudio = aligner(wholeOverlapConfidence: 0.8)
        guard case .match(let placed) = await rig.state.compareSound(of: other, duration: 600, in: id, clockOffset: 100, reliableClock: true) else {
            return XCTFail("The whole overlap finds it")
        }
        XCTAssertEqual(placed.offset, truth)
        XCTAssertEqual(placed.method, .audio)
        XCTAssertEqual(placed.clockOffset, 100, "The clocks' estimate is kept for reference")
        XCTAssertEqual(searches.values, [100, nil])

        searches.clear()
        rig.state.sources.alignAudio = aligner(wholeOverlapConfidence: 0.55)
        guard case .noMatch = await rig.state.compareSound(of: other, duration: 600, in: id, clockOffset: 100, reliableClock: true) else {
            return XCTFail("A whole-overlap match less sure than joining a conversation needs isn't kept")
        }
        XCTAssertEqual(searches.values, [100, nil])

        searches.clear()
        rig.state.sources.alignAudio = aligner(wholeOverlapConfidence: 0.8)
        guard case .match = await rig.state.compareSound(of: other, duration: 600, in: id, clockOffset: 650, reliableClock: true) else {
            return XCTFail("Found around the prior")
        }
        XCTAssertEqual(searches.values, [650], "A sure match around the prior needs no second search")
    }

    /// A recording placed only by shared phrases (or the clocks) is compared by sound once there's something sure to
    /// compare with, with both recordings' digests for the features cache; the sound's placement replaces it, and a
    /// recording lined up against it moves with it. One already compared isn't compared again.
    func testAPlacementByPhrasesIsCheckedByTheSoundAndWhatRestsOnItFollows() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        let mic = try rig.audio("microphone.wav", frequency: 220)
        let id = try await rig.macConversation("Review", at: Date(), seconds: 600, audio: mic)
        let installed = rig.state.installedModels
        rig.state.installedModels = []
        try await rig.state.importFiles([try rig.audio("recorder.wav", frequency: 523)], source: .soundcore, attachTo: id)
        try await rig.state.importFiles([try rig.audio("phone.wav", frequency: 330)], source: .imported, attachTo: id)
        rig.state.installedModels = installed
        rig.state.processor.queue.awaitingModels.remove(id)
        rig.state.processor.queue.settle(id)
        let tracks = try XCTUnwrap(rig.meeting(id)?.tracks)
        let (microphone, recorder, phone) = (tracks[0], tracks[1], tracks[2])
        rig.state.update(id) { meeting in
            meeting.applyPlacements([recorder.id: SourceAlignment(method: .transcript, offset: 3, confidence: 0.7, clockOffset: 2.5),
                                     phone.id: SourceAlignment(method: .audio, offset: 5, confidence: 0.9, referenceTrackID: recorder.id, audioChecked: true)])
        }
        let digests = Searches.Digests()
        rig.state.sources.alignAudio = { other, reference, _, _ in
            digests.add(other.digest, reference.digest)
            return AudioAlignment(offset: 3.4, confidence: 0.9)
        }
        try await rig.state.placePendingSources(id)
        let meeting = try XCTUnwrap(rig.meeting(id))
        let placed = try XCTUnwrap(meeting.tracks.first { $0.id == recorder.id }?.alignment)
        XCTAssertEqual(placed.method, .audio)
        XCTAssertEqual(placed.offset ?? 0, 3.4, accuracy: 1e-9)
        XCTAssertEqual(placed.referenceTrackID, microphone.id)
        XCTAssertEqual(meeting.clock(of: phone.id)?.offset ?? 0, 5.4, accuracy: 1e-9, "Lined up against the recorder, it moved with it")
        XCTAssertEqual(digests.values.count, 1, "The phone's recording was compared already")
        XCTAssertEqual(digests.values.first?.other, recorder.sha256)
        XCTAssertEqual(digests.values.first?.reference, microphone.sha256)

        try await rig.state.placePendingSources(id)
        XCTAssertEqual(digests.values.count, 1, "Placed by the sound, it isn't compared again")
    }

    /// Alignment features persist in this Mac's Caches folder, keyed by digest: never in the library, never synced.
    func testAlignmentFeaturesAreKeptInTheCachesFolder() throws {
        let directory = try XCTUnwrap(MultiSourceCoordinator.features.directory)
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        XCTAssertTrue(directory.standardizedFileURL.path.hasPrefix(caches.standardizedFileURL.path), directory.path)
    }

    /// Of the link's clock and the one the iPhone measured while recording, the tighter is used, not just the later.
    func testTheTighterClockMeasurementPlacesAPhonesRecording() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        let now = Date()
        var track = RecordingTrack(source: .microphone, relativePath: "p", fileName: "p", sha256: "p")
        track.capture = TrackCaptureDetails(peerClocks: [
            CapturePeerClock(deviceID: rig.state.phoneLink.identity.deviceID.uuidString, offset: -2.5, uncertainty: 0.040, sampleCount: 3,
                             measuredAt: now.addingTimeInterval(30))])
        var link = CompanionRecording(deviceID: "phone", deviceKind: "daybook.iphone", deviceName: "iPhone", macStartedAt: now)
        link.clock = CompanionClock(offset: 2.4, uncertainty: 0.004, samples: 8, measuredAt: now)
        XCTAssertEqual(rig.state.recorderClock(for: track, link: link)?.offset, 2.4, "The link's, measured earlier but ten times tighter")
        link.clock?.uncertainty = 0.080
        XCTAssertEqual(rig.state.recorderClock(for: track, link: link)?.offset, 2.5, "The phone's, now the tighter")
    }
}

/// What a stubbed aligner was asked.
private final class Searches: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimeInterval?] = []
    func add(_ expected: TimeInterval?) { lock.withLock { stored.append(expected) } }
    func clear() { lock.withLock { stored.removeAll() } }
    var values: [TimeInterval?] { lock.withLock { stored } }

    final class Digests: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(other: String?, reference: String?)] = []
        func add(_ other: String?, _ reference: String?) { lock.withLock { stored.append((other, reference)) } }
        var values: [(other: String?, reference: String?)] { lock.withLock { stored } }
    }
}
