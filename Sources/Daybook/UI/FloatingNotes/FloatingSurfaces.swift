import AppKit
import DaybookCaptions
import DaybookCore
import DaybookDesign
import DaybookDevices
import DaybookKit
import SwiftUI

// The panel's three surfaces, in the iPhone's recording-surface and status-sheet language
// (docs/interface.md, "Floating Notes"), each full or compact by the panel's height.

// MARK: - Recording

/// While recording: the title, the red clock beside You and Call meters, what else records this
/// conversation, your notes with their times, live captions, and large Bookmark and Stop. Compact:
/// the clock and meters, one caption line, and the controls.
struct RecordingSurface: View {
    let context: PanelContext
    let meeting: Meeting
    let inputs: FloatingStatusInputs
    let levels: PanelLevels
    let captionsShowing: Bool

    private var state: AppState { context.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if context.compact {
                compactBody
            } else {
                fullBody
            }
        }
    }

    private var fullBody: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                if !context.chips.isEmpty {
                    // Spacing 10 plus this: the same gap to the title as after Stop.
                    ChipRow(chips: context.chips, menus: context.menus).padding(.bottom, FloatingLayout.chipsBottom - 10)
                }
                PanelTitleField(state: state, meeting: meeting)
                HStack(alignment: .center, spacing: 14) {
                    clock(size: 34)
                    PanelMeters(levels: levels, inputs: inputs, showsCall: state.includeComputerAudio, height: 17)
                }
                let along = FloatingStatus.multipoint(inputs)
                if !along.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(along) { line in
                            StatusChip(symbol: line.symbol, text: line.text, tone: line.tone == .recording ? .calm : line.tone,
                                       showsDot: line.tone == .recording, truncates: true, metrics: .mac)
                                .accessibilityLabel(line.text)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, FloatingLayout.inset)
            .padding(.top, context.band + (context.chips.isEmpty ? 4 : FloatingLayout.chipsTop))
            .padding(.bottom, 12)
            PanelRule()
            PanelNotes(state: state, meeting: meeting, isRecording: true, showsLane: true)
            if captionsShowing {
                PanelCaptions(captions: state.captions, compact: false)
                    .padding(.top, 6)
                    .transition(.opacity)
            }
            controls(height: 44, radius: 13, size: 14)
        }
        .daybookMotion(DaybookMotion.state, value: captionsShowing)
    }

    private var compactBody: some View {
        Group {
            HStack(alignment: .center, spacing: 12) {
                clock(size: 26)
                PanelMeters(levels: levels, inputs: inputs, showsCall: state.includeComputerAudio, height: 10)
            }
            .padding(.horizontal, FloatingLayout.inset)
            .padding(.top, context.band + 6)
            Spacer(minLength: 4)
            // The newest caption sits on the controls, as the strip does on iPhone.
            if captionsShowing {
                PanelCaptions(captions: state.captions, compact: true)
            }
            controls(height: 34, radius: 10, size: 13)
        }
    }

    @ViewBuilder
    private func clock(size: CGFloat) -> some View {
        if let start = state.recordingStartedAt {
            ElapsedClock(since: start, size: size, weight: .medium)
                .fixedSize()
                // Stop carries the elapsed time for VoiceOver too.
                .accessibilitySortPriority(1)
        }
    }

    private var bookmarkCount: Int { meeting.highlights.filter { $0.trackID == nil }.count }

    private func controls(height: CGFloat, radius: CGFloat, size: CGFloat) -> some View {
        PanelControls(compact: context.compact) {
            Button { state.addHighlight(meeting.id) } label: {
                BookmarkControlLabel(count: bookmarkCount, size: size)
                    .frame(maxWidth: .infinity, minHeight: height)
                    .contentShape(Rectangle())
            }
            .daybookControl(.standard, shape: .roundedRectangle(radius: radius))
            .disabled(state.isStoppingRecording)
            .keyboardShortcut("d")
            .help("Add Bookmark (⌘D)")
            .accessibilityLabel(bookmarkCount > 0 ? "Bookmark, \(bookmarkCount) so far" : "Bookmark")
        } trailing: {
            Button { Task { await state.stopRecording() } } label: {
                StopControlLabel(isSaving: state.isStoppingRecording, savingTitle: "Saving…", size: size)
                    .frame(maxWidth: .infinity, minHeight: height)
                    .contentShape(Rectangle())
            }
            .daybookControl(.stop, shape: .roundedRectangle(radius: radius))
            .disabled(state.isStoppingRecording)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help("Stop Recording (⇧⌘R)")
            .accessibilityLabel("Stop recording")
            .accessibilityValue(state.recordingStartedAt.map { SpokenTime.format(Date().timeIntervalSince($0)) } ?? "")
        }
    }
}

/// "You" and "Call", each a rolling meter in the iPhone's style. Two sources, so a muted
/// microphone or a call that isn't being captured shows up during the call, not afterwards. The
/// meters read the trails themselves, so only they redraw as levels arrive.
private struct PanelMeters: View {
    let levels: PanelLevels
    let inputs: FloatingStatusInputs
    let showsCall: Bool
    let height: CGFloat

    var body: some View {
        let live = inputs.phase == .recording
        VStack(spacing: height > 10 ? 6 : 4) {
            meter("You", levels.you, live: live, warning: inputs.microphoneSilent,
                  height: showsCall ? height : height * 2 + 6)
            if showsCall {
                meter("Call", levels.call, live: live && inputs.call != .missing, warning: inputs.call == .missing, height: height)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func meter(_ label: String, _ trail: LevelTrail, live: Bool, warning: Bool, height: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(warning ? DaybookPalette.Ink.warning : DaybookPalette.Ink.meta)
                .frame(width: 24, alignment: .trailing)
                .help(warning ? (label == "You" ? FloatingStatus.microphoneSilentHelp : FloatingStatus.callMissingHelp) : "")
            RollingLevelMeter(trail: trail, isLive: live, metrics: .panel, accessibilityLabel: "\(label) level")
                .frame(height: height)
        }
    }
}

/// The live captions under the notes: the newest lines, You or Call in the time lane. Observes the
/// captions directly, so it alone redraws as words arrive.
private struct PanelCaptions: View {
    @ObservedObject var captions: LiveCaptionsController
    let compact: Bool

    var body: some View {
        let segments = captions.state == .listening ? captions.recent(compact ? 1 : 2) : []
        LiveCaptionStrip(lines: segments.map { CaptionLine(id: $0.id, text: $0.text, isTentative: $0.isTentative, source: $0.source?.label, speaker: $0.speaker?.name) },
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

/// After a Stop seen in the panel: the conversation and your notes; the status bar says what's
/// becoming of it. Open is where Bookmark was, and Record where Stop was, for the next call.
struct AfterStopSurface: View {
    let context: PanelContext
    let meeting: Meeting
    let inputs: FloatingStatusInputs

    private var state: AppState { context.state }
    private var recordingFailed: Bool { inputs.phase == .stopped }
    private var processingFailed: Bool { !recordingFailed && meeting.status == .failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                if !context.chips.isEmpty {
                    // VStack spacing 3 plus this.
                    ChipRow(chips: context.chips, menus: context.menus).padding(.bottom, FloatingLayout.chipsBottom - 3)
                }
                PanelTitleField(state: state, meeting: meeting)
                // The band says "Saved · 28:00", so the line under the title leaves the length out.
                PanelMetaLine(meeting: meeting, showsDuration: inputs.phase != .saved, goHome: context.goHome)
            }
            .padding(.horizontal, FloatingLayout.inset)
            .padding(.top, context.band + (context.chips.isEmpty ? 4 : FloatingLayout.chipsTop))
            .padding(.bottom, context.compact ? 4 : 12)
            if recordingFailed || processingFailed {
                problem
                    .padding(.horizontal, FloatingLayout.inset)
                    .padding(.bottom, 12)
            }
            if context.compact {
                Spacer(minLength: 0)
            } else {
                PanelRule()
                PanelNotes(state: state, meeting: meeting, isRecording: false, showsLane: true)
            }
            controls
        }
    }

    @ViewBuilder private var problem: some View {
        if recordingFailed {
            AttentionBox(title: "Recording stopped", message: context.compact ? nil : "Everything up to then is saved.", compact: true)
                .help(meeting.errorMessage ?? "")
        } else {
            let what = meeting.transcripts.isEmpty ? "transcribing" : "summarizing"
            AttentionBox(title: "Couldn’t finish \(what)", message: context.compact ? nil : meeting.errorMessage.map { FriendlyError.message(for: $0) },
                         compact: true) {
                // A recording with no speech in it can't do better a second time.
                if !FriendlyError.isNoSpeech(meeting.errorMessage ?? "") {
                    Button("Try Again") { state.enqueue(meeting.id, mode: state.defaultProcessingMode(for: meeting)) }
                        .buttonStyle(.daybookLink)
                        .font(.system(size: 12, weight: .medium))
                        .disabled(state.queuedIDs.contains(meeting.id) || state.processingID == meeting.id)
                }
            }
            .help(meeting.errorMessage ?? "")
        }
    }

    private var controls: some View {
        let height: CGFloat = context.compact ? 34 : 44, radius: CGFloat = context.compact ? 10 : 13, size: CGFloat = context.compact ? 13 : 14
        return PanelControls(compact: context.compact) {
            Button(action: context.open) {
                OpenControlLabel(title: meeting.summary != nil ? "Open Summary" : "Open", size: size)
                    .frame(maxWidth: .infinity, minHeight: height)
                    .contentShape(Rectangle())
            }
            .daybookControl(.standard, shape: .roundedRectangle(radius: radius))
            .help("Open in Daybook (⌘O)")
        } trailing: {
            RecordButton(state: state, title: recordingFailed ? "Record Again" : "Record", into: nil, size: size, height: height,
                         shape: .roundedRectangle(radius: radius))
        }
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
                        PanelTitleField(state: state, meeting: focused)
                        PanelMetaLine(meeting: focused, goHome: context.goHome)
                    }
                    .padding(.horizontal, FloatingLayout.inset)
                    .padding(.top, context.band + 4)
                } else {
                    // The newest conversation, a click from Daybook; the band carries the status.
                    RecentConversations(state: state, limit: 1, showsHeading: false)
                        .padding(.top, context.band + 2)
                }
                Spacer(minLength: 0)
            } else {
                // The status lines take the chips' room under the band.
                let hasLines = !FloatingStatus.lines(inputs).isEmpty
                if hasLines {
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(FloatingStatus.lines(inputs, now: timeline.date)) { line in StatusLineButton(state: state, line: line) }
                        }
                        .padding(.horizontal, FloatingLayout.inset)
                        .padding(.bottom, 14)
                    }
                    .padding(.top, context.band + FloatingLayout.chipsTop)
                }
                if let focused {
                    // The conversation, under the device lines: its status chip sits over its title, as after Stop.
                    if hasLines { PanelRule() }
                    VStack(alignment: .leading, spacing: 3) {
                        if !context.chips.isEmpty {
                            ChipRow(chips: context.chips, menus: context.menus).padding(.bottom, FloatingLayout.chipsBottom - 3)
                        }
                        PanelTitleField(state: state, meeting: focused)
                        PanelMetaLine(meeting: focused, goHome: context.goHome)
                    }
                    .padding(.horizontal, FloatingLayout.inset)
                    .padding(.top, hasLines ? 12 : context.band + (context.chips.isEmpty ? 4 : FloatingLayout.chipsTop))
                    .padding(.bottom, 8)
                    PanelNotes(state: state, meeting: focused, isRecording: false, showsLane: false)
                } else {
                    RecentConversations(state: state)
                        .padding(.top, hasLines ? 0 : context.band + 6)
                }
            }
            controls
        }
    }

    private var controls: some View {
        let height: CGFloat = context.compact ? 34 : 44
        return PanelControls(compact: context.compact) {
            RecordButton(state: state, title: "Record", into: focused?.id, size: context.compact ? 13 : 15, height: height, shape: .capsule)
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
    @ObservedObject var state: AppState
    let line: StatusLineItem

    var body: some View {
        let device = line.id.hasPrefix("recorder-") ? String(line.id.dropFirst(9)) : line.id.hasPrefix("phone-") ? String(line.id.dropFirst(6)) : nil
        if let device {
            Button { PanelContext.showDevice(state: state, id: device) } label: { StatusLineView(line, metrics: .mac) }
                .buttonStyle(.plain)
                .accessibilityHint("Opens it in Daybook")
        } else {
            StatusLineView(line, metrics: .mac)
        }
    }
}

/// The newest conversations, in the iPhone's row style: the title, then the time and what's
/// happening (or the gist), a glyph only when it isn't ready. A row opens in Daybook.
private struct RecentConversations: View {
    @ObservedObject var state: AppState
    var limit = 5
    var showsHeading = true

    var body: some View {
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
                        RecentRow(meeting: meeting, status: RowStatus(state: state, meeting: meeting)) {
                            PanelContext.openInDaybook(state: state, id: meeting.id)
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

private struct RecentRow: View {
    let meeting: Meeting
    let status: RowStatus
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(meeting.title.isEmpty ? "Untitled Conversation" : meeting.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DaybookPalette.Ink.title)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    glyph.font(.system(size: 10.5, weight: .semibold))
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(timeLabel).foregroundStyle(DaybookPalette.Ink.body).monospacedDigit()
                    // As in the library list and on the iPhone: the glyph carries the warning, the words stay quiet.
                    Text(status.text ?? RowPreview.text(for: meeting))
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                        .lineLimit(1)
                }
                .font(.system(size: 12))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DaybookMotion.hover, value: hovering)
        .help("Open in Daybook")
        .accessibilityElement(children: .combine)
        .accessibilityLabel([meeting.title, timeLabel, status.text].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens it in Daybook")
    }

    /// Without the list's day headings, a row says its day: the time today, then "Yesterday", the
    /// weekday this past week, else the date.
    private var timeLabel: String {
        let group = DateGroup.title(for: meeting.date, now: Date(), calendar: .current)
        return group == "Yesterday" ? "Yesterday" : RowDate.format(meeting.date, group: group)
    }

    @ViewBuilder private var glyph: some View {
        switch status.kind {
        case .recording?:
            Circle().fill(DaybookPalette.Ink.record).frame(width: 7, height: 7)
        case .processing?:
            WorkProgressLine(fraction: status.fraction).frame(width: 36)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        case .waiting?: Image(systemName: "clock").foregroundStyle(DaybookPalette.Ink.meta)
        case .waitingForModels?: Image(systemName: "arrow.down.circle").foregroundStyle(DaybookPalette.Ink.meta)
        case .paused?: Image(systemName: "pause.circle").foregroundStyle(DaybookPalette.Ink.meta)
        case .failed?: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DaybookPalette.Ink.warning)
        case .notTranscribed?: Circle().fill(DaybookPalette.accent).frame(width: 7, height: 7)
        case nil:
            let count = meeting.highlights.count
            if count > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "bookmark.fill").imageScale(.small)
                    Text("\(count)").monospacedDigit()
                }
                .foregroundStyle(DaybookPalette.bookmark)
            }
        }
    }
}

// MARK: - Pieces

/// The conversation's title in New York, editable in place.
struct PanelTitleField: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    @Environment(\.readingScale) private var scale

    var body: some View {
        let title = Binding(get: { meeting.title }, set: { title in state.update(meeting.id) { $0.title = title } })
        ZStack(alignment: .leading) {
            if title.wrappedValue.isEmpty {
                Text("Untitled Conversation").foregroundStyle(DaybookPalette.Ink.faint).accessibilityHidden(true)
            }
            TextField("Title", text: title, prompt: Text(verbatim: ""))
                .textFieldStyle(.plain)
                .foregroundStyle(DaybookPalette.Ink.title)
                .labelsHidden()
        }
        .font(.system(size: 17 * min(scale, 1.3), weight: .semibold, design: .serif))
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

/// When it was, how long, and the way back to recent conversations.
private struct PanelMetaLine: View {
    let meeting: Meeting
    var showsDuration = true
    let goHome: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(([meeting.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())]
                  + [showsDuration ? meeting.duration.map(DurationLabel.format) : nil].compactMap { $0 }).joined(separator: " · "))
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

/// The notes, with each paragraph's time in the lane (right-aligned at x = 44, text at 52).
private struct PanelNotes: View {
    @ObservedObject var state: AppState
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
            placeholder: "Add a note…",
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
}

/// A hairline between the header and the notes.
private struct PanelRule: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Rectangle()
            .fill(contrast == .increased ? DaybookPalette.Ink.meta : DaybookPalette.Ink.faint.opacity(0.45))
            .frame(height: contrast == .increased ? 1 : 0.5)
            .padding(.horizontal, FloatingLayout.inset)
            .accessibilityHidden(true)
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
    @ObservedObject var state: AppState
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

/// Open in Daybook: the link teal and the arrow out of the panel.
private struct OpenControlLabel: View {
    let title: String
    let size: CGFloat
    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1)
            Image(systemName: "arrow.up.forward").font(.system(size: size * 0.75, weight: .semibold))
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(DaybookPalette.Ink.link)
    }
}
