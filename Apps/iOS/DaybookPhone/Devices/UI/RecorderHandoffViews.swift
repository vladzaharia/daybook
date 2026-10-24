import DaybookKit
import SwiftUI

/// One recorder with its handoff (docs/devices.md, "Handing a recorder over"): "Use on This iPhone"
/// when a Mac manages it, "Use on Studio Mac" when this iPhone does and the Mac is on Wi‑Fi, and the
/// handoff's progress in between. Used by the status sheet and the device page.
///
/// A working state is a bare line; a state that needs the person (an answer, or waiting too long)
/// offers at most two actions (docs/interface.md).
struct RecorderHandoffCard: View {
    @ObservedObject var session: DeviceSession
    /// Opens the recorder's page; nil on the page itself.
    var open: (() -> Void)?
    /// The device page shows only the handoff, under its own header, in its own list row.
    var showsHeader = true
    var boxed = true
    @Environment(PhoneAppModel.self) private var model
    @State private var confirmingTakeOver = false

    var body: some View {
        let devices = model.devices
        let state = devices.handoffState(session)
        VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
            if showsHeader {
                HStack(spacing: PhoneStyle.Space.s3) {
                    DeviceGlyph(session: session, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.device.name).font(.subheadline.weight(.semibold)).foregroundStyle(PhoneStyle.Ink.title)
                        Text(PhoneDeviceCopy.line(for: session)).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if let open {
                        Button("Details", action: open)
                            .font(.footnote.weight(.semibold)).foregroundStyle(PhoneStyle.Ink.link)
                            .accessibilityLabel("\(session.device.name) details")
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if session.direct is any ManagedConnection {
                handoff(state, devices: devices)
            }
        }
        .padding(boxed ? PhoneStyle.Space.s3 : 0)
        .background(boxed ? PhoneStyle.quietFill : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .confirmationDialog("Take over \(session.device.name) now?", isPresented: $confirmingTakeOver, titleVisibility: .visible) {
            Button("Take Over Anyway") { devices.takeOverAnyway(session) }
            Button("Keep Waiting", role: .cancel) {}
        } message: {
            Text(RecorderHandoff.Words.takeOverRisk(owner: owner(state), recorder: session.device.name, here: "this iPhone"))
        }
    }

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
                    HStack(spacing: PhoneStyle.Space.s4) {
                        if session.managedElsewhere != nil {
                            Button("Take Over Anyway…") { confirmingTakeOver = true }
                        }
                        Button("OK") { devices.endHandoff(session) }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PhoneStyle.Ink.link)
                    .buttonStyle(.borderless)
                default:
                    HStack(alignment: .center, spacing: PhoneStyle.Space.s2) {
                        ProgressView().controlSize(.small)
                        Text(headline ?? "").font(.footnote.weight(.semibold)).foregroundStyle(PhoneStyle.Ink.title)
                    }
                    .accessibilityElement(children: .combine)
                    if let detail {
                        Text(detail).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if case .waitingForSync = state {
                        HStack(spacing: PhoneStyle.Space.s4) {
                            Button("Take Over Anyway…") { confirmingTakeOver = true }
                                .fontWeight(overdue ? .semibold : .regular)
                            Button("Stop Waiting") { devices.endHandoff(session) }
                        }
                        .font(.footnote)
                        .foregroundStyle(PhoneStyle.Ink.link)
                        .buttonStyle(.borderless)
                    }
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

    private func owner(_ state: RecorderHandoff.State) -> String {
        switch state {
        case .waitingForSync(let owner, _), .asking(let owner), .ownerFinishing(let owner, _): return owner
        case .refused(let by, _): return by
        default: return session.managedElsewhere?.ownerName ?? "your Mac"
        }
    }
}
