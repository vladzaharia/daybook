import AppKit
import DaybookCore
import DaybookKit
import DaybookUI
import SwiftUI

/// Detail column for a device: its page, a selected recording, Listen Live, or the conversation for
/// a selected imported recording (which brings its own toolbar). The recorder's page and Listen Live are the
/// screens the iPhone shows too (DaybookUI's `RecorderDevicePage` and `ListenLiveView`); the detail toolbar's More menu
/// holds the device's items (`DeviceMoreMenuContent`).
struct DevicePage: View {
    let state: AppState
    /// Made once, so a redraw of the page doesn't hand its rows new services to redraw for.
    @State private var services: RecorderServices

    init(state: AppState) {
        self.state = state
        _services = State(initialValue: state.recorderServices)
    }

    var body: some View {
        if let session = state.selectedDevice {
            DevicePageContent(state: state, session: session, browser: session.browser, services: services).id(session.id)
        } else {
            Color.clear.background(DaybookStyle.paper)
        }
    }
}

private struct DevicePageContent: View {
    let state: AppState
    let session: DeviceSession
    @Bindable var browser: DeviceBrowser
    let services: RecorderServices

    private enum Target: Equatable {
        case device, recordingNow, meeting(UUID), recording(DeviceRecording), several([DeviceRecording])
    }

    private var target: Target {
        let live = session.primary as? any LiveListeningConnection
        if browser.selection == [.recordingNow] {
            return session.split.inProgress != nil || live?.live.isListening == true ? .recordingNow : .device
        }
        let ids = browser.selectedRecordingIDs
        let links = session.links
        let recordings = session.primary?.recordings ?? []
        if ids.count == 1, let id = ids.first {
            if let meetingID = links.imported[id], state.meetings.contains(where: { $0.id == meetingID }) { return .meeting(meetingID) }
            let queued = ([session.queue.current].compactMap { $0 } + session.queue.waiting).first { $0.id == id }?.recording
            if let recording = recordings.first(where: { $0.id == id }) ?? queued { return .recording(recording) }
        }
        if ids.count > 1 {
            let chosen = recordings.filter { ids.contains($0.id) && links.imported[$0.id] == nil }
            if chosen.count > 1 { return .several(chosen) }
            if let only = chosen.first { return .recording(only) }
        }
        return .device
    }

    var body: some View {
        Group {
            switch target {
            case .meeting(let id):
                MeetingDetailView(state: state, meetingID: id).id(id)
            case .device:
                if session.kind.id == DaybookPhoneIntegration.id {
                    PhoneOverview(state: state, session: session)
                } else {
                    RecorderDevicePage(session: session, showsRecordings: false)
                }
            case .recordingNow:
                ListenLiveView(session: session)
            case .recording(let recording):
                RecordingPage(state: state, session: session, recordings: [recording])
            case .several(let recordings):
                RecordingPage(state: state, session: session, recordings: recordings)
            }
        }
        .environment(\.recorderServices, services)
        .onAppear { syncConversation() }
        .onChange(of: target) { _, _ in syncConversation() }
        .onDisappear { state.deviceConversationID = nil }
        .alert(item: $browser.stopRequest) { request in
            Alert(title: Text("Stop importing “\(request.title)”?"),
                  message: Text("The \(request.minutesReceived) minutes received so far will be discarded. The recording stays on your \(session.kind.shortName)."),
                  primaryButton: .destructive(Text("Stop Importing")) {
                      if request.stopsAll { session.stopAll() } else { session.stopCurrent() }
                  },
                  secondaryButton: .cancel(Text("Keep Importing")))
        }
        .sheet(item: $browser.choosingConversation) { choice in
            ConversationChooser(session: session, recordings: choice.recordings)
                .environment(\.recorderServices, services)
        }
    }

    /// The window's toolbar shows the conversation controls only while a conversation is shown here.
    private func syncConversation() {
        let id: UUID? = if case .meeting(let id) = target { id } else { nil }
        if state.deviceConversationID != id { state.deviceConversationID = id }
    }
}

// MARK: - More menu

/// The device's items for the detail toolbar's More menu and any other menu for the device: the recorder's items
/// both apps share (`RecorderMenuItems`), then Device Settings….
struct DeviceMoreMenuContent: View {
    let state: AppState
    let session: DeviceSession
    @Environment(\.openWindow) private var openSettingsWindow

    var body: some View {
        Group {
            RecorderMenuItems(session: session)
            Divider()
            Button("Device Settings…") { DeviceActions.openSettings(openSettingsWindow) }
        }
        .environment(\.recorderServices, state.recorderServices)
    }
}
