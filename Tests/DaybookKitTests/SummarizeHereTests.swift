import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// "Summarize on This Mac" (or "on This iPhone") after the cloud couldn't: the summary runs on this device, even when
/// the person's preference is to always use the cloud.
@MainActor
final class SummarizeHereTests: XCTestCase {
    private let sonnet = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
                                    inputPrice: 2, outputPrice: 10, priceIsEstimated: false, contextTokens: nil, rank: 1)

    private func placements(canSummarize: Bool) -> SummaryPlacements {
        var always = CloudSummaryPreferences()
        always.policy = .always
        return SummaryPlacements(options: SummaryOptions(thisDeviceCanSummarize: canSummarize, reachableMacs: [], cloud: sonnet),
                                 preferences: always, waitsForMacs: false, runsTimer: false)
    }

    func testBehaviorSummarizeHereRunsOnThisDeviceWhateverTheCloudPreference() async {
        let id = UUID()
        let always = placements(canSummarize: true)
        XCTAssertEqual(always.begin(UUID(), immediately: true), .cloud(sonnet), "Always goes to the cloud on its own")
        XCTAssertEqual(always.beginHere(id), .thisDevice)
        // The job reaching its summary step finds it placed here.
        let place = await always.place(id, immediately: true)
        XCTAssertEqual(place, .thisDevice)
        // A change of options never moves a summary that started.
        always.update(options: SummaryOptions(thisDeviceCanSummarize: true, reachableMacs: [], cloud: sonnet))
        XCTAssertEqual(always[id]?.started, .thisDevice)
    }

    func testBehaviorADeviceThatCantSummarizePlacesNothingHere() {
        let id = UUID()
        let placements = placements(canSummarize: false)
        XCTAssertNil(placements.beginHere(id))
        XCTAssertNil(placements[id], "nothing placed: the status offers the Mac instead")
    }
}
