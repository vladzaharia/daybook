import DaybookDesign
import DaybookKit
import DaybookUI
import Foundation

/// What the status sheet adds to the overview both apps share (docs/iphone.md, "Status sheet"): its sizes, its title,
/// where a line leads when it's tapped, and this iPhone's own words. What each line and card says is DaybookKit's
/// `StatusOverviewModel`, from the facts `StatusSheetInputs.make` gathers; the views only draw them, with the overview
/// both apps share (DaybookUI's `StatusOverview`).
enum StatusDetent: String, CaseIterable, Sendable {
    case medium, large

    /// How deep the overview goes at this size: cards, then cards with what can be done.
    var density: StatusDensity {
        switch self {
        case .medium: return .cards
        case .large: return .manage
        }
    }
}

/// What tapping a line does (the strip's, or iCloud's in the sheet): a line that needs the person goes to where it's
/// fixed; the rest show the sheet.
enum StatusLineRoute: Equatable {
    case showMore
    /// More of the sheet, at the group that says what to do (the Macs card, for a Mac).
    case showFix(StatusSection)
    case open(SettingsRoute)
}

enum StatusSheetModel {
    /// The sheet's title, and the More menu's item that shows it while everything is calm.
    static let title = "Devices"

    /// Whether the recorder cards show storage, actions, and waiting recordings.
    static func showsManagement(_ detent: StatusDetent) -> Bool { detent == .large }

    /// The audio kept on this iPhone, as Settings › Storage's row says it: downloads and recordings
    /// made here together, so not "downloaded".
    static func audioOnThisIPhone(bytes: UInt64) -> String {
        bytes == 0 ? "No audio on this iPhone" : "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)) of audio"
    }

    /// Where a line leads when it's tapped. A line that needs the person goes to where it's fixed: iCloud's to
    /// Settings › iCloud, a recorder's to its page, a paired Mac's that can't connect to its page, and a Mac that
    /// isn't set up to transcribe (paired here or not) to the Macs card, which says what to do and lists what it
    /// couldn't finish. Every other line shows the sheet.
    static func route(for line: StatusLineWords, _ inputs: StatusOverviewInputs) -> StatusLineRoute {
        guard line.tone == .attention else { return .showMore }
        if line.id == StatusOverviewModel.syncID { return .open(.icloud) }
        if line.id == StatusOverviewModel.macID { return .showFix(.macs) }
        if let mac = inputs.pairedMacs.first(where: { StatusOverviewModel.pairedID($0) == line.id }) {
            return mac.notProcessing ? .showFix(.macs) : .open(.mac(mac.id))
        }
        if line.id.hasPrefix("recorder-") { return .open(.device(String(line.id.dropFirst("recorder-".count)))) }
        return .showMore
    }

    /// What VoiceOver says tapping a line does.
    static func hint(for route: StatusLineRoute) -> String {
        switch route {
        case .showMore: return "Shows more"
        case .open(.icloud): return "Opens iCloud settings"
        case .showFix, .open: return "Shows how to fix it"
        }
    }

    /// iCloud's line when it can't be used, from the reason sync gave: the reason in a few words, as Settings'
    /// iCloud row says it (`SyncStatus.shortText`). Its narrow form is "Off" (`syncShort`).
    static func unavailablePhrase(_ reason: String) -> String {
        switch reason {
        case CloudAvailability.signedOutMessage: return SyncStatus.signedOut.shortText
        case CloudAvailability.iCloudDriveOffMessage: return SyncStatus.iCloudDriveOff.shortText
        case CloudAvailability.unsetMessage: return SyncStatus.unavailableInThisBuild.shortText
        default: return SyncStatus.iCloudUnavailable(details: nil).shortText
        }
    }
}

extension StatusQueueEntry {
    /// The row both apps draw for it, under `macName`'s row (or at the top of its card, with nil).
    func item(under macName: String?, now: Date = Date()) -> StatusQueueItem {
        var actions = self.actions.map(StatusQueueItem.Action.placement)
        if let retry { actions.insert(.tryAgain(retry), at: 0) }
        return StatusQueueItem(id: id, title: title, line: line(under: macName, at: now),
                               note: requestedHere && !failed ? "Requested from this iPhone" : nil,
                               progress: isRunning ? progress : nil, isProblem: failed, detail: detail, details: details,
                               countdownUntil: countdownUntil, actions: actions)
    }
}
