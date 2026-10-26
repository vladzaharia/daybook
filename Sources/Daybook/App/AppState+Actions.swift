import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

/// Actions people take from menus, toolbars, and context menus.
extension AppState {
    func requestNewFolder(moving ids: [UUID] = []) { newFolderRequest = NewFolderRequest(moving: ids) }

    /// Creates a folder and moves any requested conversations into it.
    func createFolder(named name: String, moving ids: [UUID]) { library.createFolder(named: name, moving: ids) }

    func moveToFolder(_ ids: [UUID], _ folder: UUID?) { library.moveToFolder(ids, folder) }

    func setPlacement(_ ids: [UUID], _ placement: LibraryPlacement?) { library.setPlacement(ids, placement) }

    func showInFinder(_ id: UUID) {
        let folder = storageURL.appendingPathComponent("Meetings", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    func copySummary(_ id: UUID) {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        LocalPasteboard.copy(MeetingExport.summaryMarkdown(meeting))
    }

    func focusSearch() { searchFocusRequest += 1 }

    func focusTitle(_ id: UUID) { titleFocusRequest = id }

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
}
