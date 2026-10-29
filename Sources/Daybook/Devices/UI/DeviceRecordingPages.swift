import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

// MARK: - A recording that isn't in Daybook yet

struct RecordingPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    let recordings: [DeviceRecording]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DevicePageScroll {
            if recordings.count == 1, let recording = recordings.first { single(recording) } else { several }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: session.queue.ids)
    }

    private var connected: Bool { session.primary?.state.isConnected == true }
    private var canImport: Bool { session.importsHere && (connected || session.primary?.isSetUp == true) }

    @ViewBuilder private func single(_ recording: DeviceRecording) -> some View {
        let queue = session.queue
        DevicePageTitle(title: recording.title) { recordingGlyph(queue.contains(recording.id)) }
        Text(byline(recording)).font(TypeStyle.byline()).foregroundStyle(Ink.secondary).padding(.top, 6)

        if queue.current?.id == recording.id {
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack {
                    Text((session.phase ?? .preparing).label).font(TypeStyle.statusLead).monospacedDigit()
                        .foregroundStyle(Ink.body)
                        .contentTransition(.numericText())
                    Spacer()
                    Button("Stop Importing") { session.requestStop(all: false) }
                        .buttonStyle(.daybookLink).font(TypeStyle.status)
                }
                // Until the transfer reports a fraction, the bar waits empty under "Preparing…".
                ProgressView(value: session.phase?.fraction ?? 0)
                    .progressViewStyle(.brand(width: nil))
            }
            .padding(.top, Space.s5)
            .transition(.opacity)
        } else if queue.isWaiting(recording.id) {
            HStack(spacing: Space.s3) {
                Label(queue.isSuspended ? "Waiting for your \(session.kind.shortName)" : "Waiting to import", systemImage: "arrow.down.circle.dotted")
                    .font(TypeStyle.status).foregroundStyle(Ink.secondary)
                Button("Remove from Queue") { session.removeFromQueue(recording.id) }
                    .buttonStyle(.daybookLink).font(TypeStyle.status)
            }
            .padding(.top, Space.s5)
        } else {
            if canImport {
                HStack(spacing: Space.s3) {
                    Button { session.importRecordings([recording]) } label: { Label("Import", systemImage: "arrow.down.circle") }
                        .buttonStyle(.borderedProminent)
                        .tint(DaybookStyle.prominentFill)
                    ImportAndAddMenu(session: session, recordings: [recording])
                        .fixedSize()
                }
                .controlSize(.large)
                .padding(.top, Space.s5)
            }
            if let failure = session.failures.first(where: { $0.id == recording.id }) {
                Label {
                    Text(failure.message).foregroundStyle(Ink.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.warning)
                }
                .font(TypeStyle.status)
                .padding(.top, Space.s3)
            }
        }

        if canImport, !queue.contains(recording.id) {
            ForEach(session.overlaps(recording)) { overlap in
                DeviceAttentionBox(symbol: "link", title: "Overlaps “\(overlap.title)”", message: "Recorded on this Mac \(overlap.span)") {
                    Button("Add to “\(overlap.title)”") { session.importRecordings([recording], attachTo: overlap.meetingID) }
                }
            }
        }
    }

    @ViewBuilder private var several: some View {
        let total = recordings.compactMap(\.length).reduce(0) { $0 + $1.seconds }
        let estimated = recordings.contains { $0.length?.isEstimate ?? true }
        DevicePageTitle(title: "\(recordings.count) Recordings Selected") { recordingGlyph(false) }
        Text("\(total > 0 ? "\(estimated ? "About " : "")\(DurationLabel.format(total)) in all · " : "")\(location) · Not in Daybook yet")
            .font(TypeStyle.byline()).foregroundStyle(Ink.secondary).padding(.top, 6)
        if canImport {
            HStack(spacing: Space.s3) {
                Button { session.importRecordings(recordings) } label: {
                    Label("Import \(recordings.count) Recordings", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(DaybookStyle.prominentFill)
                ImportAndAddMenu(session: session, recordings: recordings).fixedSize()
            }
            .controlSize(.large)
            .padding(.top, Space.s5)
        }
    }

    private func recordingGlyph(_ queued: Bool) -> some View {
        Image(systemName: queued ? "arrow.down.circle.fill" : "arrow.down.circle")
            .font(.system(size: 22))
            .foregroundStyle(Ink.secondary)
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

// MARK: - Recording now, and Listen Live

struct LivePage: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    @ObservedObject var connection: SoundcoreConnection
    @ObservedObject var live: LiveCapture
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DevicePageScroll {
            DevicePageTitle(title: "Recording on \(session.kind.shortName)") {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Ink.record)
                    .symbolEffect(.breathe, isActive: !reduceMotion)
                    .accessibilityHidden(true)
            }
            byline.padding(.top, 6)
            // Handed over mid-recording: the conversation it goes into once it's finished.
            if let id = session.split.inProgress?.id, let waiting = session.conversationWaiting(for: id),
               let meeting = state.meetings.first(where: { $0.id == waiting }) {
                Text("For \(meeting.title)").font(TypeStyle.status).foregroundStyle(Ink.secondary).padding(.top, Space.s2)
            }
            if let problem = session.problem {
                DeviceProblemBanner(problem: problem, perform: { DeviceActions.perform($0, session: session, state: state) },
                                    hidden: DeviceActions.inapplicable(for: session))
            }

            if live.isListening {
                listening
            } else {
                Button { connection.startListening() } label: { Label("Listen Live", systemImage: "waveform") }
                    .buttonStyle(.borderedProminent)
                    .tint(DaybookStyle.prominentFill)
                    .controlSize(.large)
                    .disabled(connection.info?.isRecording != true || session.queue.current != nil)
                    .padding(.top, Space.s5)
                if session.queue.current != nil {
                    Text("Available when the import finishes.").font(TypeStyle.status).foregroundStyle(Ink.secondary).padding(.top, Space.s2)
                }
                LiveSavedNotice(state: state, session: session, live: live)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: live.isListening)
    }

    @ViewBuilder private var listening: some View {
        HStack(alignment: .center, spacing: Space.s3) {
            Image(systemName: "waveform")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(DaybookStyle.neonCyan)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: !reduceMotion)
                .neonGlow(DaybookStyle.neonCyan, radius: 4)
                // The captions' label below keeps its glyph in the same column, so the words line up.
                .frame(width: LiveCaptionFeed.glyphColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Listening").font(TypeStyle.statusLead).foregroundStyle(Ink.body)
                Text("\(TimeLabel.short(live.receivedSeconds)) saved")
                    .font(TypeStyle.status).foregroundStyle(Ink.secondary).monospacedDigit()
            }
            Spacer()
            Button("Stop Listening") { connection.stopListening() }
        }
        .padding(.top, Space.s5)

        // The session's live captions, as the iPhone shows them too.
        LiveCaptionFeed(segments: session.liveCaptions, state: live.captionState, locale: state.captionSettings.locale)
            .padding(.top, Space.s5)

        Text("Stopping here doesn’t stop your \(session.kind.shortName) recording.")
            .font(TypeStyle.colophon).foregroundStyle(Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Space.s5)
    }

    @ViewBuilder private var byline: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Ink.record).accessibilityHidden(true)
            if let start = session.split.inProgress?.startedAt {
                (Text("Started \(start.formatted(date: .omitted, time: .shortened)) · ")
                 + Text(timerInterval: start...Date.distantFuture, countsDown: false)
                 + Text(" so far"))
            } else {
                Text("Recording")
            }
        }
        .font(TypeStyle.byline()).foregroundStyle(Ink.secondary)
    }
}

/// "Saved 12 minutes as a new conversation…", after Stop Listening.
struct LiveSavedNotice: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    @ObservedObject var live: LiveCapture

    var body: some View {
        if let saved = live.saved, !live.isListening {
            let meetingID = session.links.partial[saved.recordingID] ?? session.links.imported[saved.recordingID]
            DeviceNotice(symbol: "checkmark.circle.fill",
                         text: "Saved \(DurationLabel.format(saved.seconds)) as a new conversation",
                         action: meetingID.map { id in ("Show Conversation", { state.showConversation(id) }) },
                         dismiss: { live.saved = nil })
        }
    }
}

// MARK: - Choose Conversation…

/// Conversations from the same day, give or take one, to add a device recording to.
struct ConversationChooser: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    let recordings: [DeviceRecording]
    @State private var search = ""
    @State private var selection: UUID?
    @Environment(\.dismiss) private var dismiss

    private var candidates: [Meeting] {
        let calendar = Calendar.current
        let days = recordings.compactMap(\.sortDate).map { calendar.startOfDay(for: $0) }
        let query = search.trimmingCharacters(in: .whitespaces)
        return state.meetings.filter { meeting in
            let day = calendar.startOfDay(for: meeting.date)
            let near = days.isEmpty || days.contains { abs(calendar.dateComponents([.day], from: $0, to: day).day ?? 99) <= 1 }
            return near && (query.isEmpty || meeting.title.localizedCaseInsensitiveContains(query))
        }
        .sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Add to a Conversation").font(.headline)
            TextField("Search Conversations", text: $search).textFieldStyle(.roundedBorder)
            List(candidates, selection: $selection) { meeting in
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(TypeStyle.rowTitle)
                    Text(meeting.date.formatted(date: .abbreviated, time: .shortened)).font(TypeStyle.rowDetail).foregroundStyle(.secondary)
                }
                .tag(meeting.id)
            }
            .frame(height: 220)
            .overlay {
                if candidates.isEmpty { Text("No conversations from around that day.").foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import and Add") {
                    if let selection { session.importRecordings(recordings, attachTo: selection) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(Space.s5)
        .frame(width: 440)
    }
}
