import DaybookKit
import DaybookUI
import SwiftUI

/// Where a Settings row leads.
enum SettingsRoute: Hashable {
    case icloud
    /// Add Recorder on the open Duo's right page (in the hand it's a sheet).
    case addRecorder
    case libraryDevices
    case mac(UUID)
    case device(String)
    case recording
    case storage
    case models
    case cloud
    case cloudKey(String)
    case templates
    case template(String)
    case vocabulary
    case speakerProfiles
    case speakerProfile(UUID)
    case about
    case acknowledgements
}

/// Settings: iCloud, your Macs, recorders, recording, storage, models, cloud summaries, templates, vocabulary,
/// and speaker profiles, and About.
/// `LibraryBrowser` presents it (`settingsSheet`). In the hand it's one column of pushed screens; on
/// the open iPhone Duo, two pages: the list on the left, the chosen screen on the right.
struct SettingsScreen: View {
    /// Shown over the whole open display (`settingsSheet`), rather than as a sheet.
    var asPages = false
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.surfaceStyle) private var surface
    @State private var path: [SettingsRoute] = []
    @State private var showingPairing = false
    @State private var showingAddDevice = false

    var body: some View {
        Group {
            if surface == .pocket {
                // In the hand, or folded shut while shown.
                column
            } else if asPages {
                DisplayPages { leftPage } trailing: { rightPage }
            } else {
                // Shown as a sheet in the hand, then opened: two pages inside the sheet, split at the crease.
                SheetCreaseSplit { leftPage } trailing: { rightPage } single: { column }
            }
        }
        .presentationSizing(SheetPagesSizing(asPages: surface != .pocket))
        .environment(\.closeSettings) { dismiss() }
        .pairingSheet(isPresented: $showingPairing)
        .addRecorderSheet(isPresented: $showingAddDevice) { id in
            if let id { path = [.device(id)] }
        }
        .task { await openRequestedScreen() }
    }

    /// In the hand: the list, and each screen pushed over it.
    private var column: some View {
        NavigationStack(path: $path) {
            list
                .navigationDestination(for: SettingsRoute.self) { SettingsDestination(route: $0) }
        }
        .environment(\.settingsPush, SettingsPush { path.append($0) })
    }

    /// The screen on the right page, iCloud until another is chosen.
    private var selected: SettingsRoute { path.first ?? .icloud }

    private var pages: SettingsPages {
        SettingsPages(selection: selected, open: { path = [$0] }, leave: { path = [] })
    }

    /// Open: the list, its rows showing their screens on the right page.
    private var leftPage: some View {
        NavigationStack { list }
            .environment(\.settingsPages, pages)
    }

    /// Open: the chosen screen, where the screens it opens push in turn.
    private var rightPage: some View {
        let selected = selected
        return NavigationStack(path: Binding(get: { Array(path.dropFirst()) }, set: { path = [selected] + $0 })) {
            SettingsDestination(route: selected)
                .navigationDestination(for: SettingsRoute.self) { SettingsDestination(route: $0) }
        }
        .environment(\.settingsPages, pages)
        // Pushed over the chosen screen, on the right page.
        .environment(\.settingsPush, SettingsPush { path.append($0) })
        .id(selected)
    }

    private var list: some View {
        Form {
            Section {
                SettingsLink(route: .icloud) { ICloudRow() }
            }
            MacsSection(showingPairing: $showingPairing)
            RecordersSection(showingAddDevice: $showingAddDevice)
            Section {
                SettingsLink(route: .recording) {
                    SettingsRow(title: "Recording", detail: recordingSummary, systemImage: "waveform")
                }
                SettingsLink(route: .storage) {
                    SettingsRow(title: "Storage", detail: storageSummary, systemImage: "internaldrive")
                }
                SettingsLink(route: .models) {
                    SettingsRow(title: "Models", detail: modelsSummary, systemImage: "cpu")
                }
                SettingsLink(route: .cloud) {
                    SettingsRow(title: "Cloud", detail: model.cloudSummaries.summary, systemImage: "cloud")
                }
            }
            Section {
                SettingsLink(route: .templates) {
                    SettingsRow(title: TemplateWords.title, detail: templatesSummary, systemImage: "doc.text")
                }
                SettingsLink(route: .vocabulary) {
                    SettingsRow(title: VocabularyWords.title, detail: vocabularySummary, systemImage: "character.book.closed")
                }
                SettingsLink(route: .speakerProfiles) {
                    SettingsRow(title: "Speaker Profiles", detail: SpeakerProfilesScreen.summary(model.library.controller.speakerProfiles.count),
                                systemImage: "person.wave.2")
                }
            } header: {
                Text("Library")
            }
            Section {
                SettingsLink(route: .about) {
                    SettingsRow(title: "About Daybook", detail: nil, systemImage: "info.circle")
                }
            }
            SettingsScrollEndMarker()
        }
        .settingsScrollEnd()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { dismiss() }.tint(PhoneStyle.Ink.title) } }
    }

    private var recordingSummary: String {
        model.settings.requestsTranscription ? "Transcribes automatically" : "Transcribes when you ask"
    }

    private var storageSummary: String { StatusSheetModel.audioOnThisIPhone(bytes: model.audio.usage.bytes) }

    private var modelsSummary: String {
        Self.modelsDetail(model.models, processesHere: model.settings.processesOnThisIPhone,
                          transcribes: model.processingCapabilities.transcribes)
    }

    /// The Models row's words. While this iPhone transcribes its own recordings and the processing models asked for are
    /// coming, how that whole set stands, the page's figure ("Downloading · 40%", "Waiting for Wi‑Fi", "Couldn’t
    /// download"); else what's still to download (`missingModelBytes`); else what it does.
    static func modelsDetail(_ models: PhoneModels, processesHere: Bool, transcribes: Bool) -> String {
        if processesHere, let state = models.processingDownloadState {
            switch state {
            case .downloading: return ModelStatus.downloading(state.fraction ?? 0).label
            case .waitingForWiFi: return ModelStatus.waitingForWiFi.label
            case .failed: return ProcessingWords.downloadStopped
            }
        }
        let missing = missingModelBytes(models, processesHere: processesHere)
        if missing > 0 { return "\(ByteSize.format(missing)) to download" }
        return transcribes ? "Transcribes on this iPhone" : "Live transcription on this iPhone"
    }

    /// What the row's figure counts (uxf-18): while this iPhone transcribes its own recordings, only what transcribing
    /// still needs, the figure Welcome offered ("Transcription and speakers · 852 MB"); the summary model and live
    /// captions' models are listed inside Models with their own sizes. Otherwise, live transcription's, the only models
    /// it uses.
    static func missingModelBytes(_ models: PhoneModels, processesHere: Bool) -> Int64 {
        processesHere ? models.processingMissingBytes : models.missingBytes
    }

    /// "12 built-in, 2 yours", as the Mac counts them.
    private var templatesSummary: String { SettingsWords.templates(model.library.controller.templates) }

    /// Every term, wherever it's used, as the Mac counts them.
    private var vocabularySummary: String { SettingsWords.vocabulary(model.library.controller.glossary) }

    /// `--open-settings <screen>` (debug), for screenshots.
    private func openRequestedScreen() async {
        guard let screen = model.options.openSettings else { return }
        if screen.hasPrefix("device") {
            // A recorder the device autopilot is still adding: wait for it to connect and import.
            for _ in 0..<150 where model.devices.sessions.first?.links.recent.isEmpty != false {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if screen == "add-device" || screen == "add-recorder" || screen == "pairing" {
            // A sheet over Settings: only once Settings has finished coming up, or it never shows.
            try? await Task.sleep(for: .milliseconds(800))
        }
        switch screen {
        case "icloud": path = [.icloud]
        case "macs": if let mac = model.link.macs.first { path = [.mac(mac.id)] }
        case "pairing": showingPairing = true
        case "devices", "device", "device-details", "device-live", "device-recordings":
            if let session = model.devices.sessions.first { path = [.device(session.id)] }
        case "add-device", "add-recorder": if surface == .pocket { showingAddDevice = true } else { path = [.addRecorder] }
        case "storage": path = [.storage]
        case "models": path = [.models]
        case "cloud": path = [.cloud]
        case "cloud-key": path = [.cloud, .cloudKey(CloudProvider.anthropic.rawValue)]
        case "templates": path = [.templates]
        case "template": path = [.templates, .template("general")]
        case "vocabulary", "add-term": path = [.vocabulary]
        case "speaker-profiles": path = [.speakerProfiles]
        case "recording": path = [.recording]
        case "library-devices": path = [.icloud, .libraryDevices]
        case "about": path = [.about]
        case "acknowledgements": path = [.about, .acknowledgements]
        default:
            if screen.hasPrefix("speaker-profile:"),
               let profile = model.library.controller.speakerProfiles.first(where: { $0.name == screen.dropFirst("speaker-profile:".count) }) {
                path = [.speakerProfiles, .speakerProfile(profile.id)]
            }
        }
    }
}

extension View {
    /// Settings: a sheet in the hand. Open, a sheet would be a card across the crease (as the status
    /// panel and pairing avoid, docs/iphone.md), so Settings takes the display as two pages instead.
    /// Folded shut while shown, the pages become one column; opened while it's a sheet, the sheet
    /// becomes two pages.
    func settingsSheet(isPresented: Binding<Bool>) -> some View {
        pagesPresentation(isPresented: isPresented) { SettingsScreen(asPages: $0) }
    }
}

/// The screen a route opens.
struct SettingsDestination: View {
    let route: SettingsRoute

    var body: some View {
        switch route {
        case .icloud: ICloudScreen()
        case .addRecorder: AddRecorderPage()
        case .libraryDevices: LibraryDevicesScreen()
        case .mac(let id): MacDetailScreen(macID: id)
        case .device(let id): DevicePage(sessionID: id)
        case .recording: RecordingSettingsScreen()
        case .storage: StorageScreen()
        case .models: ModelsSettingsScreen()
        case .cloud: CloudSettingsScreen()
        case .cloudKey(let provider): CloudKeyScreen(provider: CloudProvider(rawValue: provider) ?? .anthropic)
        case .templates: TemplatesPage()
        case .template(let id): TemplateEditorPage(templateID: id)
        case .vocabulary: VocabularyPage()
        case .speakerProfiles: SpeakerProfilesScreen()
        case .speakerProfile(let id): SpeakerProfileScreen(profileID: id)
        case .about: AboutPage()
        case .acknowledgements: AcknowledgementsPage()
        }
    }
}

/// Settings as two pages on the open iPhone Duo: the screen on the right page, and how to change it.
struct SettingsPages {
    var selection: SettingsRoute
    /// Shows a screen on the right page.
    var open: (SettingsRoute) -> Void
    /// The right page's screen went away (a recorder removed, a Mac unpaired): back to the first.
    var leave: () -> Void
}

extension EnvironmentValues {
    /// Set while Settings is two pages; nil in the hand, and wherever else its screens appear.
    @Entry var settingsPages: SettingsPages? = nil
    /// Pushes a screen over the one it's read in.
    @Entry var settingsPush = SettingsPush { _ in }
}

/// Pushes a screen over the one it's read in: onto the column in the hand, onto the right page open (a new
/// template's editor, a copy's).
struct SettingsPush {
    var push: (SettingsRoute) -> Void
    func callAsFunction(_ route: SettingsRoute) { push(route) }
}

/// A row that opens a Settings screen: pushed in the hand; open, shown on the right page, with the
/// row marked as chosen.
struct SettingsLink<Label: View>: View {
    let route: SettingsRoute
    @ViewBuilder var label: Label
    @Environment(\.settingsPages) private var pages

    var body: some View {
        if let pages {
            let chosen = pages.selection == route
            Button { pages.open(route) } label: {
                label.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .listRowBackground(chosen ? PhoneStyle.accent.opacity(0.14) : Color(uiColor: .secondarySystemGroupedBackground))
            .accessibilityAddTraits(chosen ? .isSelected : [])
        } else {
            NavigationLink(value: route) { label }
        }
    }
}

// MARK: Rows

// The rows every Settings screen uses (SettingsTile, SettingsRow, SettingsActionLabel, DevicePageHeader) are
// DaybookUI's, shared with the Mac, by their own names.

extension View {
    /// `--scroll-end` (debug): the screen scrolled to its foot (`SettingsScrollEndMarker`), for screenshots.
    func settingsScrollEnd() -> some View { modifier(SettingsScrollEnd()) }
}

/// The foot of a Settings list that `--scroll-end` scrolls to (debug); nothing otherwise.
struct SettingsScrollEndMarker: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        if model.options.scrollEnd {
            Color.clear.frame(height: 1).listRowBackground(Color.clear).id(SettingsScrollEnd.anchor)
        }
    }
}

private struct SettingsScrollEnd: ViewModifier {
    static let anchor = "settings-scroll-end"
    @Environment(PhoneAppModel.self) private var model

    func body(content: Content) -> some View {
        if model.options.scrollEnd {
            ScrollViewReader { proxy in
                content.task {
                    try? await Task.sleep(for: .milliseconds(1500))
                    proxy.scrollTo(Self.anchor, anchor: .bottom)
                }
            }
        } else {
            content
        }
    }
}

// MARK: Recording

struct RecordingSettingsScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// Use Calendar was turned on and iOS said no.
    @State private var calendarRefused = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Transcribe Automatically", isOn: $settings.requestsTranscription)
                Toggle("Recording with Your Mac", isOn: $settings.acceptsMacRecordRequests)
            }
            CaptionSettingsSection()
            Section {
                Toggle("Lock Screen and Dynamic Island", isOn: $settings.showsLiveActivity)
            }
            Section {
                Toggle("Use Calendar", isOn: Binding(get: { settings.usesCalendar }, set: { on in
                    Task {
                        await model.setUsesCalendar(on)
                        calendarRefused = on && !settings.usesCalendar
                    }
                }))
                // Refused just now, or taken away in Settings since.
                if calendarRefused || (settings.usesCalendar && model.environment.calendar.access == .denied) {
                    Button("Allow Calendars in Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
            Section {
                LabeledContent("Format", value: "AAC, 48 kHz mono")
                LabeledContent("Size", value: "About 29 MB an hour")
            } header: {
                Text("Quality")
            }
            SettingsScrollEndMarker()
        }
        .settingsScrollEnd()
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
    }
}
