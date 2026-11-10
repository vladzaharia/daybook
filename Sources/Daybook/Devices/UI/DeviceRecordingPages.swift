import AppKit
import DaybookCore
import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI

// MARK: - A recording that isn't in Daybook yet

/// The Mac's page for recordings selected in the device's list: what they are and where, the import under way or
/// waiting, Import with Add to… (the list's own actions, `DeviceRecordingActions`), and, for one recording made at
/// the same time as a conversation, adding it there.
struct RecordingPage: View {
    let state: AppState
    let session: DeviceSession
    let recordings: [DeviceRecording]
    @Environment(\.recorderServices) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DevicePageScroll {
            if recordings.count == 1, let recording = recordings.first { single(recording) } else { several }
        }
        .animation(reduceMotion ? nil : DaybookMotion.fade, value: session.queue.ids)
    }

    private var connected: Bool { session.primary?.state.isConnected == true }
    private var canImport: Bool { session.importsHere && (connected || session.primary?.isSetUp == true) }

    @ViewBuilder private func single(_ recording: DeviceRecording) -> some View {
        let queue = session.queue
        DevicePageTitle(title: recording.title) { recordingGlyph(queue.contains(recording.id)) }
        Text(byline(recording)).font(DaybookFont.byline.font(.window)).foregroundStyle(DaybookPalette.Ink.secondary).padding(.top, 6)

        if queue.current?.id == recording.id {
            VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                HStack {
                    Text((session.phase ?? .preparing).label).font(DaybookFont.statusLead.font(.window)).monospacedDigit()
                        .foregroundStyle(DaybookPalette.Ink.body)
                        .contentTransition(.numericText())
                    Spacer()
                    Button("Stop Importing") { session.requestStop(all: false) }
                        .buttonStyle(.daybookLink).font(DaybookFont.status.font(.window))
                }
                // Until the transfer reports a fraction, the bar waits empty under "Preparing…".
                ProgressView(value: session.phase?.fraction ?? 0)
                    .progressViewStyle(.brand(width: nil))
            }
            .padding(.top, DaybookSpacing.s5)
            .transition(.opacity)
        } else if queue.isWaiting(recording.id) {
            HStack(spacing: DaybookSpacing.s3) {
                Label(queue.isSuspended ? "Waiting for your \(session.kind.shortName)" : "Waiting to import", systemImage: "arrow.down.circle.dotted")
                    .font(DaybookFont.status.font(.window)).foregroundStyle(DaybookPalette.Ink.secondary)
                Button("Remove from Queue") { session.removeFromQueue(recording.id) }
                    .buttonStyle(.daybookLink).font(DaybookFont.status.font(.window))
            }
            .padding(.top, DaybookSpacing.s5)
        } else {
            if canImport { importButtons([recording], title: "Import") }
            if let failure = session.failures.first(where: { $0.id == recording.id }) {
                Label {
                    Text(failure.message).foregroundStyle(DaybookPalette.Ink.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DaybookPalette.Ink.warning)
                }
                .font(DaybookFont.status.font(.window))
                .padding(.top, DaybookSpacing.s3)
            }
        }

        if canImport, !queue.contains(recording.id) {
            ForEach(session.overlaps(recording)) { overlap in
                AttentionBox(kind: .info, title: "Overlaps “\(overlap.title)”", symbol: "link", message: "Recorded on this Mac \(overlap.span)",
                             primary: AttentionAction("Add to “\(overlap.title)”") { session.importRecordings([recording], attachTo: overlap.meetingID) })
                    .padding(.top, DaybookSpacing.s4)
            }
        }
    }

    @ViewBuilder private var several: some View {
        let total = recordings.compactMap(\.length).reduce(0) { $0 + $1.seconds }
        let estimated = recordings.contains { $0.length?.isEstimate ?? true }
        DevicePageTitle(title: "\(recordings.count) Recordings Selected") { recordingGlyph(false) }
        Text("\(total > 0 ? "\(estimated ? "About " : "")\(DurationLabel.format(total)) in all · " : "")\(location) · Not in Daybook yet")
            .font(DaybookFont.byline.font(.window)).foregroundStyle(DaybookPalette.Ink.secondary).padding(.top, 6)
        if canImport { importButtons(recordings, title: "Import \(recordings.count) Recordings") }
    }

    /// Import, the page's one action, and Add to… for the conversations it could join instead.
    private func importButtons(_ recordings: [DeviceRecording], title: String) -> some View {
        HStack(spacing: DaybookSpacing.s3) {
            Button { session.importRecordings(recordings) } label: { Label(title, systemImage: "arrow.down.circle") }
                .buttonStyle(.borderedProminent)
                .tint(DaybookPalette.prominentFill)
            AddToMenu(session: session, recordings: recordings).fixedSize()
        }
        .controlSize(.large)
        .padding(.top, DaybookSpacing.s5)
    }

    private func recordingGlyph(_ queued: Bool) -> some View {
        Image(systemName: queued ? "arrow.down.circle.fill" : "arrow.down.circle")
            .font(.system(size: 22))
            .foregroundStyle(DaybookPalette.Ink.secondary)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }

    private var location: String {
        session.primary?.method == .files ? "In the import folder" : "On your \(session.kind.shortName)"
    }

    private func byline(_ recording: DeviceRecording) -> String {
        var parts = [recording.length?.label ?? recording.detail, location]
        if session.queue.current?.id == recording.id { parts.append("Importing") }
        else if session.queue.isWaiting(recording.id) { parts.append("Waiting to import") }
        else { parts.append("Not in Daybook yet") }
        if !connected, session.primary?.method == .direct, let updated = session.primary?.inventoryUpdatedAt {
            parts.append("as of \(updated.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }
}

/// Add to…: the conversations recorded at the same time, then Choose Conversation…, as the list offers them.
private struct AddToMenu: View {
    let session: DeviceSession
    let recordings: [DeviceRecording]
    @Environment(\.recorderServices) private var services

    var body: some View {
        let actions = DeviceRecordingActions.available(Set(recordings.map { .recording($0.id) }), in: session, revealsAudio: false)
            .filter { action in
                if case .addTo = action { return true }
                return action == .chooseConversation
            }
        Menu("Add to…") {
            ForEach(actions, id: \.self) { action in
                if action == .chooseConversation, actions.count > 1 { Divider() }
                Button(title(action)) {
                    DeviceRecordingActions.perform(action, recordings: recordings, session: session, services: services) { chosen in
                        session.browser.choosingConversation = .init(recordings: chosen)
                    }
                }
            }
        }
    }

    /// Under Add to…, a conversation is just its title.
    private func title(_ action: DeviceRecordingAction) -> String {
        if case .addTo(_, let title) = action { return "“\(title)”" }
        return action.title
    }
}
