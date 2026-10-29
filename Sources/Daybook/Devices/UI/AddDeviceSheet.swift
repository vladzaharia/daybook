import AppKit
import DaybookKit
import SwiftUI

/// Add Device: choose the kind of recorder, then its setup, which offers its methods in order of
/// preference. A direct method's card is the pre-permission screen: its one button starts the
/// search, which is when macOS asks about Bluetooth.
struct AddDeviceSheet: View {
    @ObservedObject var state: AppState
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
                KindChooser(state: state, choose: { go(to: $0.id == DaybookPhoneIntegration.id ? .pairPhone : .setUp($0.id)) }, cancel: close)
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
                                  back: request.method == .direct ? nil : { go(to: .setUp(id), forward: false) },
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
        .tint(DaybookStyle.accent)
        .onAppear { prepare(step) }
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
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.3)) { step = next }
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
    @ObservedObject var state: AppState
    let choose: (DeviceKind) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Recorder").font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: Space.s2) {
                ForEach(DeviceCatalog.kinds) { kind in
                    KindCard(kind: kind, existing: kind.allowsMultiple ? nil : state.devices.session(kind: kind.id)) { choose(kind) }
                }
            }
            .padding(.top, Space.s5)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
            .padding(.top, Space.s5)
        }
        .padding(Space.s5)
    }
}

private struct KindCard: View {
    let kind: DeviceKind
    let existing: DeviceSession?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s4) {
                // A tile in the secondary ink, as on the iPhone's Add Recorder: the accent stays on actions.
                Image(systemName: kind.systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Space.s2) {
                        Text(kind.name).font(.system(size: 13, weight: .semibold))
                        if existing != nil {
                            Label("Set Up", systemImage: "checkmark.circle.fill")
                                .labelStyle(DeviceInlineLabelStyle())
                                .font(TypeStyle.status).foregroundStyle(.secondary)
                        }
                    }
                    Text(existing != nil ? "Add another way to import." : kind.summary)
                        .font(TypeStyle.status).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.s2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .offset(x: hovering ? 2 : 0)
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.primary.opacity(0.09) : DaybookStyle.quietFill,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel("\(kind.name). \(kind.summary)")
    }
}

// MARK: - A kind's methods

private struct MethodChooser: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    let back: (() -> Void)?
    let discover: () -> Void
    let finish: () -> Void
    let cancel: () -> Void

    var body: some View {
        let kind = session.kind
        VStack(spacing: 0) {
            DeviceGlyph(symbol: kind.systemImage, size: 30, linked: false)
            Text("Set Up \(kind.name)").font(.title3.weight(.semibold)).padding(.top, Space.s3)
            VStack(spacing: Space.s3) {
                ForEach(Array(kind.implementedMethods.enumerated()), id: \.element.id) { index, method in
                    MethodCard(method: method, recommended: index == 0 && kind.implementedMethods.count > 1,
                               isSetUp: session.connection(method.kind)?.isSetUp == true) {
                        switch method.kind {
                        case .direct: discover()
                        case .files: if state.chooseDeviceFolder(for: session) { finish() }
                        case .account: break
                        }
                    }
                }
            }
            .padding(.top, Space.s5)
            HStack {
                if let back {
                    Button { back() } label: { Label("All Recorders", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                }
                Spacer()
                Button(session.setUpMethods.isEmpty ? "Cancel" : "Done") {
                    if session.setUpMethods.isEmpty { cancel() } else { finish() }
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.top, Space.s5)
        }
        .padding(Space.s5)
    }
}

/// One way to bring recordings in. The recommended one is marked, and its button is the prominent one.
private struct MethodCard: View {
    let method: ConnectionMethod
    let recommended: Bool
    let isSetUp: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            Image(systemName: method.systemImage)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    Text(method.title).font(.system(size: 13, weight: .semibold))
                    if recommended && !isSetUp { RecommendedBadge() }
                    Spacer()
                }
                Text(method.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let note = method.note, !isSetUp {
                    Text(note).font(TypeStyle.status).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    if isSetUp {
                        Label("Set Up", systemImage: "checkmark.circle.fill")
                            .font(TypeStyle.status).foregroundStyle(.secondary)
                    } else if recommended {
                        Button(method.setupAction, action: action)
                            .buttonStyle(.borderedProminent)
                            .tint(DaybookStyle.prominentFill)
                    } else {
                        Button(method.setupAction, action: action)
                    }
                }
                .padding(.top, Space.s2)
            }
        }
        .padding(Space.s4)
        .background(DaybookStyle.quietFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(recommended ? "\(method.title), recommended" : method.title)
    }
}

// MARK: - Looking for the recorder

private struct DiscoveryStep: View {
    @ObservedObject var session: DeviceSession
    @ObservedObject var connection: SoundcoreConnection
    let back: (() -> Void)?
    /// The fallback that always works, offered when nothing is found.
    let useFolder: (() -> Void)?
    let finish: () -> Void
    let cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var searching: Bool { connection.state == .searching }
    private var connecting: Bool { connection.connectingTo != nil }
    private var nothingFound: Bool { !searching && connection.discovered.isEmpty && !connecting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Space.s3) {
                Image(systemName: searching || connecting ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative, isActive: (searching || connecting) && !reduceMotion)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(title).font(.title3.weight(.semibold))
                    .contentTransition(.opacity)
                Spacer()
                if searching {
                    Button("Stop") { connection.stopSearching() }
                } else if !connecting {
                    Button(connection.discovered.isEmpty ? "Try Again" : "Look Again") { connection.search() }
                }
            }

            if let problem = connection.problem, problem.id != SoundcoreIssue.notFound.rawValue {
                SetupProblem(problem: problem) { action in
                    switch action {
                    case .openBluetoothSettings:
                        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(url) }
                    case .openPrivacySettings: PrivacySettings.open(.bluetooth)
                    default: connection.search()
                    }
                }
                .transition(.deviceNotice(reduceMotion: reduceMotion))
            }

            // What it found comes first, straight under the title; the tips are for when it doesn't.
            if !connection.discovered.isEmpty {
                VStack(spacing: 0) {
                    let nearest = connection.discovered.max { $0.signal.bars < $1.signal.bars }?.id
                    ForEach(Array(connection.discovered.enumerated()), id: \.element.id) { index, recorder in
                        if index > 0 { Divider().padding(.leading, 44) }
                        FoundRow(recorder: recorder, symbol: session.kind.systemImage, prominent: recorder.id == nearest,
                                 connection: connection)
                            .transition(.opacity)
                    }
                }
                .background(DaybookStyle.quietFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, Space.s4)
            }

            VStack(alignment: .leading, spacing: Space.s2) {
                Text("If it doesn’t appear:").font(TypeStyle.statusLead).foregroundStyle(.secondary)
                ForEach(session.kind.discoveryTips, id: \.self) { tip in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                        Image(systemName: tip.symbol).foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
                        Text(tip.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, Space.s4)

            if nothingFound, let fallback = session.kind.method(.files), let useFolder {
                HStack(spacing: Space.s1) {
                    Text("Or import exports instead:").foregroundStyle(.secondary)
                    Button("\(fallback.title)…", action: useFolder).buttonStyle(.daybookLink)
                }
                .padding(.top, Space.s4)
                .transition(.opacity)
            }

            HStack {
                if let back {
                    Button { connection.stopSearching(); back() } label: { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
            .padding(.top, Space.s5)
        }
        .padding(Space.s5)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: connection.discovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: connection.problem)
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

    private var title: String {
        if searching { return "Looking for \(session.kind.name)…" }
        if connecting { return "Connecting to \(session.kind.name)…" }
        if nothingFound { return "No \(session.kind.shortName) Found Nearby" }
        return "Found Nearby"
    }
}

private struct FoundRow: View {
    let recorder: DiscoveredRecorder
    let symbol: String
    let prominent: Bool
    @ObservedObject var connection: SoundcoreConnection

    private var connecting: Bool { connection.connectingTo == recorder.id }

    var body: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
                .accessibilityHidden(true)
            Text(recorder.name).lineLimit(1)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "cellularbars", variableValue: recorder.signal.bars)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(recorder.signal.word).foregroundStyle(.secondary)
            }
            .font(TypeStyle.status)
            .frame(minWidth: 100, alignment: .leading)
            if connecting {
                HStack(spacing: Space.s2) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(TypeStyle.status).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else if prominent {
                Button("Connect") { connection.connect(to: recorder) }
                    .buttonStyle(.borderedProminent)
                    .tint(DaybookStyle.prominentFill)
                    .disabled(connection.connectingTo != nil)
            } else {
                Button("Connect") { connection.connect(to: recorder) }
                    .disabled(connection.connectingTo != nil)
            }
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2 + 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(recorder.name), \(recorder.signal.word)")
    }
}

/// A problem inside the sheet: the device page's problem box and copy, with its first action.
private struct SetupProblem: View {
    let problem: DeviceProblem
    let perform: (DeviceProblemAction) -> Void

    var body: some View {
        DeviceAttentionBox(kind: .problem, symbol: "exclamationmark.triangle.fill", title: problem.title, message: problem.message) {
            if let action = problem.actions.first(where: { ![.technicalDetails, .dismiss, .setUpFolder].contains($0) }) {
                DeviceBoxPrimaryButton(title: action.title) { perform(action) }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
