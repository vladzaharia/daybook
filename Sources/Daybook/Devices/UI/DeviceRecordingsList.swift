import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

/// List column for a device: the recording in progress, the import queue, new recordings, and
/// recordings already in Daybook (collapsed). Its rows come from the device's primary method.
struct DeviceRecordingsList: View {
    @ObservedObject var state: AppState
    var body: some View {
        if let session = state.selectedDevice {
            DeviceRecordingsListContent(state: state, session: session, browser: session.browser)
                .id(session.id)
                .navigationTitle(session.device.name)
                .navigationSubtitle(session.subtitle)
        } else {
            Color.clear.navigationTitle("Devices")
        }
    }
}

private struct DeviceRecordingsListContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    @ObservedObject var browser: DeviceBrowser
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let split = session.split
        // An empty list keeps the column's own background; the empty state sits over it.
        list(split)
            .overlay { if let empty = emptyState(split) { empty } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: session.queue.ids)
        .onAppear { session.primary?.refreshIfStale() }
        .onDisappear { browser.selection = [] }
    }

    /// Daybook on iPhone: its recordings arrive through sync, so there's nothing to import.
    private var isPhone: Bool { session.kind.id == DaybookPhoneIntegration.id }

    // MARK: Empty states

    private func emptyState(_ split: DeviceRecordingSplit) -> AnyView? {
        let hasRows = !split.new.isEmpty || !split.imported.isEmpty || session.queue.isActive || split.inProgress != nil
        guard !hasRows, let primary = session.primary else { return nil }
        let kind = session.kind
        func unavailable(_ title: String, _ symbol: String, _ text: String?, animated: Bool = false, quiet: Bool = false,
                         action: (title: String, run: () -> Void)? = nil) -> AnyView {
            AnyView(ContentUnavailableView {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: symbol)
                        .foregroundStyle(quiet ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(DaybookStyle.brandGradient))
                        .symbolEffect(.variableColor.iterative, isActive: animated && !reduceMotion)
                }
            } description: {
                if let text { Text(text) }
            } actions: {
                if let action { Button(action.title, action: action.run) }
            })
        }
        switch primary.state {
        case .notSetUp:
            return unavailable("Not Set Up", kind.systemImage, nil,
                               action: ("Set Up…", { state.requestAddDevice(kind: kind.id) }))
        case .searching:
            return unavailable("Looking for \(kind.name)…", "dot.radiowaves.left.and.right", nil, animated: true)
        case .connecting, .reconnecting:
            return unavailable(primary.state == .reconnecting ? "Reconnecting…" : "Connecting…", "dot.radiowaves.left.and.right", nil, animated: true)
        case .unavailable:
            // The page's banner explains; the list only says why it's empty.
            if isPhone { return unavailable("Sync Is Off", "icloud.slash", nil, quiet: true) }
            return primary.method == .files
                ? unavailable("Not Watching", "folder.badge.questionmark", nil, quiet: true)
                : unavailable("Not Connected", "antenna.radiowaves.left.and.right.slash", nil, quiet: true)
        case .notConnected:
            if primary.method == .files {
                return unavailable("Not Watching", "folder", nil,
                                   action: ("Watch Folder", { primary.connect() }))
            }
            return unavailable("Not Connected", "antenna.radiowaves.left.and.right.slash",
                               "Take your \(kind.shortName) out of its case to wake it.", action: ("Connect", { session.connect() }))
        case .connected:
            if primary.isRefreshing || primary.inventoryUpdatedAt == nil {
                return AnyView(ContentUnavailableView {
                    Label { Text("Checking for Recordings…") } icon: { ProgressView().controlSize(.small) }
                })
            }
            if primary.method == .files, !isPhone {
                let folder = (primary as? ImportFolderWatcher)?.folderDisplayName ?? "the folder"
                return unavailable("Watching for Audio", "folder.badge.gearshape", "New audio saved to \(folder) becomes a conversation.")
            }
            return unavailable("No Recordings on Your \(kind.shortName)", kind.systemImage, kind.emptyHint)
        }
    }

    // MARK: The list

    private func list(_ split: DeviceRecordingSplit) -> some View {
        let queue = session.queue
        let new = split.new.filter { !queue.contains($0.id) }
        let selectedNew = new.filter { browser.selection.contains(.recording($0.id)) }
        let canImport = session.primary?.state.isConnected == true || session.primary?.isSetUp == true
        let fromFolder = session.primary?.method == .files
        return List(selection: $browser.selection) {
            if let recording = split.inProgress {
                Section {
                    RecordingNowRow(recording: recording, listening: listening)
                        .tag(DeviceBrowser.Row.recordingNow)
                }
            }
            if queue.isActive {
                Section {
                    if let current = queue.current {
                        ImportingRow(recording: current.recording, phase: session.phase ?? .preparing)
                            .tag(DeviceBrowser.Row.recording(current.id))
                    }
                    ForEach(queue.waiting) { item in
                        WaitingRow(recording: item.recording, suspended: queue.isSuspended, deviceName: session.kind.shortName)
                            .tag(DeviceBrowser.Row.recording(item.id))
                    }
                } header: {
                    HStack {
                        Text(queue.isSuspended ? "Waiting to Reconnect" : "Importing")
                        Spacer()
                        Button("Stop") { session.requestStop(all: true) }
                            .buttonStyle(.daybookLink)
                    }
                }
            }
            if !new.isEmpty {
                Section {
                    ForEach(new) { recording in
                        NewRecordingRow(recording: recording, overlap: session.overlapHint(recording),
                                        stale: session.primary?.state.isConnected != true,
                                        failure: session.failures.first { $0.id == recording.id }?.message)
                            .tag(DeviceBrowser.Row.recording(recording.id))
                    }
                } header: {
                    HStack {
                        Text(fromFolder ? "Not in Daybook" : "New on \(session.kind.shortName)")
                        Spacer()
                        if canImport {
                            Button(selectedNew.count > 1 ? "Import Selected (\(selectedNew.count))" : "Import All") {
                                session.importRecordings(selectedNew.count > 1 ? selectedNew : new)
                            }
                            .buttonStyle(.daybookLink)
                        } else if let updated = session.primary?.inventoryUpdatedAt {
                            Text("As of \(updated.formatted(date: .omitted, time: .shortened))")
                        }
                    }
                }
            } else if session.primary?.state.isConnected == true, !queue.isActive, session.primary?.inventoryUpdatedAt != nil,
                      !split.imported.isEmpty, !isPhone {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                        Image(systemName: "checkmark.circle").foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
                        Text("You’re All Caught Up").font(TypeStyle.rowTitle)
                    }
                    .padding(.vertical, 6)
                    .selectionDisabled()
                }
            }
            if !split.imported.isEmpty, isPhone {
                // Everything from the phone is in the library already: its recordings are the list.
                Section("Recordings") {
                    ForEach(split.imported) { item in
                        ImportedRow(recording: item.recording, meeting: state.meetings.first { $0.id == item.meetingID },
                                    processing: state.deviceProcessingLabel(item.meetingID))
                            .tag(DeviceBrowser.Row.recording(item.id))
                    }
                }
            } else if !split.imported.isEmpty {
                Section {
                    if browser.showsImported {
                        ForEach(split.imported) { item in
                            ImportedRow(recording: item.recording, meeting: state.meetings.first { $0.id == item.meetingID },
                                        processing: state.deviceProcessingLabel(item.meetingID))
                                .tag(DeviceBrowser.Row.recording(item.id))
                        }
                    }
                } header: {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { browser.showsImported.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(browser.showsImported ? 90 : 0))
                            Text("Already in Daybook")
                            Text("\(split.imported.count)").foregroundStyle(.secondary).monospacedDigit()
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Already in Daybook, \(split.imported.count) recordings")
                    .accessibilityHint(browser.showsImported ? "Collapses the list" : "Expands the list")
                }
            }
        }
        .contextMenu(forSelectionType: DeviceBrowser.Row.self) { rows in
            DeviceRowMenu(state: state, session: session, rows: rows)
        } primaryAction: { rows in
            guard rows.count == 1, let id = rows.first?.recordingID, let meetingID = session.links.imported[id] else { return }
            state.showConversation(meetingID)
        }
        .onExitCommand { browser.selection = [] }
    }

    private var listening: Bool { (session.primary as? any LiveListeningConnection)?.live.isListening == true }
}

// MARK: - Rows

private struct RowLayout<Glyph: View, Content: View>: View {
    @ViewBuilder var glyph: Glyph
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            glyph.frame(width: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}

private struct NewRecordingRow: View {
    let recording: DeviceRecording
    let overlap: DeviceOverlap?
    let stale: Bool
    let failure: String?

    var body: some View {
        RowLayout {
            Image(systemName: failure == nil ? "arrow.down.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ink.warning))
        } content: {
            Text(recording.title).font(TypeStyle.rowTitle).monospacedDigit().lineLimit(1).truncationMode(.middle)
            Text(failure ?? recording.detail).font(TypeStyle.rowDetail).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            if let overlap {
                Label { Text("Overlaps “\(overlap.title)”").lineLimit(1) } icon: { Image(systemName: "link") }
                    .font(TypeStyle.rowDetail).foregroundStyle(.secondary)
                    .labelStyle(DeviceInlineLabelStyle())
            }
        }
        .opacity(stale ? 0.65 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(recording.title), \(recording.length?.inlineLabel ?? recording.detail), not in Daybook yet"
                            + (overlap.map { ", overlaps \($0.title)" } ?? "") + (failure.map { ", \($0)" } ?? ""))
    }
}

private struct ImportingRow: View {
    let recording: DeviceRecording
    let phase: TransferPhase
    var body: some View {
        RowLayout {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(DaybookStyle.accent)
                .symbolEffect(.pulse, isActive: phase == .preparing)
        } content: {
            HStack(alignment: .firstTextBaseline) {
                Text(recording.title).font(TypeStyle.rowTitle).monospacedDigit().lineLimit(1)
                Spacer()
                Text(phase.label).font(TypeStyle.rowDetail).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.numericText())
            }
            // The brand gradient bar, as for all progress; it waits empty until the transfer reports a fraction.
            ProgressView(value: phase.fraction ?? 0)
                .progressViewStyle(.brand(width: nil))
                .padding(.top, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(recording.title), importing, \(phase.label)")
        .accessibilityValue(phase.fraction.map { "\(Int($0 * 100)) percent" } ?? "")
    }
}

private struct WaitingRow: View {
    let recording: DeviceRecording
    let suspended: Bool
    let deviceName: String
    var body: some View {
        RowLayout {
            Image(systemName: "arrow.down.circle.dotted").foregroundStyle(.secondary)
        } content: {
            Text(recording.title).font(TypeStyle.rowTitle).monospacedDigit().lineLimit(1)
            Text(suspended ? "Waiting for \(deviceName)" : "Waiting").font(TypeStyle.rowDetail).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ImportedRow: View {
    let recording: DeviceRecording
    let meeting: Meeting?
    let processing: String?
    var body: some View {
        RowLayout {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
        } content: {
            Text(meeting?.title ?? recording.title).font(TypeStyle.rowTitle).lineLimit(1)
            Text(([recording.title, recording.length?.label].compactMap { $0 } + (processing.map { [$0] } ?? [])).joined(separator: " · "))
                .font(TypeStyle.rowDetail).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RecordingNowRow: View {
    let recording: DeviceRecording
    let listening: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        RowLayout {
            Image(systemName: "record.circle.fill")
                .symbolRenderingMode(.hierarchical).foregroundStyle(Ink.record)
                .symbolEffect(.breathe, isActive: !reduceMotion)
        } content: {
            Text("Recording Now").font(TypeStyle.rowTitle)
            HStack(spacing: 4) {
                if let start = recording.startedAt { Text("Started \(start.formatted(date: .omitted, time: .shortened))") }
                if listening {
                    Text("·")
                    Image(systemName: "waveform").foregroundStyle(DaybookStyle.neonCyan)
                        .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                    Text("Listening")
                }
            }
            .font(TypeStyle.rowDetail).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Context menu

private struct DeviceRowMenu: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    let rows: Set<DeviceBrowser.Row>

    var body: some View {
        let links = session.links
        let ids = rows.compactMap(\.recordingID)
        let all = session.primary?.recordings ?? []
        let recordings = all.filter { ids.contains($0.id) }
        let imported = recordings.filter { links.imported[$0.id] != nil }
        let fresh = recordings.filter { links.imported[$0.id] == nil && !session.queue.contains($0.id) }
        if rows.contains(.recordingNow) {
            if let live = session.primary as? any LiveListeningConnection {
                Button(live.live.isListening ? "Stop Listening" : "Listen Live") {
                    if live.live.isListening { live.stopListening() } else { session.browser.selection = [.recordingNow]; live.startListening() }
                }
                .disabled(session.queue.current != nil)
            }
        } else if let current = session.queue.current, ids == [current.id] {
            Button("Stop Importing") { session.requestStop(all: false) }
        } else if !ids.isEmpty, ids.allSatisfy({ session.queue.isWaiting($0) }) {
            Button("Remove from Queue") { ids.forEach(session.removeFromQueue) }
        } else if !fresh.isEmpty, imported.isEmpty {
            Button(fresh.count > 1 ? "Import \(fresh.count) Recordings" : "Import") { session.importRecordings(fresh) }
            ImportAndAddMenu(session: session, recordings: fresh)
        } else if imported.count == 1, let recording = imported.first, let meetingID = links.imported[recording.id] {
            Button("Show Conversation") { state.showConversation(meetingID) }
            Button("Import Again as New Conversation") { session.importRecordings([recording]) }
                .disabled(session.queue.contains(recording.id))
            Button("Show Audio File in Finder") { DeviceActions.revealAudio(state: state, meetingID: meetingID, recordingID: recording.id) }
        }
    }
}

/// Import and Add to: overlapping conversations first, then Choose Conversation….
struct ImportAndAddMenu: View {
    @ObservedObject var session: DeviceSession
    let recordings: [DeviceRecording]

    var body: some View {
        Menu("Import and Add to…") {
            let overlaps = recordings.count == 1 ? session.overlaps(recordings[0]) : []
            ForEach(overlaps) { overlap in
                Button("“\(overlap.title)”") { session.importRecordings(recordings, attachTo: overlap.meetingID) }
            }
            if !overlaps.isEmpty { Divider() }
            Button("Choose Conversation…") { session.browser.choosingConversation = .init(recordings: recordings) }
        }
    }
}
