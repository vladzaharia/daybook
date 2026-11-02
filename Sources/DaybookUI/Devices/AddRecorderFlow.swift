import DaybookDesign
import DaybookKit
import SwiftUI

// Adding a recorder, in the same steps on both devices (docs/devices.md, "Interface"): its kind, then its way in
// when it has more than one here, then, for a recorder Daybook talks to directly, finding it nearby. Each app
// frames the steps its own way (the Mac's sheet, the iPhone's pushed screens and the open Duo's two pages); the
// steps' rows, words, and tips are these.

/// The steps, as plain values.
public enum AddRecorderStep: Equatable {
    case kinds
    case methods(String)
    case discover(String)

    /// Where choosing a kind leads: straight to finding it when its only way in here is direct, else to its ways
    /// in (a folder's way in is its own step, where the folder is chosen).
    public static func after(choosing kind: DeviceKind, on place: RecorderStatusWords.Place) -> AddRecorderStep {
        let methods = self.methods(kind, on: place)
        if methods.count == 1, methods.first?.kind == .direct { return .discover(kind.id) }
        return .methods(kind.id)
    }

    /// A kind's ways in on a device, in its order of preference. The iPhone adds a recorder it talks to directly
    /// that way only: exports from its app come in with Import Audio.
    public static func methods(_ kind: DeviceKind, on place: RecorderStatusWords.Place) -> [ConnectionMethod] {
        let methods = kind.implementedMethods
        if place == .iPhone, let direct = methods.first(where: { $0.kind == .direct }) { return [direct] }
        return methods
    }
}

/// A step's header: its glyph (20 pt) and title, left-aligned, the same on every step.
public struct AddRecorderHeader: View {
    private let symbol: String
    private let title: String
    private let animates: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(symbol: String, title: String, animates: Bool = false) {
        self.symbol = symbol
        self.title = title
        self.animates = animates
    }

    public var body: some View {
        HStack(alignment: .center, spacing: DaybookSpacing.s3) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .symbolEffect(.variableColor.iterative, isActive: animates && !reduceMotion)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(DaybookPalette.Ink.title)
                .contentTransition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
    }
}

/// A kind of recorder in the list to add: its tile, its name, and what it is in a plain label ("Set Up" once it
/// is, for a kind there's one of).
public struct RecorderKindRow: View {
    private let kind: DeviceKind
    private let isSetUp: Bool
    private let showsChevron: Bool

    public init(kind: DeviceKind, isSetUp: Bool, showsChevron: Bool = true) {
        self.kind = kind
        self.isSetUp = isSetUp
        self.showsChevron = showsChevron
    }

    public var body: some View {
        HStack(spacing: 14) {
            DaybookTile(symbol: kind.systemImage, tone: .neutral, size: .card)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DaybookSpacing.s2) {
                    Text(kind.name).daybookFont(.rowTitle).foregroundStyle(DaybookPalette.Ink.title)
                    if isSetUp {
                        Label("Set Up", systemImage: "checkmark.circle.fill")
                            .labelStyle(InlineGlyphLabelStyle())
                            .daybookFont(.rowDetail)
                            .foregroundStyle(DaybookPalette.Ink.secondary)
                    }
                }
                Text(isSetUp && kind.implementedMethods.count > 1 ? "Add another way to import." : RecorderStatusWords.kindLabel(kind))
                    .daybookFont(.rowDetail)
                    .foregroundStyle(DaybookPalette.Ink.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DaybookPalette.Ink.meta)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Finding a recorder nearby: what it found (the nearest first to connect, with its signal), the problem in its
/// box, what to try when it doesn't appear, and, when nothing was found and the kind has one, the folder to import
/// exports from instead. The step's title and its own action are `RecorderStatusWords.discoveryTitle` and
/// `discoveryAction`, which each app puts in its frame.
public struct RecorderDiscoveryContent: View {
    private let session: DeviceSession
    private let connection: any DiscoveringConnection
    private let useFolder: (() -> Void)?
    @Environment(\.recorderServices) private var services

    /// - Parameter useFolder: Sets up the kind's folder instead, offered when nothing was found.
    public init(session: DeviceSession, connection: any DiscoveringConnection, useFolder: (() -> Void)? = nil) {
        self.session = session
        self.connection = connection
        self.useFolder = useFolder
    }

    public var body: some View {
        let place = services?.place ?? .current
        let searching = connection.state == .searching
        let connecting = connection.connectingTo != nil
        let nothingFound = !searching && connection.discovered.isEmpty && !connecting
        VStack(alignment: .leading, spacing: 0) {
            if let problem = connection.problem, problem.id != SoundcoreIssue.notFound.rawValue {
                RecorderSetupProblem(problem: problem, place: place) { action in
                    switch action {
                    case .openBluetoothSettings, .openPrivacySettings: services?.openSystemSettings(action)
                    default: connection.search()
                    }
                }
                .padding(.top, DaybookSpacing.s4)
            }
            // What it found comes first, under the title; the tips are for when it doesn't.
            if !connection.discovered.isEmpty {
                let nearest = connection.discovered.max { $0.signal.bars < $1.signal.bars }?.id
                VStack(spacing: 0) {
                    ForEach(Array(connection.discovered.enumerated()), id: \.element.id) { index, recorder in
                        if index > 0 { Divider().padding(.leading, 44) }
                        FoundRecorderRow(recorder: recorder, symbol: session.kind.systemImage, prominent: recorder.id == nearest,
                                         connecting: connection.connectingTo == recorder.id, busy: connecting) {
                            connection.connect(to: recorder)
                        }
                        .daybookTransition(.opacity)
                    }
                }
                .background(DaybookPalette.quietFill, in: DaybookRadius.shape(DaybookRadius.box))
                .padding(.top, DaybookSpacing.s4)
            }
            let tips = RecorderStatusWords.discoveryTips(session.kind, on: place)
            if !tips.isEmpty, connection.discovered.isEmpty || nothingFound {
                VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                    Text("If it doesn’t appear:").daybookFont(.statusLead).foregroundStyle(DaybookPalette.Ink.secondary)
                    ForEach(tips, id: \.self) { tip in
                        HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s3) {
                            // Tips aren't actions: secondary glyphs, so the accent stays on what is.
                            Image(systemName: tip.symbol).foregroundStyle(DaybookPalette.Ink.secondary).frame(width: 20).accessibilityHidden(true)
                            Text(tip.text).foregroundStyle(DaybookPalette.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .daybookFont(.status)
                    }
                }
                .padding(.top, DaybookSpacing.s4)
            }
            if nothingFound, let fallback = session.kind.method(.files), let useFolder {
                HStack(spacing: DaybookSpacing.s1) {
                    Text("Or import exports instead:").foregroundStyle(DaybookPalette.Ink.secondary)
                    Button("\(fallback.title)…", action: useFolder).buttonStyle(.daybookLink)
                }
                .daybookFont(.status)
                .padding(.top, DaybookSpacing.s4)
                .daybookTransition(.opacity)
            }
        }
        .daybookMotion(DaybookMotion.fade, value: connection.discovered)
        .daybookMotion(DaybookMotion.fade, value: connection.problem)
    }
}

/// A recorder found nearby: its glyph, its name, its signal as bars and a word, and Connect (prominent for the
/// nearest).
public struct FoundRecorderRow: View {
    private let recorder: DiscoveredRecorder
    private let symbol: String
    private let prominent: Bool
    private let connecting: Bool
    private let busy: Bool
    private let connect: () -> Void

    public init(recorder: DiscoveredRecorder, symbol: String, prominent: Bool, connecting: Bool, busy: Bool, connect: @escaping () -> Void) {
        self.recorder = recorder
        self.symbol = symbol
        self.prominent = prominent
        self.connecting = connecting
        self.busy = busy
        self.connect = connect
    }

    public var body: some View {
        HStack(spacing: DaybookSpacing.s3) {
            Image(systemName: symbol).foregroundStyle(DaybookPalette.Ink.secondary).frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(recorder.name).foregroundStyle(DaybookPalette.Ink.title).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "cellularbars", variableValue: recorder.signal.bars).accessibilityHidden(true)
                    Text(recorder.signal.word)
                }
                .daybookFont(.status)
                .foregroundStyle(DaybookPalette.Ink.secondary)
            }
            Spacer(minLength: DaybookSpacing.s2)
            if connecting {
                HStack(spacing: DaybookSpacing.s2) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").daybookFont(.status).foregroundStyle(DaybookPalette.Ink.secondary)
                }
                .daybookTransition(.opacity)
            } else if prominent {
                Button("Connect", action: connect).buttonStyle(.daybookProminent).disabled(busy)
            } else {
                Button("Connect", action: connect).buttonStyle(.daybookTinted).disabled(busy)
            }
        }
        .padding(.horizontal, DaybookSpacing.s3)
        .padding(.vertical, DaybookSpacing.s2 + 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(recorder.name), \(recorder.signal.word)")
    }
}

/// A problem while finding a recorder: the page's problem box, with its first action (Open Settings for Bluetooth
/// on the iPhone).
struct RecorderSetupProblem: View {
    let problem: DeviceProblem
    let place: RecorderStatusWords.Place
    let perform: (DeviceProblemAction) -> Void

    var body: some View {
        let words = RecorderStatusWords.problem(problem, on: place)
        let action = RecorderStatusWords.problemActions(problem, on: place, excluding: [.dismiss, .setUpFolder]).first
        AttentionBox(kind: .problem, title: words.title, message: words.message,
                     primary: action.map { action in AttentionAction(RecorderStatusWords.actionTitle(action, on: place)) { perform(action) } })
    }
}
