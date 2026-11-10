import AVFAudio
import DaybookKit
import DaybookLink
import DaybookUI
import XCTest
@testable import DaybookPhone

/// The iPhone's Welcome: when it opens over the app, and what its Allow page reads from the microphone permission.
@MainActor
final class PhoneWelcomeTests: XCTestCase {
    private func shows(completed: Bool = false, arguments: [String] = ["DaybookPhone"], isTestHost: Bool = false,
                       conversations: Bool = false, pairedMac: Bool = false) -> Bool {
        PhoneWelcome.shouldPresent(completed: completed, arguments: arguments, isTestHost: isTestHost,
                                   hasConversations: conversations, hasPairedMac: pairedMac)
    }

    func testBehaviorWelcomeOpensOnceOnAFirstLaunch() {
        XCTAssertTrue(shows())
        XCTAssertFalse(shows(completed: true), "Once")
        XCTAssertFalse(shows(isTestHost: true), "Hosted tests never see it")
    }

    /// Someone who used Daybook on this iPhone before Welcome existed isn't welcomed now.
    func testBehaviorSomeoneAlreadyAtHomeIsntWelcomed() {
        XCTAssertFalse(shows(conversations: true))
        XCTAssertFalse(shows(pairedMac: true))
    }

    /// Demos and screenshots launch with options: Welcome stays out of their way unless asked for.
    func testBehaviorALaunchWithOptionsSeesWelcomeOnlyWhenItAsks() {
        XCTAssertFalse(shows(arguments: ["DaybookPhone", "--library-demo"]))
        XCTAssertTrue(shows(arguments: ["DaybookPhone", "--library-demo", "--welcome"]))
        XCTAssertFalse(shows(completed: true, arguments: ["DaybookPhone", "--welcome"]), "Done is done")
    }

    /// After an update, someone who paired a Mac but has no conversations here isn't welcomed: the decision is made as
    /// the library loads, before the link has started and listed its Macs, so it reads the stored pairings.
    func testBehaviorAPairedMacKeepsWelcomeAwayBeforeTheLinkStarts() async throws {
        let library = LibraryController(rootURL: try temporaryDirectory("library"), sync: nil)
        try await library.load()
        XCTAssertTrue(library.meetings.isEmpty)
        let mac = LinkPairingRecord(deviceID: UUID(), name: "Studio Mac", deviceClass: .mac, pairedAt: Date(),
                                    linkKey: Data(repeating: 7, count: 32), pskIdentity: Data(repeating: 9, count: 16))
        let paired = PhoneLink(identity: PhoneLink.identity(installation: UUID().uuidString, name: "Test iPhone", libraryID: nil),
                               keyStore: MemoryLinkKeyStore([mac]), configuration: .loopback())
        XCTAssertTrue(paired.macs.isEmpty, "Not started: the link hasn't listed its Macs")
        let decision = PhoneWelcome.presentation(completed: false, arguments: ["DaybookPhone"], isTestHost: false,
                                                 library: library, link: paired)
        XCTAssertFalse(decision.show)
        XCTAssertTrue(decision.atHome, "Welcome is done for them, now and later")

        let unpaired = PhoneLink(identity: PhoneLink.identity(installation: UUID().uuidString, name: "Test iPhone", libraryID: nil),
                                 keyStore: MemoryLinkKeyStore(), configuration: .loopback())
        let first = PhoneWelcome.presentation(completed: false, arguments: ["DaybookPhone"], isTestHost: false,
                                              library: library, link: unpaired)
        XCTAssertTrue(first.show, "A first launch")
        XCTAssertFalse(first.atHome)
    }

    /// A library that can't open at launch: Welcome stops waiting, so the app shows and says why, and Welcome isn't
    /// counted done, so it's offered on the next launch, a paired Mac or not.
    func testBehaviorALibraryThatCantOpenShowsTheAppAndKeepsWelcomeForNextTime() async throws {
        let blocked = try temporaryDirectory("library").appendingPathComponent("Daybook")
        try Data().write(to: blocked)   // a file where the library's folder should be
        let mac = LinkPairingRecord(deviceID: UUID(), name: "Studio Mac", deviceClass: .mac, pairedAt: Date(),
                                    linkKey: Data(repeating: 7, count: 32), pskIdentity: Data(repeating: 9, count: 16))
        let link = PhoneLink(identity: PhoneLink.identity(installation: "INSTALL-1", name: "Test iPhone", libraryID: nil),
                             keyStore: MemoryLinkKeyStore([mac]), configuration: .loopback())
        let model = PhoneAppModel(recorder: RecorderRig().recorder, library: PhoneLibrary(rootURL: blocked, installation: "INSTALL-1"),
                                  posture: DevicePosture(),
                                  options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]), link: link)
        let decided = Decided()
        Task { decided.value = await PhoneWelcome.decision(for: model, completed: false, arguments: ["DaybookPhone"], isTestHost: false) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(decided.value, "Waits while the library hasn't opened")

        await model.launch()
        XCTAssertTrue(model.libraryFailedToOpen)
        XCTAssertEqual(model.notice, PhoneAppModel.libraryUnavailable)
        let decision = try await waitFor("Welcome to stop waiting for the library") { decided.value }
        XCTAssertFalse(decision.show, "The app shows, with its notice")
        XCTAssertFalse(decision.atHome, "Welcome is offered on the next launch")
    }

    @MainActor private final class Decided {
        var value: (show: Bool, atHome: Bool)?
    }

    /// The Ready page says a Mac transcribes only when one that transcribes this library is known, paired or not.
    func testBehaviorTheReadyPageCountsOnlyAMacKnownToTranscribe() {
        XCTAssertTrue(PhoneWelcome.macTranscribes(.connected(name: "Studio Mac")))
        XCTAssertTrue(PhoneWelcome.macTranscribes(.seen(name: "Studio Mac", lastSeen: Date())))
        XCTAssertFalse(PhoneWelcome.macTranscribes(.notProcessing(name: "Studio Mac", lastSeen: Date())))
        XCTAssertFalse(PhoneWelcome.macTranscribes(.noMac))
        XCTAssertFalse(PhoneWelcome.macTranscribes(.checking))
        XCTAssertFalse(PhoneWelcome.macTranscribes(.unavailable("iCloud is off")))
    }

    // MARK: The Models page (P3, uxf-09)

    /// An iPhone with `gigabytes` of memory, iOS letting Daybook use `limit`, and language models running or not.
    private func models(_ gigabytes: Double, limit: UInt64? = nil, runsLanguageModels: Bool = true,
                        network: PhoneModelsTests.ScriptedNetwork = .init()) throws -> PhoneModels {
        let root = try temporaryDirectory("Models")
        return PhoneModels(root: root, defaults: makeTestDefaults("PhoneWelcomeTests"), fetcher: PhoneModelsTests.RecordingFetcher(),
                           network: network.network, physicalMemory: UInt64(gigabytes * 1e9), memoryLimit: limit,
                           runsLanguageModels: runsLanguageModels)
    }

    /// Where this iPhone can summarize (an 18 Pro: 12 GB, Gemma 4 E2B without the larger memory limit), two rows, both
    /// checked, the total on the button; with too little room for both, the summary starts unchecked and says what
    /// checking it would need.
    func testBehaviorACapableIPhoneOffersTranscriptionAndSummariesBothChecked() throws {
        let capable = try models(12, limit: 5_400_000_000)
        let summary = try XCTUnwrap(capable.summaryModel)
        XCTAssertEqual(summary.key, "gemma-4/e2b-4bit")
        let offer = PhoneWelcomeOffer(models: capable)
        XCTAssertEqual(offer.rows, [.init(part: .transcription, bytes: capable.processingMissingBytes),
                                    .init(part: .summaries, bytes: summary.approximateBytes)])
        XCTAssertEqual(ByteSize.format(offer.rows[1].bytes), "3.6 GB")
        XCTAssertTrue(offer.choosesRows)
        XCTAssertEqual(offer.initialChoice(free: nil), [.transcription, .summaries])
        XCTAssertEqual(offer.bytes([.transcription, .summaries]), capable.processingMissingBytes + summary.approximateBytes)
        XCTAssertEqual(offer.bytes([.transcription]), capable.processingMissingBytes)

        let free = summary.approximateBytes + 100_000_000
        XCTAssertEqual(offer.initialChoice(free: free), [.transcription], "what transcribing needs first")
        XCTAssertEqual(offer.shortfall(offer.rows[1], chosen: [.transcription], free: free), offer.bytes([.transcription, .summaries]))
        XCTAssertNil(offer.shortfall(offer.rows[1], chosen: [], free: free), "alone, it fits")
        XCTAssertNil(offer.shortfall(offer.rows[0], chosen: [.transcription], free: free))
    }

    /// Where it can't (no summary model fits its memory, or language models don't run), one row, as before: never a
    /// summary it can't make.
    func testBehaviorAnIPhoneThatCantSummarizeOffersOnlyTranscription() throws {
        for incapable in [try models(6), try models(12, limit: 5_400_000_000, runsLanguageModels: false)] {
            XCTAssertNil(incapable.summaryModel)
            let offer = PhoneWelcomeOffer(models: incapable)
            XCTAssertEqual(offer.rows.map(\.part), [.transcription])
            XCTAssertFalse(offer.choosesRows, "one row: nothing to leave out")
            XCTAssertEqual(offer.initialChoice(free: nil), [.transcription])
        }
    }

    /// Ready says "Your Mac summarizes it" only while this iPhone won't: once its summary model is asked for, it will.
    func testBehaviorThisIPhoneSummarizesOnceItsSummaryModelIsAskedFor() throws {
        let capable = try models(12, limit: 5_400_000_000)
        XCTAssertFalse(PhoneWelcome.summarizesHere(capable, processesHere: true))
        let summary = try XCTUnwrap(capable.summaryModel)
        capable.download(summary)
        XCTAssertEqual(capable.status(of: summary), .waitingForWiFi)
        XCTAssertTrue(PhoneWelcome.summarizesHere(capable, processesHere: true))
        XCTAssertFalse(PhoneWelcome.summarizesHere(capable, processesHere: false), "processing here off: a Mac's")
        capable.cancel(summary)
        XCTAssertFalse(PhoneWelcome.summarizesHere(try models(6), processesHere: true))
    }

    func testBehaviorTheAllowPageSaysWhatSettingsWould() {
        XCTAssertEqual(PhoneWelcome.state(.granted), .allowed)
        XCTAssertEqual(PhoneWelcome.state(.undetermined), .askable)
        XCTAssertEqual(PhoneWelcome.state(.denied), .openSettings)
        XCTAssertEqual(WelcomeWords.allow(.iPhone), "Allow")
        XCTAssertEqual(WelcomeWords.openSettings(.iPhone), "Open Settings")
    }
}
