import DaybookCore
import DaybookKit
import XCTest
@testable import DaybookPhone

/// What the page's status says on this iPhone, from what it knows (`ConversationStatusPresentation.phone`, its
/// `Inputs.phone`), over the demo library both apps fill (`ReadingDemo`): processing on this iPhone turned off, where a
/// summary runs (a Personal conversation under Always, ux-mac-10), a recording another device still has to send, and
/// work that couldn't finish. The app's own model with nothing real: no models, keys, link, or network.
@MainActor
final class PhonePageStatusTests: XCTestCase {
    /// A cloud that never answers: a summary sent to it runs until it's stopped.
    struct Unanswered: CloudSummarizing {
        func availableModels(refresh: Bool) async -> [CloudModel] { [] }
        func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String], model: CloudModel, effort: CloudEffort,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> MeetingSummary {
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
    }

    /// This iPhone with the demo library, as `--library-demo` fills it.
    private func demo() async throws -> PhoneAppModel {
        let library = PhoneLibrary(rootURL: try temporaryDirectory("PhonePageStatus"), installation: "INSTALL-1")
        let model = PhoneAppModel(recorder: RecorderRig().recorder, library: library, posture: DevicePosture(),
                                  options: DebugLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                                  environment: try PhoneAppEnvironment.test(self))
        try await library.reload()
        await ReadingDemo.seed(library.controller, as: .iPhone) { _, _, _, _ in }?.value
        return model
    }

    private func meeting(_ title: String, in model: PhoneAppModel) throws -> Meeting {
        try XCTUnwrap(model.library.controller.meetings.first { $0.title == title }, title)
    }

    private func page(_ title: String, _ model: PhoneAppModel, now: Date = Date()) throws -> ConversationStatusPresentation? {
        ConversationStatusPresentation.phone(try meeting(title, in: model), library: model.library.controller, model: model,
                                             placement: model.placement, upgrades: model.upgrades, now: now)
    }

    func testBehaviorWithProcessingOffThisIPhoneLeavesTheWorkToAMac() async throws {
        let model = try await demo()
        let library = model.library.controller
        // Its own recording, asked of a Mac, and no Mac around: with processing here on and its models still to download,
        // this iPhone would offer to do it; off, it waits for a Mac.
        let northwind = try meeting(ReadingDemo.Title.queued, in: model)
        for track in northwind.tracks { await model.library.noteBroughtIn(track.id) }
        guard case .requested(.device(let request)) = ProcessingStatus.phone(northwind) else { return XCTFail("waiting for a Mac") }

        model.settings.processesOnThisIPhone = false
        func inputs() throws -> ConversationStatusPresentation.Inputs {
            let current = try meeting(ReadingDemo.Title.queued, in: model)
            return .phone(model: model, library: library, meeting: current, status: ProcessingStatus.phone(current),
                          placement: model.placement, upgrades: model.upgrades)
        }
        XCTAssertEqual(try inputs().local, .iPhone(), "nothing of its own to transcribe, summarize, or download")
        XCTAssertTrue(try inputs().ownsUntranscribed, "its own recording")
        let waiting = try page(ReadingDemo.Title.queued, model)
        XCTAssertEqual(waiting?.kind, .line)
        XCTAssertEqual(waiting?.title, "Waiting for your Mac")
        XCTAssertEqual(waiting?.actions, [.cancelRequest(request.id)])
        let recorded = try page(ReadingDemo.Title.recorded, model)
        XCTAssertEqual(recorded?.title, "Not transcribed yet")
        XCTAssertEqual(recorded?.actions, [.transcribe(newAudio: false)])
        // Nothing within reach summarizes: the bare fact, never a summary model it wouldn't use.
        let transcript = try page(ReadingDemo.Title.transcriptOnly, model)
        XCTAssertEqual(transcript?.title, ConversationStatusPresentation.needsMacToSummarize)
        XCTAssertEqual(transcript?.actions, [])

        // Turned on, the page reads what this iPhone's models can do.
        model.settings.processesOnThisIPhone = true
        XCTAssertTrue(try inputs().local.processesHere)
        XCTAssertEqual(try inputs().local, SummaryPage.local(model.models, processesHere: true,
                                                             summarizes: model.processingCapabilities.summarizes))
    }

    /// ux-mac-10: Personal is never sent to the cloud on its own. Under Always a Work summary goes to the cloud at once; a
    /// Personal one waits, with Use the Cloud as a tap.
    func testBehaviorAPersonalConversationUnderAlwaysWaitsWithUseTheCloud() async throws {
        let model = try await demo()
        var preferences = CloudSummaryPreferences()
        preferences.policy = .always
        preferences.countdownSeconds = 30
        model.placement.cloud = CloudSetup.demo(providers: [.anthropic], preferences: preferences,
                                                defaults: makeTestDefaults("PhonePageStatusTests"))
        model.placement.cloudSummarizer = Unanswered()
        let personal = try meeting(ReadingDemo.Title.transcriptOnly, in: model)
        let work = try meeting(ReadingDemo.Title.ready, in: model)
        XCTAssertEqual(personal.effectivePlacement, .personal)
        XCTAssertEqual(work.effectivePlacement, .work)
        addTeardownBlock { @MainActor in model.placement.stop(work.id) }

        // Their summaries due, as after transcribing here.
        model.placement.placements.begin(personal.id)
        model.placement.placements.begin(work.id)
        let waits = try page(ReadingDemo.Title.transcriptOnly, model)
        XCTAssertEqual(waits?.title, "Waiting for a Mac to summarize")
        XCTAssertEqual(waits?.actions, [.placement(.useCloud)])
        let sent = try page(ReadingDemo.Title.ready, model)
        XCTAssertEqual(sent?.title, "Summarizing with Claude Sonnet 5.5")
        XCTAssertEqual(sent?.actions, [.stopSummary])
    }

    func testBehaviorWaitingForAnotherDevicesAudio() async throws {
        let model = try await demo()
        let waiting = try page(ReadingDemo.Title.awaiting, model)
        XCTAssertEqual(waiting?.title, "Waiting for audio from Soundcore Work")
        XCTAssertEqual(waiting?.actions, [.dontWait])
    }

    func testBehaviorWorkThatCouldntFinishOffersWhatThisIPhoneCanDo() async throws {
        let model = try await demo()
        // Studio Mac didn't have the models: Studio Mac's words behind Details, and Try Again (a new request).
        let missing = try page(ReadingDemo.Title.modelsMissing, model)
        XCTAssertEqual(missing?.kind, .box(.problem))
        XCTAssertEqual(missing?.title, "Couldn’t finish transcribing")
        XCTAssertEqual(missing?.detail, "The models it needs aren’t on Studio Mac yet. The recording is saved.")
        XCTAssertEqual(missing?.actions, [.details("Download Parakeet Ultra in Models before processing."), .tryAgain(.newAudio)])
        // The summary model couldn't start: an iPhone doesn't choose a Mac's models, so Details and Try Again.
        let debrief = try page(ReadingDemo.Title.failedSummarizing, model)
        XCTAssertEqual(debrief?.title, "Couldn’t finish summarizing")
        XCTAssertEqual(debrief?.actions, [.details("The language model couldn’t allocate enough memory."), .tryAgain(.summaryOnly)])
    }
}
