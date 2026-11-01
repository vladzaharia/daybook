import DaybookCaptions
import DaybookTestSupport
import Foundation
import Observation
import XCTest
@testable import DaybookDevices

/// `ObservationWatch`: following `@Observable` models outside views, which both apps do where Combine's publishers
/// used to: told once a change has landed, once per turn of the main queue, after a quiet spell with a delay, and
/// never once cancelled or released. And a device's live captions redraw only what reads them.
@MainActor
final class ObservationWatchTests: XCTestCase {
    @MainActor
    @Observable
    final class Model {
        var value = 0
        var other = 0
    }

    /// The main queue runs everything queued before it.
    private func settle() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        await Task.yield()
    }

    func testAWatchIsToldOnceTheChangeHasLandedOncePerTurn() async throws {
        let model = Model()
        var seen: [Int] = []
        let watch = ObservationWatch({ _ = model.value }) { seen.append(model.value) }
        defer { watch.cancel() }
        model.value = 1
        XCTAssertEqual(seen, [], "Never while the change is being made")
        model.value = 2
        model.value = 3
        await settle()
        XCTAssertEqual(seen, [3], "Three changes in one turn: told once, after they landed")
        model.other = 9
        await settle()
        XCTAssertEqual(seen, [3], "What it doesn't read doesn't reach it")
        model.value = 4
        await settle()
        XCTAssertEqual(seen, [3, 4], "It follows the next change too")
    }

    func testValuesAreToldNowAndDistinctValuesOnlyWhenTheyDiffer() async throws {
        let model = Model()
        var values: [Int] = [], distinct: [Int] = []
        let all = ObservationWatch.values(of: { model.value }) { values.append($0) }
        let changes = ObservationWatch.distinctValues(of: { model.value % 2 }, initial: false) { distinct.append($0) }
        defer { all.cancel(); changes.cancel() }
        XCTAssertEqual(values, [0], "Now, then after each change")
        model.value = 2
        await settle()
        model.value = 3
        await settle()
        XCTAssertEqual(values, [0, 2, 3])
        XCTAssertEqual(distinct, [1], "2 is even, like the 0 it started from: only the change to odd")
    }

    func testADelayIsToldOnceAfterABurst() async throws {
        let model = Model()
        var told = 0
        let watch = ObservationWatch(delay: .milliseconds(80), { _ = model.value }) { told += 1 }
        defer { watch.cancel() }
        for step in 1...5 {
            model.value = step
            await settle()
        }
        XCTAssertEqual(told, 0, "Still changing")
        try await waitUntil("the quiet spell") { told == 1 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(told, 1)
    }

    func testACancelledOrReleasedWatchIsToldNothing() async throws {
        let model = Model()
        var cancelledTold = 0, releasedTold = 0, delayedTold = 0
        let cancelled = ObservationWatch({ _ = model.value }) { cancelledTold += 1 }
        let delayed = ObservationWatch(delay: .milliseconds(30), { _ = model.value }) { delayedTold += 1 }
        var released: ObservationWatch? = ObservationWatch({ _ = model.value }) { releasedTold += 1 }
        XCTAssertNotNil(released)
        model.value = 1
        cancelled.cancel()
        released = nil
        await settle()
        delayed.cancel()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual([cancelledTold, releasedTold, delayedTold], [0, 0, 0])
    }

    func testUntilReturnsOnceItsConditionHolds() async throws {
        let model = Model()
        await ObservationWatch.until { model.value == 0 }
        let waiting = Task { await ObservationWatch.until { model.value >= 2 }; return model.value }
        await settle()
        model.value = 1
        await settle()
        model.value = 2
        let reached = await waiting.value
        XCTAssertEqual(reached, 2)
    }

    /// Listen Live's captions change several times a second: they redraw what reads them (the caption strip), not
    /// what reads the session's device, queue, or list.
    func testLiveCaptionsRedrawOnlyWhatReadsThem() async throws {
        let defaults = makeTestDefaults("daybook.observation.captions")
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: makeTemporaryFolder("DaybookObservationStaging"))
        environment.soundcoreTransport = { InertSoundcoreTransport() }
        environment.liveCaptions.makeCaptioner = { nil }
        let configured = ConfiguredDevice(id: "inert", kind: SoundcoreWorkIntegration().kind)
        let connection = SoundcoreConnection(device: configured, environment: environment)
        let session = DeviceSession(device: configured, kind: SoundcoreWorkIntegration().kind, connections: [connection], defaults: defaults)
        let page = ObservationCount { _ = session.device; _ = session.queue; _ = session.links; _ = session.state; _ = session.newRecordings }
        let strip = ObservationCount { _ = session.liveCaptions }
        defer { page.cancel(); strip.cancel() }
        for step in 1...5 {
            connection.live.captions = [LiveCaptionSegment(start: 0, end: Double(step), text: String(repeating: "word ", count: step),
                                                           isTentative: true)]
        }
        XCTAssertEqual(strip.count, 5)
        XCTAssertEqual(page.count, 0)
    }
}
