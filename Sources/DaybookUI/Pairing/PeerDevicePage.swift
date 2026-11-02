import DaybookDesign
import DaybookKit
import DaybookLink
import Foundation
import SwiftUI

// A paired Daybook's page, the same on both apps (docs/link.md, "A paired device's page"): "Alex’s iPhone" on
// the Mac, beside the recordings it made, and "Studio Mac" on the iPhone, pushed from Settings › Macs and inside
// the status sheet. The header (its tile, name, and status in `PeerStatusWords`' words), what's wrong with the
// pairing and its fix, what it's recording with Stop on it, the recorders it manages, whether it can start
// recording here, its facts, and Unpair.

/// What a paired device's page shows, worked out from plain facts the same way on both apps.
public struct PeerPage: Equatable, Sendable {
    /// What the page is about, from the link and the pairing.
    public struct Facts: Equatable, Sendable {
        public var id: String
        public var name: String
        /// The other device's kind.
        public var kind: PeerFacts.Kind
        public var isConnected: Bool
        public var activity: PeerFacts.Activity
        /// When it was last heard from.
        public var lastSeen: Date?
        /// When the recording it reports began, on this device's clock.
        public var recordingSince: Date?
        /// The conversation it's recording, when this device has it.
        public var conversationTitle: String?
        /// A stop sent from here would be taken: it lists `LinkCapabilities.pageStopFeature`, or this device
        /// records that conversation with it.
        public var canStop: Bool
        /// The recorders it manages, as it last said, on this device's clock.
        public var recorders: [LinkRecorderState]
        /// Whether it transcribes for other devices; nil when it hasn't said.
        public var transcribes: Bool?
        public var appVersion: String?
        public var pairedAt: Date?
        public var problem: Problem?

        public init(id: String, name: String, kind: PeerFacts.Kind, isConnected: Bool, activity: PeerFacts.Activity = .idle,
                    lastSeen: Date? = nil, recordingSince: Date? = nil, conversationTitle: String? = nil, canStop: Bool = false,
                    recorders: [LinkRecorderState] = [], transcribes: Bool? = nil, appVersion: String? = nil, pairedAt: Date? = nil,
                    problem: Problem? = nil) {
            self.id = id; self.name = name; self.kind = kind; self.isConnected = isConnected; self.activity = activity
            self.lastSeen = lastSeen; self.recordingSince = recordingSince; self.conversationTitle = conversationTitle
            self.canStop = canStop; self.recorders = recorders; self.transcribes = transcribes; self.appVersion = appVersion
            self.pairedAt = pairedAt; self.problem = problem
        }
    }

    /// What keeps the pair from working, with its fix.
    public enum Problem: Equatable, Sendable {
        /// This device's pairing for it can't be read (`LinkPairedDevice.isDamaged`): pair again.
        case damaged
        /// This device has no pairing for it (removed while it was away): pair again.
        case notPaired
        /// It doesn't know this device any more (its pairing was removed, or its library reset): pair again.
        case notRecognized
        /// No protocol version in common; its versions say which side is older when they can.
        case incompatible(peerVersions: ClosedRange<Int>?)
        /// Anything else, as a sentence (sync off on the Mac, so its recordings don't arrive).
        case other(String)
    }

    /// The recording it's making now.
    public struct Recording: Equatable, Sendable {
        public var line: String
        public var paused: Bool
        public var conversation: String?
        /// "Stop on Studio Mac", when a stop from here would be taken.
        public var stop: String?
    }

    public struct Fact: Equatable, Sendable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }
    }

    public var symbol: String
    public var title: String
    public var status: String
    public var isActive: Bool
    public var problem: String?
    /// The problem's fix is pairing again.
    public var offersPairAgain: Bool
    public var recording: Recording?
    /// "Soundcore Work · Recording since 10:02".
    public var recorders: [String]
    public var facts: [Fact]

    public init(_ facts: Facts, here: String, now: Date = Date()) {
        symbol = facts.kind == .iPhone ? "iphone" : "desktopcomputer"
        title = facts.name
        let peer = PeerFacts(id: facts.id, name: facts.name, kind: facts.kind, isConnected: facts.isConnected, activity: facts.activity,
                             lastSeen: facts.lastSeen)
        status = PeerStatusWords.line(peer, now: now).text
        isActive = facts.isConnected
        switch facts.problem {
        case .damaged?:
            problem = PairingWords.cantRead(facts.name); offersPairAgain = true
        case .notPaired?:
            problem = PairingWords.notPaired(facts.name, here: here); offersPairAgain = true
        case .notRecognized?:
            problem = PairingWords.doesntRecognize(facts.name, here: here); offersPairAgain = true
        case .incompatible(let versions)?:
            problem = PairingWords.update(facts.name, here: here, peerVersions: versions); offersPairAgain = false
        case .other(let sentence)?:
            problem = sentence; offersPairAgain = false
        case nil:
            problem = nil; offersPairAgain = false
        }
        if facts.isConnected, facts.activity != .idle {
            recording = Recording(line: PairingWords.recordingNow(since: facts.recordingSince, paused: facts.activity == .paused),
                                  paused: facts.activity == .paused, conversation: facts.conversationTitle,
                                  stop: facts.canStop ? PairingWords.stop(on: facts.name) : nil)
        } else {
            recording = nil
        }
        recorders = facts.recorders.compactMap { recorder in
            recorder.summary(now: now).map { "\(recorder.name ?? "Recorder") · \($0)" }
        }
        var list: [Fact] = []
        // Whether it transcribes is known once it has said.
        if let transcribes = facts.transcribes {
            list.append(Fact(label: PairingWords.transcribes, value: transcribes ? PairingWords.transcribesYes : PairingWords.transcribesNotSetUp))
        }
        if let version = facts.appVersion { list.append(Fact(label: PairingWords.daybook, value: version)) }
        if let paired = facts.pairedAt, paired > .distantPast {
            list.append(Fact(label: PairingWords.pairedOn, value: paired.formatted(date: .abbreviated, time: .omitted)))
        }
        self.facts = list
    }
}

/// What a paired device's page's controls do. A nil action leaves its control out.
public struct PeerPageActions {
    public var openConversation: (() -> Void)?
    public var stop: (() -> Void)?
    /// A stop is on its way: Stop waits.
    public var stopPending: Bool
    public var pairAgain: (() -> Void)?
    /// Another problem's fix ("Library Settings…").
    public var problemAction: (title: String, perform: () -> Void)?
    /// Whether it can start recording here (`PairingWords.canStartRecording`).
    public var canStartRecording: Binding<Bool>?
    /// False while a setting for every device here keeps any from starting a recording (the iPhone's Recording with
    /// Your Mac): the toggle is dimmed.
    public var canStartRecordingEnabled: Bool
    /// After the person confirms.
    public var unpair: () -> Void

    public init(openConversation: (() -> Void)? = nil, stop: (() -> Void)? = nil, stopPending: Bool = false,
                pairAgain: (() -> Void)? = nil, problemAction: (title: String, perform: () -> Void)? = nil,
                canStartRecording: Binding<Bool>? = nil, canStartRecordingEnabled: Bool = true, unpair: @escaping () -> Void) {
        self.openConversation = openConversation
        self.stop = stop
        self.stopPending = stopPending
        self.pairAgain = pairAgain
        self.problemAction = problemAction
        self.canStartRecording = canStartRecording
        self.canStartRecordingEnabled = canStartRecordingEnabled
        self.unpair = unpair
    }
}

/// A paired device's page. Each app gives it the page's words (`PeerPage`) and what its buttons do; a Mac
/// shows it in the detail column, the iPhone in Settings and the status sheet.
public struct PeerDevicePage<Footer: View>: View {
    public typealias Actions = PeerPageActions

    private let page: PeerPage
    private let actions: Actions
    private let footer: Footer
    @State private var confirmingUnpair = false
    @Environment(\.daybookDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter footer: What the app adds under the facts (the iPhone's scroll end).
    public init(_ page: PeerPage, actions: Actions, @ViewBuilder footer: () -> Footer) {
        self.page = page
        self.actions = actions
        self.footer = footer()
    }

    public var body: some View {
        Form {
            if density == .touch {
                Section { header.devicePageHeaderRow() }
            } else {
                // The Mac's grouped form boxes every row; the header stands above the boxes instead.
                Section {} header: { header.textCase(nil).padding(.bottom, DaybookSpacing.s2) }
            }
            if let problem = page.problem {
                Section {
                    ProblemLine(text: problem) {
                        if page.offersPairAgain, let pairAgain = actions.pairAgain {
                            Button(PairingWords.pairAgain, action: pairAgain)
                        } else if let action = actions.problemAction {
                            Button(action.title, action: action.perform)
                        }
                    }
                }
            }
            if let recording = page.recording {
                Section { recordingRow(recording) }
                    .daybookTransition(.opacity)
            }
            if !page.recorders.isEmpty {
                Section {
                    ForEach(page.recorders, id: \.self) { line in
                        Text(line.keepingSeparators)
                            .foregroundStyle(DaybookPalette.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text(label(PairingWords.recordersItManages))
                }
            }
            if let canStart = actions.canStartRecording {
                Section {
                    Toggle(label(PairingWords.canStartRecording), isOn: canStart)
                        .disabled(!actions.canStartRecordingEnabled)
                }
            }
            if !page.facts.isEmpty {
                Section {
                    ForEach(page.facts) { fact in LabeledContent(fact.label, value: fact.value) }
                }
            }
            Section {
                Button(PairingWords.unpair, role: .destructive) { confirmingUnpair = true }
            }
            footer
        }
        .formStyle(.grouped)
        .animation(DaybookMotion.resolved(DaybookMotion.state, reduceMotion: reduceMotion), value: page.recording)
        .confirmationDialog(PairingWords.unpairQuestion(page.title), isPresented: $confirmingUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive, action: actions.unpair)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(PairingWords.unpairConsequence)
        }
    }

    private var header: some View {
        DevicePageHeader(systemImage: page.symbol, isActive: page.isActive, title: page.title, status: page.status)
    }

    /// "● Recording now · since 10:02 AM", the conversation when this device has it, and Stop on it.
    private func recordingRow(_ recording: PeerPage.Recording) -> some View {
        HStack(alignment: .center, spacing: DaybookSpacing.s3) {
            Image(systemName: recording.paused ? "pause.circle.fill" : "record.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(recording.paused ? DaybookPalette.Ink.secondary : DaybookPalette.Ink.record)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.line.keepingSeparators)
                    .foregroundStyle(DaybookPalette.Ink.title)
                    .fixedSize(horizontal: false, vertical: true)
                if let conversation = recording.conversation {
                    if let open = actions.openConversation {
                        Button(conversation, action: open)
                            .buttonStyle(.daybookLink)
                            .lineLimit(1)
                    } else {
                        Text(conversation).foregroundStyle(DaybookPalette.Ink.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: DaybookSpacing.s2)
            if let title = recording.stop, let stop = actions.stop {
                Button(title, action: stop)
                    .controlSize(density == .touch ? .regular : .small)
                    .disabled(actions.stopPending)
            }
        }
    }

    /// A label as this device draws it: the iPhone title-cases its Settings labels.
    private func label(_ text: String) -> String { density == .touch ? SettingsWords.titleCased(text) : text }
}

extension PeerDevicePage where Footer == EmptyView {
    public init(_ page: PeerPage, actions: Actions) {
        self.init(page, actions: actions) { EmptyView() }
    }
}
