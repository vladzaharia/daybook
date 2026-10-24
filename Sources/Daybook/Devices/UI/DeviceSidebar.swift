import AppKit
import DaybookKit
import SwiftUI

/// The sidebar's Devices section: every configured device, each with at most one accessory (a
/// progress ring while importing, else a count of new recordings), and its glyph lit while the
/// recorder is linked. It appears once a device is set up.
struct DevicesSidebarSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var hub: DeviceHub
    @State private var hovering = false

    init(state: AppState) {
        self.state = state
        self.hub = state.devices
    }

    var body: some View {
        if hub.hasDevices {
            Section {
                ForEach(hub.sessions) { session in
                    DeviceSidebarRow(session: session)
                        .tag(LibraryPlace.device(session.id))
                        .contextMenu { DeviceContextMenu(state: state, session: session) }
                }
            } header: {
                HStack {
                    Text("Devices")
                    Spacer()
                    Button { state.requestAddDevice() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0)
                        .motion(Motion.hover, value: hovering)
                        .help("Add Device…")
                        .accessibilityLabel("Add Device")
                }
                .padding(.leading, 2)
                .onHover { hovering = $0 }
            }
        }
    }
}

private struct DeviceSidebarRow: View {
    @ObservedObject var session: DeviceSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let progress = session.importProgress
        let newCount = progress == nil ? session.newRecordings.count : 0
        HStack(spacing: Space.s2) {
            Label {
                Text(session.device.name).lineLimit(1)
            } icon: {
                Image(systemName: session.kind.systemImage)
                    .foregroundStyle(iconStyle)
                    .neonGlow(session.isLinked ? DaybookStyle.neonMint : .clear, radius: 4)
                    .contentTransition(.symbolEffect(.replace))
            }
            Spacer(minLength: 0)
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(DaybookStyle.accent)
                    .transition(.opacity)
                    .accessibilityLabel("Importing")
                    .accessibilityValue("\(Int(progress * 100)) percent")
            }
        }
        .badge(newCount)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: progress == nil)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: session.isLinked)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(newCount: newCount))
    }

    /// Mint while a recorder is linked; secondary while a recorder isn't; the sidebar's own colour
    /// for a watched folder.
    private var iconStyle: AnyShapeStyle {
        if session.isLinked { return AnyShapeStyle(DaybookStyle.neonMint) }
        if session.direct?.isSetUp == true || session.state == .unavailable || session.state == .notSetUp {
            return AnyShapeStyle(Color.secondary)
        }
        return AnyShapeStyle(.tint)
    }

    private func accessibilityLabel(newCount: Int) -> String {
        var parts = [session.device.name]
        if session.isLinked { parts.append("connected") }
        if session.importProgress != nil { parts.append("importing") }
        else if newCount > 0 { parts.append(newCount == 1 ? "1 new recording" : "\(newCount) new recordings") }
        return parts.joined(separator: ", ")
    }
}

/// The device row's context menu: Import All New · Connect or Disconnect · Device Settings….
struct DeviceContextMenu: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let new = session.newRecordings
        Button(new.count > 1 ? "Import \(new.count) New Recordings" : "Import New Recording") { session.importRecordings(new) }
            .disabled(new.isEmpty)
        if session.direct?.isSetUp == true {
            if session.isLinked || session.direct?.state.isBusy == true {
                Button("Disconnect") { session.disconnect(.direct) }
            } else {
                Button("Connect") { session.connect() }
                    .disabled(session.direct?.state == .unavailable)
            }
        }
        Divider()
        Button("Device Settings…") { DeviceActions.openSettings(openSettings) }
    }
}

// MARK: - Menus

/// File › Add Device… and Import from each device.
struct DeviceFileMenuItems: View {
    @ObservedObject var state: AppState
    @ObservedObject var hub: DeviceHub
    @Environment(\.openWindow) private var openWindow

    init(state: AppState) {
        self.state = state
        self.hub = state.devices
    }

    var body: some View {
        Button("Add Device…") {
            openWindow(id: WindowID.library)
            state.requestAddDevice()
        }
        ForEach(hub.sessions) { session in
            Button("Import from \(session.device.name)…") {
                openWindow(id: WindowID.library)
                state.showDevice(session.id)
            }
        }
    }
}

/// Add Recording › From <device>… in a conversation's menus: opens that device's recordings.
struct AddRecordingFromDeviceItems: View {
    @ObservedObject var state: AppState
    @ObservedObject var hub: DeviceHub

    init(state: AppState) {
        self.state = state
        self.hub = state.devices
    }

    var body: some View {
        ForEach(hub.sessions) { session in
            Button("From \(session.device.name)…") { state.showDevice(session.id) }
        }
    }
}

/// The menu bar extra's device lines: "Importing from Soundcore Work · 2 of 3", or
/// "Soundcore Work · 3 New Recordings…" which opens the device. Nothing when there's nothing to say.
struct DeviceMenuBarItems: View {
    @ObservedObject var state: AppState
    @ObservedObject var hub: DeviceHub

    init(state: AppState) {
        self.state = state
        self.hub = state.devices
    }

    var body: some View {
        ForEach(hub.sessions) { session in
            DeviceMenuBarLine(state: state, session: session)
        }
    }
}

private struct DeviceMenuBarLine: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let queue = session.queue
        if let line = state.handoffLine(for: session) {
            // A handoff under way (or just finished) says so, in the recorder's words.
            Text(line)
        } else if queue.isActive, !queue.isSuspended {
            Text("Importing from \(session.device.name) · \(queue.position) of \(queue.total)")
        } else {
            let count = session.newRecordings.count
            if count > 0 {
                Button(count == 1 ? "\(session.device.name) · 1 New Recording…" : "\(session.device.name) · \(count) New Recordings…") {
                    state.showDevice(session.id)
                    openWindow(id: WindowID.library)
                    NSApp.activate()
                }
            }
            if session.managedElsewhere != nil {
                RecorderHandoffMenuItems(state: state, session: session, namesRecorder: true)
            }
        }
    }
}
