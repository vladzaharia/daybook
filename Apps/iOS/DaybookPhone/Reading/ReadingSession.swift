import DaybookKit
import DaybookUI
import Observation
import SwiftUI

/// Where the person is in the library and in a conversation, kept above every layout so folding or
/// unfolding the iPhone Duo keeps it: the same place, the same conversation, the same scroll
/// positions, and the same playback. `RootView` owns one and puts it in the environment.
///
/// One column (pocket) and two pages (notebook) read the same state:
///
/// | State | Pocket | Notebook |
/// |---|---|---|
/// | `reading == false` | the list | list on the left, `openID`'s page on the right |
/// | `reading == true` | the conversation, pushed, showing `pageMode` | summary on the left, transcript on the right |
@MainActor
@Observable
final class ReadingSession {
    /// The list's place: a section, a folder, or the Trash.
    var place: ReadingPlace = .library(.section(.all))
    /// The conversation on the page, if any.
    var openID: UUID?
    /// A conversation is open as the main thing being read (pocket: pushed; notebook: both pages).
    var reading = false
    /// The person chose `openID` (rather than it being the newest by default), so folding the
    /// notebook's library spread opens it in one column.
    var chosen = false
    /// Which side of the conversation one column shows, and the page last read in two.
    var pageMode: PageMode = .summary
    /// The current layout is two pages, so a jump to the transcript opens the spread.
    var isNotebook = false
    /// The conversation in the Trash that the notebook's right page shows, read only, beside the Trash.
    var trashedID: UUID?

    /// The top of what's visible on each page, so a page reopens where it was left.
    var summaryAnchor: String?
    var transcriptAnchor: String?
    /// Where the transcript should go next (a search hit, a next step's evidence, a bookmark),
    /// with a token so asking for the same passage twice still moves it.
    private(set) var transcriptRequest: ScrollRequest?
    /// The summary page's equivalent: a block to bring into view ("notes").
    private(set) var summaryRequest: ScrollRequest?
    /// The passage that was just jumped to, briefly washed so the eye finds it.
    var flashedSegment: UUID?

    // Search
    var searchText = ""
    var searchTokens: [SearchToken] = []
    var searchScope: SearchScope = .all
    var isSearchPresented = false
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !searchTokens.isEmpty }

    // Selection
    var isSelecting = false
    var selection: Set<UUID> = []

    // Sheets
    var sheet: ReadingSheet?
    /// The camera is open to add a photo to this conversation.
    var cameraFor: UUID?
    /// Files is open to add a recording to a conversation (Add Recording…; `addRecording(to:)`).
    var showsRecordingPicker = false
    /// The conversation the files picked join, kept until the picker answers (`pickedRecordings`), however soon it
    /// closes.
    private(set) var addingRecordingTo: UUID?
    /// A moment's word over the page after something that leaves nothing else to see ("Copied").
    var confirmation: ConfirmationBeat?
    /// A new note: its notes take the keyboard when the page appears.
    var focusNotesFor: UUID?
    /// Something couldn't be done (the audio isn't here to share): an alert naming it.
    var alert: ReadingAlert?
    /// Conversations waiting for the person to confirm moving them to the Trash.
    var confirmingTrash: [UUID] = []

    let player = PlaybackController()
    /// Debug launch arguments for screenshots, applied once the library has loaded.
    @ObservationIgnored var launch = ReadingLaunch()
    @ObservationIgnored private var nextToken = 0

    struct ScrollRequest: Equatable {
        var target: String
        var token: Int
        var flash: Bool
    }

    /// Opens a conversation as the thing being read.
    func open(_ id: UUID, mode: PageMode? = nil) {
        if openID != id {
            summaryAnchor = nil
            transcriptAnchor = nil
        }
        openID = id
        chosen = true
        if let mode { pageMode = mode }
        reading = true
    }

    /// A conversation that's only your notes (photos can join it), in the place being viewed, open
    /// with the keyboard on its notes.
    @discardableResult
    /// Add Recording…: Files opens to pick recordings for this conversation.
    func addRecording(to id: UUID) {
        addingRecordingTo = id
        showsRecordingPicker = true
    }

    /// The picker's answer: the files picked and the conversation they join, once. Nil when it was cancelled or
    /// couldn't open, or for an answer already taken.
    func pickedRecordings(_ result: Result<[URL], any Error>) -> (urls: [URL], conversation: UUID)? {
        defer { addingRecordingTo = nil }
        guard let id = addingRecordingTo, case .success(let urls) = result, !urls.isEmpty else { return nil }
        return (urls, id)
    }

    func newNote(in library: LibraryController, now: Date = Date()) -> UUID {
        var folder: UUID?, placement: LibraryPlacement?
        switch place {
        case .library(.folder(let id)): folder = id
        case .library(.section(.work)): placement = .work
        case .library(.section(.personal)): placement = .personal
        default: break
        }
        let id = library.newMeeting(title: LibraryWords.noteTitle(at: now), date: now,
                                    folderID: folder, placement: placement)
        focusNotesFor = id
        open(id, mode: .summary)
        return id
    }

    /// Shows a conversation on the notebook's right page without leaving the list.
    func select(_ id: UUID) {
        if openID != id {
            summaryAnchor = nil
            transcriptAnchor = nil
            pageMode = .summary
        }
        openID = id
        chosen = true
    }

    func closeConversation() {
        reading = false
    }

    /// On two pages with nothing open, the right page shows the newest of the place, else of All, without choosing
    /// it. Beside the Trash it shows what's in the Trash instead (`trashedID`), never one of the library's.
    func showNewest(of meetings: [Meeting]) {
        guard openID == nil, !place.isTrash else { return }
        if let newest = place.libraryPlace.meetings(in: meetings).first ?? LibraryPlace.section(.all).meetings(in: meetings).first {
            openID = newest.id
            chosen = false
        }
    }

    /// Takes what the Trash read on two pages: the one shown beside it stays while it's still there, else the
    /// newest is shown, as the Mac's Trash selects its first. Not once the person has left the Trash, or is
    /// searching, while it read: the right page belongs to what they're looking at now.
    func showInTrash(from read: [Meeting]) {
        guard place.isTrash, !isSearching else { return }
        if !read.contains(where: { $0.id == trashedID }) { trashedID = read.first?.id }
    }

    /// Brings a passage into view on the transcript, switching one column to it.
    func showInTranscript(_ segmentID: UUID, flash: Bool = true, switchPage: Bool = true) {
        nextToken += 1
        transcriptRequest = ScrollRequest(target: segmentID.uuidString, token: nextToken, flash: flash)
        if switchPage {
            pageMode = .transcript
            if isNotebook { reading = true }
        }
        if flash { flashedSegment = segmentID }
    }

    /// Brings a saved live caption into view on the transcript's page.
    func showCaption(_ id: UUID) {
        nextToken += 1
        transcriptRequest = ScrollRequest(target: "caption:\(id.uuidString)", token: nextToken, flash: false)
        pageMode = .transcript
        if isNotebook { reading = true }
    }

    func showOnSummary(_ block: String) {
        nextToken += 1
        summaryRequest = ScrollRequest(target: block, token: nextToken, flash: false)
        pageMode = .summary
    }

    /// Opens a search hit at its passage: the transcript for a passage, the summary otherwise.
    func open(_ hit: SearchHit) {
        if hit.field == .transcript, let segment = hit.segmentID {
            open(hit.meetingID, mode: .transcript)
            showInTranscript(segment)
        } else {
            open(hit.meetingID, mode: .summary)
            if hit.field == .notes { showOnSummary(SummaryBlockID.notes) }
        }
    }

    /// The conversation was trashed or vanished in a sync: leave it.
    func forget(_ id: UUID) {
        if openID == id { openID = nil; reading = false; chosen = false }
        selection.remove(id)
        if player.meetingID == id { player.close() }
    }
}

/// Where the list is looking: a place in the library, the Trash too.
enum ReadingPlace: Hashable {
    case library(LibraryPlace)

    /// The Trash, the library's own place (`LibraryPlace.trash`), so there's one way to say it.
    static let trash = ReadingPlace.library(.trash)

    var libraryPlace: LibraryPlace { switch self { case .library(let place): return place } }
    var isTrash: Bool { libraryPlace.isTrash }
}

/// Sheets shown over the conversation or the library.
enum ReadingSheet: Identifiable, Equatable {
    case importPhotos(UUID)
    case photo(meetingID: UUID, photoID: UUID)
    case info(UUID)
    case history(UUID)
    case share([URL])
    case move([UUID])
    case tags([UUID])
    case correct(meetingID: UUID, segmentID: UUID)
    case heardIn(meetingID: UUID, segmentID: UUID)
    /// The conversation's tools, the Mac's too (DaybookUI's sheets).
    case reviewCorrections(UUID)
    case adjustTiming(meetingID: UUID, trackID: UUID?)
    case originalTranscript(meetingID: UUID, trackID: UUID)
    /// A Mac's own words for a failure.
    case details(String)
    /// The system's words behind an alert or notice on this iPhone.
    case errorDetails(String)

    var id: String {
        switch self {
        case .importPhotos(let id): return "import-photos:\(id)"
        case .photo(let meeting, let photo): return "photo:\(meeting):\(photo)"
        case .info(let id): return "info:\(id)"
        case .history(let id): return "history:\(id)"
        case .share(let urls): return "share:" + urls.map(\.path).joined(separator: ",")
        case .move(let ids): return "move:" + ids.map(\.uuidString).joined(separator: ",")
        case .tags(let ids): return "tags:" + ids.map(\.uuidString).joined(separator: ",")
        case .correct(let meeting, let segment): return "correct:\(meeting):\(segment)"
        case .heardIn(let meeting, let segment): return "heard:\(meeting):\(segment)"
        case .reviewCorrections(let id): return "review-corrections:\(id)"
        case .adjustTiming(let meeting, let track): return "adjust-timing:\(meeting):\(track?.uuidString ?? "")"
        case .originalTranscript(let meeting, let track): return "original:\(meeting):\(track)"
        case .details(let text): return "details:" + text
        case .errorDetails(let text): return "error-details:" + text
        }
    }
}

/// An alert for something that couldn't be done: a title naming it ("Couldn’t Share"), one plain
/// sentence with what to do, and the system's own words only behind Details.
struct ReadingAlert: Equatable {
    var title: String
    var message: String
    var details: String?

    init(title: String, message: String, details: String? = nil) {
        self.title = title; self.message = message; self.details = details
    }

    /// Daybook's own errors already say what to do in plain words; anything else gets `fallback`,
    /// with its words behind Details.
    init(title: String, error: Error, fallback: String) {
        let plain = PlainError.message(for: error, fallback: fallback)
        self.init(title: title, message: plain.message, details: plain.details)
    }
}

/// Stable IDs for the summary page's blocks, for scroll positions and jumps.
enum SummaryBlockID {
    static let header = "header"
    static let lede = "lede"
    static let nextSteps = "next-steps"
    static let notes = "notes"
    static let bookmarks = "bookmarks"
    static let colophon = "colophon"
    static func section(_ id: UUID) -> String { "section:\(id.uuidString)" }
}
