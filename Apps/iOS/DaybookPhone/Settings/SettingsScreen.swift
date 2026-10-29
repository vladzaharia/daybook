import DaybookCaptions
import DaybookKit
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
    case templates
    case template(String)
    case vocabulary
    case about
    case acknowledgements
}

/// Settings: iCloud, your Macs, recorders, recording, storage, templates and vocabulary, and About.
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
            }
            Section {
                SettingsLink(route: .templates) {
                    SettingsRow(title: "Summary Templates", detail: templatesSummary, systemImage: "doc.text")
                }
                SettingsLink(route: .vocabulary) {
                    SettingsRow(title: "Vocabulary", detail: vocabularySummary, systemImage: "character.book.closed")
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
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private var recordingSummary: String {
        model.settings.requestsTranscription ? "Transcribes automatically" : "Transcribes when you ask"
    }

    private var storageSummary: String {
        let used = model.audio.usage.bytes
        return used == 0 ? "No audio on this iPhone" : "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: used), countStyle: .file)) of audio"
    }

    private var templatesSummary: String {
        let count = model.library.controller.templates.count
        return count == 1 ? "1 template" : "\(count) templates"
    }

    private var vocabularySummary: String {
        let count = model.library.controller.glossary.filter(\.approved).count
        return count == 0 ? "No terms" : count == 1 ? "1 term" : "\(count) terms"
    }

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
        case "devices", "device", "device-details": if let session = model.devices.sessions.first { path = [.device(session.id)] }
        case "add-device", "add-recorder": if surface == .pocket { showingAddDevice = true } else { path = [.addRecorder] }
        case "storage": path = [.storage]
        case "templates": path = [.templates]
        case "template": path = [.templates, .template("general")]
        case "vocabulary": path = [.vocabulary]
        case "recording": path = [.recording]
        case "library-devices": path = [.icloud, .libraryDevices]
        case "about": path = [.about]
        case "acknowledgements": path = [.about, .acknowledgements]
        default: break
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
        case .templates: TemplatesScreen()
        case .template(let id): TemplateEditor(templateID: id)
        case .vocabulary: VocabularyScreen()
        case .about: AboutScreen()
        case .acknowledgements: AcknowledgementsScreen()
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

/// The measurements every Settings row shares, so titles line up whatever the symbol.
enum SettingsMetrics {
    /// The symbol tile at the default text size; it grows with Dynamic Type, up to `tileLimit`.
    static let tile: CGFloat = 30
    static let tileLimit: CGFloat = 42
    /// Between the tile column and the text.
    static let gap: CGFloat = 12
    /// Between a page and the open Duo's crease. Lists inset their cards a further 16–20 pt, so
    /// cards end about `PhoneStyle.Page.creaseClearance` from the fold.
    static let creaseGap: CGFloat = 8
}

/// The tile column's width at the person's text size.
struct SettingsTileWidth: DynamicProperty {
    @ScaledMetric(relativeTo: .body) private var scaled = SettingsMetrics.tile
    var value: CGFloat { min(scaled, SettingsMetrics.tileLimit) }
}

/// A row's symbol on a neutral tile, like the status sheet's: teal only while the device it stands
/// for is connected, orange while something needs you.
struct SettingsTile: View {
    enum Tone { case neutral, active, attention }

    let systemImage: String
    var tone: Tone = .neutral
    /// A larger tile (a device page's header); nil for the row column.
    var size: CGFloat?
    private let column = SettingsTileWidth()
    @ScaledMetric(relativeTo: .title) private var scale: CGFloat = 1

    var body: some View {
        let side = size.map { min($0 * scale, $0 * 1.35) } ?? column.value
        Image(systemName: systemImage)
            .font(.system(size: side * 0.5, weight: .medium))
            .foregroundStyle(ink)
            .frame(width: side, height: side)
            .background(fill.opacity(0.12), in: RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }

    private var ink: Color {
        switch tone {
        case .neutral: return PhoneStyle.Ink.secondary
        case .active: return PhoneStyle.accent
        case .attention: return PhoneStyle.Ink.warning
        }
    }

    private var fill: Color {
        switch tone {
        case .neutral: return .gray
        case .active: return PhoneStyle.accent
        case .attention: return PhoneStyle.Ink.warning
        }
    }
}

/// A Settings row: its symbol on a tile, the title, and one line of what it's set to or doing.
/// Explicit inks, so a row inside a button keeps them.
struct SettingsRow: View {
    let title: String
    let detail: String?
    let systemImage: String
    var tone: SettingsTile.Tone = .neutral
    /// The detail in orange: it needs you.
    var detailNeedsAttention = false

    var body: some View {
        HStack(spacing: SettingsMetrics.gap) {
            SettingsTile(systemImage: systemImage, tone: tone)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.wrappingAsName)
                    .foregroundStyle(PhoneStyle.Ink.title)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail.keepingSeparators)
                        .font(.footnote)
                        .foregroundStyle(detailNeedsAttention ? PhoneStyle.Ink.warning : PhoneStyle.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }
}

/// An action in a list of rows ("Pair with Your Mac…", "Sync Now"): its symbol in the tile column,
/// then its title, both in the link's ink, so it lines up with the rows around it.
struct SettingsActionLabel: View {
    let title: String
    let systemImage: String
    private let column = SettingsTileWidth()

    var body: some View {
        HStack(spacing: SettingsMetrics.gap) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: column.value)
                .accessibilityHidden(true)
            Text(title).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(PhoneStyle.Ink.link)
        .accessibilityElement(children: .combine)
    }
}

/// The top of a device's page (a recorder, a Mac): its tile, its name in New York, and its status.
/// The bar stays quiet, so the name is shown once.
struct DevicePageHeader: View {
    let systemImage: String
    let isActive: Bool
    let title: String
    let status: String
    var statusNeedsAttention = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At the accessibility sizes the tile sits above the name, which then has the page's width.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: PhoneStyle.Space.s3))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        layout {
            SettingsTile(systemImage: systemImage, tone: isActive ? .active : .neutral, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                // On one line when it fits; else a size smaller, wrapping at spaces (a page of the open Duo).
                ViewThatFits(in: .horizontal) {
                    Text(title).font(PhoneStyle.Typeface.title(.title)).lineLimit(1)
                    Text(title.wrappingAsName)
                        .font(PhoneStyle.Typeface.title(.title2))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(PhoneStyle.Ink.title)
                .accessibilityAddTraits(.isHeader)
                Text(status.keepingSeparators)
                    .font(.subheadline)
                    .foregroundStyle(statusNeedsAttention ? PhoneStyle.Ink.warning : PhoneStyle.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// A device page's header as a list row: on the list's background, not in a cell.
    func devicePageHeaderRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }

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

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Ask Your Mac to Transcribe", isOn: $settings.requestsTranscription)
                Toggle("Recording with Your Mac", isOn: $settings.acceptsMacRecordRequests)
            }
            CaptionSettingsSection()
            Section {
                Toggle("Lock Screen and Dynamic Island", isOn: $settings.showsLiveActivity)
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

// MARK: About

struct AboutScreen: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Daybook").font(PhoneStyle.Typeface.title(.title)).foregroundStyle(PhoneStyle.Ink.title)
                    Text("Version \(version)").font(.subheadline).foregroundStyle(PhoneStyle.Ink.secondary)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }
            Section("Privacy") {
                Text("Recordings, notes, and transcripts stay on your devices and in your iCloud.")
                    .font(.subheadline)
                    .foregroundStyle(PhoneStyle.Ink.body)
            }
            // Credits for the models behind this library's transcripts and summaries: only once there are some.
            if !AcknowledgementsScreen.entries(for: model).isEmpty {
                Section {
                    NavigationLink("Acknowledgements", value: SettingsRoute.acknowledgements)
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}

// MARK: Live captions

/// Live captions while recording, and their language, with an honest word on whether they can run.
struct CaptionSettingsSection: View {
    @Environment(PhoneAppModel.self) private var model
    @State private var availability: LiveCaptionAvailability?
    @State private var locales: [Locale] = []

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Toggle("Live Captions While Recording", isOn: $settings.liveCaptions)
            if settings.liveCaptions {
                Picker("Language", selection: $settings.captionLocaleIdentifier) {
                    Text("Same as iPhone").tag(String?.none)
                    ForEach(locales, id: \.identifier) { locale in
                        Text(LiveCaptionAvailability.name(locale)).tag(Optional(locale.identifier))
                    }
                }
            }
        } footer: {
            if let footer { Text(footer) }
        }
        .task(id: settings.captionLocaleIdentifier) {
            if locales.isEmpty { locales = await LiveCaptionAvailability.supportedLocales() }
            availability = await LiveCaptionAvailability.check(locale: settings.captionLocale)
        }
    }

    private var footer: String? {
        switch availability {
        case .needsDownload(let locale)?:
            return "Captions for \(LiveCaptionAvailability.name(locale)) download the first time you record with them on."
        case .unavailable(let reason)?: return reason
        case .ready?, nil: return nil
        }
    }
}
