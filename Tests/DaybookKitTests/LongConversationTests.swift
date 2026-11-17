import DaybookCore
import DaybookLink
import Foundation
import XCTest
@testable import DaybookKit

/// The cloud when it would do better (docs/cloud.md, "When the cloud is chosen"): a conversation longer than the local
/// model reads in one pass, which a cloud model ranks clearly above, counts down to the cloud under Offer First; a summary
/// that failed on the device tries the cloud before failing; and every such summary records why it went.
final class LongConversationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let studio = (id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, name: "Studio Mac")
    private let sonnet = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
                                    inputPrice: 2, outputPrice: 10, priceIsEstimated: false, contextTokens: 1_000_000, rank: 1)
    private let opus = CloudModel(provider: .anthropic, id: "claude-opus-5-5", name: "Claude Opus 5.5", tier: .best,
                                  inputPrice: 4, outputPrice: 20, priceIsEstimated: false, contextTokens: 1_000_000, rank: 1)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func preferences(_ policy: CloudSummaryPreferences.Policy = .ask) -> CloudSummaryPreferences {
        var preferences = CloudSummaryPreferences()
        preferences.policy = policy
        return preferences
    }

    /// A conversation of `passages` passages of about 70 characters each.
    private func meeting(passages: Int) -> Meeting {
        let track = UUID()
        var meeting = Meeting(title: "Offsite")
        meeting.unifiedTranscript = (0..<passages).map { index in
            TranscriptSegment(trackID: track, start: Double(index) * 5, end: Double(index) * 5 + 4,
                              text: "We went over item number \(index) of the quarterly planning review.", speakerID: "a")
        }
        return meeting
    }

    // MARK: Reading in one pass

    func testBehaviorALocalModelReadsAConversationWholeUpToItsLimitOrItsWindow() throws {
        let catalog = ModelCatalog.builtIn
        let e4b = try XCTUnwrap(catalog.model("gemma-4/e4b-4bit"))
        let short = meeting(passages: 60), long = meeting(passages: 1_000)
        XCTAssertLessThan(LongConversations.estimatedTokens(short), 5_400)
        XCTAssertGreaterThan(LongConversations.estimatedTokens(long), 5_400)
        XCTAssertTrue(LongConversations.readsWhole(short, model: e4b))
        XCTAssertFalse(LongConversations.readsWhole(long, model: e4b), "Past the 5,400 tokens it was measured at")
        // A model the catalog sets no limits for reads what its window holds.
        XCTAssertTrue(LongConversations.readsWhole(long, model: added(like: e4b, window: 131_072)))
        XCTAssertFalse(LongConversations.readsWhole(long, model: added(like: e4b, window: 8_192)))
        XCTAssertFalse(LongConversations.readsWhole(short, model: added(like: e4b, window: nil)), "Neither a limit nor a window: not known to")
    }

    /// `model` as the person might add it: no read limits, and `window`.
    private func added(like model: CatalogModel, window: Int?) -> CatalogModel {
        var variant = model.variant
        variant.engineOptions = ["architecture": "gemma4"]
        variant.capabilities.contextLength = window
        return CatalogModel(familyID: model.familyID, familyName: model.familyName, maker: model.maker, variant: variant, engine: model.engine,
                            roles: model.roles, license: model.license, homepage: model.homepage, origin: model.origin,
                            userRevisionIDs: model.userRevisionIDs)
    }

    func testBehaviorTheCloudDoesBetterOnlyForALongConversationAndByTheUpgradeMargin() {
        let long = meeting(passages: 1_000), short = meeting(passages: 60)
        XCTAssertTrue(LongConversations.cloudDoesBetter(long, localModel: "gemma-4/e4b-4bit", cloud: sonnet), "53 against 94")
        XCTAssertFalse(LongConversations.cloudDoesBetter(short, localModel: "gemma-4/e4b-4bit", cloud: sonnet), "Read whole: stays here")
        XCTAssertFalse(LongConversations.cloudDoesBetter(long, localModel: "gemma-4/26b-a4b-qat-4bit", cloud: opus), "90 against 95: not by 10")
        XCTAssertFalse(LongConversations.cloudDoesBetter(long, localModel: "gemma-4/e4b-4bit", cloud: nil))
        XCTAssertFalse(LongConversations.cloudDoesBetter(long, localModel: nil, cloud: sonnet))
        XCTAssertFalse(LongConversations.cloudDoesBetter(long, localModel: "someone/unranked", cloud: sonnet))
    }

    // MARK: The planner

    private let longer = SummaryPlacementPlanner.Conversation(cloudAllowed: true, cloudDoesBetter: true)
    private func options(local: Bool = true, macs: [(id: UUID, name: String)] = [], cloud: Bool = true) -> SummaryOptions {
        SummaryOptions(thisDeviceCanSummarize: local, reachableMacs: macs, cloud: cloud ? sonnet : nil)
    }

    func testBehaviorOfferFirstCountsDownToTheCloudForALongConversation() {
        var planner = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, conversation: longer)
        XCTAssertEqual(planner.phase, .countingDown(to: .cloud(sonnet), until: at(15)))
        XCTAssertEqual(planner.actions, [.startNow, .useLocal])
        XCTAssertEqual(planner.line(at: at(3), thisDevice: "this Mac"), "Summarizing with Claude Sonnet 5.5 in 12 s")
        XCTAssertEqual(SummaryPlacementPlanner.Action.useLocal.title, "Don’t Use the Cloud")
        planner.advance(to: at(15))
        XCTAssertEqual(planner.phase, .started(.cloud(sonnet)), "Never without the countdown, and then by default")
        XCTAssertEqual(planner.cloudReason, .longConversation)
        var now = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, conversation: longer)
        XCTAssertTrue(now.perform(.startNow, at: at(2)))
        XCTAssertEqual(now.cloudReason, .longConversation)
    }

    func testBehaviorDontUseTheCloudKeepsALongConversationWhereItWouldHaveRun() {
        var here = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, conversation: longer)
        XCTAssertTrue(here.perform(.useLocal, at: at(4)))
        XCTAssertEqual(here.phase, .started(.thisDevice))
        XCTAssertNil(here.cloudReason)
        // On an iPhone with no summarizer of its own, the Mac it would have gone to.
        var phone = SummaryPlacementPlanner(options: options(local: false, macs: [studio]), preferences: preferences(), at: start,
                                            waitsForMacs: true, conversation: longer)
        XCTAssertEqual(phone.phase, .countingDown(to: .cloud(sonnet), until: at(15)))
        XCTAssertTrue(phone.perform(.useLocal, at: at(1)))
        XCTAssertEqual(phone.phase, .started(.mac(id: studio.id, name: studio.name)))
        XCTAssertFalse(phone.perform(.useLocal, at: at(2)), "Started is final")
    }

    func testBehaviorTheCloudAlwaysGetsAWholeCountdownAndTheChoicesStayThePersons() {
        // A countdown to this device with a second left, retargeted to the cloud: its time starts again.
        var planner = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start)
        planner.update(conversation: longer, at: at(14))
        XCTAssertEqual(planner.phase, .countingDown(to: .cloud(sonnet), until: at(29)))
        // Back to this device, it keeps its time.
        planner.update(conversation: .init(), at: at(20))
        XCTAssertEqual(planner.phase, .countingDown(to: .thisDevice, until: at(29)))
        // Use the Cloud (an Upgrade accepted) during a countdown to the cloud: now, as the person's choice.
        var chosen = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, conversation: longer)
        XCTAssertTrue(chosen.perform(.useCloud, at: at(1)))
        XCTAssertEqual(chosen.phase, .started(.cloud(sonnet)))
        XCTAssertEqual(chosen.cloudReason, .chosen)
    }

    @MainActor
    func testBehaviorAskingForASummaryOrTheCloudDuringACountdownToItDoesWhatWasAsked() {
        let now = start
        let placements = SummaryPlacements(options: options(), preferences: preferences(), waitsForMacs: false, clock: { now }, runsTimer: false)
        placements.conversation = { _, _ in .init(cloudAllowed: true, cloudDoesBetter: true) }
        let asked = UUID(), upgraded = UUID(), failed = UUID()
        XCTAssertNil(placements.begin(asked))
        XCTAssertEqual(placements.begin(asked, immediately: true), .thisDevice, "Summarize Again: where it would have run")
        XCTAssertEqual(placements.beginInCloud(upgraded), .cloud(sonnet), "An Upgrade to the cloud's model: at once")
        XCTAssertEqual(placements[upgraded]?.cloudReason, .chosen)
        placements.beginAfterLocalFailure(failed)
        XCTAssertEqual(placements.begin(failed, immediately: true), .cloud(sonnet), "After a failure here, the cloud is all that's left")
    }

    func testBehaviorTheCloudForALongConversationStaysInsideThePrivacyRule() {
        // Always: it goes at once, as anything would, recorded as Always's.
        let always = SummaryPlacementPlanner(options: options(), preferences: preferences(.always), at: start, conversation: longer)
        XCTAssertEqual(always.phase, .started(.cloud(sonnet)))
        XCTAssertEqual(always.cloudReason, .always)
        // Never, no key, or a placement kept off the cloud: here, at once.
        XCTAssertEqual(SummaryPlacementPlanner(options: options(), preferences: preferences(.never), at: start, conversation: longer).phase,
                       .started(.thisDevice))
        XCTAssertEqual(SummaryPlacementPlanner(options: options(cloud: false), preferences: preferences(), at: start, conversation: longer).phase,
                       .started(.thisDevice))
        let personal = SummaryPlacementPlanner.Conversation(cloudAllowed: false, cloudDoesBetter: true)
        XCTAssertEqual(SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, conversation: personal).phase,
                       .started(.thisDevice))
        // Asked for (Summarize Again): no countdown, so never the cloud on its own.
        XCTAssertEqual(SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, immediately: true,
                                               conversation: longer).phase, .started(.thisDevice))
        // Moved to Personal while it counts down to the cloud: it starts here instead.
        var moved = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, conversation: longer)
        moved.update(conversation: personal, at: at(5))
        XCTAssertEqual(moved.phase, .started(.thisDevice))
        XCTAssertNil(moved.cloudReason)
    }

    func testBehaviorAFailedLocalSummaryTriesTheCloudUnderTheSameRules() {
        let failed = SummaryPlacementPlanner.Conversation(cloudAllowed: true, localFailed: true)
        // Offer First: a countdown to the cloud, never a send without it.
        var ask = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, conversation: failed)
        XCTAssertEqual(ask.phase, .countingDown(to: .cloud(sonnet), until: at(15)))
        XCTAssertEqual(ask.actions, [.startNow, .useLocal])
        ask.advance(to: at(15))
        XCTAssertEqual(ask.phase, .started(.cloud(sonnet)))
        XCTAssertEqual(ask.cloudReason, .localFailed)
        // Declined: nowhere left, so the job fails as it would have.
        var declined = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, conversation: failed)
        XCTAssertTrue(declined.perform(.useLocal, at: at(2)))
        XCTAssertEqual(declined.phase, .waiting)
        // Always: at once.
        let always = SummaryPlacementPlanner(options: options(), preferences: preferences(.always), at: start, conversation: failed)
        XCTAssertEqual(always.phase, .started(.cloud(sonnet)))
        XCTAssertEqual(always.cloudReason, .localFailed)
        // Never, no key, or kept off the cloud: nothing to try.
        XCTAssertEqual(SummaryPlacementPlanner(options: options(), preferences: preferences(.never), at: start, conversation: failed).phase, .waiting)
        XCTAssertEqual(SummaryPlacementPlanner(options: options(cloud: false), preferences: preferences(), at: start, conversation: failed).phase, .waiting)
        let kept = SummaryPlacementPlanner.Conversation(cloudAllowed: false, localFailed: true)
        XCTAssertEqual(SummaryPlacementPlanner(options: options(), preferences: preferences(.always), at: start, conversation: kept).phase, .waiting)
        // The key removed while it counts down: nothing to try any more.
        var keyGone = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, conversation: failed)
        keyGone.update(options: options(cloud: false), at: at(3))
        XCTAssertEqual(keyGone.phase, .waiting)
        // Use the Cloud chosen anywhere records the person's choice.
        var chosen = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start)
        chosen.perform(.useCloud, at: at(1))
        XCTAssertEqual(chosen.cloudReason, .chosen)
    }

    @MainActor
    func testBehaviorPlacementsTryTheCloudAfterALocalFailureReplacingTheOldPlanner() async throws {
        let now = start
        let placements = SummaryPlacements(options: options(), preferences: preferences(), waitsForMacs: false, clock: { now }, runsTimer: false)
        let id = UUID()
        XCTAssertEqual(placements.beginHere(id), .thisDevice)
        XCTAssertNil(placements.beginAfterLocalFailure(id), "Offer First: a countdown first")
        XCTAssertEqual(placements[id]?.phase, .countingDown(to: .cloud(sonnet), until: at(15)))
        XCTAssertTrue(placements[id]?.conversation.localFailed == true)
        // Whatever changes meanwhile, it stays a retry after a failure.
        placements.update(preferences: preferences())
        XCTAssertTrue(placements[id]?.conversation.localFailed == true)
        let waiting = Task { await placements.place(id) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(placements.perform(.useLocal, for: id))
        let place = await waiting.value
        XCTAssertNil(place, "Declined: nowhere to run it")
        placements.update(preferences: preferences(.always))
        XCTAssertEqual(placements.beginAfterLocalFailure(UUID()), .cloud(sonnet))
        // With nothing to try, it settles waiting at once, and waiting for its place returns rather than hanging.
        placements.update(options: options(cloud: false))
        let nothing = UUID()
        XCTAssertNil(placements.beginAfterLocalFailure(nothing))
        XCTAssertEqual(placements[nothing]?.phase, .waiting)
        let settled = await placements.place(nothing)
        XCTAssertNil(settled)
    }

    @MainActor
    func testBehaviorLeavingTheScreenNeverSendsACountdownThatEndsInTheCloud() {
        let now = start
        let placements = SummaryPlacements(options: options(), preferences: preferences(), waitsForMacs: true, clock: { now }, runsTimer: false)
        let long = UUID(), short = UUID(), failed = UUID()
        placements.conversation = { id, _ in .init(cloudAllowed: true, cloudDoesBetter: id == long) }
        placements.begin(long)
        placements.begin(short)
        placements.beginAfterLocalFailure(failed)
        placements.startDefaultsNow()
        XCTAssertEqual(placements[long]?.started, .thisDevice, "Where it would have run without the cloud")
        XCTAssertEqual(placements[short]?.started, .thisDevice)
        XCTAssertEqual(placements[failed]?.phase, .waiting, "After a failure here: nowhere, so it fails")
    }

    // MARK: Words, the link, and provenance

    func testBehaviorAMacsCountdownToTheCloudSaysSoOnThePhoneWithItsChoices() {
        let progress = LinkProcessingProgress(meetingID: UUID(), phase: .summaryCountdown, macName: "Studio Mac",
                                              countdown: LinkSummaryCountdown(secondsLeft: 12, cloudOffered: true), cloudModel: "Claude Opus 5.5")
        let live = LiveProgress(progress, from: studio.id, receivedAt: start)
        XCTAssertEqual(live.placementActions, [.startNow, .useLocal])
        let work = ConversationStatusPresentation.LinkWork(progress, receivedAt: start, answerable: true)
        XCTAssertEqual(work.placementActions, [.startNow, .useLocal])
        var inputs = ConversationStatusPresentation.Inputs(words: .iPhone(id: "phone"), local: .iPhone())
        inputs.link = work
        let line = ConversationStatusPresentation.placement(.transcribed, inputs: inputs, now: at(2))
        XCTAssertEqual(line?.title, "Summarizing with Claude Opus 5.5 in 10 s")
        XCTAssertEqual(line?.actions, [.placement(.startNow), .placement(.useLocal)])
        XCTAssertEqual(LinkSummaryChoice.Choice.useLocal.rawValue, "useLocal")
        // A countdown to the Mac itself reads as before.
        let toMac = LinkProcessingProgress(meetingID: UUID(), phase: .summaryCountdown, macName: "Studio Mac",
                                           countdown: LinkSummaryCountdown(secondsLeft: 12, cloudOffered: true))
        XCTAssertEqual(LiveProgress(toMac, from: studio.id, receivedAt: start).placementActions, [.useCloud, .startNow])
    }

    func testBehaviorASummaryRecordsWhyItWentToTheCloud() {
        let device = ProcessingRequest.Device(id: "mac", name: "Studio Mac")
        let summary = MeetingSummary(title: "Offsite", overview: "Planning.")
        for reason in [CloudReason.chosen, .always, .longConversation, .localFailed] {
            let placed = summary.placed(.cloud(sonnet), by: device, inputs: [:], cloudReason: reason)
            XCTAssertEqual(placed.cloudReason, reason)
            XCTAssertEqual(placed.processingSettings?.parameters["cloudReason"], reason.rawValue)
        }
        XCTAssertNil(summary.placed(.thisDevice, by: device, inputs: [:], cloudReason: .longConversation).cloudReason, "Only a cloud summary")
        XCTAssertNil(summary.placed(.cloud(sonnet), by: device, inputs: [:]).cloudReason)
    }
}
