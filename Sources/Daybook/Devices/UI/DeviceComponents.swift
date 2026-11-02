import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

// Building blocks for the Mac's own device surfaces: a selected recording's page, the paired iPhone's
// page, and Add Device. A recorder's page, Listen Live, and its recordings are the screens both apps
// share (DaybookUI's `Devices`). A device surface is content, not chrome: the paper surface, page
// type, the paper inks (`Ink`), quiet fills, and no glass. Colour is reserved, as on the iPhone: teal
// for a live link to a recorder and for what you can act on (`Ink.link`), the brand gradient for
// progress, `Ink.warning` for warnings, and `Ink.record` for recording.

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

/// A state that needs the person, as a conversation's status box (`StatusBox`): a problem (warning),
/// or something to know (quiet), spanning the column, its actions under the message when it's narrow.
struct DeviceAttentionBox<Actions: View>: View {
    var kind: StatusBoxKind = .info
    let symbol: String
    let title: String
    var message: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        StatusBox(kind: kind, symbol: symbol, title: title, message: message, actions: actions)
            .padding(.top, Space.s4)
            .transition(.opacity)
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

/// The M4 transition: a status line or notice slides in from the top; it only fades under Reduce Motion.
extension AnyTransition {
    static func deviceNotice(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}

extension DeviceSession {
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
    /// Settings › Devices.
    static func openSettings(_ openSettings: OpenSettingsAction) {
        SettingsPane.devices.open(with: openSettings, activating: false)
    }

    /// Show Audio File in Finder for an imported recording.
    static func revealAudio(state: AppState, meetingID: UUID, recordingID: String) {
        guard let track = state.meetings.first(where: { $0.id == meetingID })?.tracks.first(where: { $0.deviceRecordingID == recordingID }) else { return }
        Task {
            if let url = await state.audioURL(for: track, meetingID: meetingID) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
