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
        let rig = try await MultiSourceRig.make()
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
}
