import DaybookCaptions
import DaybookKit
import SwiftUI

/// Where a Settings row leads.
enum SettingsRoute: Hashable {
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

/// Settings: iCloud and sync, your Macs, recorders, recording, storage, templates and vocabulary,
/// and About. `LibraryBrowser` presents it.
struct SettingsScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsRoute] = []
    @State private var showingPairing = false
    @State private var showingAddDevice = false

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                SyncSection()
                MacsSection(showingPairing: $showingPairing)
                RecordersSection(showingAddDevice: $showingAddDevice)
                Section {
                    NavigationLink(value: SettingsRoute.recording) {
                        SettingsRow(title: "Recording", detail: recordingSummary, systemImage: "waveform", tint: PhoneStyle.Ink.record)
                    }
                    NavigationLink(value: SettingsRoute.storage) {
                        SettingsRow(title: "Storage", detail: storageSummary, systemImage: "internaldrive", tint: .gray)
                    }
                }
                Section {
                    NavigationLink(value: SettingsRoute.templates) {
                        SettingsRow(title: "Summary Templates", detail: "\(model.library.controller.templates.count) templates",
                                    systemImage: "doc.text", tint: PhoneStyle.accent)
                    }
                    NavigationLink(value: SettingsRoute.vocabulary) {
                        SettingsRow(title: "Vocabulary", detail: vocabularySummary, systemImage: "character.book.closed", tint: PhoneStyle.accent)
                    }
                } header: {
                    Text("Library")
                }
                Section {
                    NavigationLink(value: SettingsRoute.about) {
                        SettingsRow(title: "About Daybook", detail: nil, systemImage: "info.circle", tint: .gray)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
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
            .sheet(isPresented: $showingPairing) { PairingSheet() }
            .sheet(isPresented: $showingAddDevice) {
                AddDeviceSheet { id in
                    showingAddDevice = false
                    if let id { path = [.device(id)] }
                }
            }
            .task { await openRequestedScreen() }
        }
    }

    private var recordingSummary: String {
        model.settings.requestsTranscription ? "Transcribes automatically" : "Transcribes when you ask"
    }

    private var storageSummary: String {
        let used = model.audio.usage.bytes
        return used == 0 ? "No downloaded audio" : "\(ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .file)) of audio"
    }

    private var vocabularySummary: String {
        let count = model.library.controller.glossary.filter(\.approved).count
        return count == 0 ? "No terms yet" : count == 1 ? "1 term" : "\(count) terms"
    }

    /// `--open-settings <screen>` (debug), for screenshots.
    private func openRequestedScreen() async {
        guard let screen = model.options.openSettings else { return }
        if screen == "device" || screen == "devices" {
            // A recorder the device autopilot is still adding: wait for it to connect and import.
            for _ in 0..<150 where model.devices.sessions.first?.links.recent.isEmpty != false {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        switch screen {
        case "macs": if let mac = model.link.macs.first { path = [.mac(mac.id)] }
        case "pairing": showingPairing = true
        case "devices", "device": if let session = model.devices.sessions.first { path = [.device(session.id)] }
        case "add-device": showingAddDevice = true
        case "storage": path = [.storage]
        case "templates": path = [.templates]
        case "template": path = [.templates, .template("general")]
        case "vocabulary": path = [.vocabulary]
        case "recording": path = [.recording]
        case "library-devices": path = [.libraryDevices]
        case "about": path = [.about]
        case "acknowledgements": path = [.about, .acknowledgements]
        default: break
        }
    }
}

/// A Settings row: a tinted symbol tile, the title, and one line of what it's set to.
struct SettingsRow: View {
    let title: String
    let detail: String?
    let systemImage: String
    var tint: Color = .gray

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.primary)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 1)
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
            } footer: {
                if !settings.requestsTranscription {
                    Text("Recordings wait until you choose Transcribe.")
                }
            }
            Section {
                Toggle("Recording with Your Mac", isOn: $settings.acceptsMacRecordRequests)
            } footer: {
                Text("A paired Mac can start and stop recordings on this iPhone.")
            }
            CaptionSettingsSection()
            Section {
                Toggle("Lock Screen and Dynamic Island", isOn: $settings.showsLiveActivity)
            } footer: {
                Text("Shows the clock, Bookmark, and Stop while recording.")
            }
            Section {
                LabeledContent("Format", value: "AAC, 48 kHz mono")
                LabeledContent("Size", value: "About 29 MB an hour")
            } header: {
                Text("Quality")
            } footer: {
                Text("Records this iPhone’s microphone only, not calls or other apps.")
            }
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: About

struct AboutScreen: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Daybook").font(PhoneStyle.Typeface.title(.title)).foregroundStyle(PhoneStyle.Ink.title)
                    Text("Version \(version)").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section("Privacy") {
                Text("Recordings, notes, and transcripts stay on your devices and in your iCloud.")
                    .font(.subheadline)
            }
            Section {
                NavigationLink("Acknowledgements", value: SettingsRoute.acknowledgements)
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
