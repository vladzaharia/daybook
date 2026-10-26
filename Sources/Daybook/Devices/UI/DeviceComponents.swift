import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

// Building blocks shared by every device surface. The device page is content, not chrome: the
// paper surface, page type, the paper inks (`Ink`), quiet fills, and no glass. Colour is reserved:
// neon mint for a live link to a recorder, neon cyan for live listening, the brand gradient for
// progress, `Ink.link` for anything clickable, `Ink.warning` for warnings, `Ink.record` for recording.

/// The device page's column. It uses a conversation page's geometry (a 56 pt margin hanging left of
/// a 640 pt measure), so titles line up when moving between a device and a conversation. Under
/// 600 pt the margin folds away.
struct DevicePageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var narrow = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.leading, narrow ? 0 : DaybookStyle.margin)
                .frame(maxWidth: narrow ? .infinity : DaybookStyle.margin + DaybookStyle.measure, alignment: .leading)
                .padding(.leading, narrow ? Space.s5 : Space.s6 - 8)
                .padding(.trailing, narrow ? Space.s5 : Space.s6)
                .padding(.top, Space.s6)
                .padding(.bottom, Space.s8)
                .frame(maxWidth: .infinity)
        }
        .background(DaybookStyle.paper)
        .environment(\.deviceMarginFolded, narrow)
        .onGeometryChange(for: Bool.self) { $0.size.width < DaybookStyle.narrowWidth } action: { narrow = $0 }
    }
}

private struct DeviceMarginFoldedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// The page is too narrow for its margin, so glyphs that hang there are left out.
    var deviceMarginFolded: Bool {
        get { self[DeviceMarginFoldedKey.self] }
        set { self[DeviceMarginFoldedKey.self] = newValue }
    }
}

/// A page title with a glyph hanging in the margin beside it, where a conversation's times hang.
struct DevicePageTitle<Glyph: View>: View {
    let title: String
    @ViewBuilder var glyph: Glyph
    @Environment(\.deviceMarginFolded) private var folded

    var body: some View {
        Text(title).font(TypeStyle.docTitle()).monospacedDigit()
            .foregroundStyle(Ink.title)
            .lineLimit(2)
            .accessibilityAddTraits(.isHeader)
            .overlay(alignment: .topLeading) {
                if !folded {
                    glyph
                        .frame(width: DaybookStyle.margin - Space.s3, height: 36, alignment: .trailing)
                        .offset(x: -DaybookStyle.margin)
                }
            }
    }
}

/// A device kind's symbol. On the page it's drawn in the brand gradient, and a live link adds a glow.
struct DeviceGlyph: View {
    let symbol: String
    var size: CGFloat = 28
    var linked = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(DaybookStyle.brandGradient)
            .neonGlow(linked ? DaybookStyle.neonMint : .clear, radius: 5)
            .opacity(linked ? 1 : 0.85)
            .accessibilityHidden(true)
    }
}

/// The 6 pt dot before a status line: mint and glowing for a live link, accent while working,
/// warning when unavailable, meta otherwise.
struct DeviceStatusDot: View {
    let state: ConnectionState
    var linked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(color)
            .symbolEffect(.pulse, isActive: state.isBusy && !reduceMotion)
            .neonGlow(state == .connected && linked ? DaybookStyle.neonMint : .clear, radius: 3)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .connected: return linked ? DaybookStyle.neonMint : DaybookStyle.accent
        case .searching, .connecting, .reconnecting: return DaybookStyle.accent
        case .unavailable: return Ink.warning
        default: return Ink.meta
        }
    }
}

/// A page section heading: "How recordings arrive".
struct DeviceHeading: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(TypeStyle.heading())
            .foregroundStyle(Ink.body)
            .padding(.top, 28).padding(.bottom, Space.s3)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One quiet-filled box whose text lines up with the page text while its edge sits outside it.
struct DeviceBox<Content: View>: View {
    var cornerRadius: CGFloat = 8
    /// The box's fill; the quiet fill unless the box carries a warning.
    var fill: Color = DaybookStyle.quietFill
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .padding(.horizontal, -Space.s3)
    }
}

/// The banner at the top of the device page: what happened, what is safe, and at most two actions.
struct DeviceProblemBanner: View {
    let problem: DeviceProblem
    let perform: (DeviceProblemAction) -> Void
    @Environment(\.colorScheme) private var scheme

    private var actions: [DeviceProblemAction] {
        let actions = Array(problem.actions.prefix(2))
        return actions.count < 2 && !actions.contains(.dismiss) ? actions + [.dismiss] : actions
    }

    var body: some View {
        DeviceBox(fill: Ink.warning.opacity(scheme == .dark ? 0.12 : 0.08)) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s3) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(problem.title).font(TypeStyle.statusLead).foregroundStyle(Ink.warning)
                        Text(problem.message).font(TypeStyle.status).foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: Space.s3) {
                        Spacer(minLength: 0)
                        ForEach(Array(actions.dropFirst().reversed().enumerated()), id: \.offset) { _, action in
                            Button(action.title) { perform(action) }
                                .buttonStyle(.daybookLink)
                        }
                        if let primary = actions.first {
                            Button(primary.title) { perform(primary) }
                                .controlSize(.small)
                        }
                    }
                    .font(TypeStyle.status)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(problem.title). \(problem.message)")
    }
}

/// An informational notice with one optional action.
struct DeviceNotice: View {
    var symbol = "info.circle"
    let text: String
    var action: (title: String, run: () -> Void)?
    var dismiss: (() -> Void)?

    var body: some View {
        DeviceBox {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Image(systemName: symbol).foregroundStyle(Ink.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s3) {
                    Text(text).font(TypeStyle.status).foregroundStyle(Ink.body).fixedSize(horizontal: false, vertical: true)
                    if action != nil || dismiss != nil {
                        HStack(spacing: Space.s3) {
                            Spacer(minLength: 0)
                            if let dismiss { Button("Dismiss", action: dismiss).buttonStyle(.daybookLink) }
                            if let action { Button(action.title, action: action.run).controlSize(.small) }
                        }
                        .font(TypeStyle.status)
                    }
                }
            }
        }
    }
}

/// One of the page's figures, in a quiet tile: Recorder, Case, Storage.
struct DeviceFigureTile: View {
    let label: String
    let symbol: String
    let value: String
    var detail: String?
    var warning = false
    /// A value the recorder hasn't confirmed recently is drawn quieter, with its time.
    var stale = false
    let accessibility: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(warning ? Ink.warning : Ink.secondary)
                Text(label)
                    .foregroundStyle(Ink.secondary)
            }
            .font(TypeStyle.status)
            Text(value)
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(warning ? Ink.warning : stale ? Ink.secondary : Ink.body)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(detail ?? " ")
                .font(TypeStyle.colophon)
                .foregroundStyle(warning ? Ink.warning : Ink.meta)
                .lineLimit(1)
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .quietBox(cornerRadius: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }
}

/// A glyph tucked against its text, for row details.
struct DeviceInlineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.imageScale(.small); configuration.title }
    }
}

/// The M4 transition: a status line or notice slides in from the top; it only fades under Reduce Motion.
extension AnyTransition {
    static func deviceNotice(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}

extension DeviceSession {
    /// "Today, 10:02 AM" and "48 min" for the list and pages.
    func overlapHint(_ recording: DeviceRecording) -> DeviceOverlap? { overlaps(recording).first }

    /// "Connected · Recorder 80%", the list column's subtitle.
    var subtitle: String {
        if queue.isActive {
            if queue.isSuspended {
                return queue.total == 1 ? "1 recording waiting for \(kind.shortName)" : "\(queue.total) recordings waiting for \(kind.shortName)"
            }
            return "Importing \(queue.position) of \(queue.total)"
        }
        if (primary as? any LiveListeningConnection)?.live.isListening == true { return "Listening live" }
        if kind.id == DaybookPhoneIntegration.id {
            // The phone's recordings arrive through sync; the link is what connects.
            guard direct?.isSetUp == true else { return "Not paired" }
            if isLinked { return status?.isRecording == true ? "Connected · Recording" : "Connected" }
            if let last = direct?.lastConnectedAt { return "Last connected \(DeviceDateFormat.lastSeen(last))" }
            return "Not connected"
        }
        switch state {
        case .connected:
            guard isLinked else { return files?.summary ?? "Watching" }
            if let level = status?.battery?.level { return "Connected · Recorder \(level)%" }
            return "Connected"
        case .searching: return "Looking for \(kind.name)…"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .unavailable: return problem?.title ?? "Not available"
        case .notSetUp: return "Not set up"
        case .notConnected:
            if let status, status.isRecording == true { return DeviceDateFormat.recordingAsOf(status.updatedAt) }
            if let last = primary?.lastConnectedAt { return "Last connected \(DeviceDateFormat.lastSeen(last))" }
            return "Not connected"
        }
    }

    /// Stop, confirming first when more than a minute of audio has arrived (§5.19).
    func requestStop(all: Bool) {
        let seconds = Double(receivedBytes) / SoundcoreRecording.bytesPerSecond
        guard seconds > 60, let current = queue.current else {
            if all { stopAll() } else { stopCurrent() }
            return
        }
        browser.stopRequest = .init(title: current.recording.title, minutesReceived: Int(seconds / 60), stopsAll: all)
    }
}

/// Actions shared by the banner, the page, and menus.
@MainActor
enum DeviceActions {
    /// Settings › Devices. The Settings window reads its pane from `settingsPane`.
    static func openSettings(_ openSettings: OpenSettingsAction) {
        LaunchOptions.defaults.set("devices", forKey: "settingsPane")
        openSettings()
    }

    static func perform(_ action: DeviceProblemAction, session: DeviceSession, state: AppState) {
        switch action {
        case .openBluetoothSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(url) }
        case .openPrivacySettings: PrivacySettings.open(.bluetooth)
        case .setUpFolder, .chooseFolder:
            if state.chooseDeviceFolder(for: session) { session.dismissProblem() }
        case .tryAgain: session.tryAgain()
        case .technicalDetails:
            session.browser.showsTechnicalDetails = true
            session.browser.showingDetails = true
        case .reconnect, .connect: session.connect()
        case .dismiss: session.dismissProblem()
        case .refreshStatus:
            session.dismissProblem()
            session.primary?.refresh()
        }
    }

    /// Show Audio File in Finder for an imported recording.
    static func revealAudio(state: AppState, meetingID: UUID, recordingID: String) {
        guard let track = state.meetings.first(where: { $0.id == meetingID })?.tracks.first(where: { $0.deviceRecordingID == recordingID }) else { return }
        Task {
            if let url = await state.audioURL(for: track, meetingID: meetingID) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
