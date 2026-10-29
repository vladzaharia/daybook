import AppKit
import DaybookIntelligence
import DaybookKit
import SwiftUI

/// The menu bar extra: a standard menu. Personal conversations are never named here,
/// since the menu bar is visible while sharing a screen.
struct MenuBarView: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Items show the shortcuts they have in the app's menus, as Settings… and Quit do.
        if state.isRecording, let start = state.recordingStartedAt {
            Text("Recording · \(TimeLabel.short(Date().timeIntervalSince(start)))")
            Button("Stop Recording") { Task { await state.stopRecording() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.isStoppingRecording)
            Button("Add Bookmark") { if let id = state.recordingID { state.addHighlight(id) } }
                .keyboardShortcut("d")
        } else {
            Button("Start Recording") { Task { await state.startRecording() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!state.isReady || state.isStartingRecording)
        }
        // While recording, the recording; otherwise the panel's home (status, Record, recent conversations).
        Button("Show Floating Notes") { state.showFloatingNotes(focus: state.recordingID) }
            .keyboardShortcut("n", modifiers: [.command, .option])
        Divider()
        Toggle("Record Calls Automatically", isOn: $state.automaticRecording)
        if state.automaticRecording { DetectionStatusText(monitor: state.monitor) }
        // The percent follows the job's own progress, not the app's other changes.
        ActivityReader(processing: state.processingActivity, download: state.downloadActivity) {
            if let activity {
                // Work in progress is an item that opens it, so it reads at full strength, not as a dimmed status line.
                Divider()
                Button(activity, action: showActivity)
            }
        }
        DeviceMenuBarItems(state: state)
        Divider()
        Button("Open Daybook") { open(nil) }
        SettingsLink { Text("Settings…") }.keyboardShortcut(",")
        Divider()
        Button("Quit Daybook") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private var activity: String? {
        if let id = state.processingID, let meeting = state.meetings.first(where: { $0.id == id }) {
            let name = meeting.effectivePlacement == .personal ? "a personal conversation" : "“\(meeting.title)”"
            return meeting.status == .summarizing ? "Summarizing \(name)" : "Transcribing \(name) · \(Int(state.processingProgress.fraction * 100))%"
        }
        if let id = state.downloadingID { return "Downloading \(state.modelCatalog.name(for: id)) · \(Int(state.downloadProgress.fraction * 100))%" }
        return nil
    }

    /// Opens the conversation being processed, or Settings › Models for a download.
    private func showActivity() {
        if let id = state.processingID, state.meetings.contains(where: { $0.id == id }) {
            state.showConversation(id)
            open(nil)
        } else {
            LaunchOptions.defaults.set(SettingsPane.models.rawValue, forKey: "settingsPane")
            openSettings()
            NSApp.activate()
        }
    }

    private func open(_ place: LibraryPlace?) {
        if let place { state.place = place }
        openWindow(id: WindowID.library)
        NSApp.activate()
    }
}

/// "Listening for calls", from the call detector itself.
private struct DetectionStatusText: View {
    @ObservedObject var monitor: MeetingMonitor
    var body: some View { Text(monitor.statusText) }
}
