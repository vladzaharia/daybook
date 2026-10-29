import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

// Building blocks shared by every device surface. The device page is content, not chrome: the
// paper surface, page type, the paper inks (`Ink`), quiet fills, and no glass. Colour is reserved,
// as on the iPhone: teal for a live link to a recorder and for what you can act on (`Ink.link`),
// neon cyan for live listening, the brand gradient for progress, `Ink.warning` for warnings, and
// `Ink.record` for recording. Everything else is the label colour or secondary.

/// The device page's column: a conversation page's (`PageScroll`: a 640 pt measure, centred, with a
/// 56 pt margin hanging to its left), so titles line up when moving between a device and a
/// conversation. Under 600 pt the margin folds away.
struct DevicePageScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        PageScroll { DeviceColumn { content } }
            .background(DaybookStyle.paper)
    }
}

/// The text measure inside the page: past the margin, which a conversation fills with times and the
/// device page leaves to its title's glyph.
private struct DeviceColumn<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.pageIsNarrow) private var narrow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.leading, narrow ? 0 : DaybookStyle.margin)
    }
}

/// A page title with a glyph hanging in the margin beside it, where a conversation's times hang
/// (ending 8 pt before the text).
struct DevicePageTitle<Glyph: View>: View {
    let title: String
    @ViewBuilder var glyph: Glyph
    @Environment(\.pageIsNarrow) private var folded

    var body: some View {
        Text(title).font(TypeStyle.docTitle()).monospacedDigit()
            .foregroundStyle(Ink.title)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .overlay(alignment: .topLeading) {
                if !folded {
                    glyph
                        .frame(width: DaybookStyle.margin - 8, height: 36, alignment: .trailing)
                        .offset(x: -DaybookStyle.margin)
                }
            }
    }
}

/// A device kind's symbol: teal while the recorder is linked, secondary otherwise, as on the iPhone.
struct DeviceGlyph: View {
    let symbol: String
    var size: CGFloat = 28
    var linked = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(linked ? DaybookStyle.accent : Ink.secondary)
            .accessibilityHidden(true)
    }
}

/// The 7 pt dot before a status line: teal when connected (pulsing while connecting), warning
/// when unavailable, meta otherwise.
struct DeviceStatusDot: View {
    let state: ConnectionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(color)
            .symbolEffect(.pulse, isActive: state.isBusy && !reduceMotion)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .connected, .searching, .connecting, .reconnecting: return DaybookStyle.accent
        case .unavailable: return Ink.warning
        default: return Ink.meta
        }
    }
}

/// A page section heading: "Import".
struct DeviceHeading: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(TypeStyle.heading())
            .foregroundStyle(Ink.body)
            .padding(.top, Space.s6).padding(.bottom, Space.s3)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One quiet-filled box on the column, its outer edge on the text's edge as a conversation's
/// status boxes are, with their padding and corners.
struct DeviceBox<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DaybookStyle.quietFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The device page's problem, under its status line: a conversation's problem box (`StatusBox`),
/// with what happened, what is safe, and at most two actions, the first of them prominent.
struct DeviceProblemBanner: View {
    let problem: DeviceProblem
    let perform: (DeviceProblemAction) -> Void

    /// The problem's first two actions, with Dismiss when there's room for it.
    static func actions(_ problem: DeviceProblem, excluding hidden: Set<DeviceProblemAction> = []) -> [DeviceProblemAction] {
        let actions = Array(problem.actions.filter { !hidden.contains($0) }.prefix(2))
        return actions.count < 2 && !actions.contains(.dismiss) ? actions + [.dismiss] : actions
    }

    /// Actions that don't apply here (Set Up Folder… once the folder is set up).
    var hidden: Set<DeviceProblemAction> = []

    var body: some View {
        let actions = Self.actions(problem, excluding: hidden)
        DeviceAttentionBox(kind: .problem, symbol: "exclamationmark.triangle.fill", title: problem.title, message: problem.message) {
            ForEach(Array(actions.dropFirst().reversed().enumerated()), id: \.offset) { _, action in
                Button(action.title) { perform(action) }.buttonStyle(.daybookLink)
            }
            if let primary = actions.first {
                DeviceBoxPrimaryButton(title: primary.title) { perform(primary) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(problem.title). \(problem.message)")
    }
}

/// A state that needs the person, drawn as a conversation's status box (`StatusBox`: its fills,
/// glyph column, padding, and corners): a problem (warning), or something to know (quiet). It always
/// spans the column, and its actions move under the message when the column is narrow.
struct DeviceAttentionBox<Actions: View>: View {
    var kind: StatusBoxKind = .info
    let symbol: String
    let title: String
    var message: String?
    @ViewBuilder var actions: Actions
    @State private var width: CGFloat = DaybookStyle.measure
    @Environment(\.colorScheme) private var scheme

    private var stacked: Bool { width < 520 }
    private var tint: Color {
        switch kind {
        case .problem: return Ink.warning
        case .accent: return DaybookStyle.accent
        case .info: return Ink.secondary
        }
    }
    private var fill: Color {
        switch kind {
        case .problem: return Ink.warning.opacity(scheme == .dark ? 0.12 : 0.08)
        case .accent: return DaybookStyle.accent.opacity(0.08)
        case .info: return DaybookStyle.quietFill
        }
    }

    var body: some View {
        HStack(alignment: stacked ? .firstTextBaseline : .center, spacing: Space.s3) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .symbolRenderingMode(kind == .problem ? .monochrome : .hierarchical)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s2) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(TypeStyle.statusLead).foregroundStyle(kind == .problem ? Ink.warning : Ink.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message {
                        Text(message).font(TypeStyle.status).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if stacked { actionRow }
            }
            .layoutPriority(1)
            if !stacked {
                Spacer(minLength: Space.s3)
                actionRow
            }
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.top, Space.s4)
        .transition(.opacity)
    }

    private var actionRow: some View {
        HStack(spacing: Space.s3) { actions }
            .controlSize(.small)
            .fixedSize()
    }
}

/// The one prominent action in a box.
struct DeviceBoxPrimaryButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .tint(DaybookStyle.prominentFill)
    }
}

/// Something to know, with one optional action and Dismiss.
struct DeviceNotice: View {
    var symbol = "info.circle.fill"
    let text: String
    var action: (title: String, run: () -> Void)?
    var dismiss: (() -> Void)?

    var body: some View {
        DeviceAttentionBox(symbol: symbol, title: text) {
            if let dismiss { Button("Dismiss", action: dismiss).buttonStyle(.daybookLink) }
            if let action { Button(action.title, action: action.run) }
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

    /// Whether this Mac imports from the device: not from a recorder another device manages, which
    /// imports there (its recordings arrive through sync).
    var importsHere: Bool { managedElsewhere == nil || primary?.method != .direct }

    /// New recordings this Mac can import, for the sidebar's count and the menus.
    var importableCount: Int { importsHere ? newRecordings.count : 0 }

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

    /// Problem actions that don't apply to this device now: Set Up Folder… once its folder is set up.
    static func inapplicable(for session: DeviceSession) -> Set<DeviceProblemAction> {
        session.files?.isSetUp == true ? [.setUpFolder] : []
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
