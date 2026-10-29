import DaybookKit
import SwiftUI

/// A recorder's handoff (docs/devices.md, "Handing a recorder over"): "Use on This iPhone" when a
/// Mac manages it, "Use on Studio Mac" when this iPhone does and the Mac is on Wi‑Fi, and the
/// handoff's progress in between. The device page shows it under its own header; the status sheet
/// shows it as a row of the recorder's card.
///
/// A working state is a bare line; a state that needs the person (an answer, or waiting too long)
/// offers at most two actions (docs/interface.md).
struct RecorderHandoffCard: View {
    enum Style {
        /// The device page: full-width buttons.
        case page
        /// A row of the status sheet's recorder card: the card's glyph column, then the words.
        case row
    }

    @ObservedObject var session: DeviceSession
    var style: Style = .page
    @Environment(PhoneAppModel.self) private var model
    @State private var confirmingTakeOver = false

    /// Whether there's anything to show: a handoff under way, or one to offer.
    @MainActor
    static func shows(_ session: DeviceSession, devices: PhoneDevices) -> Bool {
        guard session.direct is any ManagedConnection else { return false }
        return devices.handoffState(session) != .idle || session.managedElsewhere != nil || !devices.handoffTargets(session).isEmpty
    }

    var body: some View {
        let devices = model.devices
        let state = devices.handoffState(session)
        VStack(alignment: .leading, spacing: style == .page ? PhoneStyle.Space.s2 : 0) {
            if session.direct is any ManagedConnection {
                switch style {
                case .page: handoff(state, devices: devices)
                case .row: rows(state, devices: devices)
                }
            }
        }
        .confirmationDialog("Take over \(session.device.name) now?", isPresented: $confirmingTakeOver, titleVisibility: .visible) {
            Button("Take Over Anyway") { devices.takeOverAnyway(session) }
            Button("Keep Waiting", role: .cancel) {}
        } message: {
            Text(RecorderHandoff.Words.takeOverRisk(owner: owner(state), recorder: session.device.name, here: "this iPhone"))
        }
    }

    // MARK: The device page

    @ViewBuilder
    private func handoff(_ state: RecorderHandoff.State, devices: PhoneDevices) -> some View {
        let recorder = session.device.name
        let headline = RecorderHandoff.Words.headline(state, recorder: recorder, here: "this iPhone")
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let overdue = devices.handoff.isOverdue(state, now: context.date)
            let detail = RecorderHandoff.Words.detail(state, recorder: recorder, here: "this iPhone", overdue: overdue, now: context.date)
            VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
                switch state {
                case .idle:
                    if let owner = session.managedElsewhere {
                        actionButton("Use on This iPhone", systemImage: "iphone") { devices.useHere(session) }
                            .accessibilityHint("Asks \(owner.ownerName) to let go of \(recorder), then connects here")
                    } else {
                        ForEach(devices.handoffTargets(session), id: \.linkID) { mac in
                            actionButton("Use on \(mac.name)", systemImage: "desktopcomputer") { devices.give(session, to: mac) }
                                .accessibilityHint("This iPhone finishes any import first")
                        }
                    }
                case .done:
                    Label(headline ?? "", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(PhoneStyle.Ink.secondary)
                        .symbolRenderingMode(.hierarchical)
                case .refused:
                    Text(headline ?? "").font(.footnote.weight(.semibold)).foregroundStyle(PhoneStyle.Ink.warning)
                    if let detail { Text(detail).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary).fixedSize(horizontal: false, vertical: true) }
                    refusedActions(devices: devices)
                default:
                    HStack(alignment: .center, spacing: PhoneStyle.Space.s2) {
                        ProgressView().controlSize(.small)
                        Text(headline ?? "").font(.footnote.weight(.semibold)).foregroundStyle(PhoneStyle.Ink.title)
                    }
                    .accessibilityElement(children: .combine)
                    if let detail {
                        Text(detail).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if case .waitingForSync = state { waitingActions(devices: devices, overdue: overdue) }
                }
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: systemImage).frame(maxWidth: .infinity) }
            .buttonStyle(.glass)
            .controlSize(.large)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PhoneStyle.Ink.link)
    }

    // MARK: The status sheet's row

    @ViewBuilder
    private func rows(_ state: RecorderHandoff.State, devices: PhoneDevices) -> some View {
        let recorder = session.device.name
        let headline = RecorderHandoff.Words.headline(state, recorder: recorder, here: "this iPhone") ?? ""
        switch state {
        case .idle:
            if let owner = session.managedElsewhere {
                Button { devices.useHere(session) } label: {
                    StatusRow {
                        StatusLinkGlyph(systemImage: "iphone")
                    } content: {
                        Text("Use on This iPhone").font(.subheadline.weight(.medium)).foregroundStyle(PhoneStyle.Ink.link)
                    }
                }
                .buttonStyle(StatusRowButtonStyle())
                .accessibilityHint("Asks \(owner.ownerName) to let go of \(recorder), then connects here")
            } else {
                let targets = devices.handoffTargets(session)
                ForEach(targets, id: \.linkID) { mac in
                    if mac.linkID != targets.first?.linkID { StatusDivider() }
                    Button { devices.give(session, to: mac) } label: {
                        StatusRow {
                            StatusLinkGlyph(systemImage: "desktopcomputer")
                        } content: {
                            NamePhrase(prefix: "Use on", name: mac.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(PhoneStyle.Ink.link)
                        }
                    }
                    .buttonStyle(StatusRowButtonStyle())
                    .accessibilityHint("This iPhone finishes any import first")
                }
            }
        case .done:
            StatusRow {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(PhoneStyle.Ink.secondary)
                    .accessibilityHidden(true)
            } content: {
                Text(headline).font(.subheadline).foregroundStyle(PhoneStyle.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        default:
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let overdue = devices.handoff.isOverdue(state, now: context.date)
                let detail = RecorderHandoff.Words.detail(state, recorder: recorder, here: "this iPhone", overdue: overdue, now: context.date)
                let refused: Bool = { if case .refused = state { return true }; return false }()
                StatusRow(alignment: .top) {
                    Group {
                        if refused {
                            Image(systemName: "exclamationmark.triangle.fill").font(.body).foregroundStyle(PhoneStyle.Ink.warning)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(height: 20)
                    .accessibilityHidden(true)
                } content: {
                    VStack(alignment: .leading, spacing: PhoneStyle.Space.s1) {
                        Text(headline)
                            .font(.subheadline.weight(refused ? .semibold : .regular))
                            .foregroundStyle(refused ? PhoneStyle.Ink.warning : PhoneStyle.Ink.title)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail {
                            Text(detail).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if refused {
                            refusedActions(devices: devices).padding(.top, 2)
                        } else if case .waitingForSync = state {
                            waitingActions(devices: devices, overdue: overdue).padding(.top, 2)
                        }
                    }
                }
            }
        }
    }

    // MARK: Shared

    private func refusedActions(devices: PhoneDevices) -> some View {
        HStack(spacing: PhoneStyle.Space.s4) {
            if session.managedElsewhere != nil {
                Button("Take Over Anyway…") { confirmingTakeOver = true }
            }
            Button("OK") { devices.endHandoff(session) }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(PhoneStyle.Ink.link)
        .buttonStyle(.borderless)
    }

    private func waitingActions(devices: PhoneDevices, overdue: Bool) -> some View {
        HStack(spacing: PhoneStyle.Space.s4) {
            Button("Take Over Anyway…") { confirmingTakeOver = true }
                .fontWeight(overdue ? .semibold : .regular)
            Button("Stop Waiting") { devices.endHandoff(session) }
        }
        .font(.footnote)
        .foregroundStyle(PhoneStyle.Ink.link)
        .buttonStyle(.borderless)
    }

    private func owner(_ state: RecorderHandoff.State) -> String {
        switch state {
        case .waitingForSync(let owner, _), .asking(let owner), .ownerFinishing(let owner, _): return owner
        case .refused(let by, _): return by
        default: return session.managedElsewhere?.ownerName ?? "your Mac"
        }
    }
}
