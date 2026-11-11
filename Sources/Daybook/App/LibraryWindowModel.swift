import DaybookKit
import DaybookUI
import Foundation
import Observation

/// Where the person is in the library window: the place, the conversation on the page, its side, search, the
/// selection of several, the window's sheet, and the requests other windows and menus make of it (a passage, a block
/// of the summary, the title's focus). The Mac's twin of the iPhone's `ReadingSession`, named as it names them.
/// `AppState` owns one (`window`), and Floating Notes, the menus, and the menu bar extra read it there.
///
/// It's `@Observable` apart from the processing queue: a view that reads where the person is doesn't redraw for a
/// job's progress, the queue, or a download (`WindowInvalidationTests`).
@MainActor
@Observable
final class LibraryWindowModel {
    /// The lock for Personal conversations: what `openID` asks before showing one.
    @ObservationIgnored let personalLock: PersonalLock
    /// This Mac's preferences, which keep the reading scale.
    @ObservationIgnored private let preferences: UserDefaults

    init(personalLock: PersonalLock, defaults: UserDefaults) {
        self.personalLock = personalLock
        preferences = defaults
        readingScale = defaults.object(forKey: AppState.Preference.readingScale) as? Double ?? 1
    }

    /// The sidebar selection: a library section, a folder, or a device.
    var place: LibraryPlace = .section(.all)
    /// The conversation the list selects, which the page, the inspector, Version History, Share, the menus, and
    /// Floating Notes act on. A Personal one behind the lock (`personalLock`) is selected only once the person unlocks
    /// it: setting it asks, and the selection stays where it was meanwhile, so nothing shows it locked.
    var openID: UUID? {
        get { opened }
        set {
            guard let id = newValue, personalLock.hides(id) else {
                unlocking = nil
                opened = newValue
                return
            }
            unlocking = id
            Task {
                guard await personalLock.unlock(), unlocking == id else { return }
                unlocking = nil
                opened = id
            }
        }
    }
    private var opened: UUID?
    /// The Personal conversation waiting for the person to unlock it: selected once they do, unless they chose another.
    @ObservationIgnored private var unlocking: UUID?

    /// The side of the page that shows alone: in a column too narrow for two pages, or once the person collapses the
    /// spread to it.
    var pageMode: PageMode = .summary
    /// Whether the page shows Summary and Transcript side by side where the detail column has room for two pages
    /// (`pageSpreadFits`); the toolbar's switch collapses it to one page, and the window keeps the choice
    /// (`LibraryRestoration`).
    var pageSpreadChosen = true
    /// The detail column has room for two pages now (`PageSpreadLayout`): the page says so as it lays out.
    var pageSpreadFits = false
    /// A transcript passage the page should scroll to, from search or a bookmark.
    var pageScrollTarget: UUID?
    /// A block of the summary page to bring into view, asked for from elsewhere (Show in Your Notes on the transcript,
    /// a search hit in the notes), with a token so asking for the same block twice still moves it: the iPhone's
    /// `ReadingSession.summaryRequest`. The page takes it once (`takeSummaryRequest(for:)`).
    private(set) var summaryRequest: ScrollRequest?
    /// The conversation `summaryRequest` is for, until a summary page takes it.
    @ObservationIgnored private var summaryRequestFor: UUID?
    @ObservationIgnored private var nextToken = 0

    // Search
    var searchText = ""
    var searchTokens: [SearchToken] = []
    var searchScope: SearchScope = .all
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty || !searchTokens.isEmpty }

    /// Several conversations selected in the list; empty when one or none is.
    var selection: Set<UUID> = []
    /// The one sheet the main window shows at a time.
    var sheet: ActiveSheet?
    /// Conversations waiting for the person to confirm moving them to the Trash.
    var confirmingTrash: [UUID] = []
    /// Set to move keyboard focus to a conversation's title on its page.
    var titleFocusRequest: UUID?
    /// A moment's word over the page after something that leaves nothing else to see: Copy Summary's "Copied", from
    /// whichever menu it came (`ConfirmationBeat`).
    var confirmation: ConfirmationBeat?
    /// View › Make Text Bigger scales only the reading surface.
    var readingScale: Double { didSet { preferences.set(readingScale, forKey: AppState.Preference.readingScale) } }

    /// The lock locked again: a Personal conversation on the page gives way to `firstShown` (the place's first that
    /// isn't hidden), and a selection of several lets hidden ones go.
    func lockReturned(firstShown: () -> UUID?) {
        unlocking = nil
        if let id = opened, personalLock.hides(id) { opened = firstShown() }
        if selection.contains(where: personalLock.hides) { selection = [] }
    }

    // MARK: The page's sides

    /// Whether the page shows Summary and Transcript side by side now: the detail column has room for two pages,
    /// there's a transcript's page (`hasTranscript`: `AppState.hasTranscriptPage`), and the person hasn't collapsed it
    /// to one.
    func showsPageSpread(hasTranscript: Bool) -> Bool {
        pageSpreadFits && pageSpreadChosen && hasTranscript
    }

    /// Where Summary | Transcript is a pair of toggles rather than a switch: the column has room for two pages, and
    /// there's a transcript's page to put beside the summary.
    func pairsPages(hasTranscript: Bool) -> Bool {
        pageSpreadFits && hasTranscript
    }

    /// Which sides of the page show, as the toolbar's switch and the View menu light them.
    func pageSides(hasTranscript: Bool) -> PageSides {
        PageSides(spread: showsPageSpread(hasTranscript: hasTranscript), mode: hasTranscript ? pageMode : .summary)
    }

    /// The toolbar's Summary or Transcript, or View › Summary (⌘1) or Transcript (⌘2) (`PageSides`).
    func choosePage(_ side: PageMode, hasTranscript: Bool) {
        let next = PageSides(spread: pageSpreadChosen, mode: pageMode).choosing(side, pairs: pairsPages(hasTranscript: hasTranscript))
        if next.spread != pageSpreadChosen { pageSpreadChosen = next.spread }
        if next.mode != pageMode { pageMode = next.mode }
    }

    /// Brings a side of the page into view for something asked elsewhere (a passage, Your notes, Find): in a spread
    /// it's already beside the other, so the page doesn't turn.
    func turnPage(to side: PageMode) {
        guard !(pageSpreadFits && pageSpreadChosen) else { return }
        pageMode = side
    }

    /// Shows a passage in the transcript: it scrolls there and flashes it, the page turning to it first unless the
    /// transcript is beside the summary.
    func showPassage(_ segmentID: UUID) {
        pageScrollTarget = segmentID
        turnPage(to: .transcript)
    }

    /// Asks `id`'s summary page to bring `block` (`SummaryBlockID`) into view, as the iPhone's
    /// `ReadingSession.showOnSummary` does.
    func showOnSummary(_ block: String, in id: UUID) {
        nextToken += 1
        summaryRequest = ScrollRequest(target: block, token: nextToken, flash: false)
        summaryRequestFor = id
    }

    /// The block for this conversation's summary page, once. Taking clears the request, and a request made for another
    /// conversation is dropped: the person has moved on from it.
    func takeSummaryRequest(for id: UUID) -> String? {
        defer { summaryRequestFor = nil }
        return summaryRequestFor == id ? summaryRequest?.target : nil
    }
}

/// The page's sides as the toolbar's Summary | Transcript chooses them where the window has room for two pages: a pair
/// of toggles, both lit while both pages show. Choosing a lit one keeps that page alone; choosing the other puts it back
/// beside it; one page always shows. Where there's room for one page it's a switch, and the spread waits for the room.
struct PageSides: Equatable {
    /// Both pages, side by side.
    var spread: Bool
    /// The page that shows alone.
    var mode: PageMode

    /// Whether `side` shows (is lit).
    func shows(_ side: PageMode) -> Bool { spread || mode == side }

    /// After `side` is chosen. `pairs`: the window has room for two pages (else it's a switch).
    func choosing(_ side: PageMode, pairs: Bool) -> PageSides {
        guard pairs else { return PageSides(spread: spread, mode: side) }
        if spread { return PageSides(spread: false, mode: side) }
        return side == mode ? self : PageSides(spread: true, mode: side)
    }
}
