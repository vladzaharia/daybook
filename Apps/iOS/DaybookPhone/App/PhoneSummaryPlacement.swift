import DaybookIntelligence
import DaybookKit
import DaybookLink
import Foundation
import Observation
import SwiftUI

extension EnvironmentValues {
    /// Where this iPhone's summaries run, for the page, the list, and the status sheet. Nil in previews and
    /// tests that don't set it: a Summarize request then goes to the Macs as before.
    @Entry var summaryPlacement: PhoneSummaryPlacement? = nil
}

extension LibraryController {
    /// Summarize, Summarize Again, or a template chosen: through the placement when there is one (the person
    /// asked, so it starts at once where it can), else a request for a Mac.
    func summarize(_ id: UUID, templateID: String? = nil, placement: PhoneSummaryPlacement?) {
        if let placement { placement.summarize(id, templateID: templateID) }
        else { requestProcessing(id, mode: .summaryOnly, templateID: templateID) }
    }
}

/// Where this iPhone's summaries run (docs/multipoint.md, "Where summaries run"; docs/iphone.md). The same
/// planner as the Mac's, with what an iPhone offers: its own summarizer when its processing models have one
/// (`localSummarizer`), the Macs that summarize and are reachable now (over the link, or seen through sync in
/// the last 15 minutes), and the cloud model Settings › Cloud resolves to (`cloud`, the app's `CloudSetup`).
///
/// - **Held in the library.** A summary that's due is written down first: a Summarize request this iPhone claims
///   (`claimSummary`) and keeps through the countdown or the wait for a Mac, renewing it while it waits. Sending it
///   to a Mac gives that request back; running it here or in the cloud carries it out. If Daybook is killed meanwhile,
///   the next launch places it again (`resumeHeldSummaries`); if this iPhone never comes back, the claim lapses
///   and a Mac takes the request, as it would any other.
/// - **Due** (`summaryIsDue`, once `PhoneProcessor` has transcribed and fused a conversation): with the cloud on offer it
///   counts down 15 s (or the setting) to its default: this iPhone, else "Summarizing on Vlad's MacBook
///   Pro". With nowhere to run it: "Waiting for a Mac to summarize · Use the Cloud", counting down when a
///   Mac becomes reachable. Wait for a Mac passes over this iPhone.
/// - **Asked for** (`summarize`: Summarize, Summarize Again, a template): it starts at once, where it can;
///   with no Mac reachable, the request waits for one in the library, and Use the Cloud takes it back.
/// - **Sending to a Mac** writes a Summarize request (`ProcessingRequest`, the existing path) and nudges
///   connected Macs. **Here or in the cloud**, this iPhone claims the summary through a request first, so
///   no Mac summarizes it too, and keeps a summary another device wrote meanwhile. Here, the processor runs
///   it (`runHere`), under its rules: on the screen, one at a time, backing off for heat and power.
/// - **A Mac's own countdown** (over the link) shows here, with Use the Cloud and Start Now sent to it; this
///   iPhone stops its own countdown for that conversation.
/// - **In the background**, where a countdown can't run, each countdown's default happens at once, and a
///   summary waiting for a Mac is left to one through the library. A countdown that ends in the cloud runs only while
///   Daybook is active on the screen (`isOnScreen`); otherwise it runs where it would have without the cloud.
/// - **Kept off the cloud**: a conversation whose placement Settings › Cloud keeps off it (Personal, unless the person
///   turns it on: `CloudPlacements`) is never sent there, whatever asks: no Use the Cloud, no cloud Upgrade, Always
///   doesn't send it, and one moved there (or a switch turned off) mid-countdown goes on here or to a Mac. This iPhone
///   applies its own switches: preferences are each device's own.
/// - **When the cloud would do better** (docs/cloud.md, "When the cloud is chosen"): a conversation longer than the model
///   it would run on (this iPhone's, else the Mac's) reads in one pass, whose summary the cloud's model ranks clearly above,
///   counts down to the cloud under Offer First, with Start Now and Don't Use the Cloud. A summary that fails here tries
///   the cloud before its request fails, under the same rules; declined, the request fails as it would have. The summary
///   records why it went (`cloudReason`). One longer than the cloud model can read goes here, or to a Mac.
@MainActor
@Observable
final class PhoneSummaryPlacement {
    /// What's being placed, by conversation (`placements`' planners).
    var planners: [UUID: SummaryPlacementPlanner] { placements.planners }
    /// Summaries running in the cloud, by conversation: "Summarizing with Claude Sonnet 5.5". One running here
    /// is the processor's, and its status says so.
    private(set) var runs: [UUID: SummaryPlace] = [:]
    /// Settings › Cloud (`PhoneAppModel.cloudSummaries`): the keys, the models they reach, and the preferences,
    /// read only from there. Nil until the app sets it: nothing about the cloud is offered.
    @ObservationIgnored var cloud: CloudSetup? {
        didSet {
            // A key, the models, or the preferences changing reaches every countdown at once.
            cloud?.onChange = { [weak self] in self?.refresh() }
            refresh()
        }
    }
    /// How the person wants summaries placed: Settings › Cloud's.
    var preferences: CloudSummaryPreferences { cloud?.preferences ?? CloudSummaryPreferences() }
    /// This iPhone's own summarizer, when its processing models have one that fits (`PhoneModels.summarizer`).
    @ObservationIgnored var localSummarizer: (any LocalSummarizing)? { didSet { refresh() } }
    /// Runs a summary placed on this iPhone, on the request claimed for it: the processor's work
    /// (`PhoneProcessor.summarizeHere`). Without it, a summary placed here goes to a Mac.
    @ObservationIgnored var runHere: ((UUID, ProcessingRequest) -> Void)?
    /// Summaries in the cloud with the person's own keys: `cloud`'s directory, sent as this iPhone. Tests and demos
    /// set one of their own.
    var cloudSummarizer: (any CloudSummarizing)? {
        get { cloudSummarizerOverride ?? cloud.map { CloudSummarizer(directory: $0.directory, deviceName: library.thisDevice.name) } }
        set { cloudSummarizerOverride = newValue }
    }
    @ObservationIgnored private var cloudSummarizerOverride: (any CloudSummarizing)?

    let placements: SummaryPlacements
    @ObservationIgnored private let library: LibraryController
    @ObservationIgnored private let link: PhoneLink
    @ObservationIgnored private let presence: () -> [KnownSyncDevice]
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let runsTimer: Bool
    /// Renews the claims held while summaries count down or wait for a Mac (`keepHolding`).
    @ObservationIgnored private var holding: Task<Void, Never>?
    /// How often a held claim is renewed while it waits: well inside its lease.
    static let holdRenewal: TimeInterval = 60
    /// Summaries running here or in the cloud, with the request this iPhone claimed for each.
    @ObservationIgnored private var running: [UUID: (request: UUID, task: Task<Void, Never>)] = [:]
    /// The template each was asked for with; nil uses the conversation's own.
    @ObservationIgnored private var templates: [UUID: String] = [:]
    /// Summaries that failed here and are being tried in the cloud, with the request and why it failed: declined, it fails.
    @ObservationIgnored private var localFailures: [UUID: (request: UUID, reason: String, kind: ProcessingRequest.FailureKind)] = [:]
    /// Conversations a failure here mustn't send to the cloud: the person declined its cloud countdown (Don't Use the
    /// Cloud), or the cloud model couldn't read it. Until its summary is done or given up.
    @ObservationIgnored private var keptHere: Set<UUID> = []
    /// iOS has Daybook active (`UIApplication.applicationState`), asked each time: a background launch has no scene phase
    /// to say otherwise, as `PhoneAppModel.isInFront` knows.
    @ObservationIgnored private let appIsActive: @MainActor () -> Bool
    /// The scene's phase last said Daybook is active (`cameToForeground`, `leftForeground`, `becameInactive`).
    @ObservationIgnored private var sceneIsActive = true
    /// Daybook is active on the screen: its scene and iOS both say so. Only then can a countdown that ends in the cloud run
    /// (`SummaryPlacements.countdownsAreSeen`); away from it, one runs where it would have without the cloud.
    var isOnScreen: Bool { sceneIsActive && appIsActive() }

    init(library: LibraryController, link: PhoneLink, presence: @escaping () -> [KnownSyncDevice],
         clock: @escaping () -> Date = Date.init, runsTimer: Bool = true, appIsActive: @escaping @MainActor () -> Bool) {
        self.library = library
        self.link = link
        self.presence = presence
        self.clock = clock
        self.runsTimer = runsTimer
        self.appIsActive = appIsActive
        placements = SummaryPlacements(waitsForMacs: true, clock: clock, runsTimer: runsTimer)
        placements.countdownsAreSeen = sceneIsActive && appIsActive()
        placements.onSettled = { [weak self] id, phase in self?.settled(id, phase) }
        placements.conversation = { [weak self] id, options in self?.conversation(id, options: options) ?? .init(cloudAllowed: false) }
        // A Mac's countdown or work on a conversation ends this iPhone's own countdown for it.
        link.onLiveProgress = { [weak self] _ in self?.refresh() }
        followConversationsWhilePlacing()
    }

    /// A conversation changing (moved to Personal, say) reaches its countdown at once: every change to the library asks
    /// each planner's conversation again while anything is being placed.
    private func followConversationsWhilePlacing() {
        withObservationTracking { _ = library.revision } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.placements.planners.isEmpty { self.refresh() }
                self.followConversationsWhilePlacing()
            }
        }
    }

    /// "this iPhone" in the countdown's words.
    nonisolated static let thisDeviceWords = "this iPhone"

    // MARK: What this iPhone offers

    /// The Macs that summarize and are reachable now: connected over the link, or seen through sync lately.
    var reachableMacs: [SummarizingMac] {
        let connected = link.connectedMacs.map {
            SummarizingMac.Connected(id: $0.id, syncDeviceID: $0.syncDeviceID, name: $0.name, capabilities: $0.processing, canProcess: $0.canProcess)
        }
        return SummarizingMac.reachable(connected: connected, presence: presence(), now: clock())
    }

    /// The cloud model on offer: what Settings › Cloud resolves to, nil without a key (the planner leaves it out
    /// with Never).
    var cloudOffer: CloudModel? { preferences.policy == .never ? nil : cloud?.resolved?.model }

    /// The cloud model on offer for this conversation: none when its placement is kept off the cloud.
    func cloudOffer(for meeting: Meeting) -> CloudModel? { preferences.placements.allows(meeting) ? cloudOffer : nil }

    /// The same, by conversation; none for one that's gone.
    func cloudOffer(for id: UUID) -> CloudModel? { library.meeting(id).flatMap(cloudOffer(for:)) }

    /// Whether Settings › Cloud lets this conversation go to the cloud: its placement's switch. False for one that's gone.
    func cloudAllowed(_ id: UUID) -> Bool { library.meeting(id).map(preferences.placements.allows) ?? false }

    /// What the planner needs of a conversation: whether it may go to the cloud, and whether the cloud would do clearly
    /// better than the model it would otherwise run on (this iPhone's, else the first reachable Mac's).
    func conversation(_ id: UUID, options: SummaryOptions) -> SummaryPlacementPlanner.Conversation {
        guard let meeting = library.meeting(id) else { return .init(cloudAllowed: false) }
        let allowed = preferences.placements.allows(meeting)
        let local = options.thisDeviceCanSummarize ? localSummarizer?.model : options.reachableMacs.first.flatMap { macSummaryModel($0.id) }
        return .init(cloudAllowed: allowed, cloudDoesBetter: allowed && LongConversations.cloudDoesBetter(meeting, localModel: local, cloud: options.cloud))
    }

    /// The summary model a Mac says it runs: over the link, else in its presence.
    private func macSummaryModel(_ id: UUID) -> String? {
        let role = ModelRole.summarization.rawValue
        if let connected = link.connectedMacs.first(where: { $0.id == id || $0.syncDeviceID == id.uuidString }),
           let model = connected.processing?.models?[role] { return model }
        return presence().first { $0.id == id.uuidString }?.capabilities?.models?[role]
    }

    var options: SummaryOptions {
        SummaryOptions(thisDeviceCanSummarize: runHere != nil && localSummarizer?.canSummarize == true, macs: reachableMacs,
                       cloud: cloud?.resolved?.model)
    }

    /// What's on offer changed (a Mac came or went, presence, a key, this iPhone's summarizer): every countdown
    /// follows, and one a Mac has taken meanwhile, or whose conversation went (to the Trash, or into a Mac's
    /// conversation of the same meeting), stops here.
    func refresh() {
        // Whether the person can see a countdown, as iOS says now.
        placements.countdownsAreSeen = isOnScreen
        placements.update(options: options, preferences: preferences)
        for id in placements.undecided where isTakenElsewhere(id) {
            // Another device has it: the request this iPhone held goes back, for whichever device finishes the work.
            giveBackHeld(id)
            forget(id)
            placements.end(id)
        }
        renewHeld()
        // A summary this iPhone runs in the cloud that another device took over in a merge, or whose conversation
        // went: it stands down.
        for (id, run) in running {
            guard let request = library.meeting(id)?.processingRequests?.first(where: { $0.id == run.request }) else {
                run.task.cancel()
                continue
            }
            if let holder = request.activeClaim(at: clock()), holder.device.id != library.thisDevice.id { run.task.cancel() }
        }
    }

    /// Reads the keys and their models again (`CloudSetup.reload`): before a summary is placed, at launch, and when
    /// Daybook comes back. A key added on the Mac reaches this iPhone through iCloud Keychain.
    func reloadCloud() async {
        await cloud?.reload()
        refresh()
    }

    // MARK: Starting

    /// A conversation's summary is due on this iPhone: its own transcript is ready and fused (the processor
    /// calls this). A Mac already working on it keeps it.
    func summaryIsDue(_ id: UUID, templateID: String? = nil) async {
        await reloadCloud()
        guard placements[id] == nil, running[id] == nil, !isTakenElsewhere(id) else { return }
        // Written down before anything else: if Daybook stops now, the next launch, or a Mac, takes it from here.
        guard library.claimSummary(id, templateID: templateID, at: clock()) != nil else { return }
        if let templateID { templates[id] = templateID }
        refresh()
        placements.begin(id)
        // Away from the screen (transcribed in the background, a background launch), nothing is left to count down.
        if !isOnScreen { leftForeground() }
        keepHolding()
    }

    /// At launch: the summaries this iPhone held when Daybook stopped (counting down, waiting for a Mac, or under way
    /// here or in the cloud) are placed again, so none is left with nobody to make it. One a Mac took over meanwhile,
    /// or that has a summary now, is left alone.
    func resumeHeldSummaries() async {
        for meeting in library.meetings where placements[meeting.id] == nil && running[meeting.id] == nil {
            guard let held = heldRequest(meeting.id) else { continue }
            await summaryIsDue(meeting.id, templateID: held.templateID)
        }
    }

    /// The Summarize request this iPhone holds for a conversation: claimed by it and never given back (its lease may
    /// have run out while Daybook was stopped, as long as nobody else took it), not finished, and not yet satisfied.
    func heldRequest(_ id: UUID) -> ProcessingRequest? {
        guard let meeting = library.meeting(id) else { return nil }
        let me = library.thisDevice, now = clock()
        return meeting.openProcessingRequests.first { request in
            guard request.mode == .summaryOnly, let claim = request.claim, claim.device.id == me.id, claim.lease > 0 else { return false }
            return request.isClaimable(by: me, at: now) && !request.isSatisfied(by: meeting)
        }
    }

    /// Gives a held request back: a Mac may take it now.
    @discardableResult
    private func giveBackHeld(_ id: UUID) -> ProcessingRequest? {
        guard let held = heldRequest(id) else { return nil }
        return library.releaseProcessingRequest(held.id, in: id, at: clock())
    }

    /// Renews the claims on summaries still counting down or waiting for a Mac, so no Mac takes one meanwhile.
    func renewHeld() {
        let now = clock()
        for id in placements.undecided {
            guard let held = heldRequest(id), let claim = held.claim, now.timeIntervalSince(claim.heartbeat) >= Self.holdRenewal else { continue }
            library.renewProcessingClaim(held.id, in: id, stage: .summarizing, at: now)
        }
    }

    /// While anything waits here, its claim is renewed once a minute (only with a timer: tests renew by hand).
    private func keepHolding() {
        guard runsTimer, holding == nil else { return }
        holding = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.holdRenewal))
                guard let self, !self.placements.undecided.isEmpty else { break }
                self.renewHeld()
            }
            self?.holding = nil
        }
    }

    /// The person asked for a summary (Summarize, Summarize Again, a template): it starts at once wherever it
    /// can. With no Mac reachable it's left to one in the library, where Use the Cloud can still take it.
    func summarize(_ id: UUID, templateID: String? = nil) {
        if let templateID { templates[id] = templateID } else { templates[id] = nil }
        refresh()
        placements.begin(id, immediately: true)
        if placements[id]?.phase == .waitingForMac { send(id) }
    }

    /// The person's choice for a conversation's summary: this iPhone's own countdown, a Mac's countdown shown
    /// here (sent to that Mac), or Use the Cloud for a Summarize request still waiting for a Mac.
    func perform(_ action: SummaryPlacementPlanner.Action, for id: UUID) {
        if planners[id] != nil {
            placements.perform(action, for: id)
        } else if let live = link.liveProgress[id], live.isCountingDown, let mac = live.macID {
            switch action {
            case .useCloud: link.sendSummaryChoice(.useCloud, for: id, to: mac)
            case .startNow: link.sendSummaryChoice(.startNow, for: id, to: mac)
            case .useLocal: link.sendSummaryChoice(.useLocal, for: id, to: mac)
            case .waitForMac: break
            }
        } else if action == .useCloud, let model = cloudOffer(for: id), waitingSummaryRequest(id) != nil {
            run(id, .cloud(model), reason: .chosen)
        }
    }

    /// Leaving the screen: a countdown can't run in the background, so each one's default happens now, and a
    /// summary waiting for a Mac is left to one through the library.
    /// A countdown that ends in the cloud doesn't go there: it runs where it would have without the cloud.
    func leftForeground() {
        sceneIsActive = false
        placements.countdownsAreSeen = false
        placements.startDefaultsNow()
        for id in placements.undecided { send(id) }
    }

    /// Still on the screen but not active (Control Center, the app switcher, a call coming in): a countdown here goes on,
    /// and one that ends in the cloud runs where it would have without the cloud.
    func becameInactive() {
        sceneIsActive = false
        placements.countdownsAreSeen = false
    }

    /// Back on the screen: countdowns can run again, and a new one may end in the cloud.
    func cameToForeground() {
        sceneIsActive = true
        placements.countdownsAreSeen = isOnScreen
    }

    /// A sync pass applied: what Macs did may stop work here (a claim lost in a merge, a Mac on it).
    func syncApplied() { refresh() }

    // MARK: Reading

    /// A Summarize request waiting for a Mac that nobody has claimed: Use the Cloud can take it.
    func waitingSummaryRequest(_ id: UUID) -> ProcessingRequest? {
        guard let meeting = library.meeting(id), case .requested(.device(let request)) = ProcessingStatus(meeting, now: clock()),
              request.mode == .summaryOnly else { return nil }
        return request
    }

    /// A Mac's live progress on the conversation, over the link.
    func live(_ id: UUID) -> LiveProgress? { link.liveProgress[id] }

    /// A Mac is working on the conversation, or counting down to: it has it. A conversation that's gone (a Mac
    /// moved its recording into its own conversation of the same meeting, and this one went to the Trash) is
    /// nobody's to summarize here.
    func isTakenElsewhere(_ id: UUID) -> Bool {
        guard let meeting = library.meeting(id) else { return true }
        if let live = link.liveProgress[id], !live.isFinished { return true }
        return meeting.summaryHolder(excluding: library.thisDevice.id, at: clock()) != nil
    }

    // MARK: Running

    private func settled(_ id: UUID, _ phase: SummaryPlacementPlanner.Phase) {
        switch phase {
        case .waiting where localFailures[id] != nil:
            // The cloud declined or not on offer after a failure here: the request fails as it would have.
            failAfterLocalFailure(id)
        case .started(.mac), .waiting:
            send(id)
        case .started(let place):
            run(id, place)
        case .countingDown, .waitingForMac:
            break
        }
    }

    /// The summary placed on this iPhone failed (the processor asks, `PhoneProcessor.Services.summaryFailed`): the cloud is
    /// tried before its request fails, as this conversation's rules allow: at once under Always, after a countdown to it
    /// under Offer First, never without the cloud on offer for it. False when it isn't tried; the request then fails.
    func localSummaryFailed(_ id: UUID, request: UUID, reason: String, kind: ProcessingRequest.FailureKind) -> Bool {
        guard running[id] == nil, !keptHere.contains(id), let meeting = library.meeting(id), cloudOffer(for: meeting) != nil else {
            keptHere.remove(id)
            return false
        }
        localFailures[id] = (request, reason, kind)
        placements.beginAfterLocalFailure(id)
        if !isOnScreen { leftForeground() }
        keepHolding()
        return true
    }

    /// Done with what this iPhone held for a conversation's retry: its summary was made, given back, or given up.
    private func forget(_ id: UUID) {
        localFailures[id] = nil
        keptHere.remove(id)
    }

    /// A summary that failed here and won't go to the cloud: its request fails with what went wrong here.
    private func failAfterLocalFailure(_ id: UUID) {
        defer { placements.end(id) }
        guard let failure = localFailures.removeValue(forKey: id) else { return }
        templates[id] = nil
        library.failProcessingRequest(failure.request, in: id, reason: failure.reason, kind: failure.kind, at: clock())
    }

    /// Hands the summary to a Mac: a Summarize request in the library (a Mac that's here hears of it now). The
    /// request this iPhone held through the countdown is the one given back.
    private func send(_ id: UUID) {
        defer { placements.end(id) }
        forget(id)
        let templateID = templates.removeValue(forKey: id)
        guard library.meeting(id) != nil, !isTakenElsewhere(id) else { return }
        if let request = giveBackHeld(id) ?? library.requestProcessing(id, mode: .summaryOnly, templateID: templateID) {
            link.nudge(request)
        }
    }

    /// Summarizes here or in the cloud, holding a claim on a Summarize request so no Mac does it too. Here, the
    /// processor runs it (`runHere`) under its rules; in the cloud, it runs now.
    private func run(_ id: UUID, _ place: SummaryPlace, reason chosen: CloudReason? = nil) {
        if place == .thisDevice, runHere == nil { return send(id) }
        // The device that sends it applies its own switches, as the conversation is now: one moved to a placement kept
        // off the cloud (or a switch turned off) since it was placed goes here, or to a Mac.
        if case .cloud = place, let meeting = library.meeting(id), !preferences.allowsCloud(for: meeting) {
            return options.thisDeviceCanSummarize ? run(id, .thisDevice) : send(id)
        }
        let templateID = templates.removeValue(forKey: id)
        guard running[id] == nil, let meeting = library.meeting(id), !isTakenElsewhere(id),
              let claimed = library.claimSummary(id, templateID: templateID, at: clock()) else {
            forget(id)
            placements.end(id)
            return
        }
        let reason = placements[id]?.cloudReason ?? chosen
        // A retry after a failure here carries that failure: if the cloud can't read it either, the request fails with it.
        let failedHere = localFailures.removeValue(forKey: id)
        // Declined the cloud and placed here: a failure here mustn't bring the cloud back.
        if place == .thisDevice, placements[id]?.prefersLocal == true { keptHere.insert(id) }
        placements.end(id)
        link.nudge(claimed)
        guard case .cloud(let model) = place, let cloud = cloudSummarizer else {
            // The processor's work from here: its status says "Summarizing on this iPhone".
            runHere?(id, claimed)
            return
        }
        // From here it shows as running (`runs`), whether it was placed here or taken from a waiting request.
        runs[id] = place
        let started = clock()
        let template = (claimed.templateID ?? templateID).map { SummaryTemplate.resolved(id: $0, kind: meeting.kind, templates: library.templates) }
            ?? library.resolvedTemplate(for: meeting)
        let vocabulary = library.glossary.filter { $0.approved || $0.sourceMeetingIDs.contains(id) }.map(\.term)
        let effort = preferences.effort
        let task = Task { [weak self] in
            do {
                let output = try await cloud.summaryOutput(meeting, template: template, vocabulary: vocabulary, model: model, effort: effort) { _ in }
                try Task.checkCancellation()
                await self?.finished(id, request: claimed.id, output: output, place: place, started: started, writtenFrom: meeting,
                                     cloudReason: reason)
            } catch CloudError.inputTooLong {
                // Longer than the cloud model can read: nothing was sent; here, or a Mac, instead (after a failure here,
                // the request fails with that failure).
                self?.cloudCouldntRead(id, request: claimed.id, failedHere: failedHere)
            } catch is CancellationError {
                self?.stopped(id, request: claimed.id, failure: nil)
            } catch {
                self?.stopped(id, request: claimed.id, failure: error)
            }
        }
        running[id] = (claimed.id, task)
    }

    private func finished(_ id: UUID, request: UUID, output: SummaryProcessingOutput, place: SummaryPlace, started: Date,
                          writtenFrom meeting: Meeting, cloudReason: CloudReason?) async {
        running[id] = nil
        runs[id] = nil
        forget(id)
        let applied = library.applyPlacedSummary(output.summary, to: id, place: place, started: started, writtenFrom: meeting,
                                                 cloudReason: cloudReason)
        library.completeProcessingRequest(request, in: id, at: clock())
        guard applied else { return }
        library.update(id) { $0.errorMessage = output.warnings.isEmpty ? nil : output.warnings.joined(separator: "\n") }
        try? await library.proposeTerms(output.suggestedTerms, for: id)
    }

    /// The cloud model couldn't read the conversation (nothing was sent): this iPhone summarizes it when it can, else the
    /// request goes back for a Mac. When it already failed here, the request fails with that failure instead, so the two
    /// never hand it back and forth.
    private func cloudCouldntRead(_ id: UUID, request: UUID, failedHere: (request: UUID, reason: String, kind: ProcessingRequest.FailureKind)?) {
        running[id] = nil
        runs[id] = nil
        if let failedHere {
            forget(id)
            library.failProcessingRequest(request, in: id, reason: failedHere.reason, kind: failedHere.kind, at: clock())
            return
        }
        // Summarized here next: a failure here mustn't try the cloud again.
        keptHere.insert(id)
        if options.thisDeviceCanSummarize, let runHere, let claimed = library.meeting(id)?.processingRequests?.first(where: { $0.id == request }) {
            runHere(id, claimed)
        } else if let released = library.releaseProcessingRequest(request, in: id, at: clock()) {
            link.nudge(released)
        }
    }

    /// Cancelled (given back: a Mac may take it) or failed (with the error's words and kind, for Try Again).
    private func stopped(_ id: UUID, request: UUID, failure: Error?) {
        running[id] = nil
        runs[id] = nil
        forget(id)
        if let failure { library.failProcessingRequest(request, in: id, error: failure, at: clock()) }
        else { library.releaseProcessingRequest(request, in: id, at: clock()) }
    }

    /// Stops a summary running in the cloud; the request goes back for a Mac.
    func stop(_ id: UUID) { running[id]?.task.cancel() }
}
