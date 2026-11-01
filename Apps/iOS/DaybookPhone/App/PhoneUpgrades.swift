import DaybookKit
import Foundation
import Observation
import SwiftUI

extension EnvironmentValues {
    /// "Upgrade" offers for the conversation page. Nil in previews and tests that don't set it: nothing is offered.
    @Entry var upgrades: PhoneUpgrades? = nil
}

/// "Upgrade" on this iPhone (docs/multipoint.md, "Upgrade"): the conversation page offers to redo its transcript, speakers,
/// or summary when a clearly better model is within reach, in the Mac's words: "Upgrade transcript on Vlad's MacBook Pro",
/// "Upgrade summary with Claude Sonnet 5.5", or "Upgrade transcript" when this iPhone's own models are the better ones
/// (its own recordings only, as it processes them).
///
/// - **Within reach:** this iPhone's processing models, the Macs reachable now (over the link, or seen through sync in
///   the last 15 minutes) that say what they run, and the cloud model Settings › Cloud resolves to, unless Never.
/// - **Upgrade** asks the device with the better model: a request a Mac (or this iPhone's processor) carries out, with
///   every later step; this iPhone's summary goes through the placement like any due summary (`summaryIsDue`: held,
///   counting down), and the cloud's starts there at once.
/// - **Dismiss** is kept on the conversation and syncs, so the offer goes on every device.
@MainActor
@Observable
final class PhoneUpgrades {
    @ObservationIgnored private let library: LibraryController
    @ObservationIgnored private let placement: PhoneSummaryPlacement
    @ObservationIgnored private let link: PhoneLink
    @ObservationIgnored private let presence: () -> [KnownSyncDevice]
    @ObservationIgnored private let clock: () -> Date
    /// What this iPhone's processing models can do now (`PhoneAppModel.processingCapabilities`).
    @ObservationIgnored var capabilities: () -> ProcessingCapabilities = { .none }
    /// Whether a recording was made or brought in on this iPhone: only those it redoes itself.
    @ObservationIgnored var owns: () -> @Sendable (RecordingTrack) -> Bool = { { _ in false } }
    /// Starts this iPhone's processor on a request it made for itself.
    @ObservationIgnored var pickUp: () -> Void = {}
    /// Bumped when what this iPhone's own models can do changes (`refresh`), so a page showing an offer reads it again.
    private var revision = 0

    init(library: LibraryController, placement: PhoneSummaryPlacement, link: PhoneLink, presence: @escaping () -> [KnownSyncDevice],
         clock: @escaping () -> Date = Date.init) {
        self.library = library
        self.placement = placement
        self.link = link
        self.presence = presence
        self.clock = clock
    }

    /// What this iPhone can reach for an upgrade now.
    var candidates: UpgradeCandidates {
        let owns = self.owns()
        let connected = link.connectedMacs.map {
            SummarizingMac.Connected(id: $0.id, syncDeviceID: $0.syncDeviceID, name: $0.name, capabilities: $0.processing, canProcess: $0.canProcess)
        }
        return UpgradeCandidates(thisDevice: capabilities(),
                                 redoesRecordings: { meeting in !meeting.transcribableTracks.isEmpty && meeting.transcribableTracks.allSatisfy(owns) },
                                 macs: ProcessingMac.reachable(connected: connected, presence: presence(), now: clock()),
                                 cloud: placement.cloudOffer)
    }

    /// The offer the page makes now; nil while the conversation's summary is held, counts down, or runs here or in the
    /// cloud, while anything works or waits, or when nothing within reach is clearly better.
    func offer(for meeting: Meeting, now: Date = Date()) -> UpgradeOffer? {
        _ = revision
        guard placement.planners[meeting.id] == nil, placement.runs[meeting.id] == nil else { return nil }
        return Upgrades.offer(for: meeting, status: ProcessingStatus.phone(meeting, now: now), candidates: candidates)
    }

    /// This iPhone's processing models changed (downloaded, removed, or Transcribe on This iPhone switched): offers are
    /// worked out again.
    func refresh() { revision &+= 1 }

    /// Upgrade: the work goes to the device with the better model.
    func accept(_ offer: UpgradeOffer, for id: UUID) async {
        switch (offer.role, offer.place) {
        case (.summarization, .thisDevice):
            // This iPhone's own summary, as any due one: held, and counting down while the cloud is on offer.
            await placement.summaryIsDue(id)
        case (.summarization, .cloud):
            // The person chose the cloud's better summary: it starts there at once.
            await placement.summaryIsDue(id)
            placement.perform(.useCloud, for: id)
        default:
            // A Mac's, or this iPhone's own recordings redone by its processor: a request naming the device.
            guard let request = library.requestUpgrade(offer, in: id, at: clock()) else { return }
            if case .mac = offer.place { link.nudge(request) } else { pickUp() }
        }
    }

    /// Dismiss: kept on the conversation, so the offer goes on every device.
    func dismiss(_ offer: UpgradeOffer, for id: UUID) {
        library.dismissUpgrade(offer, in: id, at: clock())
    }
}
