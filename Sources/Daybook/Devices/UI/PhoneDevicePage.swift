import DaybookCore
import DaybookKit
import SwiftUI

/// The device page for Daybook on iPhone: whether it's paired and connected, what it's recording,
/// how its recordings arrive, and its latest recordings in the library. Nothing imports from it:
/// its recordings are conversations already, and arrive through sync.
struct PhoneOverview: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    private var direct: (any DeviceConnection)? { session.direct }

    var body: some View {
        DevicePageScroll {
            if let direct, !direct.isSetUp {
                DeviceNotice(symbol: "exclamationmark.triangle", text: "This Mac isn’t paired with \(session.device.name) any more.",
                             action: ("Pair…", { state.requestAddDevice(kind: DaybookPhoneIntegration.id) }))
                    .padding(.bottom, Space.s5)
            } else if let problem = session.problem {
                // Sync is off: the one thing that keeps its recordings from arriving.
                DeviceNotice(symbol: "icloud.slash", text: problem.message, action: ("Library Settings…", {
                    LaunchOptions.defaults.set(SettingsPane.library.rawValue, forKey: "settingsPane")
                    openSettings()
                }))
                .padding(.bottom, Space.s5)
            }
            DevicePageTitle(title: session.device.name) {
                DeviceGlyph(symbol: session.kind.systemImage, size: 26, linked: session.isLinked)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: Space.s2) {
                    DeviceStatusDot(state: direct?.state ?? .notSetUp, linked: session.isLinked)
                    Text(byline(now: context.date))
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
                        }
                    }
                }
            }

            if let status = session.status, status.isRecording == true, session.isLinked {
                recordingNow(status, paused: (direct as? PhoneLinkConnection)?.recordingPhase == .paused)
                    .padding(.top, Space.s5)
                    .transition(.deviceNotice(reduceMotion: reduceMotion))
            }

            DeviceHeading("Import")
            DeviceMethodRows(state: state, session: session)

            RecentImports(state: state, session: session, heading: "Recently recorded")
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: session.isLinked)
    }

    private func byline(now: Date) -> String {
        guard let direct, direct.isSetUp else { return "Not paired" }
        if direct.state.isConnected {
            var parts = ["Connected"]
            if session.status?.isRecording == true { parts.append((direct as? PhoneLinkConnection)?.recordingPhase == .paused ? "Paused" : "Recording") }
            if state.sync.folder == nil { parts.append("Sync is off") }
            return parts.joined(separator: " · ")
        }
        if let last = direct.lastConnectedAt { return "Not connected · Last connected \(DeviceDateFormat.lastSeen(last, now: now))" }
        return "Not connected"
    }

    /// "Recording now · since 10:02 AM" (or "Paused"), with the conversation when this Mac has it, and Stop.
    private func recordingNow(_ status: DeviceStatus, paused: Bool) -> some View {
        let conversation = (direct as? PhoneLinkConnection)?.recordingConversationID.flatMap { id in state.meetings.first { $0.id == id } }
        return DeviceBox {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Image(systemName: paused ? "pause.circle" : "record.circle").foregroundStyle(paused ? Ink.secondary : .red).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text((paused ? "Paused" : "Recording now") + (status.recordingStartedAt.map { " · since \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
                        .font(TypeStyle.statusLead).foregroundStyle(Ink.body)
                    if let conversation {
                        Button(conversation.title) { state.showConversation(conversation.id) }
                            .buttonStyle(.daybookLink).font(TypeStyle.status)
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
