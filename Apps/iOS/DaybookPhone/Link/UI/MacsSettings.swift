import DaybookLink
import SwiftUI

/// Settings › Macs: paired Macs and how each is doing, and Pair with a Mac.
struct MacsSection: View {
    @Environment(PhoneAppModel.self) private var model
    @Binding var showingPairing: Bool

    var body: some View {
        Section {
            ForEach(model.link.macs) { mac in
                NavigationLink(value: SettingsRoute.mac(mac.id)) { MacRow(mac: mac, recordingBySync: model.isRecordingBySync(mac)) }
            }
            Button {
                showingPairing = true
            } label: {
                // The Mac's instructions name this item, so it's always the same words.
                Label("Pair with Your Mac…", systemImage: "plus.circle")
            }
        } header: {
            Text("Macs")
        }
    }
}

struct MacRow: View {
    let mac: PhoneLink.Mac
    /// Its presence in the library says it's recording, while the link has no word from it.
    var recordingBySync = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 18))
                    .foregroundStyle(mac.isConnected ? PhoneStyle.accent : .secondary)
                    .frame(width: 30, height: 30)
                Circle()
                    .fill(mac.isConnected ? PhoneStyle.accent : Color(uiColor: .tertiaryLabel))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name)
                Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var line: String {
        if let recording = mac.recording, mac.isRecording {
            return recording.phase == .paused ? "Paused recording" : "Recording now"
        }
        if recordingBySync { return "Recording now" }
        return mac.stateLine
    }
}

/// One paired Mac: its connection, clock, and Unpair.
struct MacDetailScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let macID: UUID
    @State private var confirmingUnpair = false

    var body: some View {
        if let mac = model.link.macs.first(where: { $0.id == macID }) {
            Form {
                Section {
                    MacRow(mac: mac, recordingBySync: model.isRecordingBySync(mac))
                }
                Section("This Mac") {
                    Toggle("Can Start Recording", isOn: Binding(
                        get: { model.settings.macMayStartRecording(mac.id, pairedAt: mac.pairedAt) },
                        set: { model.settings.setMacMayStartRecording($0, for: mac.id, pairedAt: mac.pairedAt) }))
                    LabeledContent("Transcribes", value: mac.canProcess ? "Yes" : mac.isConnected ? "Not set up" : "Unknown until connected")
                    if let version = mac.appVersion { LabeledContent("Daybook", value: version) }
                    LabeledContent("Paired", value: mac.pairedAt.formatted(date: .abbreviated, time: .omitted))
                    if let clock = mac.clock {
                        LabeledContent("Clock", value: clockLine(clock))
                    }
                }
                Section {
                    Button("Unpair \(mac.name)…", role: .destructive) { confirmingUnpair = true }
                }
            }
            .navigationTitle(mac.name)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Unpair \(mac.name)?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    Task {
                        await model.link.unpair(macID)
                        model.settings.forgetMacRecordDecision(macID)
                        dismiss()
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
    /// The Mac just paired, until the person says whether it may start recording here.
    @State private var asking: LinkPairedDevice?
    @State private var showingQuestion = false
    @FocusState private var codeFocused: Bool

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
            .alert("Let \(asking?.name ?? "this Mac") start recording on this iPhone?", isPresented: $showingQuestion,
                   presenting: asking) { device in
                Button("Not Now", role: .cancel) { decide(false, for: device) }
                Button("Allow") { decide(true, for: device) }
            }
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
                .foregroundStyle(PhoneStyle.accent)
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
            Text("Macs on This Wi‑Fi")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PhoneStyle.Ink.meta)
                .textCase(.uppercase)
            VStack(spacing: 0) {
                let candidates = model.link.candidates
                if candidates.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for Macs… Both need to be on the same Wi‑Fi.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(candidates) { mac in
                    Button { selection = mac.id } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer").foregroundStyle(PhoneStyle.accent).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mac.name).foregroundStyle(.primary)
                                Text(mac.isPaired ? "Paired" : mac.isPairing ? "Showing a code" : "Not showing a code")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selection == mac.id { Image(systemName: "checkmark").foregroundStyle(PhoneStyle.accent).fontWeight(.semibold) }
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == mac.id ? .isSelected : [])
                    if mac.id != candidates.last?.id { Divider().padding(.leading, 52) }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func codeEntry(for mac: PhoneLink.PairingCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Code on \(mac.name)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PhoneStyle.Ink.meta)
                .textCase(.uppercase)
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
                HStack(spacing: 8) { ProgressView(); Text("Pairing…").foregroundStyle(.secondary) }
            }
        }
    }

    private func decide(_ allowed: Bool, for device: LinkPairedDevice) {
        model.settings.setMacMayStartRecording(allowed, for: device.deviceID, pairedAt: device.pairedAt)
        asking = nil
    }

    private func pair() async {
        guard let mac = selectedMac else { return }
        pairing = true
        defer { pairing = false }
        do {
            let device = try await model.link.pair(with: mac.endpoint, code: digits)
            paired = device.name
            code = ""
            // Asked once per pairing; until then the Mac can't start recording here.
            if !model.settings.hasMacRecordDecision(device.deviceID, pairedAt: device.pairedAt) {
                asking = device
                showingQuestion = true
            }
        } catch {
            self.error = PhoneLink.message(for: error)
            code = ""
        }
    }
}
