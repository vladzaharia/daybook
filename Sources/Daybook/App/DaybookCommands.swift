import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

/// The menu bar, one `Commands` per menu. Every toolbar and context-menu action has a home here, and items that don't
/// apply are disabled, never hidden.
///
/// A command for a conversation acts on the one the library window shows (`FocusedValues.shownConversation`): with
/// another window in front (Settings, Vocabulary, Speaker Profiles), or the library window closed, it's disabled, so
/// nothing happens to a conversation that isn't on screen. What Daybook does anywhere stays on: New Note, New Folder,
/// Record, Import, a bookmark while recording, Floating Notes, and searching.
struct DaybookCommands: Commands {
    let state: AppState

    var body: some Commands {
        // The standard About panel, crediting the models (their licenses and required attributions).
        CommandGroup(replacing: .appInfo) {
            Button("About Daybook") { AboutPanel.show(catalog: state.modelCatalog) }
        }
        // Settings is a window of its own (`WindowID.settings`), so its menu item is too.
        CommandGroup(replacing: .appSettings) { SettingsMenuItem() }
        FileCommands(state: state)
        // Continuity Camera: Take Photo, Scan Documents, and Add Sketch from an iPhone or iPad
        // (the page receives them through `importsItemProviders`).
        ImportFromDevicesCommands()
        // Edit › Find in Conversation… (⌘F), Find Next, Find Previous. Edit › Find ▸ Find… comes first in the menu, so
        // ⌘F still finds in the notes while they have the focus; Search Conversations is ⌥⌘F.
        ConversationFindCommands(state: state)
        EditCommands(state: state)
        ViewCommands(state: state)
        WindowCommands(state: state)
        ConversationCommands(state: state)
        ControlsCommands(state: state)
        HelpCommands()
    }
}

extension AppState {
    /// The conversation the library window shows (`FocusedValues.shownConversation`), nil unless it's the key window.
    func shownMeeting(_ id: UUID?) -> Meeting? {
        guard let id else { return nil }
        return meetings.first { $0.id == id }
    }
}

// MARK: - File

private struct FileCommands: Commands {
    let state: AppState
    @FocusedValue(\.shownConversation) private var shownID
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let meeting = state.shownMeeting(shownID)
        CommandGroup(replacing: .newItem) {
            // A conversation that's only your notes so far, as on the iPhone; Record records into it.
            Button("New Note") {
                if state.place.isDevice { state.place = .section(.all) }
                state.newNote()
                openWindow(id: WindowID.library)
            }
            .keyboardShortcut("n")
            Button("New Folder") {
                if state.place.isDevice { state.place = .section(.all) }
                state.requestNewFolder()
                openWindow(id: WindowID.library)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button(state.isRecording ? "Stop Recording" : "Start Recording") {
                Task { if state.isRecording { await state.stopRecording() } else { await state.startRecording() } }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!state.isReady || state.isStartingRecording || state.isStoppingRecording)
            Button("Import Audio…") { state.chooseImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            DeviceFileMenuItems(state: state)
            Button("Add Recording to Conversation…") { if let id = meeting?.id { state.chooseImport(attachTo: id) } }
                .disabled(meeting.map { state.isBusy($0.id) } ?? true)
            Button("Add Photos…") { if let id = meeting?.id { state.chooseAddPhoto(to: id) } }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(meeting == nil)
        }
        CommandGroup(after: .saveItem) {
            Menu("Export") {
                Button("Markdown…") { if let id = meeting?.id { state.export(id) } }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Full Data (JSON)…") { if let id = meeting?.id { state.export(id, json: true) } }
            }
            .disabled(meeting == nil)
            Button("Show in Finder") { if let id = meeting?.id { state.showInFinder(id) } }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(meeting == nil)
            Divider()
            Button("Move to Trash…") { state.trashRequestID = meeting?.id }
                .disabled(meeting.map { state.isBusy($0.id) } ?? true)
        }
    }
}

// MARK: - Edit

private struct EditCommands: Commands {
    let state: AppState
    @FocusedValue(\.shownConversation) private var shownID
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let meeting = state.shownMeeting(shownID)
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Summary") { if let meeting { state.copySummary(meeting.id) } }
                .disabled(meeting?.summary == nil)
            Button("Paste Photo") { if let meeting { state.pastePhoto(into: meeting.id) } }
                .disabled(meeting == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Search Conversations") {
                openWindow(id: WindowID.library)
                state.focusSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
        }
    }
}

// MARK: - View

private struct ViewCommands: Commands {
    let state: AppState
    @FocusedValue(\.shownConversation) private var shownID
    /// Whether the library window's toolbar shows, while that window is key.
    @FocusedBinding(\.libraryToolbarShown) private var toolbarShown
    /// Whether its inspector shows; asking for it widens a window too narrow for it.
    @FocusedBinding(\.libraryInspectorShown) private var inspectorShown

    var body: some Commands {
        let meeting = state.shownMeeting(shownID)
        SidebarCommands()
        // The library window's own, rather than InspectorCommands': asking for the inspector widens a window too narrow
        // for it, which a change SwiftUI makes on its own must not.
        CommandGroup(after: .sidebar) {
            Button(inspectorShown == true ? "Hide Inspector" : "Show Inspector") {
                if let shown = inspectorShown { withAnimation { inspectorShown = !shown } }
            }
            .keyboardShortcut("i", modifiers: [.command, .control])
            .disabled(inspectorShown == nil)
        }
        // Show or Hide Toolbar alone: the toolbar isn't customizable (`DetailToolbar`), so there's no Customize Toolbar….
        CommandGroup(replacing: .toolbar) {
            Button(toolbarShown == false ? "Show Toolbar" : "Hide Toolbar") {
                if let shown = toolbarShown { toolbarShown = !shown }
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(toolbarShown == nil)
        }
        CommandGroup(before: .sidebar) {
            // The toolbar's Summary | Transcript, ticked as it's lit: where the window has room for two pages, both
            // while both show, and choosing one keeps it alone or puts the other back beside it (`PageSides`).
            ForEach(PageMode.allCases) { side in
                Toggle(side.title, isOn: Binding(get: { meeting.map { state.pageSides($0).shows(side) } ?? false },
                                                 set: { _ in if let meeting { state.choosePage(side, for: meeting) } }))
                    .keyboardShortcut(side == .summary ? "1" : "2")
                    .disabled(side == .summary ? meeting == nil : meeting.map { state.hasTranscriptPage($0) } != true)
            }
            Divider()
            // The reading surface scales in every window that shows it, Floating Notes too.
            Button("Make Text Bigger") { state.readingScale = ReadingScale.bigger(state.readingScale) }
                .keyboardShortcut("+")
            Button("Make Text Smaller") { state.readingScale = ReadingScale.smaller(state.readingScale) }
                .keyboardShortcut("-")
            Button("Actual Size") { state.readingScale = 1 }
                .keyboardShortcut("0")
            Divider()
        }
    }
}

// MARK: - Window

private struct WindowCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(before: .windowList) {
            // The panel isn't in the window list (it floats over calls), so it has its own item. It opens where the menu
            // bar extra's and the Dock's do (`floatingNotesFocus`).
            Button("Floating Notes") { state.showFloatingNotes(focus: state.floatingNotesFocus) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
        }
    }
}

// MARK: - Conversation

private struct ConversationCommands: Commands {
    let state: AppState
    @FocusedValue(\.shownConversation) private var shownID

    var body: some Commands {
        let meeting = state.shownMeeting(shownID)
        let locked = meeting.map { state.isBusy($0.id) } ?? true
        let queued = meeting.map { state.queuedIDs.contains($0.id) } ?? false
        CommandMenu("Conversation") {
            if let meeting, state.processingID == meeting.id {
                Button("Pause Transcription") { state.pauseProcessing(meeting.id) }
            } else if let meeting, state.pausedIDs.contains(meeting.id) {
                Button("Resume Transcription") { state.enqueue(meeting.id, mode: state.defaultProcessingMode(for: meeting)) }
            } else {
                Button("Transcribe") { if let meeting { state.enqueue(meeting.id, mode: state.defaultProcessingMode(for: meeting)) } }
                    .disabled(meeting?.hasUntranscribedAudio != true || locked || queued)
            }
            Divider()
            ForEach([ProcessingRequest.Mode.summaryOnly, .speakerRefresh, .newAudio, .fullRetranscription]) { mode in
                Button(mode.title) { if let id = meeting?.id { state.enqueue(id, mode: mode) } }
                    .disabled(meeting?.tracks.isEmpty != false || locked || queued)
            }
            Menu("Template") {
                if let meeting { TemplateMenuItems(state: state, meetingID: meeting.id) }
            }
            .disabled(meeting == nil)
            Divider()
            // While this Mac records, at the recording's moment, wherever the person is; otherwise at the player's moment
            // in the conversation on screen.
            Button("Add Bookmark") { state.addBookmark(in: meeting?.id) }
                .keyboardShortcut("d")
                .disabled(!state.canAddBookmark(in: meeting?.id))
            Button("Adjust Timing…") { state.activeSheet = .adjustTiming(nil) }
                .disabled(meeting.map { $0.tracks.count < 2 } ?? true)
            Button("Review Earlier Corrections…") { state.activeSheet = .reviewCorrections }
                .disabled(meeting?.correctionTransferIssues?.isEmpty != false)
            Divider()
            Menu("Move to Folder") {
                if let meeting { FolderMenuItems(state: state, meetingIDs: [meeting.id]) }
            }
            .disabled(meeting == nil)
            PlacementMenuItem(state: state, meeting: meeting)
            Divider()
            Button("Version History…") { state.activeSheet = .versionHistory }
                .disabled(meeting?.revisions.isEmpty != false)
        }
    }
}

/// Move to Work, or Move to Personal for one in Work, which Edit › Undo takes back.
private struct PlacementMenuItem: View {
    let state: AppState
    let meeting: Meeting?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let personal = meeting?.effectivePlacement == .personal
        Button(personal ? "Move to Work" : "Move to Personal") {
            if let meeting { state.library.setPlacement([meeting.id], personal ? .work : .personal, undoManager: undoManager ?? NSApp.keyWindow?.undoManager) }
        }
        .disabled(meeting == nil)
    }
}

// MARK: - Controls

private struct ControlsCommands: Commands {
    let state: AppState
    @FocusedValue(\.shownConversation) private var shownID

    var body: some Commands {
        let meeting = state.shownMeeting(shownID)
        CommandMenu("Controls") {
            PlayPauseMenuItem(state: state, player: state.playback, meeting: meeting)
            Button("Jump Back 15 Seconds") { state.playback.skip(-15) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(state.playback.meetingID == nil)
            Button("Jump Forward 15 Seconds") { state.playback.skip(15) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(state.playback.meetingID == nil)
            Divider()
            PlaybackSpeedMenu(player: state.playback)
        }
    }
}

/// Controls › Play or Pause (⇧⌘Space), as playback is: what's loaded goes on or stops, or the conversation on screen
/// plays from the start. It reads only whether playback is playing and what's loaded, so the menu isn't rebuilt as the
/// position moves.
private struct PlayPauseMenuItem: View {
    let state: AppState
    let player: AudioPlaybackController
    let meeting: Meeting?

    var body: some View {
        let target = meeting?.id ?? player.meetingID
        Button(player.isPlaying && (meeting == nil || player.meetingID == meeting?.id) ? "Pause" : "Play") {
            if let target { state.togglePlayback(of: target) }
        }
        .keyboardShortcut(.space, modifiers: [.command, .shift])
        .disabled(target == nil || state.isRecording || (meeting.map { $0.tracks.isEmpty } ?? false))
    }
}

/// Controls › Playback Speed: the speeds the player's capsule offers, kept when another recording loads.
private struct PlaybackSpeedMenu: View {
    @Bindable var player: AudioPlaybackController

    var body: some View {
        Menu("Playback Speed") {
            Picker("Playback Speed", selection: $player.rate) {
                ForEach(AudioPlaybackController.speeds, id: \.self) { rate in Text(rate.formatted() + "×").tag(rate) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

extension AudioPlaybackController {
    /// The speeds offered in Controls › Playback Speed and the player's capsule.
    static let speeds: [Float] = [0.75, 1, 1.25, 1.5, 2]
}

// MARK: - Help

private struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Show Welcome") { openWindow(id: WindowID.welcome) }
        }
    }
}

// MARK: - Shared menu items

/// Template choices for a conversation, shared by the colophon, inspector, and Conversation menu.
struct TemplateMenuItems: View {
    let state: AppState
    let meetingID: UUID
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Picker("Template", selection: state.templateSelection(for: meetingID)) {
            Text(TemplateWords.automatic(for: state.meetings.first { $0.id == meetingID })).tag("auto")
            Divider()
            ForEach(state.templates.filter(\.isBuiltIn)) { template in Text(template.name).tag(template.id) }
            let custom = state.templates.filter { !$0.isBuiltIn }
            if !custom.isEmpty {
                Divider()
                ForEach(custom) { template in Text(template.name).tag(template.id) }
            }
        }
        .pickerStyle(.inline)
        Divider()
        Button("Edit Templates…") { openWindow(id: WindowID.templates) }
    }
}

/// Folder choices for one or more conversations. Edit › Undo takes a move back ("Undo Move to Folder").
struct FolderMenuItems: View {
    let state: AppState
    let meetingIDs: [UUID]
    @Environment(\.undoManager) private var undoManager
    var body: some View {
        Button("None") { state.library.moveToFolder(meetingIDs, nil, undoManager: undo) }
        if !state.folders.isEmpty { Divider() }
        ForEach(state.folders) { folder in
            Button(folder.name) { state.library.moveToFolder(meetingIDs, folder.id, undoManager: undo) }
        }
        Divider()
        Button("New Folder") { state.requestNewFolder(moving: meetingIDs) }
    }

    /// The window's undo manager; a menu bar item reads the key window's, which is the library's whenever it's enabled.
    private var undo: UndoManager? { undoManager ?? NSApp.keyWindow?.undoManager }
}

/// Daybook › Settings… (⌘,).
private struct SettingsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openWindow.settings() }
            .keyboardShortcut(",")
    }
}
