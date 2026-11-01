import DaybookCore
import DaybookKit
import Foundation

/// "Upgrade" on this Mac (docs/multipoint.md, "Upgrade"). A conversation whose transcript, speakers, or summary a clearly
/// better model within reach could redo says so on its page, in one line with Upgrade and Dismiss: "Upgrade transcript"
/// when this Mac has the model, "Upgrade transcript on Studio Mac" when another Mac does, "Upgrade summary with Claude
/// Sonnet 5.5" for the cloud.
///
/// - **Within reach:** this Mac's own models (whether or not it takes other devices' work), the other Macs seen through
///   sync in the last 15 minutes that say what they run, and the cloud model Settings › Cloud resolves to, unless Never.
/// - **Upgrade** here queues the step's own work (Transcribe Everything Again, Identify Speakers Again, Summarize Again)
///   marked as an upgrade, which redoes every later step; its summary counts down as a due one does, or goes to the cloud
///   at once when the cloud was the better model. On another Mac, it's a request naming that Mac, which it (or another Mac
///   with a model as good) carries out.
/// - **Dismiss** is kept on the conversation and syncs; a later, better model may offer again.
extension AppState {
    /// How good each model is: this Mac's catalog (the person's added models are unranked) and the cloud's.
    var upgradeRanks: UpgradeRanks { UpgradeRanks(catalog: modelCatalog) }

    /// What this Mac can reach for an upgrade now.
    var upgradeCandidates: UpgradeCandidates {
        UpgradeCandidates(thisDevice: processingCapabilities, macs: ProcessingMac.reachable(connected: [], presence: syncDevices),
                          cloud: upgradeCloud)
    }

    /// The cloud model on offer for an upgrade: Settings › Cloud's, unless Never. Nil until Settings › Cloud is first
    /// needed (`prepareUpgradeOffer`), so a launch that never shows a page an upgrade could reach the cloud for never
    /// reads the keychain.
    var upgradeCloud: CloudModel? {
        guard hasCloudSetup, cloud.preferences.policy != .never else { return nil }
        return cloud.resolved?.model
    }

    /// The offer the conversation's page makes now; nil while it records, counts down, works, or waits, or when nothing
    /// within reach is clearly better.
    func upgradeOffer(for meeting: Meeting) -> UpgradeOffer? {
        guard recordingID != meeting.id, placements[meeting.id] == nil else { return nil }
        #if DEBUG
        guard UpgradeDemo.showsOffers else { return nil }
        #endif
        return Upgrades.offer(for: meeting, status: processingStatus(for: meeting), candidates: upgradeCandidates, ranks: upgradeRanks)
    }

    /// The page asks before it shows a conversation whose summary the cloud could do clearly better: Settings › Cloud is
    /// made (reading the keys) so the offer can name a cloud model.
    func prepareUpgradeOffer(for meeting: Meeting) async {
        guard !hasCloudSetup, let current = meeting.upgradeCurrent(.summarization, ranks: upgradeRanks),
              let best = upgradeRanks.cloud.models.compactMap(\.summaryQuality).max(),
              best >= current.quality + UpgradeRole.summarization.margin else { return }
        await cloud.reload()
        objectWillChange.send()
    }

    /// Upgrade: the work goes to the device with the better model (docs/multipoint.md, "Upgrade").
    func acceptUpgrade(_ offer: UpgradeOffer, for id: UUID) {
        switch offer.place {
        case .thisDevice, .cloud:
            enqueue(id, mode: offer.role.mode, upgrade: offer.request(by: library.thisDevice))
        case .mac:
            guard library.requestUpgrade(offer, in: id) != nil else { return }
            sync.requestSync()
        }
    }

    /// Dismiss: kept on the conversation, so the offer goes on every device.
    func dismissUpgrade(_ offer: UpgradeOffer, for id: UUID) {
        library.dismissUpgrade(offer, in: id)
    }

    /// The devices in the library's presence records, read again after each sync pass: other Macs and what they run.
    func refreshSyncDevices() async {
        let devices = await sync.knownDevices()
        if devices != syncDevices { syncDevices = devices }
    }
}
