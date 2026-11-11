import DaybookDesign
import DaybookKit
import DaybookUI
import Foundation

/// What the status sheet adds to the overview both apps share (docs/iphone.md, "Status sheet"): its sizes, where it
/// stands, its title, what its compact size says, where a line leads when it's tapped, and this iPhone's own words.
/// What each line and card says is DaybookKit's `StatusOverviewModel`, from the facts `StatusSheetInputs.make` gathers;
/// the views only draw them, with the overview both apps share (DaybookUI's `StatusOverview`).
enum StatusDetent: String, CaseIterable, Sendable {
    /// Minimized: Record, Import, and Search, small, and the one line with something to say, if any.
    case compact
    /// Dragged up: the lines and the cards.
    case medium
    /// Full height: the cards with what can be done.
    case large

    /// How deep the overview goes at this size: lines, then cards, then cards with what can be done.
    var density: StatusDensity {
        switch self {
        case .compact: return .lines
        case .medium: return .cards
        case .large: return .manage
        }
    }
}

/// What tapping a line does: a line that needs the person goes to where it's fixed; the rest show more of the sheet.
enum StatusLineRoute: Equatable {
    case showMore
    /// More of the sheet, at the group that says what to do (the Macs card, for a Mac).
    case showFix(StatusSection)
    case open(SettingsRoute)
}

/// The standing sheet's state, which `StatusSheetHost` keeps: its size, what it was last asked to show, and a request
/// shown on its own while it doesn't stand.
struct StatusSheetState: Equatable {
    /// The standing sheet's size: minimized at rest.
    var size: StatusDetent = .compact
    /// What the standing sheet was last asked to show: a screen in it, or a group to scroll to.
    var asked: StatusRequest?
    /// A request shown on its own while the sheet doesn't stand: a sheet in one column, a card on two pages.
    var request: StatusRequest?

    /// More › Devices, a line's tap, a recorder's notification: in the standing sheet while it stands, dragged up to
    /// the request's size; else on its own.
    mutating func show(_ next: StatusRequest, standing: Bool) {
        if standing {
            size = next.detent
            asked = next
        } else {
            request = next
        }
    }

    /// It stopped standing (a conversation, search, selection, the Trash, or the iPhone turned): back, it's minimized,
    /// not wherever it was left.
    mutating func stepAside() {
        size = .compact
        asked = nil
    }
}

enum StatusSheetModel {
    /// The sheet's title where it has one (a card on the right page, or a sheet over a conversation), and the More
    /// menu's item that shows it.
    static let title = "Devices"

    // MARK: Where it stands

    /// Where the standing sheet is: the system's sheet over the library in one column; drawn at the foot of the
    /// library's page (`StatusSheetFoot`) on two pages, and in one column on its side, where the system's would take
    /// the whole window; or nowhere.
    enum Placement: Equatable {
        case sheet, foot, none
    }

    /// The standing sheet stands while the library is the thing on screen: not over a conversation, search (the
    /// keyboard), selection (its bar), or the Trash, which nothing records into or searches. On two pages it's the
    /// left page's foot at its compact size (what's more is a card on the right page); in one column it's the system's
    /// sheet, unless the height is compact (an iPhone on its side, the Duo's cover turned), where it's the foot too.
    static func placement(
        twoPages: Bool, compactHeight: Bool, reading: Bool, searching: Bool, selecting: Bool, inTrash: Bool
    ) -> Placement {
        guard !searching, !selecting, !inTrash else { return .none }
        if twoPages { return .foot }
        if reading { return .none }
        return compactHeight ? .foot : .sheet
    }

    // MARK: What it says

    /// Whether the recorder cards show storage, actions, and waiting recordings.
    static func showsManagement(_ detent: StatusDetent) -> Bool { detent == .large }

    /// The groups under the lines at a size: none at compact; at medium and large the overview's
    /// (`StatusOverviewModel.sections`), less iCloud's line, which the lines above them already say.
    static func groups(for detent: StatusDetent, _ inputs: StatusOverviewInputs, now: Date = Date()) -> [StatusSection] {
        guard detent != .compact else { return [] }
        return StatusOverviewModel.sections(inputs, now: now).filter { $0 != .lines }
    }

    /// The lines under Record, Import, and Search at a size. Minimized, only the one with something to say
    /// (`StatusOverviewModel.strip`: what needs the person, what's recording elsewhere, what's working or counting
    /// down), and with nothing to say none, so it's the row alone; dragged up, every line.
    static func lines(for detent: StatusDetent, _ lines: [StatusLineWords]) -> [StatusLineWords] {
        guard detent == .compact else { return lines }
        return StatusOverviewModel.strip(lines).map { [$0] } ?? []
    }

    /// The audio kept on this iPhone, as Settings › Storage's row says it: downloads and recordings
    /// made here together, so not "downloaded".
    static func audioOnThisIPhone(bytes: UInt64) -> String {
        bytes == 0 ? "No audio on this iPhone" : "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)) of audio"
    }

    // MARK: Where a line leads

    /// Where a line leads when it's tapped. A line that needs the person goes to where it's fixed: iCloud's to
    /// Settings › iCloud, a recorder's to its page, a paired Mac's that can't connect to its page, and a Mac that
    /// isn't set up to transcribe (paired here or not) to the Macs card, which says what to do and lists what it
    /// couldn't finish. Every other line shows more of the sheet.
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
