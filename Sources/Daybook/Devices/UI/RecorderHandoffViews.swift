import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

// Recorder handoff on the Mac (docs/devices.md, "Handing a recorder over"): the device page's line
// or box, the More menu's "Use on <iPhone>", Settings › Devices' "Managed by" row, and the menu bar.
// A working state is a bare line; a state that needs the person is a quiet box with at most two
// actions (docs/interface.md, "Status speaks only when there is something to say").

/// The device page's handoff state, under the byline. Nothing when no handoff is under way.
struct RecorderHandoffNotice: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    @ObservedObject var handoff: RecorderHandoff
    @State private var confirmingTakeOver = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: AppState, session: DeviceSession) {
        self.state = state
        self.session = session
        self.handoff = state.recorderHandoff
    }

    var body: some View {
        let current = handoff.state(of: session)
        TimelineView(.periodic(from: .now, by: 15)) { context in
            content(current, now: context.date)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: current)
        .confirmationDialog("Take over \(session.device.name) now?", isPresented: $confirmingTakeOver) {
            Button("Take Over Anyway") { state.takeOverRecorder(session) }
            Button("Keep Waiting", role: .cancel) {}
        } message: {
            Text(RecorderHandoff.Words.takeOverRisk(owner: owner(current), recorder: session.device.name, here: "this Mac"))
        }
    }

    @ViewBuilder
    private func content(_ current: RecorderHandoff.State, now: Date) -> some View {
        let recorder = session.device.name
        let headline = RecorderHandoff.Words.headline(current, recorder: recorder, here: "this Mac")
        let overdue = handoff.isOverdue(current, now: now)
        let detail = RecorderHandoff.Words.detail(current, recorder: recorder, here: "this Mac", overdue: overdue, now: now)
        switch current {
        case .idle:
            EmptyView()
        case .refused:
            // Needs the person: the page's quiet box, with Take Over Anyway and OK.
            DeviceAttentionBox(symbol: "exclamationmark.circle.fill", title: headline ?? "", message: detail) {
                if session.managedElsewhere != nil {
                    Button("Take Over Anyway…") { confirmingTakeOver = true }.buttonStyle(.daybookLink)
                }
                Button("OK") { state.cancelRecorderHandoff(session) }
            }
            .accessibilityElement(children: .contain)
        case .waitingForSync where overdue:
            DeviceAttentionBox(symbol: "hourglass", title: headline ?? "", message: detail) {
                Button("Stop Waiting") { state.cancelRecorderHandoff(session) }.buttonStyle(.daybookLink)
                Button("Take Over Anyway…") { confirmingTakeOver = true }
            }
            .accessibilityElement(children: .contain)
        case .done:
            Label { Text(headline ?? "") } icon: { Image(systemName: "checkmark.circle") }
                .font(TypeStyle.status)
                .foregroundStyle(Ink.secondary)
                .labelStyle(HandoffLineLabelStyle())
                .padding(.top, Space.s4)
        default:
            // Working: one bare line, its detail, and, while waiting through iCloud, the way out. Handing
            // over after an import, the import's own progress below says what's left.
            let showsDetail = !(current.isHandingOver && session.queue.isActive)
            VStack(alignment: .leading, spacing: 4) {
                Label { Text(headline ?? "").font(TypeStyle.statusLead).foregroundStyle(Ink.body) } icon: { ProgressView().controlSize(.mini) }
                    .labelStyle(HandoffLineLabelStyle())
                if let detail, showsDetail {
                    Text(detail).font(TypeStyle.status).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, HandoffLineLabelStyle.indent)
                }
                if case .waitingForSync = current {
                    HStack(spacing: Space.s4) {
                        Button("Take Over Anyway…") { confirmingTakeOver = true }
                        Button("Stop Waiting") { state.cancelRecorderHandoff(session) }
                    }
                    .buttonStyle(.daybookLink)
                    .font(TypeStyle.status)
                    .padding(.leading, HandoffLineLabelStyle.indent)
                    .padding(.top, 2)
                }
            }
            .padding(.top, Space.s4)
            .accessibilityElement(children: .combine)
        }
    }

    private func owner(_ current: RecorderHandoff.State) -> String {
        switch current {
        case .waitingForSync(let owner, _), .asking(let owner), .ownerFinishing(let owner, _): return owner
        case .refused(let by, _): return by
        default: return session.managedElsewhere?.ownerName ?? "the other device"
        }
    }
}

/// A handoff line: its symbol in a fixed column (a box's width), so the lines under it start where
/// its text does.
private struct HandoffLineLabelStyle: LabelStyle {
    static let column: CGFloat = 18
    static let indent: CGFloat = column + Space.s2

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.s2) {
            configuration.icon.frame(width: Self.column).accessibilityHidden(true)
            configuration.title
        }
    }
}

private extension RecorderHandoff.State {
    var isHandingOver: Bool { if case .handingOver = self { return true } else { return false } }
}

/// "Use on This Mac" / "Use on Alex’s iPhone" in the device page's More menu and the menu bar.
struct RecorderHandoffMenuItems: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
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
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession

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
