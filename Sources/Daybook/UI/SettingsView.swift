import AppKit
import AVFoundation
import CoreGraphics
import DaybookCore
import DaybookDesign
import DaybookKit
import DaybookUI
import ServiceManagement
import SwiftUI

/// Settings' pages, in the sidebar's order, the one showing restored from `@AppStorage(SettingsPane.storageKey)`.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, recording, devices, library, models, cloud

    var id: String { rawValue }

    /// The sidebar's groups, as System Settings spaces its own.
    static let groups: [[SettingsPane]] = [[.general, .recording], [.devices, .library], [.models, .cloud]]

    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .devices: "Devices"
        case .library: "Library"
        case .models: "Models"
        case .cloud: "Cloud"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .recording: "waveform"
        case .devices: "iphone"
        case .library: "books.vertical.fill"
        case .models: "cpu.fill"
        case .cloud: "cloud.fill"
        }
    }

    /// The icon's tile, colored as System Settings colors its own.
    var tint: Color {
        switch self {
        case .general: .gray
        case .recording: .red
        case .devices: .blue
        case .library: .brown
        case .models: .purple
        case .cloud: .cyan
        }
    }

    /// What else finds the page in the sidebar's search: what's on it, in the words people look for.
    var keywords: [String] {
        switch self {
        case .general: ["Login", "Startup", "Menu Bar"]
        case .recording: ["Microphone", "Computer Audio", "Calls", "Automatic", "Live Captions", "Floating Notes", "Permissions", "Screen"]
        case .devices: ["iPhone", "Recorder", "Soundcore", "Pair", "Bluetooth", "Wi-Fi"]
        case .library: ["Folder", "Storage", "iCloud", "Sync", "Import", "Privacy", "Encryption"]
        case .models: ["Transcription", "Speakers", "Summaries", "Language", "Download", "Quality", "Voice", "Vocabulary", "Templates",
                       "Parakeet", "Whisper", "Gemma", "Nemotron", "Community-1"]
        case .cloud: ["Anthropic", "OpenAI", "Claude", "GPT", "Key"]
        }
    }

    /// Whether the sidebar's search finds the page.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return ([title] + keywords).contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// Settings, laid out as System Settings is: the pages in a sidebar with search, each a grouped page that can open
/// pages of its own (Models' Transcription, Speakers, Summaries, and Model Library).
struct SettingsView: View {
    let state: AppState
    @AppStorage(SettingsPane.storageKey) private var pane = SettingsPane.general
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(SettingsPane.groups, id: \.self) { group in
                    Section {
                        ForEach(group.filter { $0.matches(query) }) { pane in
                            SettingsSidebarRow(pane: pane).tag(pane)
                        }
                    }
                }
                if !SettingsPane.allCases.contains(where: { $0.matches(query) }) {
                    Text("No Results").foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(215)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            page.id(pane)
        }
        .frame(width: 780)
        .frame(minHeight: 520, idealHeight: 680)
    }

    private var selection: Binding<SettingsPane?> {
        Binding(get: { pane }, set: { if let chosen = $0 { pane = chosen } })
    }

    @ViewBuilder private var page: some View {
        switch pane {
        // Models has pages of its own, so its stack is its own.
        case .models: ModelSettings(state: state)
        default:
            NavigationStack {
                Group {
                    switch pane {
                    case .general: GeneralSettings()
                    case .recording: RecordingSettings(state: state)
                    case .devices: DevicesSettingsPane(state: state)
                    case .library: LibrarySettings(state: state)
                    case .cloud: CloudSettings(state: state)
                    case .models: EmptyView()
                    }
                }
                .navigationTitle(pane.title)
            }
        }
    }
}

/// A page in the sidebar: its symbol on a colored tile, then its name.
private struct SettingsSidebarRow: View {
    let pane: SettingsPane

    var body: some View {
        Label {
            Text(pane.title)
        } icon: {
            Image(systemName: pane.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

// Settings' footers and problem lines are the ones both apps draw (DaybookUI's `SettingsFooter`, DaybookDesign's
// `ProblemLine` and `DetailsButton`). These names reach the Mac's files that don't import those libraries.
typealias SettingsFooter = DaybookUI.SettingsFooter
typealias ProblemLine<Actions: View> = DaybookDesign.ProblemLine<Actions>
typealias DetailsButton = DaybookDesign.DetailsButton

extension DaybookDesign.ProblemLine where Actions == EmptyView {
    /// An `AppProblem` shown in place: its message, and its details behind Details….
    init(problem: AppProblem) { self.init(text: problem.message, details: problem.details) }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(AppState.Preference.showsMenuBarExtra) private var showsMenuBarExtra = true
    @State private var loginItem = LoginItem.forSettings()

    var body: some View {
        Form {
            Section {
                // Record calls automatically and the menu bar item work only while Daybook is open.
                Toggle("Open at login", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }))
                    .controlSize(.regular)
                if let problem = loginItem.problem {
                    ProblemLine(text: problem.text, details: problem.details) {
                        if problem.opensSettings {
                            Button("Open Login Items Settings…") { loginItem.openSettings() }
                        }
                    }
                }
                Toggle("Show Daybook in the menu bar", isOn: $showsMenuBarExtra)
                    .controlSize(.regular)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in loginItem.refresh() }
    }
}

// MARK: - Recording

private struct RecordingSettings: View {
    let state: AppState
    @AppStorage(AppState.Preference.showsFloatingNotesWhileRecording) private var showsFloatingNotes = true
    @AppStorage("screenCaptureRequested") private var screenCaptureRequested = false
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var screenCapture = CGPreflightScreenCaptureAccess()
    @State private var showingSupportedApps = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: computerAudio) {
                    Text("Include computer audio")
                    Text("Records the other people on a call.")
                }
                .controlSize(.regular)
                LabeledContent {
                    HStack(spacing: Space.s2) {
                        Button { showingSupportedApps = true } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Supported Calls")
                        .accessibilityLabel("Supported calls")
                        .popover(isPresented: $showingSupportedApps, arrowEdge: .bottom) { SupportedCallsPopover() }
                        Toggle("Record calls automatically", isOn: automaticRecording)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.regular)
                    }
                } label: {
                    Text("Record calls automatically")
                    if state.automaticRecording { DetectionStatusLine(state: state) }
                }
                Toggle("Show floating notes while recording", isOn: $showsFloatingNotes)
                    .controlSize(.regular)
            }

            LiveCaptionSettingsSection(settings: state.captionSettings)

            Section {
                LabeledContent("Microphone") { microphoneStatus }
                LabeledContent("Screen & System Audio Recording") { screenCaptureStatus }
            } header: {
                Text("Permissions")
            } footer: {
                if !screenCapture {
                    SettingsFooter("Needed to record computer audio.")
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
    }

    private var computerAudio: Binding<Bool> {
        Binding(get: { state.includeComputerAudio }, set: { enabled in
            if enabled && !CGPreflightScreenCaptureAccess() { requestScreenCapture() }
            state.includeComputerAudio = enabled
        })
    }

    private var automaticRecording: Binding<Bool> {
        Binding(get: { state.automaticRecording }, set: { enabled in
            if enabled && !CGPreflightScreenCaptureAccess() { requestScreenCapture() }
            state.automaticRecording = enabled
        })
    }

    @ViewBuilder private var microphoneStatus: some View {
        switch microphone {
        case .authorized:
            AllowedLabel()
        case .notDetermined:
            Button("Allow…") {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    Task { @MainActor in microphone = AVCaptureDevice.authorizationStatus(for: .audio) }
                }
            }
        default:
            Button("Open System Settings…") { PrivacySettings.open(.microphone) }
        }
    }

    @ViewBuilder private var screenCaptureStatus: some View {
        if screenCapture {
            AllowedLabel()
        } else if !screenCaptureRequested {
            Button("Allow…") { requestScreenCapture() }
        } else {
            Button("Open System Settings…") { PrivacySettings.open(.screenCapture) }
        }
    }

    /// macOS asks only once; after that, the person allows it in System Settings.
    private func requestScreenCapture() {
        screenCaptureRequested = true
        screenCapture = CGRequestScreenCaptureAccess()
    }

    private func refreshPermissions() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        screenCapture = CGPreflightScreenCaptureAccess()
    }
}

// MARK: Open at login

/// What `LoginItem` asks of the system: SMAppService's main app, or a stand-in in tests.
@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

extension SMAppService: LoginItemService {
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Open at login (Settings › General): Daybook as a login item, off until the person turns it on, so Record calls
/// automatically and the menu bar item work after a restart. Its status is the system's, read again whenever
/// Daybook comes to the front; one System Settings is still waiting to approve is on, with the way there.
@MainActor
@Observable
final class LoginItem {
    struct Problem: Equatable {
        var text: String
        var details: String?
        /// Its fix is in System Settings › General › Login Items.
        var opensSettings: Bool
    }

    private let service: any LoginItemService
    private(set) var status: SMAppService.Status
    /// The system refused to add or remove it.
    private var failure: Problem?

    init(service: any LoginItemService = SMAppService.mainApp) {
        self.service = service
        status = service.status
    }

    /// On once registered, whether or not System Settings has approved it yet.
    var isOn: Bool { status == .enabled || status == .requiresApproval }

    /// What stops it opening Daybook at login, said once under the toggle.
    var problem: Problem? {
        if let failure { return failure }
        if status == .requiresApproval {
            return Problem(text: "Allow Daybook in Login Items to open it at login.", details: nil, opensSettings: true)
        }
        return nil
    }

    func set(_ on: Bool) {
        guard on != isOn else { return }
        do {
            if on { try service.register() } else { try service.unregister() }
            failure = nil
        } catch {
            failure = Problem(text: on ? "Daybook couldn’t be added to Login Items." : "Daybook couldn’t be removed from Login Items.",
                              details: (error as NSError).localizedDescription, opensSettings: true)
        }
        refresh()
    }

    func refresh() { status = service.status }

    func openSettings() { service.openSystemSettings() }

    /// The login item Settings › General shows: this app's, or (debug, `--login-item-demo approval|refused`) a stand-in
    /// in that state, for screenshots, which never touches this Mac's login items.
    static func forSettings(arguments: [String] = CommandLine.arguments) -> LoginItem {
        #if DEBUG
        if let index = arguments.firstIndex(of: "--login-item-demo") {
            let demo = DemoLoginItem()
            let item = LoginItem(service: demo)
            switch arguments.dropFirst(index + 1).first {
            case "refused":
                demo.refuses = true
                item.set(true)
            default:
                item.set(true)
            }
            return item
        }
        #endif
        return LoginItem()
    }
}

#if DEBUG
/// A login item waiting for approval in System Settings, or one the system refuses (`--login-item-demo`).
private final class DemoLoginItem: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var refuses = false

    struct Refused: LocalizedError { var errorDescription: String? { "The operation couldn’t be completed. Operation not permitted" } }

    func register() throws {
        if refuses { throw Refused() }
        status = .requiresApproval
    }

    func unregister() throws { status = .notRegistered }
    func openSystemSettings() { }
}
#endif

/// "✓ Allowed": the teal check Daybook uses for anything done (neon teal in dark).
private struct AllowedLabel: View {
    var body: some View {
        Label {
            Text("Allowed").foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.link)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// The live line under "Record calls automatically", shown only while it's on: a mint dot while
/// listening, the recording red while a detected call is being recorded.
private struct DetectionStatusLine: View {
    let state: AppState
    private let monitor: MeetingMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: AppState) {
        self.state = state
        monitor = state.monitor
    }

    private var recording: Bool { monitor.isMeetingActive && state.isRecording }
    private var color: Color { recording ? Ink.record : DaybookStyle.neonMint }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(color)
                .neonGlow(color, radius: 3)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                .accessibilityHidden(true)
            Text(monitor.statusText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The calls Daybook can notice, generated from the detection rules so the list stays in sync.
private struct SupportedCallsPopover: View {
    private var apps: [String] {
        MeetingAppRule.defaults.filter { !$0.isBrowser }.map { rule in
            switch rule.displayName {
            case "Teams": return "Microsoft Teams"
            case "Slack": return "Slack huddles"
            default: return rule.displayName
            }
        }
    }
    private var browsers: String {
        MeetingAppRule.defaults.filter(\.isBrowser).map(\.displayName).formatted(.list(type: .or))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Daybook notices calls in:").fontWeight(.semibold)
            VStack(alignment: .leading, spacing: Space.s1) {
                ForEach(apps + ["Google Meet, Zoom, or Teams calls in \(browsers)"], id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(Space.s4)
        .frame(width: 300, alignment: .leading)
    }
}

// MARK: - Library

private struct LibrarySettings: View {
    let state: AppState
    /// The import-matching switch lives on the sources coordinator, which the window doesn't follow.
    @Bindable private var sources: MultiSourceCoordinator

    init(state: AppState) {
        self.state = state
        sources = state.sources
    }

    /// "Version 1.2 (45)", as the About panel and the iPhone's About say it; nothing for a development build.
    private var version: String? { AboutWords.version(Bundle.main.infoDictionary) }

    var body: some View {
        Form {
            Section("Location") {
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([state.storageURL]) }
                } label: {
                    Text("Library folder")
                    Text(SettingsPath.display(state.storageURL))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(state.storageURL.path)
                }
                StorageSettingsRow(state: state)
            }

            SyncSettingsView(state: state)

            Section("Imports") {
                Toggle("Add imported files to conversations they overlap", isOn: $sources.matchesImportedFiles)
                    .controlSize(.regular)
            }

            Section {
                PrivacyStatement()
            } header: {
                Text(AboutWords.privacy)
            } footer: {
                if let version {
                    Text(version)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Space.s2)
                }
            }
        }
        .formStyle(.grouped)
        #if DEBUG
        .task { LibraryMoveDemo.apply(to: state) }
        #endif
    }
}

/// Paths as people read them: "iCloud Drive › Daybook", or "~/Library/Application Support/Daybook". `home` is the
/// person's own home folder (`UserHome`): in the App Sandbox the library is in the container, and shows as such.
enum SettingsPath {
    static func display(_ url: URL, home: URL = UserHome.url) -> String {
        let path = url.standardizedFileURL.path
        let mobile = home.appendingPathComponent("Library/Mobile Documents").path + "/"
        if path.hasPrefix(mobile) {
            var parts = path.dropFirst(mobile.count).split(separator: "/").map(String.init)
            guard let container = parts.first else { return "iCloud Drive" }
            parts.removeFirst()
            // An app's own container shows as its Documents folder inside iCloud Drive.
            if container != "com~apple~CloudDocs", parts.first == "Documents" { parts.removeFirst() }
            return (["iCloud Drive"] + parts).joined(separator: " › ")
        }
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }
}
