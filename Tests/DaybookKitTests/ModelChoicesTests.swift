import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// What Settings › Models says on both apps (`ModelChoices.swift`): a model's state, a role's line and what it offers,
/// the space a download needs, the row that downloads what's chosen, what removing does, and the order a preset names
/// its models in.
final class ModelChoicesTests: XCTestCase {
    private let catalog = ModelCatalog.builtIn

    private func model(_ key: String) throws -> CatalogModel { try XCTUnwrap(catalog.model(key)) }

    private func choice(_ key: String, status: ModelStatus?, downloadBytes: Int64? = nil) throws -> ModelRoleChoice {
        let model = try model(key)
        return ModelRoleChoice(role: .transcription, selection: key,
                               options: [ModelOption(key: key, name: model.name, detail: ModelOption.detail(for: model, status: status ?? .notDownloaded),
                                                     isEnabled: true)],
                               selectedModel: model, status: status, downloadBytes: downloadBytes)
    }

    func testBehaviorEachStateIsWordedOnceForBothApps() {
        XCTAssertEqual(ModelStatus.notDownloaded.label, "Not downloaded")
        XCTAssertEqual(ModelStatus.waitingForWiFi.label, "Waiting for Wi‑Fi")
        XCTAssertEqual(ModelStatus.downloading(0.419).label, "Downloading · 41%", "whole percents, rounded down")
        XCTAssertEqual(ModelStatus.downloading(.nan).label, "Downloading · 0%")
        XCTAssertEqual(ModelStatus.damaged.label, "Needs downloading again")
        XCTAssertEqual(ModelStatus.failed("You’re offline.").label, "You’re offline.")
        XCTAssertEqual(ModelStatus.builtIn.label, "Included with macOS")
        XCTAssertTrue(ModelStatus.waitingForWiFi.isTransferring)
        XCTAssertTrue(ModelStatus.failed("x").canDownload)
        XCTAssertTrue(ModelStatus.failed("x").needsAttention)
        XCTAssertFalse(ModelStatus.inUse.needsAttention)
    }

    func testBehaviorOnlyAFinishedDownloadEarnsTheCheckmark() {
        XCTAssertTrue(ModelStatus.finishedDownloading(from: .downloading(0.9), to: .downloaded))
        XCTAssertTrue(ModelStatus.finishedDownloading(from: .waiting, to: .inUse), "a quick download can finish between reports")
        XCTAssertFalse(ModelStatus.finishedDownloading(from: .downloading(0.4), to: .notDownloaded), "cancelled")
        XCTAssertFalse(ModelStatus.finishedDownloading(from: .downloading(0.4), to: .failed("offline")))
        XCTAssertFalse(ModelStatus.finishedDownloading(from: .downloaded, to: .inUse), "chosen for a role")
        XCTAssertFalse(ModelStatus.finishedDownloading(from: nil, to: .downloaded))
    }

    /// A role's row shows its checkmark (and the iPhone plays its haptic) only when the chosen model's own download
    /// finished: choosing a model that's already here, away from one still downloading or waiting, isn't one.
    func testBehaviorChoosingADownloadedModelMidDownloadEarnsNoCheckmark() throws {
        let downloading = try choice("parakeet/ultra", status: .downloading(0.4)).standing
        XCTAssertTrue(ModelRoleChoice.finishedDownloading(from: downloading, to: try choice("parakeet/ultra", status: .inUse).standing))
        XCTAssertTrue(ModelRoleChoice.finishedDownloading(from: try choice("parakeet/ultra", status: .waiting).standing,
                                                          to: try choice("parakeet/ultra", status: .downloaded).standing))
        let other = try XCTUnwrap(catalog.models(for: .transcription).first { $0.key != "parakeet/ultra" && !$0.isSystemModel })
        XCTAssertFalse(ModelRoleChoice.finishedDownloading(from: downloading, to: try choice(other.key, status: .inUse).standing),
                       "the Mac: another model chosen, already here")
        XCTAssertFalse(ModelRoleChoice.finishedDownloading(from: try choice("parakeet/ultra", status: .waitingForWiFi).standing,
                                                           to: try choice(other.key, status: .downloaded).standing),
                       "the iPhone: another model chosen while the first waits for Wi‑Fi")
    }

    func testBehaviorARolesLineSpeaksOnlyWhenTheModelIsntReady() throws {
        let parakeet = try model("parakeet/ultra")
        XCTAssertEqual(try choice("parakeet/ultra", status: .notDownloaded).line(), ModelLine("Not downloaded · \(ByteSize.format(parakeet.approximateBytes))"))
        XCTAssertEqual(try choice("parakeet/ultra", status: .notDownloaded, downloadBytes: 132_000_000).line()?.text, "Not downloaded · 132 MB",
                       "what an unfinished download still needs")
        XCTAssertEqual(try choice("parakeet/ultra", status: .downloading(0.4)).line(), ModelLine("Downloading · 40%"))
        XCTAssertEqual(try choice("parakeet/ultra", status: .damaged).line(), ModelLine("Needs downloading again", needsAttention: true))
        XCTAssertEqual(try choice("parakeet/ultra", status: .failed("You’re offline.")).line(), ModelLine("You’re offline.", needsAttention: true))
        XCTAssertNil(try choice("parakeet/ultra", status: .downloaded).line())
        XCTAssertNil(try choice("parakeet/ultra", status: .inUse).line())
        let unlisted = ModelRoleChoice(role: .transcription, selection: "gone/model", options: [], selectedModel: nil, status: nil)
        XCTAssertEqual(unlisted.line(), ModelLine("No longer available", needsAttention: true))
        XCTAssertFalse(unlisted.canDownload())
        XCTAssertEqual(ModelRoleChoice(role: .summarization, selection: nil, options: [], selectedModel: nil, status: nil).line(),
                       ModelLine("Choose a model"))
        XCTAssertEqual(try choice("parakeet/ultra", status: .downloaded).title, "Transcription")
    }

    func testBehaviorADownloadThatWouldntFitSaysWhatItNeedsAndWaits() throws {
        let space = ModelSpace(free: 300_000_000)
        let tooBig = try choice("parakeet/ultra", status: .notDownloaded, downloadBytes: 632_000_000)
        XCTAssertEqual(tooBig.line(space: space), ModelLine("Needs 632 MB · 300 MB free", needsAttention: true))
        XCTAssertFalse(tooBig.canDownload(space: space))
        XCTAssertTrue(tooBig.canDownload(space: ModelSpace(free: 632_000_000)), "exactly enough fits")
        XCTAssertTrue(tooBig.canDownload(space: .unknown), "when the system doesn't say, nothing waits")
        XCTAssertNil(ModelSpace(free: 12_000_000_000).shortfall(7_400_000_000))
        XCTAssertEqual(ModelSpace(free: 12_000_000_000).shortfall(16_500_000_000), "Needs 16.5 GB · 12.0 GB free")
        XCTAssertNotNil(ModelSpace.available(at: FileManager.default.temporaryDirectory.appendingPathComponent("Not-there-\(UUID())/Models")).free,
                        "read from the nearest folder that exists")
    }

    /// What's free for another download sets aside what those already asked for will still take: a download under way
    /// counts its size less what it had fetched when the space was read, by its partial files or its progress.
    func testBehaviorWhatsFreeSetsAsideWhatsOnItsWay() {
        XCTAssertEqual(ModelSpace(free: 10_000_000_000).less(8_000_000_000), ModelSpace(free: 2_000_000_000))
        XCTAssertEqual(ModelSpace(free: 1_000_000_000).less(3_000_000_000), ModelSpace(free: 0), "never below nothing")
        XCTAssertEqual(ModelSpace.unknown.less(3_000_000_000), .unknown, "when the system doesn't say, nothing waits")
        XCTAssertFalse(ModelSpace(free: 10_000_000_000).less(8_000_000_000).fits(5_000_000_000), "8 GB on its way, then 5 GB more")
        XCTAssertEqual(ModelSpace.stillToFetch(1_600_000_000), 1_600_000_000)
        XCTAssertEqual(ModelSpace.stillToFetch(1_600_000_000, partial: 600_000_000), 1_000_000_000)
        XCTAssertEqual(ModelSpace.stillToFetch(1_600_000_000, partial: 200_000_000, fraction: 0.5), 800_000_000, "a file still arriving")
        XCTAssertEqual(ModelSpace.stillToFetch(1_600_000_000, fraction: .nan), 1_600_000_000)
        XCTAssertEqual(ModelSpace.stillToFetch(1_600_000_000, partial: 2_000_000_000), 0)
    }

    func testBehaviorTheDownloadRowSaysWhatsLeftThenHowFarItsGot() {
        let all = ModelDownloadSummary.missing(names: ["Parakeet Ultra", "Community-1"], bytes: 654_000_000, rest: .nothing)
        XCTAssertEqual(all.title, "Not downloaded yet")
        XCTAssertEqual(all.line(), ModelLine("654 MB"))
        let some = ModelDownloadSummary.missing(names: ["Community-1"], bytes: 22_000_000, rest: .here)
        XCTAssertEqual(some.title, "Partly downloaded")
        XCTAssertEqual(some.line(), ModelLine("Community-1 · 22 MB"))
        let beside = ModelDownloadSummary.missing(names: ["Community-1"], bytes: 22_000_000, rest: .onItsWay)
        XCTAssertEqual(beside.title, "Not downloaded yet", "nothing is here yet")
        XCTAssertEqual(beside.line(), ModelLine("Community-1 · 22 MB"), "what's left, by name")
        XCTAssertEqual(all.line(space: ModelSpace(free: 100_000_000)), ModelLine("Needs 654 MB · 100 MB free", needsAttention: true))
        XCTAssertFalse(all.canDownload(space: ModelSpace(free: 100_000_000)))
        let going = ModelDownloadSummary.downloading(done: 400_000_000, total: 1_600_000_000)
        XCTAssertEqual(going.title, "Downloading")
        XCTAssertEqual(going.line(), ModelLine("0.4 of 1.6 GB"))
        XCTAssertEqual(going.fraction, 0.25, accuracy: 1e-9)
        XCTAssertFalse(going.canDownload())
    }

    /// Asked for, with none of it arriving yet: the row says what it waits for, as each role's row does, with what it
    /// will download and no bar.
    func testBehaviorTheDownloadRowSaysWhatItWaitsFor() {
        let wifi = ModelDownloadSummary.waiting(bytes: 853_000_000, forWiFi: true)
        XCTAssertEqual(wifi.title, "Waiting for Wi‑Fi")
        XCTAssertEqual(wifi.title, ModelStatus.waitingForWiFi.label)
        XCTAssertEqual(wifi.line(), ModelLine("853 MB"))
        XCTAssertEqual(wifi.fraction, 0)
        XCTAssertFalse(wifi.canDownload())
        let queued = ModelDownloadSummary.waiting(bytes: 1_600_000_000, forWiFi: false)
        XCTAssertEqual(queued.title, "Waiting to download")
        XCTAssertEqual(queued.line(space: ModelSpace(free: 0)), ModelLine("1.6 GB"), "already asked for: nothing to say about room")
    }

    /// Both apps add their chosen models up the same way: what's left first, then how far it's got, or what it waits
    /// for while none of it is arriving. "Partly downloaded" only once something is here.
    func testBehaviorTheDownloadRowAddsUpTheChosenModels() {
        typealias Item = ModelDownloadSummary.Item
        func items(_ statuses: ModelStatus...) -> [Item] {
            zip(["Parakeet Ultra", "Community-1", "Gemma"], statuses).map { Item(name: $0, status: $1, bytes: 600_000_000) }
        }
        XCTAssertEqual(ModelDownloadSummary(chosen: items(.notDownloaded, .notDownloaded, .failed("offline"))),
                       .missing(names: ["Parakeet Ultra", "Community-1", "Gemma"], bytes: 1_800_000_000, rest: .nothing))
        let beside = ModelDownloadSummary(chosen: items(.downloading(0.4), .notDownloaded, .notDownloaded))
        XCTAssertEqual(beside, .missing(names: ["Community-1", "Gemma"], bytes: 1_200_000_000, rest: .onItsWay),
                       "one on its way and none here: not partly downloaded")
        XCTAssertEqual(beside?.title, "Not downloaded yet")
        XCTAssertEqual(beside?.line(), ModelLine("Community-1, Gemma · 1.2 GB"))
        XCTAssertEqual(ModelDownloadSummary(chosen: items(.waitingForWiFi, .damaged, .notDownloaded)),
                       .missing(names: ["Community-1", "Gemma"], bytes: 1_200_000_000, rest: .onItsWay))
        XCTAssertEqual(ModelDownloadSummary(chosen: items(.downloading(0.4), .inUse, .notDownloaded))?.title, "Partly downloaded")
        XCTAssertEqual(ModelDownloadSummary(chosen: items(.unavailable("Needs a newer Daybook"), .notDownloaded)),
                       .missing(names: ["Community-1"], bytes: 600_000_000, rest: .nothing), "a model that can't run here isn't counted")

        XCTAssertEqual(ModelDownloadSummary(chosen: items(.waitingForWiFi, .waitingForWiFi, .waitingForWiFi)),
                       .waiting(bytes: 1_800_000_000, forWiFi: true))
        XCTAssertEqual(ModelDownloadSummary(chosen: [Item(name: "Parakeet Ultra", status: .downloaded, bytes: 600_000_000),
                                                     Item(name: "Community-1", status: .waitingForWiFi, bytes: 600_000_000, stillToFetch: 250_000_000)]),
                       .waiting(bytes: 250_000_000, forWiFi: true), "what's still to come, not how much is here")
        XCTAssertEqual(ModelDownloadSummary(chosen: items(.waiting, .waiting))?.title, "Waiting to download",
                       "the Mac's: behind another model's download")
        XCTAssertEqual(ModelDownloadSummary(chosen: items(.waiting, .waitingForWiFi))?.title, "Waiting to download")

        XCTAssertEqual(ModelDownloadSummary(chosen: items(.downloading(0.5), .waiting, .downloaded)),
                       .downloading(done: 900_000_000, total: 1_800_000_000))
        XCTAssertEqual(ModelDownloadSummary(chosen: items(.downloading(.nan), .waiting)), .downloading(done: 0, total: 1_200_000_000))
        XCTAssertNil(ModelDownloadSummary(chosen: items(.downloaded, .inUse, .builtIn)))
        XCTAssertNil(ModelDownloadSummary(chosen: []))
    }

    func testBehaviorRemovingSaysWhatItFreesAndWhatEachRoleDoes() {
        XCTAssertEqual(ModelRemovalWords.title("Whisper Base"), "Remove Whisper Base?")
        XCTAssertEqual(ModelRemovalWords.title("Qwen", removesEntry: true), "Remove Qwen from Daybook?")
        XCTAssertEqual(ModelRemovalWords.message(frees: 489_000_000, changes: [.switched(.transcription, to: "Whisper Small", onceDownloaded: false)]),
                       "Frees 489 MB. Transcription will use Whisper Small.")
        XCTAssertEqual(ModelRemovalWords.message(frees: 489_000_000, changes: [.waits(.diarization)]),
                       "Frees 489 MB. Speaker detection will wait until you download it again.")
        XCTAssertEqual(ModelRemovalWords.message(frees: 0, changes: [.switched(.summarization, to: "Gemma 4", onceDownloaded: true), .needsAnother(.smallTasks)],
                                                 removesEntry: true),
                       "Summaries will use Gemma 4, once it’s downloaded. Titles and tags will need another model.")
        XCTAssertEqual(ModelRemovalWords.message(frees: 22_000_000, changes: []), "Frees 22 MB. You can download it again at any time.")
    }

    func testBehaviorAPresetNamesWhatSetsItApartFirst() {
        let roles: [ModelRole] = [.transcription, .diarization, .speakerEmbedding, .summarization, .smallTasks]
        XCTAssertEqual(ModelQualityOption.ordered(roles, differing: [.summarization, .diarization]),
                       [.summarization, .diarization, .speakerEmbedding, .smallTasks, .transcription])
        XCTAssertEqual(ModelQualityOption.ordered(roles, differing: []).last, .transcription, "the model every preset shares goes last")
    }

    /// VoiceOver names the device a preset is recommended for (these tests run on the Mac).
    func testBehaviorTheRecommendedPresetNamesThisDevice() {
        XCTAssertEqual(ModelLabels.recommendedHint, "Recommended for this Mac")
    }

    func testBehaviorTheSystemsSpeechModelReadsAsBuiltInNeverNotDownloaded() throws {
        let speech = try model("apple-speech/system")
        XCTAssertEqual(ModelOption.detail(for: speech, status: .builtIn), "Included with macOS", "Its menu item, as Apple's other models read")
        let chosen = try choice("apple-speech/system", status: .builtIn)
        XCTAssertNil(chosen.line(), "Chosen, its row says nothing: it's ready")
        XCTAssertNil(chosen.line(space: ModelSpace(free: 0)), "Nothing to fit, even on a full disk")
        XCTAssertFalse(chosen.canDownload(), "Nothing to download")
        XCTAssertEqual(chosen.downloadBytes, 0)
        XCTAssertEqual(chosen.selectionName, "Apple Speech")
        XCTAssertNil(ModelDownloadSummary(chosen: [ModelDownloadSummary.Item(name: speech.name, status: .builtIn, bytes: speech.approximateBytes)]),
                     "It never asks for a download")
        XCTAssertEqual(ModelOption.detail(for: speech, status: .unavailable("Needs macOS 26 or later")), "Needs macOS 26 or later")
        XCTAssertEqual(ModelLabels.of(speech), [], "Built in: no license or origin label")
    }

    func testBehaviorAMenuItemSaysItsStateAndItsLicense() throws {
        let parakeet = try model("parakeet/ultra")
        XCTAssertEqual(ModelOption.detail(for: parakeet, status: .inUse), "Downloaded")
        XCTAssertEqual(ModelOption.detail(for: parakeet, status: .failed("offline")), ByteSize.format(parakeet.approximateBytes))
        XCTAssertEqual(ModelOption.detail(for: parakeet, status: .unavailable("Needs a newer Daybook")), "Needs a newer Daybook")
        if let nonCommercial = catalog.models.first(where: { $0.license?.allowsCommercialUse == false }) {
            XCTAssertTrue(ModelOption.detail(for: nonCommercial, status: .downloaded).hasSuffix(" · Non-commercial"))
            XCTAssertEqual(ModelLabels.of(nonCommercial).first, "Non-commercial")
        }
    }
}
