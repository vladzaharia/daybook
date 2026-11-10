import DaybookKit
import Foundation

/// Carries out the library's half of a conversation's actions (DaybookKit's `ConversationActions`) once for both
/// apps, from every menu that lists them (More, a row's, a selection's; on the iPhone its swipes and selection bar):
/// Copy Summary, then "Copied" over the page; Reprocess ▸ a mode; Version History…; Move to Folder; Tags…; Move to
/// Work or Personal, which Edit › Undo takes back ("Undo Move to Personal", for one conversation or several); and
/// Move to Trash…, which asks first. Each app says how it processes, what it shows, and how it copies, and carries
/// out its own actions itself (share, export, Show in Finder, the camera, Floating Notes, rename).
@MainActor
public struct ConversationActionPerformer {
    /// What an action asks its app to show.
    public enum Request: Equatable, Sendable {
        /// Tags…: the chooser, or the Mac's inspector beside the page.
        case tags([UUID])
        case versionHistory(UUID)
        /// Move to Folder: the iPhone's sheet of folders. The Mac's menu lists them itself.
        case moveToFolder([UUID])
        /// Move to Trash…: the question first ("Move “Weekly sync” to the Trash?").
        case moveToTrash([UUID])
    }

    public var library: LibraryController
    /// What filing registers its undo with; without one it's the plain edit.
    public var undoManager: UndoManager?
    /// Processes a conversation in a mode: the Mac's queue, or on the iPhone its summary or a request for a Mac.
    public var process: @MainActor (UUID, ProcessingRequest.Mode) -> Void
    /// Shows what an action asks for.
    public var show: @MainActor (Request) -> Void
    /// Copies text for this device only, not Universal Clipboard.
    public var copy: @MainActor (String) -> Void
    /// A moment's word over the page (`ConfirmationBeat`).
    public var confirm: @MainActor (ConfirmationBeat) -> Void

    public init(library: LibraryController, undoManager: UndoManager?,
                process: @escaping @MainActor (UUID, ProcessingRequest.Mode) -> Void,
                show: @escaping @MainActor (Request) -> Void,
                copy: @escaping @MainActor (String) -> Void,
                confirm: @escaping @MainActor (ConfirmationBeat) -> Void) {
        self.library = library; self.undoManager = undoManager
        self.process = process; self.show = show; self.copy = copy; self.confirm = confirm
    }

    /// Whether the performer carries `id` out; the rest are each app's own.
    public static func carriesOut(_ id: ConversationAction.ID) -> Bool {
        switch id {
        case .copySummary, .process, .versionHistory, .moveToFolder, .tags, .moveTo, .moveToTrash:
            return true
        case .share, .shareMarkdown, .shareJSON, .shareAudio, .export, .exportMarkdown, .exportJSON,
             .showFloatingNotes, .takePhoto, .addPhotos, .addRecording, .addRecordingFromFile, .reprocess,
             .rename, .showInFinder, .play, .adjustTiming, .showOriginalTranscript, .moveToNewConversation, .removeRecording:
            return false
        }
    }

    /// Carries out `id` on the conversations `ids` that are in the library: the library's actions here, the app's own
    /// by `platform`, given those conversations.
    public func perform(_ id: ConversationAction.ID, on ids: [UUID], platform: ([Meeting]) -> Void) {
        let meetings = library.meetings.filter { ids.contains($0.id) }
        guard let first = meetings.first else { return }
        let chosen = meetings.map(\.id)
        switch id {
        case .copySummary:
            copy(MeetingExport.summaryMarkdown(first))
            confirm(.copied)
        case .process(let mode):
            // A selection's Summarize Again passes over those with no transcript to summarize.
            for meeting in meetings where mode != .summaryOnly || !meeting.unifiedTranscript.isEmpty { process(meeting.id, mode) }
        case .versionHistory: show(.versionHistory(first.id))
        case .moveToFolder: show(.moveToFolder(chosen))
        case .tags: show(.tags(chosen))
        case .moveTo(let placement): library.setPlacement(chosen, placement, undoManager: undoManager)
        case .moveToTrash: show(.moveToTrash(chosen))
        case .share, .shareMarkdown, .shareJSON, .shareAudio, .export, .exportMarkdown, .exportJSON,
             .showFloatingNotes, .takePhoto, .addPhotos, .addRecording, .addRecordingFromFile, .reprocess,
             .rename, .showInFinder, .play, .adjustTiming, .showOriginalTranscript, .moveToNewConversation, .removeRecording:
            platform(meetings)
        }
    }
}
