import AppKit
import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI

/// Add Device: choose the kind of device, then its setup, which offers its methods in order of
/// preference. A direct method's card is the pre-permission screen: its one button starts the
/// search, which is when macOS asks about Bluetooth. The steps' rows, words, and tips are the ones the
/// iPhone's Add Recorder shows (DaybookUI's `AddRecorderFlow`); every step has the same header, and its
/// actions in the footer, the one that moves on as the default.
struct AddDeviceSheet: View {
    let state: AppState
    let request: AddDeviceRequest
    @State private var step: Step
    @State private var session: DeviceSession?
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Step: Equatable {
        case choose
        case setUp(String)
        case discover(String)
        /// Daybook on iPhone: pairing over the local link, rather than a method to set up.
        case pairPhone

        var kindID: String? {
            switch self {
            case .choose, .pairPhone: return nil
            case .setUp(let id), .discover(let id): return id
            }
        }
    }

    init(state: AppState, request: AddDeviceRequest) {
        self.state = state
        self.request = request
        if request.kindID == DaybookPhoneIntegration.id {
            _step = State(initialValue: .pairPhone)
        } else if let kind = request.kindID {
            _step = State(initialValue: request.method == .direct ? .discover(kind) : .setUp(kind))
        } else {
            _step = State(initialValue: .choose)
        }
    }

    var body: some View {
        ZStack {
            switch step {
            case .choose:
                KindChooser(state: state, choose: { go(to: Self.step(choosing: $0)) }, cancel: close)
                    .transition(transition)
            case .pairPhone:
                PhonePairingStep(state: state, back: request.kindID == nil ? { go(to: .choose, forward: false) } : nil) { paired in
                    state.addDeviceRequest = nil
                    if let paired { state.showDevice(paired.deviceID.uuidString) }
                }
                .transition(transition)
            case .setUp(let id):
                if let session, session.kind.id == id {
                    MethodChooser(state: state, session: session,
                                  back: request.kindID == nil ? { go(to: .choose, forward: false) } : nil,
                                  discover: { go(to: .discover(id)) }, finish: { finish(session) }, cancel: close)
                        .transition(transition)
                }
            case .discover(let id):
                if let session, session.kind.id == id, let direct = session.direct as? SoundcoreConnection {
                    DiscoveryStep(session: session, connection: direct,
                                  back: backFromDiscovering(id),
                                  useFolder: session.files == nil || session.files?.isSetUp == true ? nil : {
                                      direct.stopSearching()
                                      if state.chooseDeviceFolder(for: session) { finish(session) }
                                  },
                                  finish: { finish(session) }, cancel: close)
                        .transition(transition)
                }
            }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
        .environment(\.recorderServices, state.recorderServices)
        .onAppear { prepare(step) }
    }

    /// Where choosing a kind leads, by the rule the iPhone follows too (`AddRecorderStep`): Daybook on iPhone pairs; a
    /// kind whose only way in here is direct is looked for at once; any other offers its ways in.
    static func step(choosing kind: DeviceKind) -> Step {
        if kind.id == DaybookPhoneIntegration.id { return .pairPhone }
        switch AddRecorderStep.after(choosing: kind, on: .mac) {
        case .kinds: return .choose
        case .methods(let id): return .setUp(id)
        case .discover(let id): return .discover(id)
        }
    }

    /// Back from finding a recorder: to the kinds when it came straight from them, else to its ways in; nowhere when
    /// the sheet opened on this step.
    private func backFromDiscovering(_ id: String) -> (() -> Void)? {
        guard request.method != .direct else { return nil }
        if request.kindID == nil, let kind = DeviceCatalog.kind(id), case .discover = AddRecorderStep.after(choosing: kind, on: .mac) {
            return { go(to: .choose, forward: false) }
        }
        return { go(to: .setUp(id), forward: false) }
    }

    /// Starts (or continues) setting up the step's kind, outside of view updates.
    private func prepare(_ step: Step) {
        guard let id = step.kindID, session?.kind.id != id, let kind = DeviceCatalog.kind(id) else { return }
        session = state.devices.beginSetup(kind)
    }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private func go(to next: Step, forward: Bool = true) {
        self.forward = forward
        prepare(next)
        withAnimation(DaybookMotion.resolved(DaybookMotion.state, reduceMotion: reduceMotion)) { step = next }
    }

    private func close() {
        (session?.direct as? any DiscoveringConnection)?.stopSearching()
        state.devices.cancelSetup()
        state.addDeviceRequest = nil
    }

    /// A method is set up: the device joins the sidebar and its page opens.
    private func finish(_ session: DeviceSession) {
        if state.devices.pendingSetup === session { state.devices.commitSetup() }
        state.addDeviceRequest = nil
        state.showDevice(session.id)
    }
}

// MARK: - Choose a kind

private struct KindChooser: View {
    let state: AppState
    let choose: (DeviceKind) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AddRecorderHeader(symbol: "plus.circle", title: "Add Device")
            VStack(spacing: DaybookSpacing.s2) {
                ForEach(DeviceCatalog.kinds) { kind in
                    KindCard(kind: kind, isSetUp: !kind.allowsMultiple && state.devices.session(kind: kind.id) != nil) { choose(kind) }
                }
            }
            .padding(.top, DaybookSpacing.s4)
            SheetFooter {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(DaybookSpacing.s5)
    }
}

/// A kind on a quiet card that lifts under the pointer: the row the iPhone's Add Recorder lists.
private struct KindCard: View {
    let kind: DeviceKind
    let isSetUp: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RecorderKindRow(kind: kind, isSetUp: isSetUp)
                .padding(DaybookSpacing.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? Color.primary.opacity(0.09) : DaybookPalette.quietFill,
                            in: RoundedRectangle(cornerRadius: DaybookRadius.box, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DaybookRadius.box, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .daybookMotion(DaybookMotion.hover, value: hovering)
        .accessibilityLabel("\(kind.name). \(RecorderStatusWords.kindLabel(kind))")
    }
}

/// A step's footer: Back on the leading edge when there's somewhere to go back to, then the step's actions at the
/// trailing edge, as a Mac sheet places them.
private struct SheetFooter<Actions: View>: View {
    var back: (() -> Void)?
    var backTitle = "Back"
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: DaybookSpacing.s3) {
            if let back {
                Button { back() } label: { Label(backTitle, systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
            }
            Spacer()
            actions
        }
        .padding(.top, DaybookSpacing.s5)
    }
}

// MARK: - A kind's methods

private struct MethodChooser: View {
    let state: AppState
    let session: DeviceSession
    let back: (() -> Void)?
    let discover: () -> Void
    let finish: () -> Void
    let cancel: () -> Void

    var body: some View {
        let kind = session.kind
        let methods = AddRecorderStep.methods(kind, on: .mac)
        VStack(alignment: .leading, spacing: 0) {
            AddRecorderHeader(symbol: kind.systemImage, title: "Set Up \(kind.name)")
            VStack(spacing: DaybookSpacing.s3) {
                ForEach(Array(methods.enumerated()), id: \.element.id) { index, method in
                    MethodCard(method: method, recommended: index == 0 && methods.count > 1,
                               isSetUp: session.connection(method.kind)?.isSetUp == true) {
                        switch method.kind {
                        case .direct: discover()
                        case .files: if state.chooseDeviceFolder(for: session) { finish() }
                        case .account: break
                        }
                    }
                }
            }
            .padding(.top, DaybookSpacing.s4)
            SheetFooter(back: back, backTitle: "All Devices") {
                if session.setUpMethods.isEmpty {
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                } else {
                    Button("Done", action: finish).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(DaybookSpacing.s5)
    }
}

/// One way to bring recordings in. The recommended one is marked, and its button is the prominent one.
private struct MethodCard: View {
    let method: ConnectionMethod
    let recommended: Bool
    let isSetUp: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s3) {
            Image(systemName: method.systemImage)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DaybookSpacing.s1) {
                HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s2) {
                    Text(method.title).font(.system(size: 13, weight: .semibold))
                    if recommended && !isSetUp { RecommendedLabel() }
                    Spacer()
                }
                Text(method.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let note = method.note, !isSetUp {
                    Text(note).font(DaybookFont.status.font(.window)).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    if isSetUp {
                        Label("Set Up", systemImage: "checkmark.circle.fill")
                            .font(DaybookFont.status.font(.window)).foregroundStyle(.secondary)
                    } else if recommended {
                        Button(method.setupAction, action: action)
                            .buttonStyle(.borderedProminent)
                            .tint(DaybookPalette.prominentFill)
                    } else {
                        Button(method.setupAction, action: action)
                    }
                }
                .padding(.top, DaybookSpacing.s2)
            }
        }
        .padding(DaybookSpacing.s4)
        .background(DaybookPalette.quietFill, in: RoundedRectangle(cornerRadius: DaybookRadius.box, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(recommended ? "\(method.title), recommended" : method.title)
    }
}

// MARK: - Looking for the recorder

private struct DiscoveryStep: View {
    let session: DeviceSession
    let connection: SoundcoreConnection
    let back: (() -> Void)?
    /// The fallback that always works, offered when nothing is found.
    let useFolder: (() -> Void)?
    let finish: () -> Void
    let cancel: () -> Void

    private var searching: Bool { connection.state == .searching }
    private var connecting: Bool { connection.connectingTo != nil }
    private var found: Bool { !connection.discovered.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AddRecorderHeader(symbol: searching || connecting ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash",
                              title: RecorderStatusWords.discoveryTitle(session.kind, searching: searching, connecting: connecting, found: found),
                              animates: searching || connecting)
            RecorderDiscoveryContent(session: session, connection: connection, useFolder: useFolder)
            SheetFooter(back: back.map { back in { connection.stopSearching(); back() } }) {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                if let action = RecorderStatusWords.discoveryAction(searching: searching, connecting: connecting, found: found) {
                    if searching {
                        Button(action) { connection.stopSearching() }
                    } else if found {
                        // Look Again: the nearest recorder's Connect is the default.
                        Button(action) { connection.search() }
                    } else {
                        Button(action) { connection.search() }.keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(DaybookSpacing.s5)
        .onAppear {
            if connection.state == .connected { finish() }
            else if !searching && !connecting && connection.discovered.isEmpty && connection.problem == nil && !connection.searchFoundNothing {
                connection.search()
            }
        }
        .onChange(of: connection.state) { _, state in
            if state == .connected { finish() }
        }
    }
}
