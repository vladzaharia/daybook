import AppKit
import DaybookDesign
import DaybookKit
import DaybookLink
import DaybookUI
import SwiftUI

/// Pair with iPhone…: the shared pairing screen (`PairingView`) as the Mac takes part, showing its code to type on
/// the phone, then who paired, then the phones this Mac is paired with, each with Unpair. Pairing stays open only
/// while this is showing.
struct PhonePairingStep: View {
    let state: AppState
    let link: PhoneLink
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
            PairingView(role: .showsCode, paired: pairedNow?.name, problem: link.pairingProblem) {
                if !link.paired.isEmpty {
                    PairedPhonesList(state: state, link: link, unpairing: $unpairing)
                        .daybookTransition(.push(from: .top))
                }
            } code: {
                stage
            }
            HStack {
                if let back {
                    Button { back() } label: { Label("All Devices", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                }
                Spacer()
                if let device = pairedNow {
                    Button("Done") { finish(device) }.keyboardShortcut(.defaultAction)
                } else {
                    Button(link.paired.isEmpty ? "Cancel" : "Done") { finish(nil) }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(.top, DaybookSpacing.s5)
        }
        .padding(DaybookSpacing.s5)
        .onAppear { if link.pairing == .closed { state.beginPhonePairing() } }
        .onDisappear { state.endPhonePairing() }
        .alert(PairingWords.unpairQuestion(unpairing?.name ?? PairingWords.unnamed(.iPhone)),
               isPresented: Binding(get: { unpairing != nil }, set: { if !$0 { unpairing = nil } })) {
            Button("Unpair", role: .destructive) { if let phone = unpairing { state.unpairPhone(phone.deviceID) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(PairingWords.unpairConsequence)
        }
    }

    /// The code and what to do with it; while it's coming, a line; when pairing closed, a new code.
    @ViewBuilder private var stage: some View {
        switch link.pairing {
        case .closed, .starting:
            HStack(spacing: DaybookSpacing.s2) {
                ProgressView().controlSize(.small)
                Text(PairingWords.gettingACode).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
        case .showing(let code):
            VStack(spacing: DaybookSpacing.s3) {
                PairingCodeView(code)
                Text(PairingWords.onTheIPhone(macName: link.identity.name))
                    .font(DaybookFont.status.font(.window)).foregroundStyle(DaybookPalette.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(PairingWords.expiry(code, now: context.date)).font(DaybookFont.status.font(.window)).foregroundStyle(DaybookPalette.Ink.meta)
                }
                if let problem = link.pairingProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(DaybookFont.status.font(.window)).foregroundStyle(DaybookPalette.Ink.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(DaybookSpacing.s4)
            .background(DaybookPalette.quietFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .paired:
            // The title says who paired, and the list below shows it connected.
            EmptyView()
        case .unavailable(let message):
            AttentionBox(kind: .problem, title: message, message: nil) {
                DeviceBoxPrimaryButton(title: PairingWords.showNewCode) { state.beginPhonePairing() }
            }
            .transition(.opacity)
        }
    }
}

/// The phones this Mac is paired with, each with whether it's connected and Unpair. A pairing that can't be read
/// says so, to be paired again or unpaired.
struct PairedPhonesList: View {
    let state: AppState
    let link: PhoneLink
    @Binding var unpairing: LinkPairedDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
            Text(PairingWords.pairedIPhones).font(DaybookFont.statusLead.font(.window)).foregroundStyle(DaybookPalette.Ink.secondary)
            VStack(spacing: 0) {
                ForEach(Array(link.paired.enumerated()), id: \.element.id) { index, phone in
                    if index > 0 { Divider() }
                    HStack(spacing: DaybookSpacing.s3) {
                        Image(systemName: "iphone")
                            // Connected is teal, like every linked device; mint means playing.
                            .foregroundStyle(link.peers[phone.deviceID] != nil ? AnyShapeStyle(DaybookPalette.accent) : AnyShapeStyle(.secondary))
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(phone.name.isEmpty ? PairingWords.unnamed(.iPhone) : phone.name)
                            Text(line(phone))
                                .font(DaybookFont.status.font(.window)).foregroundStyle(phone.isDamaged ? DaybookPalette.Ink.warning : DaybookPalette.Ink.secondary)
                        }
                        Spacer()
                        Button(PairingWords.unpair) { unpairing = phone }.controlSize(.small)
                    }
                    .padding(.vertical, DaybookSpacing.s2)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, DaybookSpacing.s3)
            .background(DaybookPalette.quietFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(_ phone: LinkPairedDevice) -> String {
        if phone.isDamaged { return PairingWords.needsPairingAgain }
        if link.peers[phone.deviceID] != nil { return "Connected" }
        return "\(PairingWords.pairedOn) \(phone.pairedAt.formatted(date: .abbreviated, time: .omitted))"
    }
}
