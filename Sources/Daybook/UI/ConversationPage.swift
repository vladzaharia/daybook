import AppKit
import DaybookCore
import DaybookIntelligence
import DaybookKit
import SwiftUI

// MARK: - Page geometry

struct PageIsNarrowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True when the detail column is too narrow for the time margin; times then render inline.
    var pageIsNarrow: Bool {
        get { self[PageIsNarrowKey.self] }
        set { self[PageIsNarrowKey.self] = newValue }
    }
}

/// A scrolling, centred page: a 56 pt time margin hanging left of a 640 pt text measure.
struct PageScroll<Content: View>: View {
    var lazy = false
    var bottomInset: CGFloat = 0
    @ViewBuilder var content: Content
    @State private var width: CGFloat = 1000

    private var narrow: Bool { width < DaybookStyle.narrowWidth }
    /// The measure is centred in the column; the time margin hangs into the space on its left.
    private var leading: CGFloat {
        narrow ? Space.s5 : max(Space.s5, (width - DaybookStyle.measure) / 2 - DaybookStyle.margin)
    }

    var body: some View {
        ScrollView {
            Group {
                if lazy { LazyVStack(alignment: .leading, spacing: 0) { content } }
                else { VStack(alignment: .leading, spacing: 0) { content } }
            }
            .frame(maxWidth: narrow ? .infinity : DaybookStyle.margin + DaybookStyle.measure, alignment: .leading)
            .padding(.leading, leading)
            .padding(.trailing, narrow ? Space.s5 : Space.s6)
            .padding(.top, Space.s6)
            .padding(.bottom, Space.s8 + bottomInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.pageIsNarrow, narrow)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// One block of the page: an optional margin item (a time, a glyph) and content in the measure.
struct MarginRow<Margin: View, Content: View>: View {
    var alignment: VerticalAlignment = .firstTextBaseline
    /// A 4 pt dot drawn in the 8 pt gutter between the margin and the text, never moving the time.
    var gutterDot: Color? = nil
    @ViewBuilder var margin: Margin
    @ViewBuilder var content: Content
    @Environment(\.pageIsNarrow) private var narrow

    var body: some View {
        if narrow {
            HStack(alignment: alignment, spacing: 6) {
                margin.fixedSize()
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: alignment, spacing: 0) {
                HStack(spacing: 4) { margin }
                    .frame(width: DaybookStyle.margin - 8, alignment: .trailing)
                    .padding(.trailing, 8)
                    .overlay(alignment: .trailing) {
                        if let gutterDot { Circle().fill(gutterDot).frame(width: 4, height: 4).offset(x: -2) }
                    }
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension MarginRow where Margin == EmptyView {
    init(alignment: VerticalAlignment = .firstTextBaseline, @ViewBuilder content: () -> Content) {
        self.init(alignment: alignment, gutterDot: nil, margin: { EmptyView() }, content: content)
    }
}

/// A clickable time in the margin: meta ink, link ink on hover, plays from there.
struct MarginTime: View {
    let time: TimeInterval
    var alwaysVisible = true
    let play: () -> Void
    @Environment(\.readingScale) private var scale
    @State private var hovering = false
    var body: some View {
        Button(action: play) {
            Text(TimeLabel.short(time))
                .font(TypeStyle.margin(scale))
                .foregroundStyle(hovering ? Ink.link : Ink.meta)
        }
        .buttonStyle(.plain)
        .opacity(alwaysVisible || hovering ? 1 : 0)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help("Play from here")
        .accessibilityLabel("Play from \(SpokenTime.format(time))")
    }
}

// MARK: - Header

/// Title and one byline: the same on Summary and Transcript, so switching feels like turning the page.
struct PageHeader: View {
    @ObservedObject var state: AppState
    @ObservedObject var player: AudioPlaybackController
    let meeting: Meeting
    let play: (PlaybackTarget) -> Void
    @AppStorage("isInspectorPresented") private var inspectorPresented = false
    @Environment(\.readingScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var titleFocused: Bool

    private var isRecording: Bool { state.recordingID == meeting.id }
    private var isPlayingHere: Bool { player.meetingID == meeting.id && player.duration > 0 }

    var body: some View {
        MarginRow {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Untitled Conversation", text: Binding(get: { meeting.title }, set: { title in state.update(meeting.id) { $0.title = title } }), axis: .vertical)
                    .font(TypeStyle.docTitle(scale))
                    .foregroundStyle(Ink.title)
                    .textFieldStyle(.plain)
                    // A long title wraps rather than being cut off mid-sentence.
                    .lineLimit(1...4)
                    .focused($titleFocused)
                    .accessibilityLabel("Title")
                    .onAppear { focusTitleIfRequested() }
                    .onChange(of: state.titleFocusRequest) { _, _ in focusTitleIfRequested() }
                byline
            }
        }
    }

    private func focusTitleIfRequested() {
        guard state.titleFocusRequest == meeting.id else { return }
        DispatchQueue.main.async { titleFocused = true; state.titleFocusRequest = nil }
    }

    /// In a narrow column the byline gives up the month's full name, then the people, rather than
    /// cutting the date short.
    private var byline: some View {
        ViewThatFits(in: .horizontal) {
            bylineRow(month: .wide, people: true)
            bylineRow(month: .abbreviated, people: true)
            bylineRow(month: .abbreviated, people: false)
        }
        .font(TypeStyle.byline(scale))
        .foregroundStyle(Ink.secondary)
        .lineLimit(1)
    }

    private func bylineRow(month: Date.FormatStyle.Symbol.Month, people showsPeople: Bool) -> some View {
        HStack(spacing: 0) {
            if isRecording {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Ink.record)
                    .symbolEffect(.breathe, options: reduceMotion ? .nonRepeating : .repeating)
                    .neonGlow(Ink.record, radius: 4)
                    .padding(.trailing, 5)
                Text("Recording")
                separator
            } else if let duration = meeting.duration {
                PlayPill(state: state, player: player, duration: duration, isPlayingHere: isPlayingHere) { play(.timeline(0)) }
                separator
            } else if meeting.tracks.isEmpty {
                Text("Notes only")
                separator
            }
            Text(meeting.date.formatted(.dateTime.weekday(.abbreviated).day().month(month).hour().minute()))
            if showsPeople, let people = meeting.peopleLine, !isRecording {
                separator
                Button { inspectorPresented = true } label: { HoverLink(rest: Ink.secondary) { Text(people) } }
                    .buttonStyle(.plain)
                    .help("Show the people in this conversation")
            }
        }
    }

    private var separator: some View { Text(" · ").foregroundStyle(Ink.meta).padding(.horizontal, 4) }
}

/// The byline's play control: a teal pill that shows a live waveform while this conversation plays.
private struct PlayPill: View {
    @ObservedObject var state: AppState
    @ObservedObject var player: AudioPlaybackController
    let duration: TimeInterval
    let isPlayingHere: Bool
    let start: () -> Void
    @State private var hovering = false
    @Environment(\.readingScale) private var scale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var playing: Bool { isPlayingHere && player.isPlaying }
    private var ink: Color { playing && scheme == .dark ? DaybookStyle.neonMint : Ink.link }

    var body: some View {
        Button {
            if isPlayingHere { state.playback.toggle() } else { start() }
        } label: {
            HStack(spacing: 5) {
                Group {
                    if playing && !hovering {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing, isActive: !reduceMotion)
                    } else {
                        Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 9 * scale, weight: .bold))
                    }
                }
                .contentTransition(.symbolEffect(.replace))
                .frame(minWidth: 12 * scale)
                Text(isPlayingHere ? TimeLabel.short(player.position) : DurationLabel.format(duration))
                    .monospacedDigit()
            }
            .font(TypeStyle.byline(scale).weight(.medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(DaybookStyle.accent.opacity(hovering ? 0.22 : 0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // The capsule's edge, not its glyph, lines up with the title.
        .opacity(state.isRecording ? 0.4 : 1)
        .disabled(state.isRecording)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help(state.isRecording ? "Playback is off while recording" : playing ? "Pause" : "Play the conversation")
        .accessibilityLabel(playing ? "Pause" : "Play conversation, \(DurationLabel.format(duration))")
    }
}

// MARK: - Status line

/// The one line that speaks when something is working or needs the person, and is absent otherwise.
struct ConversationStatus: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    /// What the recorders recording along are doing ("Soundcore Work is recording too").
    @ObservedObject private var sources: MultiSourceCoordinator
    @AppStorage(SettingsPaneKey.storageKey) private var settingsPane = "general"
    @Environment(\.openSettings) private var openSettings
    @State private var showingDetails = false

    init(state: AppState, meeting: Meeting) {
        self.state = state
        self.meeting = meeting
        sources = state.sources
    }

    var body: some View {
        // Progress redraws only this line, at its own pace.
        ActivityReader(processing: state.processingActivity, download: state.downloadActivity) { content }
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.easeOut(duration: 0.2), value: state.processingID)
    }

    /// Recording is this Mac's own state; everything else reads from `ProcessingStatus`, which the
    /// conversation list and the iPhone share.
    @ViewBuilder private var content: some View {
        if state.recordingID == meeting.id {
            if let status = state.sources.recorders.status { line(symbol: "dot.radiowaves.left.and.right") { Text(status) } }
        } else {
            switch state.processingStatus(for: meeting) {
            case .failed(let failure) where !failure.reason.isEmpty:
                failed(failure)
            case .processing(let progress) where progress.device == nil:
                line(symbol: nil) {
                    if meeting.status == .transcribing && progress.stage != .identifyingSpeakers {
                        Text(state.sourceActivity(meeting.id) ?? "Transcribing")
                        ProgressView(value: state.processingProgress.fraction).progressViewStyle(.brand(width: 140))
                        Text("\(Int(state.processingProgress.fraction * 100))%")
                            .monospacedDigit()
                            .contentTransition(.numericText(value: state.processingProgress.fraction))
                            .motion(Motion.state, value: Int(state.processingProgress.fraction * 100))
                    } else {
                        ProgressView().controlSize(.small)
                        Text(stageText(progress.stage))
                    }
                    if let origin = state.requestOrigin(for: meeting) { Text("· \(origin)").foregroundStyle(Ink.meta) }
                    if !progress.awaiting.isEmpty { Text("· \(ProcessingStatus.awaitingLine(progress.awaiting))").foregroundStyle(Ink.meta) }
                    Spacer(minLength: Space.s2)
                    Button(meeting.status == .summarizing ? "Stop" : "Pause") { state.pauseProcessing(meeting.id) }
                        .buttonStyle(.daybookLink)
                }
            case .processing(let progress):
                // Another device's work reads like this Mac's: its bar and percent once it reports one.
                line(symbol: nil) {
                    let verb = progress.stage == .summarizing ? "Summarizing" : "Transcribing"
                    let device = progress.device?.name ?? "another device"
                    if let fraction = progress.fraction {
                        Text("\(verb) on \(device)")
                        ProgressView(value: fraction).progressViewStyle(.brand(width: 140))
                        Text("\(Int(fraction * 100))%").monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                        Text("\(verb) on \(device)…")
                    }
                }
            case .requested(.queued(let position, _)):
                line(symbol: "clock") {
                    Text((position == 0 ? waitingText : "Waiting · \(position + 1) in line")
                         + (state.requestOrigin(for: meeting).map { " · \($0)" } ?? ""))
                    Spacer(minLength: Space.s2)
                    Button("Cancel") { state.cancelQueued(meeting.id) }.buttonStyle(.daybookLink)
                }
            case .requested(.models):
                waitingForModels
            case .requested(.paused):
                line(symbol: "pause.circle") {
                    Text("Paused")
                    Spacer(minLength: Space.s2)
                    Button("Resume") { state.enqueue(meeting.id, mode: state.defaultProcessingMode(for: meeting)) }.buttonStyle(.daybookLink)
                }
            case .requested(.device(let request)):
                // Asked for on another device and waiting for a Mac: this one can take it.
                if meeting.hasUntranscribedAudio { transcribe(title: "Requested from \(request.requestedBy.name)") } else { info }
            case .recorded, .failed:
                if meeting.hasUntranscribedAudio { transcribe() } else { info }
            case .awaitingRecordings(let recordings):
                line(symbol: "clock") { Text(ProcessingStatus.awaitingDetail(recordings)) }
                info
            case .done:
                info
            }
        }
    }

    /// The last attempt failed. Trying again can't find speech that isn't there, so a silent
    /// recording offers only the details.
    private func failed(_ failure: ProcessingStatus.Failure) -> some View {
        let error = failure.reason
        let silent = FriendlyError.isNoSpeech(error)
        return box(.problem, symbol: "exclamationmark.triangle.fill",
            title: silent ? "No speech in this recording" : "Couldn’t finish \(failure.hadTranscripts ? "summarizing" : "transcribing")",
            message: silent ? "The audio is saved." : FriendlyError.message(for: error)) {
            Button("Details…") { showingDetails = true }
                .buttonStyle(.daybookLink)
                .popover(isPresented: $showingDetails) {
                    Text(error).font(.callout).textSelection(.enabled).padding(14).frame(width: 320, alignment: .leading)
                }
            if !silent && !meeting.tracks.isEmpty { primary("Try Again") { state.enqueue(meeting.id, mode: state.defaultProcessingMode(for: meeting)) } }
        }
    }

    @ViewBuilder private var waitingForModels: some View {
        if let id = state.downloadingID {
            line(symbol: "arrow.down.circle") {
                Text("Downloading \(state.modelCatalog.name(for: id))")
                ProgressView(value: state.downloadProgress.fraction).progressViewStyle(.brand(width: 120))
                Text("\(Int(state.downloadProgress.fraction * 100))%").monospacedDigit()
                Spacer(minLength: Space.s2)
                Button("Cancel") { state.cancelDownload() }.buttonStyle(.daybookLink)
            }
        } else {
            box(.accent, symbol: "arrow.down.circle.fill", title: "Download models to transcribe this conversation",
                message: missingBytes > 0 ? ByteCountFormatter.string(fromByteCount: missingBytes, countStyle: .file) : nil) {
                Button("Choose Models…") { settingsPane = "models"; openSettings() }.buttonStyle(.daybookLink)
                primary("Download") { state.enqueue(meeting.id); state.downloadModels(state.missingSelectedModels) }
            }
        }
    }

    private func transcribe(title: String? = nil) -> some View {
        box(.accent, symbol: "waveform.circle.fill",
            title: title ?? (meeting.transcripts.isEmpty ? "Not transcribed yet" : "A new recording isn’t transcribed yet"),
            message: nil) {
            primary(meeting.transcripts.isEmpty ? "Transcribe" : "Transcribe New Audio") { state.enqueue(meeting.id, mode: .newAudio) }
        }
    }

    @ViewBuilder private var info: some View {
        if let message = meeting.errorMessage {
            box(.info, symbol: "info.circle.fill", title: message, message: nil) {
                Button("Dismiss") { state.update(meeting.id) { $0.errorMessage = nil } }.buttonStyle(.daybookLink)
            }
        }
    }

    private func stageText(_ stage: ProcessingRequest.Stage) -> String {
        switch stage {
        case .summarizing: return "Summarizing…"
        case .identifyingSpeakers: return "Identifying speakers…"
        case .transcribing: return "Transcribing · \(Int(state.processingProgress.fraction * 100))%"
        }
    }
    private var waitingText: String {
        guard let current = state.processingID, let title = state.meetings.first(where: { $0.id == current })?.title else { return "Waiting" }
        return "Waiting · after “\(title)”"
    }
    private var missingBytes: Int64 {
        state.missingSelectedModels.compactMap { state.modelCatalog.model($0)?.approximateBytes }.reduce(0, +)
    }

    /// A working state: one bare line.
    private func line(symbol: String?, @ViewBuilder _ content: () -> some View) -> some View {
        MarginRow {
            HStack(spacing: Space.s2) {
                if let symbol { Image(systemName: symbol).foregroundStyle(Ink.secondary) }
                content()
            }
            .font(TypeStyle.status)
            .foregroundStyle(Ink.secondary)
            .controlSize(.small)
        }
        .padding(.top, Space.s5)
    }

    /// The one primary action in a status box.
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .tint(DaybookStyle.prominentFill)
    }

    private func box(_ kind: StatusBoxKind, symbol: String, title: String, message: String?,
                     @ViewBuilder actions: () -> some View) -> some View {
        MarginRow {
            StatusBox(kind: kind, symbol: symbol, title: title, message: message, actions: actions())
        }
        .padding(.top, Space.s5)
    }
}

/// What a status box is about: something went wrong, something to do, or something to know.
enum StatusBoxKind { case problem, accent, info }

/// A state that needs the person: a box tinted by what kind of state it is, with at most two actions.
/// In a narrow measure the actions move under the message, on the text's edge, so it never wraps to an orphan.
struct StatusBox<Actions: View>: View {
    let kind: StatusBoxKind
    let symbol: String
    let title: String
    let message: String?
    let actions: Actions
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
        // Stacked or not, the box spans the measure, so boxes and lines share both edges.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var actionRow: some View {
        HStack(spacing: Space.s3) { actions }
            .controlSize(.small)
            .fixedSize()
    }
}

enum SettingsPaneKey { static let storageKey = "settingsPane" }

/// Plain-language reasons for processing failures. The technical message stays one click away.
enum FriendlyError {
    /// The recording worked but holds no speech; trying again can't help.
    static func isNoSpeech(_ error: String) -> Bool { error.lowercased().contains("no speech") }

    static func message(for error: String) -> String {
        let lower = error.lowercased()
        if lower.contains("no speech") { return "No speech was found. The recording is saved." }
        if lower.contains("download") || lower.contains("not installed") { return "Its models aren’t downloaded yet. The recording is saved." }
        if lower.contains("memory") || lower.contains("language model") { return "The summary model couldn’t start. Choose Quick in Settings › Models, or close other apps and try again." }
        return "Something went wrong. The recording is saved."
    }
}

// MARK: - Colophon

/// How the page was made, at its foot: a fact that doubles as the privacy line. A transcript that
/// has no summary yet keeps the template and Summarize here.
struct Colophon: View {
    @ObservedObject var state: AppState
    let meeting: Meeting

    var body: some View {
        MarginRow {
            VStack(alignment: .leading, spacing: Space.s2) {
                Rectangle().fill(Ink.faint).frame(width: 24, height: 1).padding(.bottom, Space.s1)
                if let summary = meeting.summary {
                    HStack(spacing: 5) {
                        Image(systemName: "laptopcomputer").font(.system(size: 10))
                            .symbolEffect(.bounce, value: summary.createdAt)
                        Text("Summarized on this Mac · \(state.modelCatalog.name(for: summary.modelID, provenance: summary.processingSettings?.model)) · \(summary.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                    }
                }
                HStack(spacing: 4) {
                    Text("Template:")
                    Menu {
                        TemplateMenuItems(state: state, meetingID: meeting.id)
                    } label: {
                        HoverLink {
                            HStack(spacing: 3) {
                                Text(templateTitle).fontWeight(.medium)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .semibold))
                            }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    if !meeting.unifiedTranscript.isEmpty {
                        Text("·")
                        Button { state.enqueue(meeting.id, mode: .summaryOnly) } label: {
                            HoverLink { Text(meeting.summary == nil ? "Summarize" : "Summarize Again").fontWeight(.medium) }
                        }
                        .buttonStyle(.plain)
                        .disabled(state.processingID == meeting.id || state.queuedIDs.contains(meeting.id) || state.recordingID == meeting.id)
                    }
                }
            }
            .font(TypeStyle.colophon)
            .foregroundStyle(Ink.meta)
        }
        .padding(.top, Space.s7)
    }

    private var templateTitle: String {
        if let template = state.resolvedTemplate(for: meeting) { return template.name }
        // The inspector's words for the same choice.
        if let kind = meeting.summary?.kind, kind != .auto { return "Automatic (\(kind.title))" }
        return "Automatic"
    }
}

/// Quiet text that is also a control: secondary ink at rest, link ink while the pointer is over it.
struct HoverLink<Label: View>: View {
    var rest: Color = Ink.secondary
    @ViewBuilder var label: Label
    @State private var hovering = false
    var body: some View {
        label
            .foregroundStyle(hovering ? Ink.link : rest)
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
    }
}
