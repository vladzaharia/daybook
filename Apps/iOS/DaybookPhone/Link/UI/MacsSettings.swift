import DaybookLink
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
                SettingsActionLabel(title: "Pair with Your Mac…", systemImage: "plus")
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
                    tone: mac.isConnected ? .active : .neutral)
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

/// One paired Mac: the same header as a recorder's page, then what it may do here, its facts, and
/// Unpair.
struct MacDetailScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsPages) private var pages
    let macID: UUID
    @State private var confirmingUnpair = false

    var body: some View {
        if let mac = model.link.macs.first(where: { $0.id == macID }) {
            Form {
                Section {
                    DevicePageHeader(systemImage: "desktopcomputer", isActive: mac.isConnected, title: mac.name,
                                     status: mac.rowLine(recordingBySync: model.isRecordingBySync(mac)))
                        .devicePageHeaderRow()
                }
                Section {
                    Toggle("Can Start Recording", isOn: Binding(
                        get: { model.settings.macMayStartRecording(mac.id, pairedAt: mac.pairedAt) },
                        set: { model.settings.setMacMayStartRecording($0, for: mac.id, pairedAt: mac.pairedAt) }))
                }
                Section {
                    // Whether it transcribes is known once it has connected.
                    if mac.canProcess {
                        LabeledContent("Transcribes", value: "Yes")
                    } else if mac.isConnected {
                        LabeledContent("Transcribes", value: "Not set up")
                    }
                    if let version = mac.appVersion { LabeledContent("Daybook", value: version) }
                    LabeledContent("Paired", value: mac.pairedAt.formatted(date: .abbreviated, time: .omitted))
                    if let clock = mac.clock {
                        LabeledContent("Clock", value: clockLine(clock))
                    }
                }
                Section {
                    Button("Unpair This Mac…", role: .destructive) { confirmingUnpair = true }
                }
            }
            .settingsScrollEnd()
            .navigationTitle(mac.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The header names the Mac; the bar stays quiet (the back button still names it).
                ToolbarItem(placement: .principal) { Text("") }
            }
            .confirmationDialog("Unpair \(mac.name)?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    Task {
                        await model.link.unpair(macID)
                        model.settings.forgetMacRecordDecision(macID)
                        // On the open Duo's right page there's nothing to go back to.
                        if let pages { pages.leave() } else { dismiss() }
                    }
                }
            } message: {
                Text("Recording together and live progress stop until you pair again.")
            }
        } else {
            ContentUnavailableView("Not Paired", systemImage: "desktopcomputer")
        }
    }

    /// "In step (±4 ms)" or "12 ms ahead (±4 ms)": how the recordings will line up.
    private func clockLine(_ clock: LinkClockEstimate) -> String {
        let offset = Int((clock.offset * 1000).rounded()), uncertainty = max(1, Int((clock.uncertainty * 1000).rounded()))
        if abs(offset) <= uncertainty { return "In step (±\(uncertainty) ms)" }
        return "\(abs(offset)) ms \(offset > 0 ? "ahead" : "behind") (±\(uncertainty) ms)"
    }
}

extension View {
    /// Pair with Your Mac: a sheet in the hand. Open, a sheet would be a card across the crease (as
    /// the status panel avoids, docs/iphone.md), so pairing takes the display as two pages instead.
    func pairingSheet(isPresented: Binding<Bool>) -> some View {
        modifier(PairingPresentation(isPresented: isPresented))
    }
}

private struct PairingPresentation: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.surfaceStyle) private var surface
    /// How it was shown, kept until it's dismissed, so a fold doesn't start pairing over.
    @State private var shownAsPages: Bool?

    func body(content: Content) -> some View {
        let asPages = shownAsPages ?? (surface != .pocket)
        content
            .sheet(isPresented: Binding(get: { isPresented && !asPages }, set: { if !$0 { isPresented = false } })) {
                PairingSheet()
            }
            .fullScreenCover(isPresented: Binding(get: { isPresented && asPages }, set: { if !$0 { isPresented = false } })) {
                PairingSheet(asPages: true)
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

/// Pair with a Mac: choose it, then type the six digits it shows. The code proves you can see the Mac's
/// screen; nothing else is needed (docs/link.md, "Pairing"). No Mac is chosen for you, and the code
/// boxes appear only once one is, so a code always goes to the Mac that shows it.
///
/// Over the whole open iPhone Duo it's two pages: the Macs on the left, the code on the right, at the
/// top where the keyboard can't cover it.
struct PairingSheet: View {
    var asPages = false
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.surfaceStyle) private var surface
    @State private var selection: String?
    @State private var code = ""
    @State private var pairing = false
    @State private var error: String?
    @State private var paired: String?
    @FocusState private var codeFocused: Bool
    private let tileColumn = SettingsTileWidth()

    var body: some View {
        NavigationStack {
            Group {
                // Folded shut while shown, it's one column again.
                if asPages, surface != .pocket {
                    CreaseSplit {
                        page {
                            heading(showsMark: false)
                            if paired == nil { macList }
                        }
                    } trailing: {
                        if paired != nil || selectedMac != nil || error != nil {
                            page { outcome }
                        } else {
                            // Until a Mac is chosen the left page says what to do, so this one shows only the mark.
                            mark.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: PhoneStyle.Space.s5) {
                                heading(showsMark: true)
                                if paired == nil { macList }
                                outcome
                            }
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
                    code = "482 9"; codeFocused = false
                }
            }
            .onDisappear { Task { await model.link.stopBrowsing() } }
            .onChange(of: model.link.candidates) { _, candidates in
                // The chosen Mac left the network: choose again.
                if let selection, !candidates.contains(where: { $0.id == selection }) { self.selection = nil }
            }
            .onChange(of: selection) { _, chosen in
                // A code belongs to one Mac; choosing another starts over, ready to type.
                code = ""
                error = nil
                codeFocused = chosen != nil
            }
        }
    }

    private static let column = "column"

    /// One of the two pages: a column clear of the crease.
    private func page(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PhoneStyle.Space.s5, content: content)
                .padding(.vertical, PhoneStyle.Space.s5)
                .pageColumn()
        }
    }

    private var mark: some View {
        Image(systemName: "macbook.and.iphone")
            .font(.system(size: 40, weight: .light))
            .foregroundStyle(PhoneStyle.accent)
            .accessibilityHidden(true)
    }

    private func heading(showsMark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsMark { mark }
            Text("Pair with Your Mac")
                .font(PhoneStyle.Typeface.title(.title))
                .foregroundStyle(PhoneStyle.Ink.title)
            Text("On your Mac, open Daybook › Settings › Devices and add your iPhone.")
                .font(.callout)
                .foregroundStyle(PhoneStyle.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Paired; or the code for the chosen Mac, and what went wrong.
    @ViewBuilder private var outcome: some View {
        if let paired {
            Label("Paired with \(paired)", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(PhoneStyle.Ink.link)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            if let mac = selectedMac {
                codeEntry(for: mac)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(PhoneStyle.Ink.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var digits: String { code.filter(\.isNumber) }
    private var selectedMac: PhoneLink.PairingCandidate? { selection.flatMap { id in model.link.candidates.first { $0.id == id } } }
    private var canPair: Bool { digits.count == 6 && selectedMac != nil && !pairing }

    private var macList: some View {
        VStack(alignment: .leading, spacing: 8) {
            PairingHeading(text: "Macs on This Wi‑Fi")
            VStack(spacing: 0) {
                let candidates = model.link.candidates
                if candidates.isEmpty {
                    HStack(spacing: SettingsMetrics.gap) {
                        ProgressView().frame(width: tileColumn.value)
                        Text("Looking for Macs…")
                            .font(.subheadline)
                            .foregroundStyle(PhoneStyle.Ink.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(candidates) { mac in
                    Button { selection = mac.id } label: {
                        HStack(spacing: SettingsMetrics.gap) {
                            SettingsRow(title: mac.name, detail: mac.isPaired ? "Paired" : mac.isPairing ? "Showing a code" : "Not showing a code",
                                        systemImage: "desktopcomputer")
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
                    .accessibilityAddTraits(selection == mac.id ? .isSelected : [])
                    if mac.id != candidates.last?.id {
                        Divider().padding(.leading, 14 + tileColumn.value + SettingsMetrics.gap)
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func codeEntry(for mac: PhoneLink.PairingCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PairingHeading(text: "Code on \(mac.name)")
            ZStack {
                // The real field, nearly invisible under the boxes: VoiceOver and the keyboard use it.
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($codeFocused)
                    .opacity(0.02)
                    .accessibilityLabel("Code on \(mac.name)")
                    .accessibilityValue(digits.isEmpty ? "Empty" : digits.map(String.init).joined(separator: " "))
                    .onChange(of: code) { _, value in
                        let filtered = String(value.filter(\.isNumber).prefix(6))
                        if filtered != value { code = filtered }
                        error = nil
                    }
                HStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) { index in
                        let characters = Array(digits)
                        Text(index < characters.count ? String(characters[index]) : "")
                            .font(.system(size: 30, weight: .medium).monospacedDigit())
                            .foregroundStyle(PhoneStyle.Ink.title)
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(index == characters.count && codeFocused ? PhoneStyle.accent : Color.clear, lineWidth: 2))
                        if index == 2 { Text("–").foregroundStyle(.tertiary) }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture { codeFocused = true }
            if pairing {
                HStack(spacing: 8) { ProgressView(); Text("Pairing…").foregroundStyle(PhoneStyle.Ink.secondary) }
            }
        }
    }

    private func pair() async {
        guard let mac = selectedMac else { return }
        pairing = true
        defer { pairing = false }
        do {
            let device = try await model.link.pair(with: mac.endpoint, code: digits)
            paired = device.name
            code = ""
        } catch {
            self.error = PhoneLink.message(for: error)
            code = ""
        }
    }
}

/// A heading over pairing's groups, as the status sheet's: a generic label, never filler.
private struct PairingHeading: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(PhoneStyle.Ink.secondary)
            .textCase(.uppercase)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}
