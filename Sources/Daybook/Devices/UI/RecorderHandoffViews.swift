import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

// Recorder handoff in the Mac's own places (docs/devices.md, "Handing a recorder over"): the sidebar's,
// the menu bar's, and Floating Notes' menus, and Settings › Devices' "Managed by" row. The device
// page's handoff is the view both apps share (DaybookUI's `RecorderHandoffView`).

/// "Use on This Mac" / "Use on Alex’s iPhone" in the Mac's menus: the sidebar's, the menu bar's, Floating Notes'.
struct RecorderHandoffMenuItems: View {
    let state: AppState
    let session: DeviceSession
    /// The menu bar names the recorder; the device page doesn't need to.
    var namesRecorder = false

    var body: some View {
        let busy = state.recorderHandoff.state(of: session).isPending
        if session.direct is any ManagedConnection, session.recorderSerial != nil {
            if let owner = session.managedElsewhere {
                Button(namesRecorder ? "Use \(session.device.name) on This Mac" : "Use on This Mac") { state.useRecorderOnThisMac(session) }
                    .disabled(busy)
                    .help("Asks \(owner.ownerName) to let go, then connects here.")
            } else {
                ForEach(state.handoffTargets(for: session), id: \.linkID) { peer in
                    Button(namesRecorder ? "Use \(session.device.name) on \(peer.name)" : "Use on \(peer.name)") {
                        state.giveRecorder(session, to: peer)
                    }
                    .disabled(busy)
                    .help("This Mac finishes any import first.")
                }
            }
        }
    }
}

/// Settings › Devices: who manages the recorder, and the way to move it.
struct RecorderOwnershipRow: View {
    let state: AppState
    let session: DeviceSession

    var body: some View {
        if session.direct is any ManagedConnection, session.recorderSerial != nil {
            let handoff = state.recorderHandoff
            let current = handoff.state(of: session)
            LabeledContent("Managed by") {
                HStack(spacing: Space.s2) {
                    if let line = state.handoffLine(for: session), current.isPending {
                        ProgressView().controlSize(.mini)
                        Text(line).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    } else if let owner = session.managedElsewhere {
                        Text(owner.ownerName).foregroundStyle(.secondary)
                        Button("Use on This Mac") { state.useRecorderOnThisMac(session) }
                    } else {
                        Text("This Mac").foregroundStyle(.secondary)
                        let targets = state.handoffTargets(for: session)
                        if targets.count == 1, let peer = targets.first {
                            Button("Use on \(peer.name)") { state.giveRecorder(session, to: peer) }
                        } else if targets.count > 1 {
                            Menu("Use on…") {
                                ForEach(targets, id: \.linkID) { peer in Button(peer.name) { state.giveRecorder(session, to: peer) } }
                            }
                            .fixedSize()
                        }
                    }
                }
            }
            .padding(.leading, Space.s5)
        }
    }
}
