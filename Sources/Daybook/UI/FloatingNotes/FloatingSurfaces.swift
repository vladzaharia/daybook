import AppKit
import DaybookCaptions
import DaybookCore
import DaybookDesign
import DaybookDevices
import DaybookKit
import DaybookUI
import SwiftUI

// The panel's three surfaces (docs/interface.md, "Floating Notes"). While recording and after Stop it's the
// recorder both apps share (DaybookUI's `RecorderSurface` and `RecorderAfterStop`), filled from AppState; with
// nothing recording, a small home in the language of the iPhone's status sheet. Each is full or compact by the
// panel's height.

// MARK: - Recording

/// While recording: the title, the red clock beside a meter for each source, your notes with their times and
/// bookmarks, live captions, and large Bookmark and Stop. What else records this conversation is in the chips, at
/// every size. Compact: the clock and meters, a line for a note, one caption line, and the controls.
struct FloatingRecording: View {
    let context: PanelContext
    let meeting: Meeting
    let inputs: FloatingStatusInputs
    let levels: RecorderLevels
    let captionsShowing: Bool

    private var state: AppState { context.state }

    var body: some View {
        RecorderSurface(state: surfaceState, levels: levels, actions: actions, slots: slots)
            .environment(\.surfaceLayout, context.compact ? .compact : .column)
            .daybookMotion(DaybookMotion.state, value: captionsShowing)
    }

    private var surfaceState: RecorderSurfaceState {
        RecorderSurfaceState(
            title: meeting.title,
            rename: { [state, id = meeting.id] title in state.update(id) { $0.title = title } },
            chips: context.chips,
            meters: FloatingStatus.meters(inputs),
            clock: .since(state.recordingStartedAt ?? Date()),
            isLive: inputs.phase == .recording,
            bookmarkCount: meeting.highlights.filter { $0.trackID == nil }.count,
            canBookmark: !state.isStoppingRecording,
            isSaving: state.isStoppingRecording,
            topInset: context.band,
            keyboardShortcuts: true)
    }

    private var actions: RecorderSurfaceActions {
        let state = self.state, id = meeting.id
        return RecorderSurfaceActions(
            bookmark: { state.addHighlight(id) },
            stop: { Task { await state.stopRecording() } },
            addNote: { line in
                guard let notes = state.meetings.first(where: { $0.id == id })?.notes else { return }
                state.editNotes(id, text: RecorderNoteField.appending(line, to: notes))
            })
    }

    private var slots: RecorderSlots {
        RecorderSlots(
            notes: AnyView(PanelNotes(state: state, meeting: meeting, isRecording: true, showsLane: true)),
            captions: AnyView(Group {
                if captionsShowing {
                    PanelCaptions(captions: state.captions, compact: context.compact)
                        .padding(.top, context.compact ? 0 : 6)
                        .transition(.opacity)
                }
            }),
            menu: { [context] chip in AnyView(ChipMenuItems(context: context, chip: chip)) })
    }
}

/// The live captions under the notes: the newest lines, You or Call in the time lane. Observes the
/// captions directly, so it alone redraws as words arrive.
private struct PanelCaptions: View {
    let captions: LiveCaptionsController
    let compact: Bool

    var body: some View {
        let segments = captions.state == .listening ? captions.recent(compact ? 1 : 2) : []
        LiveCaptionStrip(lines: segments.map { LiveCaptionLabels.line($0, names: captions.sourceNames) },
                         status: LiveCaptionStatus.line(captions.state, locale: captions.locale),
                         style: compact ? .panelCompact : .panel)
            .padding(.leading, FloatingLayout.inset)
            .padding(.trailing, FloatingLayout.inset)
            // A fixed height, so the notes never move as words arrive.
            .frame(height: compact ? 18 : 74, alignment: .top)
            .clipped()
    }
}

// MARK: - After Stop

/// After a Stop seen in the panel: the conversation and your notes; the chips say what's becoming of it. Open is
/// where Bookmark was, and Record where Stop was, for the next call. A recording that stopped short says why, with
/// Record Again into the same conversation.
struct FloatingAfterStop: View {
    let context: PanelContext
    let meeting: Meeting
    let inputs: FloatingStatusInputs

    private var state: AppState { context.state }
    private var stoppedShort: Bool { inputs.phase == .stopped }

    var body: some View {
        RecorderAfterStop(state: afterState, actions: actions,
                          notes: AnyView(PanelNotes(state: state, meeting: meeting, isRecording: false, showsLane: true)),
                          menu: { [context] chip in AnyView(ChipMenuItems(context: context, chip: chip)) })
            .environment(\.surfaceLayout, context.compact ? .compact : .column)
    }

    private var afterState: RecorderAfterStopState {
        RecorderAfterStopState(
            title: meeting.title,
            rename: { [state, id = meeting.id] title in state.update(id) { $0.title = title } },
            chips: context.chips,
            // The band says "Saved · 18 min", so the line under the title leaves the length out.
            meta: PanelMeta.text(meeting, showsDuration: inputs.phase != .saved),
            problem: problem,
            openTitle: meeting.summary != nil ? "Open Summary" : "Open",
            recordTitle: stoppedShort ? "Record Again" : "Record",
            canRecord: state.isReady && !state.isStoppingRecording && !state.isRecording,
            isStartingRecording: state.isStartingRecording,
            topInset: context.band,
            keyboardShortcuts: true)
    }

    private var actions: RecorderAfterStopActions {
        let state = self.state, id = meeting.id, again = stoppedShort
        return RecorderAfterStopActions(
            open: context.open,
            record: { Task { again ? await state.recordAgain(into: id) : await state.startRecording() } },
            metaLink: (title: "Recent", help: "Show recent conversations", action: context.goHome))
    }

    private var problem: RecorderProblem? {
        if stoppedShort {
            // Why it stopped, when the recorder knows; the system's words stay in the tooltip.
            return RecorderProblem(title: "Recording stopped", message: FloatingStatus.stoppedMessage(state.unexpectedStops[meeting.id]),
                                   help: meeting.errorMessage)
        }
        guard case .failed(let words)? = inputs.work else { return nil }
        let failure: ProcessingStatus.Failure? = { if case .failed(let failure) = state.processingStatus(for: meeting) { return failure }; return nil }()
        // A recording with no speech in it can't do better a second time.
        let retries = failure?.kind != .noSpeech
        return RecorderProblem(title: words.title, message: words.message, help: failure?.reason,
                               actionTitle: retries ? "Try Again" : nil,
                               actionEnabled: !state.queuedIDs.contains(meeting.id) && state.processingID != meeting.id,
                               action: retries ? { [state, meeting] in state.enqueue(meeting.id, mode: state.defaultProcessingMode(for: meeting)) } : nil)
    }
}

extension AppState {
    /// Record Again after a recording stopped short: into the same conversation, after what was saved. The
    /// processing its first part queued waits for the whole.
    func recordAgain(into id: UUID) async {
        if processingID == id { pauseProcessing(id) } else if queuedIDs.contains(id) { cancelQueued(id) }
        // A job that was running lets go of the conversation once its work notices.
        for _ in 0..<40 where processingID == id { try? await Task.sleep(for: .milliseconds(50)) }
        // The first part is still being added: its capture holds the conversation's folder until it's in the library.
        let session = storageURL.appendingPathComponent("Staging").appendingPathComponent(id.uuidString)
            .appendingPathComponent("capture-session.json").path
        for _ in 0..<60 where FileManager.default.fileExists(atPath: session) { try? await Task.sleep(for: .milliseconds(50)) }
        // One that couldn't be added is kept there for recovery: record anew rather than fail.
        let held = FileManager.default.fileExists(atPath: session)
        dismissUnexpectedStop(id)
        await startRecording(into: held ? nil : id)
    }
}

// MARK: - Home

/// Nothing recording: the iPhone's status sheet, floating. Status lines (recorders, iPhones, this
/// Mac's queue), then recent conversations, or the focused conversation's notes; Record and Import
/// at the foot. Compact: the status bar and Record and Import.
struct HomeSurface: View {
    let context: PanelContext
    let focused: Meeting?
    let inputs: FloatingStatusInputs

    private var state: AppState { context.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if context.compact {
                if let focused {
                    VStack(alignment: .leading, spacing: 3) {
                        PanelTitle(state: state, meeting: focused)
                        PanelMetaLine(meeting: focused, goHome: context.goHome)
                    }
                    .padding(.horizontal, FloatingLayout.inset)
                    .padding(.top, context.band + 4)
                } else {
                    // The newest conversation, a click from Daybook; the band carries the status.
                    RecentConversations(context: context, limit: 1, showsHeading: false)
                        .padding(.top, context.band + 2)
                }
                Spacer(minLength: 0)
            } else {
                // The status lines take the chips' room under the band.
                let lines = FloatingStatus.lines(inputs)
                if !lines.isEmpty {
                    // A countdown moves a second at a time; otherwise the lines' recency ("Last seen") every half minute.
                    TimelineView(.periodic(from: .now, by: lines.contains { $0.countdownUntil != nil } ? 1 : 30)) { timeline in
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(FloatingStatus.lines(inputs, now: timeline.date)) { line in
                                let item = FloatingStatus.item(line, at: timeline.date)
                                // A countdown's digits roll down as they change.
                                StatusLineButton(context: context, line: item)
                                    .daybookMotion(DaybookMotion.tick, value: line.countdownUntil == nil ? "" : item.text)
                            }
                        }
                        .padding(.horizontal, FloatingLayout.inset)
                        .padding(.bottom, 14)
                    }
                    .padding(.top, context.band + FloatingLayout.chipsTop)
                }
                if let focused {
                    // The conversation, under the device lines: its status chip sits over its title, as after Stop.
                    if !lines.isEmpty { RecorderRule().padding(.horizontal, FloatingLayout.inset) }
                    VStack(alignment: .leading, spacing: 3) {
                        if !context.chips.isEmpty {
                            RecorderChipRow(chips: context.chips) { ChipMenuItems(context: context, chip: $0) }
                                .padding(.bottom, FloatingLayout.chipsBottom - 3)
                        }
                        PanelTitle(state: state, meeting: focused)
                        PanelMetaLine(meeting: focused, goHome: context.goHome)
                    }
                    .padding(.horizontal, FloatingLayout.inset)
                    .padding(.top, !lines.isEmpty ? 12 : context.band + (context.chips.isEmpty ? 4 : FloatingLayout.chipsTop))
                    .padding(.bottom, 8)
                    PanelNotes(state: state, meeting: focused, isRecording: false, showsLane: false)
                } else {
                    RecentConversations(context: context)
                        .padding(.top, !lines.isEmpty ? 0 : context.band + 6)
                }
            }
            controls
        }
    }

    /// Record goes into the focused conversation only while it has only notes; one that already has a recording
    /// gets a new conversation of its own, so a past call is never added to (docs/interface.md, "Home").
    static func recordTarget(_ focused: Meeting?) -> UUID? {
        focused.flatMap { $0.tracks.isEmpty ? $0.id : nil }
    }

    private var controls: some View {
        let height: CGFloat = context.compact ? 34 : 44
        return PanelControls(compact: context.compact) {
            RecordButton(state: state, title: "Record", into: Self.recordTarget(focused), size: context.compact ? 13 : 15, height: height,
                         shape: .capsule)
        } trailing: {
            Button {
                NSApp.activate()
                state.chooseImport()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: context.compact ? 13 : 15, weight: .medium))
                    .foregroundStyle(DaybookPalette.Ink.link)
                    .frame(width: height, height: height)
                    .contentShape(Circle())
            }
            .daybookControl(.standard, shape: .circle)
            .help("Import Audio… (⇧⌘I)")
            .accessibilityLabel("Import Audio")
        }
    }
}

/// A status line that opens what it's about: a recorder's or iPhone's page.
private struct StatusLineButton: View {
    let context: PanelContext
    let line: StatusLineItem

    var body: some View {
        let device = line.id.hasPrefix("recorder-") ? String(line.id.dropFirst(9)) : line.id.hasPrefix("phone-") ? String(line.id.dropFirst(6)) : nil
        if let device {
            Button { context.showDevice(device) } label: { StatusLineView(line) }
                .buttonStyle(.plain)
                .accessibilityHint("Opens it in Daybook")
        } else {
            StatusLineView(line)
        }
    }
}

/// The newest conversations, in the iPhone's row style: the title, then the time and what's
/// happening (or the gist), a glyph only when it isn't ready. A row opens in Daybook.
private struct RecentConversations: View {
    let context: PanelContext
    var limit = 5
    var showsHeading = true

    var body: some View {
        let state = context.state
        let recent = state.meetings.filter { $0.id != state.recordingID }.sorted { $0.date > $1.date }.prefix(limit)
        VStack(alignment: .leading, spacing: 4) {
            if showsHeading {
                Text("Recent")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DaybookPalette.Ink.meta)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .padding(.horizontal, FloatingLayout.inset)
                    .accessibilityAddTraits(.isHeader)
            }
            if recent.isEmpty {
                Text("Conversations you record or import appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(DaybookPalette.Ink.meta)
                    .padding(.horizontal, FloatingLayout.inset)
                    .padding(.top, 4)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(recent)) { meeting in
                        RecentRow(meeting: meeting, status: MacRowStatus.make(state, meeting)) {
                            context.openConversation(meeting.id)
                        }
                    }
                }
                .padding(.horizontal, FloatingLayout.inset - 6)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: showsHeading ? .infinity : nil, alignment: .top)
    }
}

/// One of Recent: the library list's row (DaybookUI's `ConversationRowView`, at the panel's density), as a button
/// that opens it in Daybook.
private struct RecentRow: View {
    let meeting: Meeting
    let status: ConversationRowStatus?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            ConversationRowView(meeting: meeting, status: status, timeLabel: timeLabel)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(hovering ? 0.05 : 0), in: DaybookRadius.shape(DaybookRadius.row))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .daybookMotion(DaybookMotion.hover, value: hovering)
        .help("Open in Daybook")
        .accessibilityHint("Opens it in Daybook")
    }

    /// Without the list's day headings, a row says its day: the time today, then "Yesterday", the
    /// weekday this past week, else the date.
    private var timeLabel: String {
        let group = DateGroup.title(for: meeting.date, now: Date(), calendar: .current)
        return group == "Yesterday" ? "Yesterday" : RowDate.format(meeting.date, group: group)
    }
}

// MARK: - Pieces

/// The conversation's title in New York, editable in place.
private struct PanelTitle: View {
    let state: AppState
    let meeting: Meeting

    var body: some View {
        RecorderTitle(meeting.title, rename: { [state, id = meeting.id] title in state.update(id) { $0.title = title } })
    }
}

/// When it was, and how long.
enum PanelMeta {
    static func text(_ meeting: Meeting, showsDuration: Bool = true) -> String {
        ([meeting.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())]
         + [showsDuration ? meeting.duration.map(DurationLabel.format) : nil].compactMap { $0 }).joined(separator: " · ")
    }
}

/// When it was, how long, and the way back to recent conversations.
private struct PanelMetaLine: View {
    let meeting: Meeting
    var showsDuration = true
    let goHome: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(PanelMeta.text(meeting, showsDuration: showsDuration))
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: goHome) { Text("Recent") }
                .buttonStyle(.daybookLink)
                .help("Show recent conversations")
        }
        .font(.system(size: 12))
    }
}

/// The notes, with each paragraph's time in the lane (right-aligned at x = 44, text at 52), and the bookmarks
/// made while recording as ticks beside the paragraphs written after them.
private struct PanelNotes: View {
    let state: AppState
    let meeting: Meeting
    let isRecording: Bool
    /// Reserve the lane even before a note has a time (while and after recording, so nothing jumps).
    let showsLane: Bool
    @Environment(\.readingScale) private var scale

    var body: some View {
        let times = meeting.paragraphTimes()
        let lane = showsLane || times.contains { $0 != nil }
        MarginNotesEditor(
            text: Binding(get: { meeting.notes }, set: { state.editNotes(meeting.id, text: $0) }),
            times: times,
            marks: showsLane ? Self.marks(meeting) : [],
            placeholder: MarginNotesEditor.placeholder,
            fontSize: 14 * scale, lineSpacing: 4 * scale,
            margin: lane ? FloatingLayout.textLeading : FloatingLayout.inset, trailingInset: FloatingLayout.inset,
            timeFontSize: FloatingLayout.timeSize, bottomInset: 12,
            scrolls: true, isEditable: true, focusOnAppear: isRecording)
            .padding(.top, FloatingLayout.notesTop)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Notes scroll softly under the captions and controls.
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [DaybookPalette.paper.opacity(0), DaybookPalette.paper], startPoint: .top, endPoint: .bottom)
                    .frame(height: 12)
                    .allowsHitTesting(false)
            }
    }

    /// The conversation's bookmarks on the notes' timeline.
    static func marks(_ meeting: Meeting) -> [NoteMark] {
        meeting.highlights.map { NoteMark(id: $0.id.uuidString, kind: .bookmark, time: meeting.alignedTime(for: $0) ?? $0.time) }
    }
}

/// The large controls at the foot: two side by side, as on the iPhone.
private struct PanelControls<Leading: View, Trailing: View>: View {
    let compact: Bool
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            leading
            trailing
        }
        .padding(.horizontal, FloatingLayout.inset)
        .padding(.top, compact ? 6 : 10)
        .padding(.bottom, compact ? 12 : 16)
    }
}

/// Record: a new conversation, or into the focused one while it has only notes.
private struct RecordButton: View {
    let state: AppState
    let title: String
    let into: UUID?
    let size: CGFloat
    let height: CGFloat
    let shape: DaybookControlShape

    var body: some View {
        Button { Task { await state.startRecording(into: into) } } label: {
            RecordControlLabel(title: state.isStartingRecording ? "Starting…" : title, size: size)
                .frame(maxWidth: .infinity, minHeight: height)
                .contentShape(Rectangle())
        }
        .daybookControl(.standard, shape: shape)
        .disabled(!state.isReady || state.isStartingRecording || state.isStoppingRecording || state.isRecording)
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .help("Start Recording (⇧⌘R)")
    }
}
