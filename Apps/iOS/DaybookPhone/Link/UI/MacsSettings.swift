import DaybookDesign
import DaybookKit
import DaybookLink
import DaybookUI
import SwiftUI

/// Settings › Macs: paired Macs and how each is doing, and Pair with Your Mac.
struct MacsSection: View {
    @Environment(PhoneAppModel.self) private var model
    @Binding var showingPairing: Bool

    var body: some View {
        Section {
            ForEach(model.link.macs) { mac in
                SettingsLink(route: .mac(mac.id)) { MacRow(mac: mac, recordingBySync: model.isRecordingBySync(mac)) }
            }
            Button {
                showingPairing = true
            } label: {
                // The Mac's instructions name this item, so it's always the same words.
                SettingsActionLabel(title: PairingWords.pairWithMac, systemImage: "plus")
            }
        } header: {
            Text("Macs")
        } footer: {
            if let footer = Self.footer(model.macPresence, pairedNames: model.link.macs.map(\.name)) { Text(footer) }
        }
    }

    /// What the library's sync says about its Mac, when the rows above don't already: a Mac that syncs
    /// but isn't paired here, or one to set up. Nil for a paired Mac (its row says it) and while checking.
    static func footer(_ presence: MacPresence, pairedNames: [String], now: Date = Date()) -> String? {
        switch presence {
        case .checking, .unavailable, .connected: return nil
        case .seen(let name, _), .recording(let name, _):
            return pairedNames.contains(name) ? nil : presence.summary(now: now)
        case .notProcessing, .olderMac, .noMac: return presence.summary(now: now)
        }
    }
}

/// A paired Mac in a list: its tile (teal while it's connected), its name, and what it's doing.
struct MacRow: View {
    let mac: PhoneLink.Mac
    /// Its presence in the library says it's recording, while the link has no word from it.
    var recordingBySync = false

    var body: some View {
        SettingsRow(title: mac.name, detail: mac.rowLine(recordingBySync: recordingBySync), systemImage: "desktopcomputer",
                    tone: mac.isConnected ? .active : mac.problem != nil ? .attention : .neutral,
                    detailNeedsAttention: mac.problem != nil)
    }
}

extension PhoneLink.Mac {
    /// The line under its name in a list (Settings › Macs, the status sheet): recording, else the link's state.
    func rowLine(recordingBySync: Bool) -> String {
        if let recording, isRecording {
            return recording.phase == .paused ? "Paused recording" : "Recording now"
        }
        if recordingBySync { return "Recording now" }
        return stateLine
    }
}

/// One paired Mac: the page both apps show for a paired Daybook (`PeerDevicePage`), as the Mac's page for this
/// iPhone does. Its header, what keeps it from connecting with its fix (Pair Again…, or Open Settings for Local
/// Network), what it's recording with Stop on it,
/// the recorders it manages, whether it can start recording here, its facts, and Unpair.
struct MacDetailScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsPages) private var pages
    @Environment(\.openURL) private var openURL
    let macID: UUID
    @State private var pairingAgain = false
    /// Why the last Stop on it didn't stop it.
    @State private var stopProblem: String?
    @State private var unpairFailed = false

    var body: some View {
        if let mac = model.link.macs.first(where: { $0.id == macID }) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                PeerDevicePage(PeerPage(facts(mac, now: context.date), here: PairingWords.here(.iPhone), now: context.date),
                               actions: actions(mac)) {
                    if let stopProblem {
                        Section { ProblemLine(text: stopProblem) }
                    }
                    SettingsScrollEndMarker()
                }
            }
            .settingsScrollEnd()
            .navigationTitle(mac.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The header names the Mac; the bar stays quiet (the back button still names it).
                ToolbarItem(placement: .principal) { Text("") }
            }
            .pairingSheet(isPresented: $pairingAgain, preselect: macID)
            .onChange(of: mac.recording?.conversationID) { _, _ in stopProblem = nil }
            .alert(PairingWords.couldntUnpair(mac.name), isPresented: $unpairFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(PairingWords.couldntUnpairMessage)
            }
        } else {
            ContentUnavailableView("Not Paired", systemImage: "desktopcomputer")
        }
    }

    /// What its page says, from the link, the library, and this iPhone's recorder.
    private func facts(_ mac: PhoneLink.Mac, now: Date) -> PeerPage.Facts {
        let recording = mac.isRecording ? mac.recording : nil
        let conversation = recording?.conversationID
        let activity: PeerFacts.Activity = recording?.phase == .paused ? .paused
            : recording != nil || model.isRecordingBySync(mac, now: now) ? .recording : .idle
        // Stop is taken when it stops for a page (and hasn't said this iPhone may not start recording there), or when
        // this iPhone records that conversation with it.
        let recordsTogether = conversation != nil && model.recorder.isActive && model.recorder.captureID == conversation
        return PeerPage.Facts(
            id: mac.id.uuidString, name: mac.name, kind: .mac, isConnected: mac.isConnected, activity: activity,
            lastSeen: mac.lastConnectedAt,
            recordingSince: recording?.startedAt.map { mac.clock?.localDate(fromPeer: $0) ?? $0 },
            conversationTitle: conversation.flatMap { model.library.controller.meeting($0)?.title },
            canStop: (mac.stopsForPages && mac.takesStartsFromHere != false) || recordsTogether,
            recorders: mac.recorders,
            // Whether it transcribes is known once it has connected.
            transcribes: mac.canProcess ? true : mac.isConnected ? false : nil,
            appVersion: mac.appVersion, pairedAt: mac.pairedAt, problem: mac.problem)
    }

    private func actions(_ mac: PhoneLink.Mac) -> PeerPageActions {
        PeerPageActions(
            stop: {
                Task { stopProblem = await model.link.stopRecording(on: mac.id) }
            },
            stopPending: model.link.stopsInFlight.contains(mac.id),
            pairAgain: { pairingAgain = true },
            // Local Network off: where to allow it.
            problemAction: mac.needsLocalNetwork ? (title: PairingWords.openSettings, perform: {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }) : nil,
            canStartRecording: mac.isDamaged ? nil : Binding(
                get: { model.settings.macMayStartRecording(mac.id, pairedAt: mac.pairedAt) },
                set: { model.settings.setMacMayStartRecording($0, for: mac.id, pairedAt: mac.pairedAt) }),
            unpair: {
                Task {
                    do {
                        try await model.link.unpair(macID)
                    } catch {
                        unpairFailed = true
                        return
                    }
                    model.settings.forgetMacRecordDecision(macID)
                    // On the open Duo's right page there's nothing to go back to.
                    if let pages { pages.leave() } else { dismiss() }
                }
            })
    }
}

extension View {
    /// Pair with Your Mac: a sheet in the hand. Open, a sheet would be a card across the crease (as
    /// the status panel avoids, docs/iphone.md), so pairing takes the display as two pages instead.
    /// - Parameter preselect: A paired Mac to pair again (Pair Again… on its page), chosen once it's found.
    func pairingSheet(isPresented: Binding<Bool>, preselect: UUID? = nil) -> some View {
        modifier(PairingPresentation(isPresented: isPresented, preselect: preselect))
    }
}

private struct PairingPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let preselect: UUID?
    @Environment(\.surfaceStyle) private var surface
    /// How it was shown, kept until it's dismissed, so a fold doesn't start pairing over.
    @State private var shownAsPages: Bool?

    func body(content: Content) -> some View {
        let asPages = shownAsPages ?? (surface != .pocket)
        content
            .sheet(isPresented: Binding(get: { isPresented && !asPages }, set: { if !$0 { isPresented = false } })) {
                PairingSheet(preselect: preselect)
            }
            .fullScreenCover(isPresented: Binding(get: { isPresented && asPages }, set: { if !$0 { isPresented = false } })) {
                PairingSheet(asPages: true, preselect: preselect)
            }
            .onChange(of: isPresented) { _, shown in shownAsPages = shown ? asPages : nil }
    }
}

/// iOS 27 tucks the navigation bar away as content scrolls down, which the code boxes do when the
/// keyboard comes up; Pair is in that bar.
private struct KeepsPairInReach: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.toolbarMinimizationBehavior(.never, for: .navigationBar)
        } else {
            content
        }
    }
}

/// Pair with a Mac: the shared pairing screen (`PairingView`) as the iPhone takes part. Choose the Mac, then type
/// the six digits it shows. The code proves you can see the Mac's screen; nothing else is needed (docs/link.md,
/// "Pairing"). No Mac is chosen for you (unless you came to pair one again), and the code boxes appear only once
/// one is, so a code always goes to the Mac that shows it.
///
/// Over the whole open iPhone Duo it's two pages: the Macs on the left, the code on the right, at the
/// top where the keyboard can't cover it.
struct PairingSheet: View {
    var asPages = false
    /// A paired Mac to pair again, chosen once it's on the list.
    var preselect: UUID?
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.surfaceStyle) private var surface
    @Environment(\.openURL) private var openURL
    @State private var selection: String?
    @State private var attempt = PairingAttempt()
    @State private var pairing = false
    @State private var paired: String?
    /// Looked for `PairingWords.noMacFoundAfter` without finding a Mac to offer.
    @State private var lookedAWhile = false
    @FocusState private var codeFocused: Bool
    private let tileColumn = SettingsTileWidth()

    var body: some View {
        NavigationStack {
            Group {
                // Folded shut while shown, it's one column again.
                if asPages, surface != .pocket {
                    pairingView(pages: { leading, trailing in
                        AnyView(CreaseSplit { page { leading } } trailing: { page { trailing } })
                    })
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            pairingView(pages: nil)
                                .padding(PhoneStyle.Space.s5)
                                .id(Self.column)
                                .frame(maxWidth: 520, alignment: .leading)
                                .frame(maxWidth: .infinity)
                        }
                        // The system shows only the field under the boxes; bring up all of them (they're
                        // at the foot of the column).
                        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                            guard codeFocused else { return }
                            withAnimation { proxy.scrollTo(Self.column, anchor: .bottom) }
                        }
                    }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .modifier(KeepsPairInReach())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(paired == nil ? "Cancel" : "Done") { dismiss() } }
                if paired == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Pair") { Task { await pair() } }
                            .disabled(!canPair)
                    }
                }
            }
            .task {
                await model.link.startBrowsing()
                // Screenshots: a chosen Mac with a code half typed.
                if model.options.openSettings == "pairing" {
                    selection = model.link.candidates.first?.id
                    try? await Task.sleep(for: .milliseconds(100))   // after choosing clears the code
                    attempt.code = "4829"; codeFocused = false
                }
            }
            .task {
                try? await Task.sleep(for: PairingWords.noMacFoundAfter)
                lookedAWhile = true
            }
            .onDisappear { Task { await model.link.stopBrowsing() } }
            .onAppear { choosePreselected(model.link.candidates) }
            .onChange(of: model.link.candidates) { _, candidates in
                // The chosen Mac left the network: choose again.
                if let selection, !candidates.contains(where: { $0.id == selection && !$0.usesAnotherLibrary }) { self.selection = nil }
                choosePreselected(candidates)
            }
            .onChange(of: selection) { _, chosen in
                // A code belongs to one Mac; choosing another starts over, ready to type.
                attempt = PairingAttempt()
                codeFocused = chosen != nil
            }
        }
    }

    private static let column = "column"

    private func pairingView(pages: ((AnyView, AnyView) -> AnyView)?) -> some View {
        PairingView(role: .entersCode, paired: paired, problem: attempt.problem, showsCode: selectedMac != nil || attempt.problem != nil,
                    pages: pages) {
            macList
        } code: {
            if let mac = selectedMac { codeEntry(for: mac) }
            if let problem = attempt.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(PhoneStyle.Ink.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One of the two pages: a column clear of the crease.
    private func page(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PhoneStyle.Space.s5, content: content)
                .padding(.vertical, PhoneStyle.Space.s5)
                .pageColumn()
        }
    }

    private var selectedMac: PhoneLink.PairingCandidate? {
        selection.flatMap { id in model.link.candidates.first { $0.id == id && !$0.usesAnotherLibrary } }
    }
    private var canPair: Bool { attempt.code.filter(\.isNumber).count == LinkProtocol.pairingCodeDigits && selectedMac != nil && !pairing }

    /// Pair Again… on a Mac's page chooses that Mac once it's found.
    private func choosePreselected(_ candidates: [PhoneLink.PairingCandidate]) {
        guard selection == nil, paired == nil, let preselect,
              let mac = candidates.first(where: { $0.pairedMacID == preselect }) else { return }
        selection = mac.id
    }

    private var macList: some View {
        VStack(alignment: .leading, spacing: 8) {
            PairingHeading(text: PairingWords.macsOnThisNetwork)
            let candidates = model.link.candidates
            if model.link.discovery == .localNetworkDenied {
                // Without Local Network, iOS shows Daybook no Mac at all: say so, with where to allow it.
                ProblemLine(text: PairingWords.allowLocalNetwork) {
                    Button(PairingWords.openSettings) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                .font(.subheadline)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    if candidates.isEmpty {
                        HStack(spacing: SettingsMetrics.gap) {
                            ProgressView().frame(width: tileColumn.value)
                            Text(PairingWords.lookingForMacs)
                                .font(.subheadline)
                                .foregroundStyle(PhoneStyle.Ink.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(candidates) { mac in
                        candidateRow(mac)
                        if mac.id != candidates.last?.id {
                            Divider().padding(.leading, 14 + tileColumn.value + SettingsMetrics.gap)
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if lookedAWhile, !candidates.contains(where: { !$0.usesAnotherLibrary }) {
                    Text(PairingWords.noMacFound)
                        .font(.footnote)
                        .foregroundStyle(PhoneStyle.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .daybookTransition(.opacity)
                }
            }
        }
    }

    /// A Mac on the network: chosen with a checkmark; one with another library open, dimmed and not offered.
    private func candidateRow(_ mac: PhoneLink.PairingCandidate) -> some View {
        Button { selection = mac.id } label: {
            HStack(spacing: SettingsMetrics.gap) {
                SettingsRow(title: mac.name, detail: mac.line, systemImage: "desktopcomputer")
                Spacer(minLength: 0)
                if selection == mac.id {
                    Image(systemName: "checkmark").foregroundStyle(PhoneStyle.accent).fontWeight(.semibold)
                        .accessibilityHidden(true)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(mac.usesAnotherLibrary)
        .opacity(mac.usesAnotherLibrary ? 0.45 : 1)
        .accessibilityAddTraits(selection == mac.id ? .isSelected : [])
    }

    private func codeEntry(for mac: PhoneLink.PairingCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PairingHeading(text: PairingWords.code(on: mac.name))
            PairingCodeEntry(code: $attempt.code, label: PairingWords.code(on: mac.name), focus: $codeFocused)
                .onChange(of: attempt.code) { _, typed in attempt.codeChanged(to: typed) }
            if pairing {
                HStack(spacing: 8) { ProgressView(); Text(PairingWords.pairing).foregroundStyle(PhoneStyle.Ink.secondary) }
            }
        }
    }

    private func pair() async {
        guard let mac = selectedMac else { return }
        pairing = true
        defer { pairing = false }
        do {
            let device = try await model.link.pair(with: mac.endpoint, code: attempt.code.filter(\.isNumber))
            paired = device.name
            attempt.code = ""
            codeFocused = false
        } catch {
            attempt.failed(PhoneLink.message(for: error))
        }
    }
}

/// The code being typed on the pairing screen, and why the last one didn't pair. A code that fails empties the
/// boxes for the next and keeps its reason on screen until the person types again.
struct PairingAttempt: Equatable {
    var code = ""
    /// Why the last code didn't pair ("That code didn’t match. Your Mac now shows a new code.").
    var problem: String?

    /// The code didn't pair: the boxes empty, and the reason stays.
    mutating func failed(_ reason: String) {
        problem = reason
        code = ""
    }

    /// The boxes changed: typing puts the last reason away, and emptying them (as a failed code does) keeps it.
    mutating func codeChanged(to typed: String) {
        if !typed.isEmpty { problem = nil }
    }
}

/// A heading over pairing's groups, as Settings' section headings read: a generic label, never filler, in the
/// iPhone's title case.
private struct PairingHeading: View {
    let text: String
    var body: some View {
        Text(SettingsWords.titleCased(text))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(PhoneStyle.Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}
