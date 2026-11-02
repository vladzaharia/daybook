import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

/// Actions people take from menus, toolbars, and context menus.
extension AppState {
    func requestNewFolder(moving ids: [UUID] = []) { newFolderRequest = NewFolderRequest(moving: ids) }

    /// Creates a folder and moves any requested conversations into it.
    func createFolder(named name: String, moving ids: [UUID]) { library.createFolder(named: name, moving: ids) }

    /// Files conversations in a folder, or in none. With `undoManager`, Edit › Undo takes it back ("Undo Move to Folder").
    func moveToFolder(_ ids: [UUID], _ folder: UUID?, undoManager: UndoManager? = nil) {
        guard let undoManager else { library.moveToFolder(ids, folder); return }
        for id in ids { library.update(id, actionName: "Move to Folder", undoManager: undoManager) { $0.folderID = folder } }
    }

    /// Shows conversations in Work or Personal, or where their kind puts them (nil). With `undoManager`, Edit › Undo
    /// takes it back, named as the menu item was ("Undo Move to Personal").
    func setPlacement(_ ids: [UUID], _ placement: LibraryPlacement?, undoManager: UndoManager? = nil) {
        guard let undoManager else { library.setPlacement(ids, placement); return }
        for id in ids { library.update(id, actionName: Self.placementActionName(placement), undoManager: undoManager) { $0.placement = placement } }
    }

    /// The Undo menu's name for a change of placement.
    nonisolated static func placementActionName(_ placement: LibraryPlacement?) -> String {
        switch placement {
        case .work?: return "Move to Work"
        case .personal?: return "Move to Personal"
        case nil: return "Show Automatically"
        }
    }

    /// Where Floating Notes opens from a menu (Window › Floating Notes, the menu bar extra, the Dock), one rule for all:
    /// on the recording, else the conversation the library window shows, else its home.
    var floatingNotesFocus: UUID? {
        if let recordingID { return recordingID }
        guard multiSelection.count < 2 else { return nil }
        return place.isDevice ? deviceConversationID : selectedID
    }

    /// Add Bookmark (⌘D) can mark a moment: while this Mac records, the recording's, wherever the person is; otherwise
    /// the player's, in conversation `id` when it's loaded there.
    func canAddBookmark(in id: UUID?) -> Bool {
        if recordingID != nil { return true }
        guard let id else { return false }
        return playback.meetingID == id && playback.trackID != nil && playback.duration > 0
    }

    /// Add Bookmark (⌘D), at the moment `canAddBookmark` names.
    func addBookmark(in id: UUID?) {
        if let recordingID { addHighlight(recordingID); return }
        guard let id, canAddBookmark(in: id), let trackID = playback.trackID else { return }
        addPlaybackHighlight(id, trackID: trackID, seconds: playback.position)
    }

    /// Controls › Play or Pause for a conversation: its recording in the player goes on or stops, or, with another one
    /// (or none) loaded, it plays from the start. Playback waits while this Mac records, so the call audio doesn't
    /// capture it.
    func togglePlayback(of id: UUID) {
        guard !isRecording else { return }
        if playback.meetingID == id, playback.duration > 0 { playback.toggle(); return }
        guard let meeting = meetings.first(where: { $0.id == id }), let target = PlaybackTarget.timeline(0).resolve(in: meeting) else { return }
        Task {
            guard let url = await audioURL(for: target.track, meetingID: id), !isRecording else { return }
            playback.play(url: url, at: target.seconds, trackID: target.track.id, meetingID: id)
        }
    }

    func showInFinder(_ id: UUID) {
        let folder = storageURL.appendingPathComponent("Meetings", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    func copySummary(_ id: UUID) {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        LocalPasteboard.copy(MeetingExport.summaryMarkdown(meeting))
    }

    func focusSearch() { searchFocusRequest += 1 }

    func showInspector() { inspectorRequest += 1 }

    func focusTitle(_ id: UUID) { titleFocusRequest = id }

    /// File › New Note (⌘N): a conversation that's only your notes so far, titled as on the iPhone
    /// ("Note at 10:15 AM"), in the place being viewed. Record records into it.
    @discardableResult func newNote(at now: Date = Date()) -> UUID {
        newMeeting(title: LibraryWords.noteTitle(at: now), date: now)
    }

    /// The selected template; "auto" lets the local model identify the kind of conversation.
    /// Choosing a different template summarizes again right away; the earlier summary stays in Version History.
    func templateSelection(for meetingID: UUID) -> Binding<String> {
        Binding(get: { [weak self] in
            self?.library.templateSelection(for: meetingID) ?? "auto"
        }, set: { [weak self] id in
            guard let self, self.library.chooseTemplate(id, for: meetingID),
                  let after = self.meetings.first(where: { $0.id == meetingID }),
                  !after.unifiedTranscript.isEmpty, self.processingID != meetingID else { return }
            self.cancelQueued(meetingID)
            self.enqueue(meetingID, mode: .summaryOnly)
        })
    }
}

/// Copy for conversation content: it stays on this Mac (`.currentHostOnly`) rather than going to
/// Universal Clipboard on every nearby device signed in to the same Apple Account.
enum LocalPasteboard {
    static func copy(_ string: String, to pasteboard: some LocalPasteboardWriting = NSPasteboard.general) {
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        _ = pasteboard.setString(string, forType: .string)
    }

    static func copy(_ objects: [NSPasteboardWriting], to pasteboard: some LocalPasteboardWriting = NSPasteboard.general) {
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        _ = pasteboard.writeObjects(objects)
    }
}

/// What copying needs of a pasteboard, so tests can watch it.
protocol LocalPasteboardWriting {
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: LocalPasteboardWriting {}

/// Opens a Privacy & Security pane in System Settings.
enum PrivacySettings {
    enum Pane: String {
        case microphone = "Privacy_Microphone", screenCapture = "Privacy_ScreenCapture", bluetooth = "Privacy_Bluetooth"
    }
    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") { NSWorkspace.shared.open(url) }
    }

    /// The pane where a recording that couldn't start is allowed to, when a permission is why.
    static func pane(for error: Error) -> Pane? {
        switch error as? RecordingError {
        case .microphoneDenied?: return .microphone
        case .noDisplay?: return .screenCapture
        default: return nil
        }
    }
}
