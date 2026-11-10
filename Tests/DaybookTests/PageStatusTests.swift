#if DEBUG
import DaybookCore
import DaybookIntelligence
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// What the page's status says on this Mac, from what this Mac knows (`ConversationStatusPresentation.mac`, its
/// `Inputs.mac`), over the demo library both apps fill (`ReadingDemo`): its own downloads and queue, where a summary
/// runs (a Personal conversation under Always, ux-mac-10), a recording another device still has to send, and work that
/// couldn't finish. The queue is held still, as `LibraryDemo` holds it; no models, keys, or network.
@MainActor
final class PageStatusTests: XCTestCase {
    private var defaults: UserDefaults!

    /// This Mac with the demo library: its models here, the queue held, and Settings › Cloud with no key.
    private func demo() async throws -> AppState {
        defaults = makeTestDefaults("PageStatusTests")
        let state = AppState(libraryURL: makeTemporaryFolder("DaybookPageStatus"), defaults: defaults)
        await state.initialize()
        state.processSyncedAudio = false
        state.processingTask = Task { try? await Task.sleep(for: .seconds(3600)) }
        state.cloud = CloudSetup.demo(providers: [], defaults: defaults)
        addTeardownBlock { @MainActor in
            state.processingTask?.cancel()
            await state.flush()
        }
        await ReadingDemo.seed(state.library, as: .mac) { _, _, _, _ in }?.value
        state.installedModels = Set(state.routedRequiredModelIDs)
        return state
    }

    private func id(_ title: String, in state: AppState) throws -> UUID {
        try XCTUnwrap(state.meetings.first { $0.title == title }?.id, title)
    }

    private func page(_ id: UUID, _ state: AppState, now: Date = Date()) throws -> ConversationStatusPresentation? {
        ConversationStatusPresentation.mac(state: state, meeting: try XCTUnwrap(state.meetings.first { $0.id == id }), now: now)
    }

    /// Settings › Cloud with an Anthropic key: Claude Sonnet 5.5 under `policy`, a countdown of 30 s.
    private func cloud(_ state: AppState, policy: CloudSummaryPreferences.Policy) {
        var preferences = CloudSummaryPreferences()
        preferences.policy = policy
        preferences.countdownSeconds = 30
        state.cloud = CloudSetup.demo(providers: [.anthropic], preferences: preferences, defaults: defaults)
        state.cloudSummarizer = PlacementDemo.StandIn()
    }

    func testBehaviorADownloadRunningSpeaksWhereTheWorkWaitsForIt() async throws {
        let state = try await demo()
        let research = try id(ReadingDemo.Title.waitingForModels, in: state)
        let northwind = try id(ReadingDemo.Title.queued, in: state)
        // The transcription model arriving, halfway; the conversation that needs it waits, and another is in the queue.
        let arriving = state.transcriptionModel
        let model = try XCTUnwrap(state.modelCatalog.model(arriving))
        state.installedModels.remove(model.key)
        state.downloadingID = arriving
        state.downloadProgress = IntelligenceProgress(0.5, "Downloading")
        state.awaitingModels = [research]
        state.processingQueue = [state.makeJob(meetingID: northwind, mode: .newAudio)]

        let waiting = try page(research, state)
        XCTAssertEqual(waiting?.title, "Downloading models · 50%")
        XCTAssertEqual(waiting?.detail, ByteSize.progress(model.approximateBytes / 2, of: model.approximateBytes))
        XCTAssertEqual(waiting?.actions, [.cancelDownload])
        let queued = try page(northwind, state)
        XCTAssertEqual(queued?.title, "Waiting to transcribe after the download")
        XCTAssertEqual(queued?.actions, [.cancel])

        // Once it's here, the queue goes on: the one in line waits for nothing.
        state.downloadingID = nil
        state.installedModels.insert(model.key)
        state.awaitingModels = []
        XCTAssertEqual(try page(northwind, state)?.title, "Waiting to transcribe")
        XCTAssertEqual(try page(research, state)?.kind, .box(.accent), "not transcribed yet")
    }

    /// ux-mac-10: Personal is never sent to the cloud on its own. Under Always a Work summary goes to the cloud at once;
    /// a Personal one counts down as Offer First does, with Use the Cloud as a tap, and without its summary model here
    /// it waits for one rather than for the cloud.
    func testBehaviorAPersonalConversationUnderAlwaysCountsDownOrWaits() async throws {
        let state = try await demo()
        cloud(state, policy: .always)
        let personal = try id(ReadingDemo.Title.transcriptOnly, in: state)
        let work = try id(ReadingDemo.Title.ready, in: state)
        XCTAssertEqual(state.meetings.first { $0.id == personal }?.effectivePlacement, .personal)

        // Its summary placed as this Mac's queue places one it's about to write (`PlacementDemo`).
        for id in [personal, work] {
            state.update(id) { $0.status = .summarizing }
            state.placements.begin(id)
        }
        state.processingID = personal
        state.processingProgress = IntelligenceProgress(0, "Summarizing", stage: .summarizing)
        let started = try XCTUnwrap(state.placements[personal]?.deadline).addingTimeInterval(-30)
        let countdown = try page(personal, state, now: started)
        XCTAssertEqual(countdown?.title, "Summarizing on this Mac in 30 s")
        XCTAssertEqual(countdown?.actions, [.placement(.useCloud), .placement(.startNow)])
        state.processingID = work
        let sent = try page(work, state)
        XCTAssertEqual(sent?.title, "Summarizing with Claude Sonnet 5.5")
        XCTAssertEqual(sent?.actions, [.stopSummary])
        for id in [personal, work] {
            state.placements.end(id)
            state.update(id) { $0.status = .ready }
        }
        state.processingID = nil

        // Without its summary model, a Personal transcript waits for one, with Use the Cloud; a Work one would go.
        state.installedModels.remove(state.summaryModel)
        let waits = try page(personal, state)
        XCTAssertEqual(waits?.title, "Download models to summarize this conversation")
        XCTAssertEqual(waits?.actions.first, .placement(.useCloud))
        state.update(personal) { $0.placement = .work }
        let goes = try page(personal, state)
        XCTAssertEqual(goes?.title, "Not summarized yet")
        XCTAssertEqual(goes?.actions, [.summarize])
    }

    func testBehaviorWaitingForAnotherDevicesAudioSaysWhereItIs() async throws {
        let state = try await demo()
        let walkthrough = try id(ReadingDemo.Title.awaiting, in: state)
        let soundcore = try page(walkthrough, state)
        XCTAssertEqual(soundcore?.title, "Waiting for audio from Soundcore Work")
        XCTAssertEqual(soundcore?.actions, [.dontWait])

        // An iPhone recorded along instead, and its sync presence says iCloud is full.
        let phone = UUID()
        let meeting = try XCTUnwrap(state.meetings.first { $0.id == walkthrough })
        var along = CompanionRecording(deviceID: phone.uuidString, deviceKind: DaybookPhoneIntegration.id, deviceName: "Alex’s iPhone",
                                       macStartedAt: meeting.date, state: .stopped, startedByDaybook: true)
        along.macEndedAt = meeting.date.addingTimeInterval(20)
        along.recordingID = UUID().uuidString
        state.update(walkthrough) { $0.companions = [along] }
        defaults.set([phone.uuidString: "alex-iphone"], forKey: AppState.phoneSyncIDsKey)
        var presence = KnownSyncDevice(id: "alex-iphone", deviceClass: .phone, displayName: "Alex’s iPhone", canProcess: false,
                                       lastSeen: Date())
        presence.problem = .storageFull
        state.phones.knownDevices = { [presence] }
        await state.checkAwaitedRecordings()
        let iPhone = try page(walkthrough, state)
        XCTAssertEqual(iPhone?.title, "Waiting for audio from Alex’s iPhone · Alex’s iPhone is out of iCloud storage")
        XCTAssertEqual(iPhone?.actions, [.dontWait])
    }

    func testBehaviorWorkThatCouldntFinishSaysWhereAndOffersTheFix() async throws {
        let state = try await demo()
        // Studio Mac's model stopped: Studio Mac's words behind Details, and Try Again.
        let board = try page(try id(ReadingDemo.Title.failedTranscribing, in: state), state)
        XCTAssertEqual(board?.kind, .box(.problem))
        XCTAssertEqual(board?.title, "Couldn’t finish transcribing")
        XCTAssertEqual(board?.detail, "Something went wrong on Studio Mac. The recording is saved.")
        XCTAssertEqual(board?.actions, [.details("Transcription stopped: the model process exited unexpectedly (code 5)."), .tryAgain(.newAudio)])
        // This Mac's summary model couldn't start: this Mac chooses its models.
        let debrief = try page(try id(ReadingDemo.Title.failedSummarizing, in: state), state)
        XCTAssertEqual(debrief?.title, "Couldn’t finish summarizing")
        XCTAssertEqual(debrief?.actions, [.chooseModels, .tryAgain(.summaryOnly)])

        // The cloud refused this Mac's key: the model named, Cloud Settings…, and this Mac's own summarizer.
        cloud(state, policy: .ask)
        let personal = try id(ReadingDemo.Title.transcriptOnly, in: state)
        let device = state.library.thisDevice
        let asked = ProcessingRequest(meetingID: personal, mode: .summaryOnly, requestedBy: device, createdAt: Date())
        let failed = try XCTUnwrap(asked.claimed(by: device, at: Date())?
            .failed(by: device, at: Date(), reason: "The cloud didn’t accept the key.", kind: .cloud(.badKey)))
        state.update(personal) { $0.upsertProcessingRequest(failed) }
        let refused = try page(personal, state)
        XCTAssertEqual(refused?.title, "Couldn’t summarize with Claude Sonnet 5.5")
        XCTAssertEqual(refused?.actions, [.cloudSettings, .summarizeHere("This Mac")])
    }
}
#endif
