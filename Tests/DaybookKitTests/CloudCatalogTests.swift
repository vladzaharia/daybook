import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// The cloud catalog: the measured models and the family rules, OpenRouter's prices and the bundled snapshot, which
/// models are offered for what a key reaches, the recommendation per tier, and the estimates. No network.
final class CloudCatalogTests: XCTestCase {
    private let catalog = CloudCatalog.builtIn

    private func listed(_ ids: [String]) -> [CloudListedModel] { ids.map { CloudListedModel(id: $0) } }

    // MARK: The catalog

    func testBehaviorBuiltInCatalogPlacesEveryMeasuredModelInItsFamilyAndTier() throws {
        XCTAssertEqual(catalog.version, 1)
        XCTAssertEqual(Set(catalog.models.map(\.id)), ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "gpt-6-astra",
                                                       "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna"])
        for model in catalog.models {
            let name = try XCTUnwrap(catalog.name(model.id, provider: model.provider), model.id)
            XCTAssertEqual(name.family.tier, model.tier, model.id)
            XCTAssertEqual(name.displayName, model.name, "A model's family names it as the catalog does: \(model.id)")
            if let quality = model.summaryQuality { XCTAssertTrue((0...100).contains(quality), model.id) }
        }
        for tier in CloudTier.allCases {
            let ranks = catalog.models.filter { $0.tier == tier }.map(\.rank)
            XCTAssertEqual(Set(ranks).count, ranks.count, "Ranks are unique within \(tier)")
        }
        // The plan's initial ranking.
        func first(_ tier: CloudTier) -> String? { catalog.models.filter { $0.tier == tier }.min { $0.rank < $1.rank }?.id }
        XCTAssertEqual(first(.best), "claude-opus-5-5")
        XCTAssertEqual(first(.balanced), "claude-sonnet-5-5")
        XCTAssertEqual(first(.economy), "claude-haiku-5-5")
    }

    func testBehaviorBundledSnapshotPricesEveryCatalogModelWithItsLongPromptRates() throws {
        let book = CloudPriceBook.snapshot
        XCTAssertNil(book.fetchedAt)
        XCTAssertFalse(book.models.keys.contains { $0.contains(":") }, "Batch listings are left out")
        XCTAssertFalse(book.models.keys.contains { !$0.hasPrefix("anthropic/") && !$0.hasPrefix("openai/") })
        for model in catalog.models {
            let id = try XCTUnwrap(catalog.name(model.id, provider: model.provider)).openRouterID
            XCTAssertNotNil(book[id]?.price, "\(id) has a price")
        }
        let sonnet = try XCTUnwrap(book["anthropic/claude-sonnet-5.5"]?.price)
        XCTAssertEqual(sonnet.input, 2, accuracy: 1e-9)
        XCTAssertEqual(sonnet.output, 10, accuracy: 1e-9)
        XCTAssertTrue(sonnet.longPrompts.isEmpty)
        let haiku = try XCTUnwrap(book["anthropic/claude-haiku-5.5"]?.price)
        XCTAssertEqual(haiku.input, 0.1, accuracy: 1e-9)
        XCTAssertEqual(haiku.longPrompts, [CloudPrice.LongPrompt(aboveInputTokens: 100_000, input: 0.5, output: 2.5)])
        let sol = try XCTUnwrap(book["openai/gpt-6.1-sol"]?.price)
        XCTAssertEqual(sol.longPrompts, [CloudPrice.LongPrompt(aboveInputTokens: 272_000, input: 4, output: 15)])
        XCTAssertEqual(book["openai/gpt-6.1-sol"]?.efforts, ["max", "xhigh", "high", "medium", "low"])
        XCTAssertEqual(book["anthropic/claude-sonnet-5.5"]?.maxOutputTokens, 128_000)
        XCTAssertEqual(book["anthropic/claude-sonnet-5.5"]?.name, "Claude Sonnet 5.5", "OpenRouter's \"Anthropic: \" prefix goes")
    }

    func testBehaviorLongPromptsPayTheHigherRate() throws {
        let haiku = try XCTUnwrap(CloudPriceBook.snapshot["anthropic/claude-haiku-5.5"]?.price)
        XCTAssertEqual(haiku.cost(inputTokens: 100_000, outputTokens: 10_000), (100_000 * 0.1 + 10_000 * 0.5) / 1e6, accuracy: 1e-12)
        XCTAssertEqual(haiku.cost(inputTokens: 150_000, outputTokens: 10_000), (150_000 * 0.5 + 10_000 * 2.5) / 1e6, accuracy: 1e-12)
    }

    // MARK: Family rules

    func testBehaviorNameRulesPlaceModelsByFamilyAndSkipEverythingElse() throws {
        let opus = try XCTUnwrap(catalog.name("claude-opus-6", provider: .anthropic))
        XCTAssertEqual(opus.family.tier, .best)
        XCTAssertEqual(opus.version, [6])
        XCTAssertEqual(opus.displayName, "Claude Opus 6")
        let dated = try XCTUnwrap(catalog.name("claude-haiku-4-5-20251001", provider: .anthropic))
        XCTAssertEqual(dated.version, [4, 5])
        XCTAssertEqual(dated.date, "20251001")
        XCTAssertEqual(dated.alias, "claude-haiku-4-5")
        XCTAssertEqual(dated.openRouterID, "anthropic/claude-haiku-4.5")
        let pro = try XCTUnwrap(catalog.name("gpt-6.1-sol-pro", provider: .openai))
        XCTAssertTrue(pro.isPro)
        XCTAssertEqual(pro.family.tier, .balanced)
        XCTAssertEqual(pro.displayName, "GPT-6.1 Sol Pro")
        XCTAssertEqual(pro.openRouterID, "openai/gpt-6.1-sol-pro")
        XCTAssertEqual(catalog.name("gpt-7-astra", provider: .openai)?.family.tier, .best)
        XCTAssertEqual(catalog.name("gpt-6-luna", provider: .openai)?.family.tier, .economy)
        XCTAssertEqual(catalog.name("gpt-6.1-sol-2026-09-29", provider: .openai)?.alias, "gpt-6.1-sol")
        XCTAssertEqual(catalog.name("claude-sonnet-5-5", provider: .anthropic)?.openRouterID, "anthropic/claude-sonnet-5.5")
        for other in ["claude-fable-5-1", "claude-3-haiku-20240307", "gpt-4o", "gpt-5.4-mini", "o3", "gpt-6.1-sol-mini", "text-embedding-3-large",
                      "gpt-6.1-sol:batch", "claude-sonnet-latest"] {
            XCTAssertNil(catalog.name(other, provider: other.hasPrefix("claude") ? .anthropic : .openai), "\(other) isn't offered")
        }
        XCTAssertNil(catalog.name("claude-sonnet-5-5", provider: .openai), "A family belongs to one provider")
    }

    // MARK: Offers

    func testBehaviorOffersKeepMeasuredModelsAndNewerVersionsOnly() throws {
        let offers = catalog.offers(listings: [.anthropic: listed(["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-sonnet-4-6",
                                                                   "claude-haiku-4-5-20251001", "claude-fable-5-1", "claude-sonnet-6"])],
                                    prices: .snapshot)
        XCTAssertEqual(offers.map(\.id), ["claude-opus-5-5", "claude-sonnet-5-5", "claude-sonnet-6", "claude-haiku-5-5"])
        let future = try XCTUnwrap(offers.offer("claude-sonnet-6"))
        XCTAssertTrue(future.model.priceIsEstimated, "OpenRouter doesn't list it: its family's newest price, estimated")
        XCTAssertEqual(future.model.inputPrice, 2)
        XCTAssertEqual(future.model.name, "Claude Sonnet 6")
        XCTAssertEqual(future.model.tier, .balanced)
        XCTAssertEqual(future.model.rank, 2, "Unmeasured, after the measured")
        XCTAssertNil(future.summaryQuality)
        let sonnet = try XCTUnwrap(offers.offer("claude-sonnet-5-5"))
        XCTAssertFalse(sonnet.model.priceIsEstimated)
        XCTAssertEqual(sonnet.summaryQuality, 94)
        XCTAssertTrue(sonnet.refusalFallback)
        XCTAssertEqual(sonnet.maxOutputTokens, 128_000)
        XCTAssertEqual(sonnet.model.contextTokens, 1_000_000)
    }

    func testBehaviorANewerModelOpenRouterListsTakesItsOwnPrice() throws {
        var book = CloudPriceBook.snapshot
        book.models["anthropic/claude-sonnet-6"] = OpenRouterModel(id: "anthropic/claude-sonnet-6", name: "Claude Sonnet 6",
                                                                   price: CloudPrice(input: 2.5, output: 12), efforts: ["low", "high"])
        let offer = try XCTUnwrap(catalog.offers(listings: [.anthropic: listed(["claude-sonnet-6"])], prices: book).first)
        XCTAssertFalse(offer.model.priceIsEstimated)
        XCTAssertEqual(offer.model.inputPrice, 2.5)
        XCTAssertEqual(offer.efforts, [.low, .high], "Only the efforts the model takes")
        XCTAssertEqual(offer.effort(.medium), .high, "The nearest it takes")
    }

    func testBehaviorProVariantsAreTheirOwnModelsOnlyWhenTheProviderListsThem() {
        let offers = catalog.offers(listings: [.openai: listed(["gpt-6.1-sol", "gpt-6.1-sol-pro", "gpt-6-sol-pro", "gpt-6.1-sol-2026-09-29",
                                                                "gpt-6.1-terra", "gpt-6-luna", "gpt-6-astra", "gpt-5.5", "gpt-chat-latest"])],
                                    prices: .snapshot)
        XCTAssertEqual(offers.map(\.id), ["gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-sol-pro", "gpt-6.1-terra", "gpt-6-luna"])
        XCTAssertEqual(offers.offer("gpt-6.1-sol-pro")?.model.name, "GPT-6.1 Sol Pro")
        XCTAssertEqual(offers.offer("gpt-6.1-sol-pro")?.efforts, [.low, .medium, .high])
        let alone = catalog.offers(listings: [.openai: listed(["gpt-6.1-sol-2026-09-29"])], prices: .snapshot)
        XCTAssertEqual(alone.map(\.id), ["gpt-6.1-sol-2026-09-29"], "A dated snapshot without its alias stands for it")
        XCTAssertEqual(alone.first?.model.name, "GPT-6.1 Sol")
        XCTAssertEqual(alone.first?.model.rank, 2)
    }

    func testBehaviorAModelWithNoPriceAnywhereIsNotOffered() {
        let empty = CloudPriceBook()
        XCTAssertTrue(catalog.offers(listings: [.anthropic: listed(["claude-sonnet-5-5", "claude-sonnet-6"])], prices: empty).isEmpty)
    }

    func testBehaviorRecommendationFollowsTheTierAndAChosenModelFallsBackWhenGone() {
        let both = catalog.offers(listings: [.anthropic: listed(["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]),
                                             .openai: listed(["gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna"])], prices: .snapshot)
        var preferences = CloudSummaryPreferences()
        XCTAssertEqual(preferences.tier, .balanced)
        XCTAssertEqual(both.resolve(preferences)?.id, "claude-sonnet-5-5")
        preferences.tier = .economy
        XCTAssertEqual(both.resolve(preferences)?.id, "claude-haiku-5-5")
        preferences.model = "gpt-6.1-terra"
        XCTAssertEqual(both.resolve(preferences)?.id, "gpt-6.1-terra", "A chosen model wins while a key reaches it")

        let openAIOnly = both.filter { $0.model.provider == .openai }
        preferences.model = "claude-haiku-5-5"
        XCTAssertEqual(openAIOnly.resolve(preferences)?.id, "gpt-6.1-terra", "Gone: the tier's recommendation")
        preferences = CloudSummaryPreferences()
        XCTAssertEqual(openAIOnly.resolve(preferences)?.id, "gpt-6.1-sol")

        let economyOnly = both.filter { $0.model.tier == .economy }
        preferences.tier = .best
        XCTAssertEqual(economyOnly.resolve(preferences)?.id, "claude-haiku-5-5", "A tier with nothing offered: the nearest one's")
        XCTAssertNil([CloudOffer]().resolve(preferences))
    }

    // MARK: Estimates

    func testBehaviorOutputEstimatesFollowTheMeasuredRuns() {
        XCTAssertEqual(catalog.expectedOutputTokens("claude-sonnet-5-5", provider: .anthropic, minutes: 60, effort: .medium), 4_875)
        XCTAssertEqual(catalog.expectedOutputTokens("claude-sonnet-5-5", provider: .anthropic, minutes: 186, effort: .medium), 10_434)
        XCTAssertEqual(catalog.expectedOutputTokens("claude-sonnet-5-5", provider: .anthropic, minutes: 90, effort: .medium), (4_875 + 10_917) / 2)
        XCTAssertEqual(catalog.expectedOutputTokens("claude-sonnet-5-5", provider: .anthropic, minutes: 372, effort: .medium), 20_868,
                       "Longer than measured: the longest run's rate")
        XCTAssertEqual(catalog.expectedOutputTokens("claude-sonnet-5-5", provider: .anthropic, minutes: 60, effort: .high), Int((4_875 * 1.72).rounded()))
        XCTAssertEqual(catalog.expectedOutputTokens("claude-sonnet-6", provider: .anthropic, minutes: 60, effort: .medium), 4_875,
                       "A newer version: its family's measurements")
        XCTAssertEqual(catalog.expectedOutputTokens("gpt-6-luna", provider: .openai, minutes: 60, effort: .medium), 80 * 60,
                       "Unmeasured, with no measured family: the provider's rate")
        XCTAssertGreaterThanOrEqual(catalog.expectedOutputTokens("claude-haiku-5-5", provider: .anthropic, minutes: 1, effort: .low), 500)
    }

    func testBehaviorCostPerHourIsNearTheMeasuredHour() throws {
        // Measured on an hour at medium (docs/validation.md, 2026-10-31): Sonnet $0.0885, Sol $0.0798, Haiku $0.0077.
        let offers = catalog.offers(listings: [.anthropic: listed(["claude-sonnet-5-5", "claude-haiku-5-5"]),
                                               .openai: listed(["gpt-6.1-sol"])], prices: .snapshot)
        for (id, measured) in [("claude-sonnet-5-5", 0.0885), ("gpt-6.1-sol", 0.0798), ("claude-haiku-5-5", 0.0077)] {
            let estimate = try XCTUnwrap(offers.offer(id)?.estimatedCost(minutes: 60, effort: .medium))
            XCTAssertEqual(estimate, measured, accuracy: measured * 0.25, "\(id): \(estimate)")
        }
    }

    func testBehaviorCostsReadPlainly() {
        XCTAssertEqual(CloudCost.perHour(0.0885), "About $0.09 an hour")
        XCTAssertEqual(CloudCost.perHour(0.004), "Under $0.01 an hour")
        XCTAssertEqual(CloudCost.perHour(1.234), "About $1.23 an hour")
        XCTAssertNil(CloudCost.perHour(nil))
    }
}
