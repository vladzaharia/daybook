import AppKit
import DaybookKit
import DaybookLink
import SwiftUI

/// Add iPhone…: the six-digit code to type on the phone, then what happened, then the phones this
/// Mac is paired with, each with Unpair. Pairing stays open only while this is showing.
struct PhonePairingStep: View {
    @ObservedObject var state: AppState
    @ObservedObject var link: PhoneLink
    let back: (() -> Void)?
    /// Pairing finished (with the phone that paired) or was cancelled (nil).
    let finish: (LinkPairedDevice?) -> Void
    @State private var unpairing: LinkPairedDevice?

    init(state: AppState, back: (() -> Void)?, finish: @escaping (LinkPairedDevice?) -> Void) {
        self.state = state
        self.link = state.phoneLink
        self.back = back
        self.finish = finish
    }

    private var pairedNow: LinkPairedDevice? {
        if case .paired(let device) = link.pairing { return device }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            DeviceGlyph(symbol: "iphone", size: 30, linked: pairedNow != nil)
            Text(pairedNow.map { "Paired with \($0.name)" } ?? "Add iPhone").font(.title3.weight(.semibold)).padding(.top, Space.s3)
            if pairedNow == nil {
                stage
                    .padding(.top, Space.s5)
            }
            if !link.paired.isEmpty {
                PairedPhonesList(state: state, link: link, unpairing: $unpairing)
                    .padding(.top, Space.s5)
            }
            HStack {
                if let back {
                    Button { back() } label: { Label("All Recorders", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                }
                Spacer()
                if let device = pairedNow {
                    Button("Done") { finish(device) }.keyboardShortcut(.defaultAction)
                } else {
                    Button(link.paired.isEmpty ? "Cancel" : "Done") { finish(nil) }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(.top, Space.s5)
        }
        .padding(Space.s5)
        .onAppear { if link.pairing == .closed { state.beginPhonePairing() } }
        .onDisappear { state.endPhonePairing() }
        .alert("Unpair \(unpairing?.name ?? "this iPhone")?", isPresented: Binding(get: { unpairing != nil }, set: { if !$0 { unpairing = nil } })) {
            Button("Unpair", role: .destructive) { if let phone = unpairing { state.unpairPhone(phone.deviceID) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Mac and the iPhone stop recording together. Its recordings stay in your library.")
        }
    }

    @ViewBuilder private var stage: some View {
        switch link.pairing {
        case .closed, .starting:
            HStack(spacing: Space.s2) {
                ProgressView().controlSize(.small)
                Text("Getting a code…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
        case .showing(let code):
            VStack(spacing: Space.s3) {
                Text(code.formatted)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .tracking(2)
                    .textSelection(.enabled)
                    .accessibilityLabel("Pairing code \(code.digits.map(String.init).joined(separator: " "))")
                Text("On your iPhone, open Daybook › Settings › Pair with Your Mac, choose “\(link.identity.name)”, and enter this code.")
                    .font(TypeStyle.status).foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(expiry(code, now: context.date)).font(TypeStyle.status).foregroundStyle(Ink.meta)
                }
                if let problem = link.pairingProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(TypeStyle.status).foregroundStyle(Ink.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(Space.s4)
            .background(DaybookStyle.quietFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .paired:
            // The title says who paired, and the list below shows it connected.
            EmptyView()
        case .unavailable(let message):
            DeviceBox {
                HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.warning).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.s3) {
                        Text(message).font(TypeStyle.status).foregroundStyle(Ink.body).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button("Show New Code") { state.beginPhonePairing() }.controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func expiry(_ code: LinkPairingCode, now: Date) -> String {
        let minutes = Int((code.expiresAt.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 1 ? "Expires in about a minute" : "Expires in \(minutes) minutes"
    }
}

/// The phones this Mac is paired with, each with whether it's connected and Unpair.
struct PairedPhonesList: View {
    @ObservedObject var state: AppState
    @ObservedObject var link: PhoneLink
    @Binding var unpairing: LinkPairedDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Paired iPhones").font(TypeStyle.statusLead).foregroundStyle(Ink.secondary)
            VStack(spacing: 0) {
                ForEach(Array(link.paired.enumerated()), id: \.element.id) { index, phone in
                    if index > 0 { Divider() }
                    HStack(spacing: Space.s3) {
                        Image(systemName: "iphone")
                            // Connected is teal, like every linked device; mint means playing.
                            .foregroundStyle(link.peers[phone.deviceID] != nil ? AnyShapeStyle(DaybookStyle.accent) : AnyShapeStyle(.secondary))
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(phone.name)
                            Text(link.peers[phone.deviceID] != nil ? "Connected" : "Paired \(phone.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(TypeStyle.status).foregroundStyle(Ink.secondary)
                        }
                        Spacer()
                        Button("Unpair…") { unpairing = phone }.controlSize(.small)
                    }
                    .padding(.vertical, Space.s2)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, Space.s3)
            .background(DaybookStyle.quietFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
