import DaybookCore
import XCTest
@testable import DaybookKit

final class SummarizeAgainChoicesTests: XCTestCase {
    private let cloud = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
                                   inputPrice: nil, outputPrice: nil, priceIsEstimated: false, contextTokens: nil, rank: 1)
    private let small = SummarizeAgainChoices.LocalModel(id: "gemma/e4b", name: "Gemma 4 E4B")
    private let big = SummarizeAgainChoices.LocalModel(id: "gemma/26b", name: "Gemma 4 26B A4B")

    private func work(_ placement: LibraryPlacement = .work) -> Meeting { Meeting(title: "Weekly", status: .ready, placement: placement) }

    private func rows(_ meeting: Meeting, local: [SummarizeAgainChoices.LocalModel] = [],
                      cloud: CloudModel?, _ preferences: CloudSummaryPreferences = .init()) -> [SummarizeAgainChoice] {
        SummarizeAgainChoices.rows(for: meeting, local: local, defaultLocal: "gemma/e4b", cloud: cloud, preferences: preferences)
    }

    func testBehaviorOrdersThisDeviceThenCloudWithTheDefaultFirst() {
        let all = rows(work(), local: [big, small], cloud: cloud)
        XCTAssertEqual(all.map(\.title), ["With Gemma 4 E4B", "With Gemma 4 26B A4B", "With Claude Sonnet 5.5"])
        XCTAssertEqual(all.first?.place, .thisDevice(model: "gemma/e4b"))
    }

    func testBehaviorOneOptionOnlyIsNotAMenu() {
        XCTAssertEqual(rows(work(), local: [small], cloud: nil).count, 1)
        XCTAssertEqual(rows(work(), cloud: nil).count, 0)
    }

    func testBehaviorTheCloudRowIsAbsentWithoutAKeyOrUnderNever() {
        XCTAssertFalse(rows(work(), local: [small], cloud: nil).contains { if case .cloud = $0.place { true } else { false } })
        var never = CloudSummaryPreferences()
        never.policy = .never
        XCTAssertEqual(rows(work(), local: [small], cloud: cloud, never).count, 1)
        XCTAssertEqual(rows(work(), local: [small], cloud: cloud).count, 2)
    }

    func testBehaviorThePlacementSwitchDecidesAndPersonalIsOffByDefault() {
        XCTAssertEqual(rows(work(.personal), local: [small], cloud: cloud).count, 1, "Personal is off until turned on")
        var on = CloudSummaryPreferences()
        on.placements.set(.personal, allowed: true)
        XCTAssertEqual(rows(work(.personal), local: [small], cloud: cloud, on).count, 2)
        var off = CloudSummaryPreferences()
        off.placements.set(.work, allowed: false)
        XCTAssertEqual(rows(work(), local: [small], cloud: cloud, off).count, 1)
    }

    func testBehaviorAnUnreadablePlacementSettingNeverGoes() throws {
        var unreadable = CloudSummaryPreferences()
        unreadable.placements = try JSONDecoder().decode(CloudPlacements.self, from: Data("[1]".utf8))
        XCTAssertEqual(rows(work(), local: [small], cloud: cloud, unreadable).count, 1)
    }

    func testBehaviorAModelNotInstalledIsNotOffered() {
        let titles = rows(work(), local: [small], cloud: cloud).map(\.title)
        XCTAssertFalse(titles.contains("With Gemma 4 26B A4B"))
    }

    func testBehaviorOnlyTheCloudRowCarriesAGlyph() {
        let all = rows(work(), local: [small, big], cloud: cloud)
        XCTAssertEqual(all.map(\.symbol), [nil, nil, "cloud"])
    }

    func testBehaviorTheRowOfTheModelThatWroteTheSummaryIsTheOneChecked() {
        let all = rows(work(), local: [small, big], cloud: cloud)
        let local = MeetingSummary(overview: "x", modelID: "gemma/26b")
        XCTAssertEqual(all.map { $0.wrote(local) }, [false, true, false])
        XCTAssertEqual(all.map { $0.wrote(nil) }, [false, false, false])
        let provenance = CloudProvenance(provider: .anthropic, model: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", effort: .medium,
                                         inputTokens: 1, outputTokens: 1, estimatedCost: nil)
        let sent = MeetingSummary(overview: "x", modelID: provenance.modelID, processingSettings: ProcessingSettings(
            modelID: provenance.modelID, parameters: provenance.parameters, model: provenance.modelProvenance))
        XCTAssertEqual(all.last?.wrote(sent), true)
        XCTAssertEqual(all.dropLast().map { $0.wrote(sent) }, [false, false], "a cloud summary names no local model")
    }
}
