import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// The iPhone's processing models per memory tier, from the catalog's iOS lists (docs/models.md,
/// "iPhone processing"): Parakeet Ultra, or Redux on the smallest phones; Nemotron 3 and Community-1
/// for speakers; a Gemma 4 summary model only where its measured peak fits in what iOS lets the app use.
final class PhoneProcessingModelsTests: XCTestCase {
    private let catalog = ModelCatalog.builtIn
    private let gib: UInt64 = 1_073_741_824

    /// What iPhones report: a little under their marketed memory.
    private let fourGB: UInt64 = 3_900_000_000, sixGB: UInt64 = 6_000_000_000, eightGB: UInt64 = 8_050_000_000
    private let twelveGB: UInt64 = 12_000_000_000

    private func limit(_ physical: UInt64, increased: Bool) -> UInt64 {
        AppMemoryLimit.estimate(physicalMemory: physical, increasedLimit: increased)
    }

    func testBehaviorTiersFollowThePhonesMemory() {
        XCTAssertEqual(PhoneTier(physicalMemory: fourGB), .small)
        XCTAssertEqual(PhoneTier(physicalMemory: sixGB), .medium)
        XCTAssertEqual(PhoneTier(physicalMemory: eightGB), .standard)
        XCTAssertEqual(PhoneTier(physicalMemory: twelveGB), .large)
        XCTAssertEqual(PhoneTier(physicalMemory: 16 * gib), .large)
    }

    func testBehaviorTranscriptionIsUltraAndReduxOnTheSmallestPhones() {
        XCTAssertEqual(PhoneProcessingModels.defaults(for: .transcription, tier: .small, catalog: catalog), ["parakeet/redux", "parakeet/ultra"])
        for tier in [PhoneTier.medium, .standard, .large] {
            XCTAssertEqual(PhoneProcessingModels.defaults(for: .transcription, tier: tier, catalog: catalog).first, "parakeet/ultra", "\(tier)")
        }
        XCTAssertEqual(PhoneProcessingModels.options(for: .transcription, catalog: catalog), ["parakeet/ultra", "parakeet/redux"])
    }

    func testBehaviorSpeakersAreNemotronWithCommunityOnesVoiceProfiles() {
        XCTAssertEqual(PhoneProcessingModels.defaults(for: .diarization, tier: .small, catalog: catalog).first, "nemotron-3-diarization/compact")
        XCTAssertEqual(PhoneProcessingModels.defaults(for: .diarization, tier: .medium, catalog: catalog).first, "nemotron-3-diarization/compact")
        XCTAssertEqual(PhoneProcessingModels.defaults(for: .diarization, tier: .standard, catalog: catalog).first, "nemotron-3-diarization/offline")
        XCTAssertEqual(PhoneProcessingModels.defaults(for: .diarization, tier: .large, catalog: catalog),
                       ["nemotron-3-diarization/offline", "nemotron-3-diarization/compact", "community-1/offline"])
        for tier in PhoneTier.allCases {
            XCTAssertEqual(PhoneProcessingModels.defaults(for: .speakerEmbedding, tier: tier, catalog: catalog), ["community-1/offline"])
        }
    }

    func testBehaviorSummariesOnlyWhereTheModelFitsInTheAppsMemory() {
        func summary(_ physical: UInt64, increased: Bool) -> String? {
            PhoneProcessingModels.choice(for: .summarization, selections: ModelSelections(), tier: PhoneTier(physicalMemory: physical),
                                         memoryLimit: limit(physical, increased: increased), catalog: catalog)
        }
        // 4 and 6 GB iPhones: no summary model is listed.
        XCTAssertNil(summary(fourGB, increased: true))
        XCTAssertNil(summary(sixGB, increased: true))
        // 8 GB: E2B (3.2 GB at its peak, and 1 GB for the app) fits only with the Increased Memory Limit entitlement.
        XCTAssertNil(summary(eightGB, increased: false))
        XCTAssertEqual(summary(eightGB, increased: true), "gemma-4/e2b-4bit")
        // 12 GB: E2B without the entitlement, E4B (5.0 GB) with it.
        XCTAssertEqual(summary(twelveGB, increased: false), "gemma-4/e2b-4bit")
        XCTAssertEqual(summary(twelveGB, increased: true), "gemma-4/e4b-4bit")
        XCTAssertEqual(PhoneProcessingModels.options(for: .summarization, catalog: catalog), ["gemma-4/e4b-4bit", "gemma-4/e2b-4bit"])
    }

    func testBehaviorAChoiceThatDoesntFitFallsBackToOneThatDoes() {
        let chosen = ModelSelections([.summarization: "gemma-4/e4b-4bit", .transcription: "parakeet/redux"])
        let large = PhoneTier(physicalMemory: twelveGB)
        XCTAssertEqual(PhoneProcessingModels.choice(for: .summarization, selections: chosen, tier: large,
                                                    memoryLimit: limit(twelveGB, increased: false), catalog: catalog), "gemma-4/e2b-4bit")
        XCTAssertEqual(PhoneProcessingModels.choice(for: .summarization, selections: chosen, tier: large,
                                                    memoryLimit: limit(twelveGB, increased: true), catalog: catalog), "gemma-4/e4b-4bit")
        XCTAssertEqual(PhoneProcessingModels.choice(for: .transcription, selections: chosen, tier: large, memoryLimit: 0, catalog: catalog),
                       "parakeet/redux", "the person's choice stands")
        // A model the catalog lists for another role isn't taken for this one.
        let wrong = ModelSelections([.transcription: "gemma-4/e2b-4bit"])
        XCTAssertEqual(PhoneProcessingModels.choice(for: .transcription, selections: wrong, tier: large, memoryLimit: 0, catalog: catalog),
                       "parakeet/ultra")
    }

    func testBehaviorMeasuredPeaksDecideWhatFits() throws {
        let e2b = try XCTUnwrap(catalog.model("gemma-4/e2b-4bit")), e4b = try XCTUnwrap(catalog.model("gemma-4/e4b-4bit"))
        XCTAssertEqual(e2b.capabilities.memoryGB, 3.2)
        XCTAssertEqual(e4b.capabilities.memoryGB, 5.0)
        XCTAssertTrue(PhoneProcessingModels.fits(e2b, memoryLimit: 4_250_000_000), "the peak and a gigabyte for the app")
        XCTAssertFalse(PhoneProcessingModels.fits(e2b, memoryLimit: 4_150_000_000))
        XCTAssertFalse(PhoneProcessingModels.fits(e4b, memoryLimit: 5_950_000_000))
        XCTAssertTrue(PhoneProcessingModels.fits(e4b, memoryLimit: 6_050_000_000))
    }

    func testBehaviorTheMacsChoicesDontChange() {
        // The iPhone's lists are its platform's: a Mac's first launch and presets read as before.
        XCTAssertEqual(ModelRecommendations.initialSelections(for: .compact, catalog: catalog)[.summarization], "gemma-4/e2b-4bit")
        XCTAssertEqual(ModelRecommendations.initialSelections(for: .standard, catalog: catalog)[.diarization], "community-1/offline")
        XCTAssertEqual(ModelRecommendations.initialSelections(for: .compact, catalog: catalog)[.transcription], "parakeet/ultra")
    }

    func testBehaviorPlatformTiersRoundTripAndOverrideThePlatformsList() throws {
        let table = ModelChoiceTable(roles: ["transcription": ["a"]], platforms: ["iOS": ["transcription": ["b"], "summarization": []]],
                                     platformTiers: ["iOS": ["small": ["transcription": ["c"]]]])
        XCTAssertEqual(table.choices(for: .transcription, platform: .iOS, platformTier: "small"), ["c"])
        XCTAssertEqual(table.choices(for: .transcription, platform: .iOS, platformTier: "large"), ["b"])
        XCTAssertEqual(table.choices(for: .summarization, platform: .iOS, platformTier: "large"), [], "an empty list means none")
        XCTAssertEqual(table.choices(for: .transcription, platform: .macOS, platformTier: "large"), ["a"])
        XCTAssertEqual(table.choices(for: .transcription, tier: "compact"), ["a"], "a Mac's tiers ignore the iPhone's")
        let manifest = ModelManifest(initialSelection: table)
        let read = try ModelManifestReader.read(ModelManifestReader.encode(manifest)).manifest
        XCTAssertEqual(read.initialSelection, table, "round trips")
    }
}
