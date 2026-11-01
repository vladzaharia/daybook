import AppKit
import AVFoundation
import CoreGraphics
import DaybookCore
import SwiftUI

/// The Settings panes, restored from `@AppStorage("settingsPane")`.
enum SettingsPane: String {
    case general, models, cloud, devices, library
}

/// Settings (Direction A §5.14): five grouped panes, 600 pt wide, each as tall as its content.
struct SettingsView: View {
    @ObservedObject var state: AppState
    @AppStorage("settingsPane") private var pane = SettingsPane.general

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
            Tab("Devices", systemImage: "waveform.badge.microphone", value: SettingsPane.devices) {
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

/// A section footer: one or two sentences in secondary, aligned with the rows above.
struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
    }
}

/// A problem in place, in Settings and its sheets: the warning glyph, one plain sentence in the label colour, the system's
/// own words behind Details…, and its actions. They sit beside a short sentence and move under a long one, so a row never
/// squeezes its sentence into a narrow column.
struct ProblemLine<Actions: View>: View {
    let text: String
    var details: String?
    var symbol = "exclamationmark.triangle.fill"
    @ViewBuilder var actions: Actions

    /// The glyph's column, so a wrapped sentence and stacked actions keep one leading edge.
    private static var glyphWidth: CGFloat { 18 }
    private var hasButtons: Bool { details != nil || Actions.self != EmptyView.self }

    var body: some View {
        if hasButtons {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    sentence
                    Spacer(minLength: Space.s3)
                    buttons
                }
                VStack(alignment: .leading, spacing: Space.s2) {
                    sentence
                    // Wrapped, so several long ones ("Get Key from Alex's iPhone 15 Pro Max") stay inside the row.
                    FlowLayout(spacing: Space.s2) { buttons }
                        .padding(.leading, Self.glyphWidth + Space.s2)
                }
            }
        } else {
            sentence
        }
    }

    private var sentence: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Image(systemName: symbol)
                .foregroundStyle(Ink.warning)
                .frame(width: Self.glyphWidth)
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var buttons: some View {
        if let details { DetailsButton(details: details) }
        actions
    }
}

extension ProblemLine where Actions == EmptyView {
    init(text: String, details: String? = nil, symbol: String = "exclamationmark.triangle.fill") {
        self.init(text: text, details: details, symbol: symbol) { EmptyView() }
    }

    /// An `AppProblem` shown in place: its message, and its details behind Details….
    init(problem: AppProblem) { self.init(text: problem.message, details: problem.details) }
}

/// Details… beside a problem: the system's own words, selectable, in a popover.
struct DetailsButton: View {
    let details: String
    @State private var showing = false

    var body: some View {
        Button("Details…") { showing = true }
            .popover(isPresented: $showing) {
                Text(details)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Space.s4)
                    .frame(width: 360, alignment: .leading)
            }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var state: AppState
    /// The import-matching switch lives on the sources coordinator, which the window doesn't follow.
    @ObservedObject private var sources: MultiSourceCoordinator
    @AppStorage("showsFloatingNotesWhileRecording") private var showsFloatingNotes = true
    @AppStorage("showsMenuBarExtra") private var showsMenuBarExtra = true
    @AppStorage("screenCaptureRequested") private var screenCaptureRequested = false
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var screenCapture = CGPreflightScreenCaptureAccess()
    @State private var showingSupportedApps = false

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
    }
}

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
    @ObservedObject var state: AppState
    @ObservedObject private var monitor: MeetingMonitor
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
    @ObservedObject var state: AppState

    /// "Daybook 1.2 (45)"; nothing for a development build without a version.
    private var version: String? {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        guard let build = info?["CFBundleVersion"] as? String else { return "Daybook \(short)" }
        return "Daybook \(short) (\(build))"
    }

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
            }

            SyncSettingsView(state: state)

            Section {
                Label {
                    Text("Transcripts and summaries are made on this Mac. Nothing is uploaded except to your own iCloud, when sync is on.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(DaybookStyle.brandGradient)
                }
            } header: {
                Text("Privacy")
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
