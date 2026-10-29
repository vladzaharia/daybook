import DaybookCore
import DaybookKit
import SwiftUI

/// The device page for Daybook on iPhone: whether it's paired and connected, what it's recording,
/// and how its recordings arrive. Nothing imports from it: its recordings are conversations already,
/// arrive through sync, and are the list beside the page.
struct PhoneOverview: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    /// Sync turning on or off redraws the page (its box says when it's off).
    @ObservedObject private var sync: LibrarySyncController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    init(state: AppState, session: DeviceSession) {
        self.state = state
        self.session = session
        sync = state.sync
    }

    private var direct: (any DeviceConnection)? { session.direct }

    var body: some View {
        DevicePageScroll {
            DevicePageTitle(title: session.device.name) {
                DeviceGlyph(symbol: session.kind.systemImage, size: 26, linked: session.isLinked)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: Space.s2) {
                    DeviceStatusDot(state: direct?.state ?? .notSetUp)
                    Text(byline(now: context.date)).fixedSize(horizontal: false, vertical: true)
                }
                .font(TypeStyle.byline())
                .foregroundStyle(Ink.secondary)
            }
            .padding(.top, 6)

            // The recorders it manages, as it last said: "Soundcore Work · Recording since 10:02".
            if let phone = direct as? PhoneLinkConnection {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ForEach(Array(phone.recorders(now: context.date).enumerated()), id: \.offset) { _, recorder in
                        if let summary = recorder.summary(now: context.date) {
                            Text("\(recorder.name ?? "Recorder") · \(summary)")
                                .font(TypeStyle.byline())
                                .foregroundStyle(Ink.secondary)
                                .padding(.top, 2)
                        }
                    }
                }
            }

            // The one thing that needs the person, in the same box as every device's problem.
            if let direct, !direct.isSetUp {
                DeviceAttentionBox(kind: .problem, symbol: "exclamationmark.triangle.fill",
                                   title: "This Mac isn’t paired with \(session.device.name)") {
                    DeviceBoxPrimaryButton(title: "Pair…") { state.requestAddDevice(kind: DaybookPhoneIntegration.id) }
                }
            } else if let problem = session.problem {
                // Sync is off: the one thing that keeps its recordings from arriving.
                DeviceAttentionBox(kind: .problem, symbol: "exclamationmark.triangle.fill", title: problem.title, message: problem.message) {
                    DeviceBoxPrimaryButton(title: "Library Settings…") {
                        LaunchOptions.defaults.set(SettingsPane.library.rawValue, forKey: "settingsPane")
                        openSettings()
                    }
                }
            }

            if let status = session.status, status.isRecording == true, session.isLinked {
                recordingNow(status, paused: (direct as? PhoneLinkConnection)?.recordingPhase == .paused)
                    .padding(.top, Space.s4)
                    .transition(.deviceNotice(reduceMotion: reduceMotion))
            }

            DeviceHeading("Import")
            DeviceMethodRows(state: state, session: session)
            // Its recordings are listed beside the page already, every one of them in the library.
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: session.isLinked)
    }

    /// Its link's state; the box below says when sync is off.
    private func byline(now: Date) -> String {
        guard let direct, direct.isSetUp else { return "Not paired" }
        if direct.state.isConnected {
            guard session.status?.isRecording == true else { return "Connected" }
            return (direct as? PhoneLinkConnection)?.recordingPhase == .paused ? "Connected · Paused" : "Connected · Recording"
        }
        if let last = direct.lastConnectedAt { return "Not connected · Last connected \(DeviceDateFormat.lastSeen(last, now: now))" }
        return "Not connected"
    }

    /// "Recording now · since 10:02 AM" (or "Paused"), with the conversation when this Mac has it, and Stop.
    private func recordingNow(_ status: DeviceStatus, paused: Bool) -> some View {
        let conversation = (direct as? PhoneLinkConnection)?.recordingConversationID.flatMap { id in state.meetings.first { $0.id == id } }
        return DeviceBox {
            HStack(alignment: .center, spacing: Space.s3) {
                Image(systemName: paused ? "pause.circle.fill" : "record.circle.fill")
                    .font(.system(size: 15))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(paused ? Ink.secondary : Ink.record)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text((paused ? "Paused" : "Recording now") + (status.recordingStartedAt.map { " · since \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
                        .font(TypeStyle.statusLead).foregroundStyle(Ink.body)
                    if let conversation {
                        Button(conversation.title) { state.showConversation(conversation.id) }
                            .buttonStyle(.daybookLink).font(TypeStyle.status)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Space.s2)
                if let control = direct as? any RecordControlConnection {
                    Button("Stop on iPhone") { control.pauseRecording() }
                        .controlSize(.small)
                        .disabled(control.recordCommandPending)
                }
            }
        }
    }
}
