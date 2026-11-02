import AppKit
import AVFoundation
import CoreGraphics
import DaybookCore
import DaybookDesign
import DaybookKit
import DaybookUI
import ServiceManagement
import SwiftUI

/// The Settings panes, restored from `@AppStorage(SettingsPane.storageKey)`.
enum SettingsPane: String {
    case general, models, cloud, devices, library
}

/// Settings (Direction A §5.14): five grouped panes, 600 pt wide, each as tall as its content.
struct SettingsView: View {
    let state: AppState
    @AppStorage(SettingsPane.storageKey) private var pane = SettingsPane.general

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: SettingsPane.general) {
                GeneralSettings(state: state).settingsPane()
            }
            Tab("Models", systemImage: "cpu", value: SettingsPane.models) {
                ModelSettings(state: state).settingsPane()
            }
            Tab("Cloud", systemImage: "cloud", value: SettingsPane.cloud) {
                CloudSettings(state: state).settingsPane()
            }
            Tab("Devices", systemImage: "recordingtape", value: SettingsPane.devices) {
                DevicesSettingsPane(state: state).settingsPane()
            }
            Tab("Library", systemImage: "books.vertical", value: SettingsPane.library) {
                LibrarySettings(state: state).settingsPane()
            }
        }
    }
}

extension View {
    /// A pane is 600 pt wide and hugs its content, so the window resizes as panes change.
    func settingsPane() -> some View { modifier(SettingsPaneSize()) }
}

/// Hugs the pane's content; a pane taller than the screen keeps the screen's height and scrolls.
private struct SettingsPaneSize: ViewModifier {
    @State private var contentHeight: CGFloat = 0
    /// The visible screen height, less the title bar and pane toolbar.
    private var limit: CGFloat { max(320, (NSScreen.main?.visibleFrame.height ?? 900) - 120) }

    func body(content: Content) -> some View {
        let fits = contentHeight <= limit
        content
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in contentHeight = height }
            .scrollDisabled(fits)
            .fixedSize(horizontal: false, vertical: fits)
            .frame(width: 600)
            .frame(height: fits ? nil : limit)
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
    let state: AppState
    /// The import-matching switch lives on the sources coordinator, which the window doesn't follow.
    @Bindable private var sources: MultiSourceCoordinator
    @AppStorage(AppState.Preference.showsFloatingNotesWhileRecording) private var showsFloatingNotes = true
    @AppStorage(AppState.Preference.showsMenuBarExtra) private var showsMenuBarExtra = true
    @AppStorage("screenCaptureRequested") private var screenCaptureRequested = false
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var screenCapture = CGPreflightScreenCaptureAccess()
    @State private var showingSupportedApps = false
    @State private var loginItem = LoginItem.forSettings()

    init(state: AppState) {
        self.state = state
        sources = state.sources
    }

    var body: some View {
        Form {
            Section("Recording") {
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
                Toggle("Show floating notes while recording", isOn: $showsFloatingNotes)
                    .controlSize(.regular)
                Toggle("Add imported files to conversations they overlap", isOn: $sources.matchesImportedFiles)
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

            Section("Menu Bar") {
                Toggle("Show Daybook in the menu bar", isOn: $showsMenuBarExtra)
                    .controlSize(.regular)
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
        loginItem.refresh()
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
