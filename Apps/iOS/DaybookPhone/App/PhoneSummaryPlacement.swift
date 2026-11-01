import Combine
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
/// planner as the Mac's, with what an iPhone offers: its own summarizer when it has one (`localSummarizer`;
/// none yet, so its summaries go to a Mac or the cloud), the Macs that summarize and are reachable now (over
/// the link, or seen through sync in the last 15 minutes), and the cloud model the person's keys and
/// preferences resolve to.
///
/// - **Due** (`summaryIsDue`, once this iPhone has a transcript of its own): with the cloud on offer it
///   counts down 15 s (or the setting) to its default: this iPhone, else "Summarizing on Vlad's MacBook
///   Pro". With nowhere to run it: "Waiting for a Mac to summarize · Use the Cloud", counting down when a
///   Mac becomes reachable. Wait for a Mac passes over this iPhone.
/// - **Asked for** (`summarize`: Summarize, Summarize Again, a template): it starts at once, where it can;
///   with no Mac reachable, the request waits for one in the library, and Use the Cloud takes it back.
/// - **Sending to a Mac** writes a Summarize request (`ProcessingRequest`, the existing path) and nudges
///   connected Macs. **Here or in the cloud**, this iPhone claims the summary through a request first, so
///   no Mac summarizes it too, and keeps a summary another device wrote meanwhile.
/// - **A Mac's own countdown** (over the link) shows here, with Use the Cloud and Start Now sent to it; this
///   iPhone stops its own countdown for that conversation.
/// - **In the background**, where a countdown can't run, each countdown's default happens at once, and a
///   summary waiting for a Mac is left to one through the library.
@MainActor
@Observable
final class PhoneSummaryPlacement {
    /// What's being placed, by conversation (`placements`' planners, observable here).
    private(set) var planners: [UUID: SummaryPlacementPlanner] = [:]
    /// Summaries running here or in the cloud, by conversation: "Summarizing with Claude Sonnet 5.5".
    private(set) var runs: [UUID: SummaryPlace] = [:]
    /// The cloud models the person's keys reach, as the cloud last said.
    private(set) var cloudModels: [CloudModel] = []
    /// How the person wants summaries placed (Settings › Cloud).
    var preferences: CloudSummaryPreferences {
        didSet {
            guard preferences != oldValue else { return }
            preferences.save(to: defaults)
            refresh()
        }
    }
    /// This iPhone's own summarizer, once it has one (the iPhone's processing models fill it in).
    @ObservationIgnored var localSummarizer: (any LocalSummarizing)? { didSet { refresh() } }
    /// Summaries in the cloud, with the person's own keys. Nil until there's a cloud to use.
    @ObservationIgnored var cloudSummarizer: (any CloudSummarizing)? { didSet { Task { await refreshCloudModels() } } }

    @ObservationIgnored let placements: SummaryPlacements
    @ObservationIgnored private let library: LibraryController
    @ObservationIgnored private let link: PhoneLink
    @ObservationIgnored private let presence: () -> [KnownSyncDevice]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    /// Summaries running here or in the cloud, with the request this iPhone claimed for each.
    @ObservationIgnored private var running: [UUID: (request: UUID, task: Task<Void, Never>)] = [:]
    /// The template each was asked for with; nil uses the conversation's own.
    @ObservationIgnored private var templates: [UUID: String] = [:]
    @ObservationIgnored private var subscription: AnyCancellable?

    init(library: LibraryController, link: PhoneLink, presence: @escaping () -> [KnownSyncDevice], defaults: UserDefaults,
         clock: @escaping () -> Date = Date.init, runsTimer: Bool = true) {
        self.library = library
        self.link = link
        self.presence = presence
        self.defaults = defaults
        self.clock = clock
        let preferences = CloudSummaryPreferences.load(from: defaults)
        self.preferences = preferences
        placements = SummaryPlacements(preferences: preferences, waitsForMacs: true, clock: clock, runsTimer: runsTimer)
        subscription = placements.$planners.sink { [weak self] planners in self?.planners = planners }
        placements.onSettled = { [weak self] id, phase in self?.settled(id, phase) }
        // A Mac's countdown or work on a conversation ends this iPhone's own countdown for it.
        link.onLiveProgress = { [weak self] _ in self?.refresh() }
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

    /// The cloud model on offer, if any.
    var cloudOffer: CloudModel? { preferences.resolve(in: cloudModels) }

    var options: SummaryOptions {
        SummaryOptions(thisDeviceCanSummarize: localSummarizer?.canSummarize ?? false, macs: reachableMacs, cloud: cloudOffer)
    }

    /// What's on offer changed (a Mac came or went, presence, a key, this iPhone's summarizer): every countdown
    /// follows, and one a Mac has taken meanwhile stops here.
    func refresh() {
        placements.update(options: options, preferences: preferences)
        for id in placements.undecided where isTakenElsewhere(id) { placements.end(id) }
        // A summary this iPhone runs that another device took over in a merge: it stands down.
        for (id, run) in running {
            guard let request = library.meeting(id)?.processingRequests?.first(where: { $0.id == run.request }) else { continue }
            if let holder = request.activeClaim(at: clock()), holder.device.id != library.thisDevice.id { run.task.cancel() }
        }
    }

    func refreshCloudModels(refresh: Bool = false) async {
        let models = await cloudSummarizer?.availableModels(refresh: refresh) ?? []
        if models != cloudModels { cloudModels = models }
        self.refresh()
    }

    // MARK: Starting

    /// A conversation's summary is due on this iPhone: its own transcript is ready (the iPhone's processing
    /// calls this). A Mac already working on it keeps it.
    func summaryIsDue(_ id: UUID, templateID: String? = nil) {
        guard !isTakenElsewhere(id) else { return }
        if let templateID { templates[id] = templateID }
        refresh()
        placements.begin(id)
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
            case .waitForMac: break
            }
        } else if action == .useCloud, let model = cloudOffer, waitingSummaryRequest(id) != nil {
            run(id, .cloud(model))
        }
    }

    /// Leaving the screen: a countdown can't run in the background, so each one's default happens now, and a
    /// summary waiting for a Mac is left to one through the library.
    func leftForeground() {
        placements.startDefaultsNow()
        for id in placements.undecided { send(id) }
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

    /// A Mac is working on the conversation, or counting down to: it has it.
    func isTakenElsewhere(_ id: UUID) -> Bool {
        if let live = link.liveProgress[id], !live.isFinished { return true }
        return library.meeting(id)?.summaryHolder(excluding: library.thisDevice.id, at: clock()) != nil
    }

    // MARK: Running

    private func settled(_ id: UUID, _ phase: SummaryPlacementPlanner.Phase) {
        switch phase {
        case .started(.mac), .waiting:
            send(id)
        case .started(let place):
            run(id, place)
        case .countingDown, .waitingForMac:
            break
        }
    }

    /// Hands the summary to a Mac: a Summarize request in the library (a Mac that's here hears of it now).
    private func send(_ id: UUID) {
        defer { placements.end(id) }
        guard library.meeting(id) != nil, !isTakenElsewhere(id) else { return }
        if let request = library.requestProcessing(id, mode: .summaryOnly, templateID: templates.removeValue(forKey: id)) {
            link.nudge(request)
        }
    }

    /// Summarizes here or in the cloud, holding a claim on a Summarize request so no Mac does it too.
    private func run(_ id: UUID, _ place: SummaryPlace) {
        let templateID = templates.removeValue(forKey: id)
        guard running[id] == nil, let meeting = library.meeting(id), !isTakenElsewhere(id),
              let claimed = library.claimSummary(id, templateID: templateID, at: clock()) else {
            placements.end(id)
            return
        }
        // From here it shows as running (`runs`), whether it was placed here or taken from a waiting request.
        placements.end(id)
        runs[id] = place
        link.nudge(claimed)
        let started = clock()
        let template = (claimed.templateID ?? templateID).map { SummaryTemplate.resolved(id: $0, kind: meeting.kind, templates: library.templates) }
            ?? library.resolvedTemplate(for: meeting)
        let vocabulary = library.glossary.filter { $0.approved || $0.sourceMeetingIDs.contains(id) }.map(\.term)
        let cloud = cloudSummarizer, local = localSummarizer, effort = preferences.effort
        let task = Task { [weak self] in
            do {
                let summary: MeetingSummary
                switch place {
                case .cloud(let model):
                    guard let cloud else { throw CancellationError() }
                    summary = try await cloud.summarize(meeting, template: template, vocabulary: vocabulary, model: model, effort: effort) { _ in }
                case .thisDevice:
                    guard let local else { throw CancellationError() }
                    summary = try await local.summarize(meeting, template: template, vocabulary: vocabulary) { _ in }.summary
                case .mac:
                    throw CancellationError()
                }
                try Task.checkCancellation()
                self?.finished(id, request: claimed.id, summary: summary, place: place, started: started)
            } catch is CancellationError {
                self?.stopped(id, request: claimed.id, reason: nil)
            } catch {
                self?.stopped(id, request: claimed.id, reason: error.localizedDescription)
            }
        }
        running[id] = (claimed.id, task)
    }

    private func finished(_ id: UUID, request: UUID, summary: MeetingSummary, place: SummaryPlace, started: Date) {
        running[id] = nil
        runs[id] = nil
        library.applyPlacedSummary(summary, to: id, place: place, started: started)
        library.completeProcessingRequest(request, in: id, at: clock())
    }

    /// Cancelled (given back: a Mac may take it) or failed (with the reason, for Try Again).
    private func stopped(_ id: UUID, request: UUID, reason: String?) {
        running[id] = nil
        runs[id] = nil
        if let reason { library.failProcessingRequest(request, in: id, reason: reason, at: clock()) }
        else { library.releaseProcessingRequest(request, in: id, at: clock()) }
    }

    /// Stops a summary running here or in the cloud; the request goes back for a Mac.
    func stop(_ id: UUID) { running[id]?.task.cancel() }
}
