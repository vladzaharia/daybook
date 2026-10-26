import DaybookKit
import Foundation

/// Debug launch arguments that put a reading surface on screen for screenshots, without tapping:
///
///     --select "<title prefix>"          open that conversation
///     --page summary|transcript          which side one column shows
///     --spread library|conversation      the notebook's spread (default: conversation when selected)
///     --place work|personal|trash|folder:<name>
///     --search "<query>"                 the library search
///     --select-many <n>                  multi-select the first n conversations
///     --sheet info|history|correct|heard|move|tags|photo|photos
///     --scroll-to "<words>"              bring the passage containing these words into view
///     --summary-scroll notes|bookmarks|next-steps|colophon   bring that part of the summary into view
///     --play [<seconds>]                 start playback there, silently
///     --play-muted                       anything played plays silently (for UI tests)
///     --simulate-download                audio "downloads" slowly (see `SimulatedAudioProvider`)
///     --simulate-offline                 audio isn't on this iPhone and can't be fetched
///
/// Release builds ignore all of them.
struct ReadingLaunch {
    var select: String?
    var page: PageMode?
    var spread: String?
    var place: String?
    var search: String?
    var selectMany: Int?
    var sheet: String?
    var scrollTo: String?
    var summaryScroll: String?
    var play: Double?
    var muted = false
    private(set) var applied = false

    init(arguments: [String] = CommandLine.arguments) {
        #if DEBUG
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        select = value("--select")
        page = value("--page").flatMap(PageMode.init(rawValue:))
        spread = value("--spread")
        place = value("--place")
        search = value("--search")
        selectMany = value("--select-many").flatMap(Int.init)
        sheet = value("--sheet")
        scrollTo = value("--scroll-to")
        summaryScroll = value("--summary-scroll")
        muted = arguments.contains("--play-muted")
        if let index = arguments.firstIndex(of: "--play") {
            play = arguments.indices.contains(index + 1) ? Double(arguments[index + 1]) ?? 0 : 0
        }
        #endif
    }

    var isEmpty: Bool {
        select == nil && page == nil && spread == nil && place == nil && search == nil && selectMany == nil && sheet == nil && play == nil
    }

    /// Applies the arguments once the library has loaded.
    @MainActor
    mutating func apply(to session: ReadingSession, library: LibraryController, provider: any AudioProviding) {
        guard !applied, library.isLoaded else { return }
        applied = true
        if muted { session.player.muted = true }
        guard !isEmpty else { return }
        switch place {
        case "work"?: session.place = .library(.section(.work))
        case "personal"?: session.place = .library(.section(.personal))
        case "trash"?: session.place = .trash
        case let value? where value.hasPrefix("folder:"):
            let name = String(value.dropFirst("folder:".count))
            if let folder = library.folders.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                session.place = .library(.folder(folder.id))
            }
        default: break
        }
        if let search {
            session.searchText = search
            session.isSearchPresented = true
        }
        if let selectMany, let place = session.place.libraryPlace {
            session.isSelecting = true
            session.selection = Set(place.meetings(in: library.meetings).prefix(selectMany).map(\.id))
        }
        guard let select, let meeting = library.meetings.first(where: { $0.title.localizedCaseInsensitiveContains(select) }) else { return }
        if spread == "library" {
            session.select(meeting.id)
        } else {
            session.open(meeting.id, mode: page ?? .summary)
        }
        if let page { session.pageMode = page }
        if let summaryScroll { session.showOnSummary(summaryScroll) }
        if let page { session.pageMode = page }
        if let scrollTo, let segment = meeting.unifiedTranscript.first(where: { $0.text.localizedCaseInsensitiveContains(scrollTo) }) {
            session.showInTranscript(segment.id, flash: false, switchPage: page == .transcript)
        }
        switch sheet {
        case "photos"?: session.sheet = .importPhotos(meeting.id)
        case "photo"?:
            if let photo = meeting.visiblePhotos.first { session.sheet = .photo(meetingID: meeting.id, photoID: photo.id) }
        case "info"?: session.sheet = .info(meeting.id)
        case "history"?: session.sheet = .history(meeting.id)
        case "move"?: session.sheet = .move([meeting.id])
        case "tags"?: session.sheet = .tags([meeting.id])
        case "correct"?:
            if let segment = scrollTarget(in: meeting) { session.sheet = .correct(meetingID: meeting.id, segmentID: segment) }
        case "heard"?:
            if let segment = scrollTarget(in: meeting) { session.sheet = .heardIn(meetingID: meeting.id, segmentID: segment) }
        default: break
        }
        if let play {
            session.player.muted = true
            session.player.play(.timeline(play), in: meeting, provider: provider)
        }
    }

    private func scrollTarget(in meeting: Meeting) -> UUID? {
        if let scrollTo, let segment = meeting.unifiedTranscript.first(where: { $0.text.localizedCaseInsensitiveContains(scrollTo) }) { return segment.id }
        return meeting.unifiedTranscript.first?.id
    }
}
