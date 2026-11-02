import AppKit
import DaybookCore
import DaybookKit
import DaybookUI
import SwiftUI

/// List column for a device: everything on it (DaybookUI's `DeviceRecordingsView`, which the iPhone pushes as All
/// Recordings), titled by the device with its state as the subtitle. A selection opens the recording's page, or
/// its conversation, beside it.
struct DeviceRecordingsList: View {
    let state: AppState
    /// Made once, so a redraw doesn't hand the rows new services to redraw for.
    @State private var services: RecorderServices

    init(state: AppState) {
        self.state = state
        _services = State(initialValue: state.recorderServices)
    }

    var body: some View {
        if let session = state.selectedDevice {
            DeviceRecordingsView(session: session)
                .environment(\.recorderServices, services)
                .onDisappear { session.browser.selection = [] }
                .id(session.id)
                .navigationTitle(session.device.name)
                // The subtitle follows the device ("Connected · 80% · 2 new") without redrawing the list.
                .modifier(DeviceListSubtitle(session: session, services: services))
        } else {
            Color.clear.navigationTitle("Devices")
        }
    }
}

/// The list's subtitle, kept current by the session on its own: the recorder's status line, as both apps word it.
private struct DeviceListSubtitle: ViewModifier {
    let session: DeviceSession
    let services: RecorderServices

    func body(content: Content) -> some View {
        content.navigationSubtitle(session.kind.id == DaybookPhoneIntegration.id
                                   ? session.subtitle
                                   : RecorderStatusWords.line(services.facts(session), here: services.place.here).text)
    }
}
