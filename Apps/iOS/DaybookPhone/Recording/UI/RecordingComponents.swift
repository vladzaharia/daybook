import AVKit
import DaybookCaptions
import DaybookCore
import DaybookDesign
import DaybookKit
import DaybookLink
import DaybookUI
import SwiftUI
import UIKit

// What the iPhone puts into the recorder both apps share (DaybookUI's `RecorderSurface`): its recording's status in
// the shared words, its captions, and the pieces only the iPhone has (the camera, the live timeline, the bookmark
// log, its notices). Each reads the app model itself, so a posture change only rearranges them; nothing about the
// recording restarts.

// MARK: - The recording, in the shared words

/// The iPhone's recording as the shared recorder reads it: the phase, the recorders and Macs recording along, the
/// meters, and a pause.
@MainActor
enum PhoneRecorderStatus {
    static func inputs(_ model: PhoneAppModel, afterStop: Bool = false) -> RecordingStatusInputs {
        let recorder = model.recorder
        var inputs = RecordingStatusInputs()
        inputs.here = "this iPhone"
        inputs.phase = phase(recorder.state, isFiling: model.isFiling)
        inputs.inputDevice = recorder.isCapturing ? recorder.inputRoute?.name : nil
        // The input's name is the button for the system's input picker (`PhoneInputButton`): "iPhone Microphone ▾".
        inputs.choosesInput = recorder.isCapturing
        inputs.microphoneSilent = recorder.isCapturing && recorder.isMicrophoneSilent
        let conversation = recorder.captureID
        if recorder.isActive {
            let cascade = model.devices.cascade
            inputs.recorders = model.devices.sessions.filter { $0.direct != nil || cascade.member($0.id) != nil }.map { session in
                RecorderFacts(session: session, handoff: model.devices.handoffState(session),
                              along: cascade.conversation?.id == conversation ? cascade.member(session.id).map { along($0.state, role: $0.role) } : nil)
            }
            // The Mac this recording follows, when it's out of reach: its chip says so while this iPhone keeps recording.
            var leadAway: UUID?
            if model.multipoints.leadOutOfReach != nil, case .macLed(let lead)? = model.multipoint?.role { leadAway = lead }
            inputs.peers = peers(multipoint: model.multipoint, connected: model.link.connectedMacs, conversation: conversation, outOfReach: leadAway)
        }
        return inputs
    }

    /// The recorder's state in the phase both recorders say.
    static func phase(_ state: PhoneRecorder.State, isFiling: Bool) -> RecordingStatusInputs.Phase {
        switch state {
        case .starting: return .starting
        case .recording: return .recording
        case .paused: return .paused
        case .stopping: return .saving
        case .idle: return isFiling ? .saving : .idle
        }
    }

    /// A recorder's part in this recording, as the conversation's links say it on the Mac.
    static func along(_ state: RecorderCascade.State, role: RecorderCascade.Role) -> CompanionRecording.State {
        switch state {
        case .starting: return .starting
        case .recording: return role == .alreadyRecording ? .alreadyRecording : .recording
        case .stopping: return .stopping
        case .stopped: return .stopped
        case .unavailable: return .unavailable
        case .stopFailed: return .stopFailed
        }
    }

    /// The Macs around this recording: each one asked or recording along, each one recording the same conversation
    /// on its own, then each connected one that could.
    static func peers(multipoint: MultipointSession?, connected: [PhoneLink.Mac], conversation: UUID?,
                      outOfReach: UUID? = nil) -> [RecordingStatusInputs.Peer] {
        let connectedIDs = Set(connected.map(\.id))
        var peers = (multipoint?.macs ?? []).map { mac in
            let along = Self.along(mac.state)
            return RecordingStatusInputs.Peer(id: mac.id.uuidString, name: mac.name, kind: .mac, isConnected: connectedIDs.contains(mac.id),
                                              activity: along == .recording ? .recording : .idle, along: along, hasMeter: false,
                                              outOfReach: outOfReach == mac.id)
        }
        let involved = Set(multipoint?.macs.map(\.id) ?? [])
        for mac in connected where !involved.contains(mac.id) {
            let recordsThis = mac.isRecording && conversation != nil && mac.recording?.conversationID == conversation
            peers.append(RecordingStatusInputs.Peer(id: mac.id.uuidString, name: mac.name, kind: .mac, isConnected: true,
                                                    activity: mac.isRecording ? .recording : .idle,
                                                    along: recordsThis ? .alreadyRecording : nil, lastConnected: mac.lastConnectedAt, hasMeter: false))
        }
        return peers
    }

    static func along(_ state: MultipointSession.Mac.State) -> CompanionRecording.State {
        switch state {
        case .asking: return .starting
        case .recording: return .recording
        case .stopped: return .stopped
        case .failed: return .failed
        case .noAnswer: return .unavailable
        }
    }

    /// Why the recording is paused and whether it can go on. iOS doesn't say what interrupted; without a reason (a
    /// muted or unplugged microphone gives one) it's almost always a call.
    static func pause(_ state: PhoneRecorder.State, message: String?, canResume: Bool) -> RecorderPause? {
        guard case .paused(let reason) = state else { return nil }
        let isCall = reason == .interruption && message == PhoneRecorder.unspecifiedInterruption
        let title: String
        switch reason {
        case .interruption: title = isCall ? "Paused for a call" : "Paused"
        case .inputFailed: title = "The microphone stopped"
        }
        // Resume is right below once it can: the words don't ask for it.
        let words = canResume
            ? (isCall ? "The call has ended. Everything so far is saved." : (message ?? "Everything so far is saved."))
            : (isCall ? "Everything so far is saved. Recording can continue when the call ends." : (message ?? "Everything so far is saved."))
        return RecorderPause(title: title, message: words, canResume: canResume)
    }

    /// What VoiceOver hears as the recording changes on its own: a pause, a resume, a silent microphone.
    static func announcement(from old: RecordingStatusInputs.Phase, to new: RecordingStatusInputs.Phase, pause: RecorderPause?) -> String? {
        switch (old, new) {
        case (.recording, .paused): return pause.map { "Recording paused. \($0.title)." } ?? "Recording paused"
        case (.paused, .recording): return "Recording resumed"
        default: return nil
        }
    }
}

// MARK: - The input

/// The recorder's phase while it names the input, "● RECORDING · iPhone Microphone ▾": a button that shows the system's
/// input picker (`AVInputPickerInteraction`), where the person can pick AirPods, a USB microphone, or the iPhone's own.
/// What they pick is recorded from at once and remembered for later recordings (`PhoneRecorder.inputChosen`); chosen
/// AirPods that can hear the room capture it (`AudioInputPlan`).
struct PhoneInputButton: View {
    @Environment(PhoneAppModel.self) private var model
    let phase: RecorderPhase
    let label: AnyView
    /// Each tap asks the picker to show once.
    @State private var requests = 0

    /// The control the shared recorder puts around its phase (`RecorderInputControl`).
    static let control = RecorderInputControl { phase, label in AnyView(PhoneInputButton(phase: phase, label: label)) }

    var body: some View {
        let recorder = model.recorder
        Button { requests += 1 } label: {
            label.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(InputPickerAnchor(requests: requests, chosen: { recorder.inputChosen() }).accessibilityHidden(true))
        .accessibilityLabel(phase.title)
        .accessibilityValue([phase.detailIsWarning ? phase.detail : nil, phase.input].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Chooses the microphone")
    }
}

/// A view behind the input's name for the system's input picker to show from, and word when the person has picked.
private struct InputPickerAnchor: UIViewRepresentable {
    let requests: Int
    let chosen: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.addInteraction(context.coordinator.interaction)
        context.coordinator.shown = requests
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let picker = context.coordinator
        picker.chosen = chosen
        guard requests != picker.shown else { return }
        picker.shown = requests
        picker.interaction.present()
    }

    @MainActor
    final class Coordinator: NSObject, AVInputPickerInteraction.Delegate {
        let interaction = AVInputPickerInteraction()
        var chosen: (@MainActor () -> Void)?
        var shown = 0

        override init() {
            super.init()
            interaction.delegate = self
        }

        nonisolated func inputPickerInteractionDidEndDismissing(_ inputPickerInteraction: AVInputPickerInteraction) {
            Task { @MainActor in self.chosen?() }
        }
    }
}

// MARK: - Captions

extension CaptionStripStyle {
    /// iPhone, pocket, at the accessibility sizes: the strip's newest line only, so the notes keep their room.
    static let stripNewest = CaptionStripStyle(lines: 1, newestSize: 19, olderSize: 15, newestLineLimit: 1, olderLineLimit: 1,
                                               labelSize: 12, labelStyle: .caption, spacing: 6, lineSpacing: 4)
}

/// Live captions in a layout's style, from this iPhone's captions: the newest lines, the person live speakers
/// recognized (or the recorder that heard it) before the words, and why there are none yet.
struct PhoneCaptions: View {
    @Environment(PhoneAppModel.self) private var model
    let style: CaptionStripStyle

    var body: some View {
        let captions = model.captions
        if captions.isShowing {
            let segments = captions.state == .listening ? captions.recent(style.lines) : []
            LiveCaptionStrip(lines: segments.map { segment in
                                 CaptionLine(id: segment.id, text: segment.text, isTentative: segment.isTentative,
                                             speaker: LiveCaptionLabels.speaker(segment, names: captions.sourceNames))
                             },
                             status: status(captions.state),
                             style: style)
        }
    }

    private func status(_ state: LiveCaptionState) -> String? {
        switch state {
        case .listening: return "Listening…"
        case .preparing: return "Getting captions ready…"
        case .downloading(let fraction):
            let percent = fraction.map { " · \(ProcessingWords.percentText($0))" } ?? ""
            return "Downloading captions for \(LiveCaptionAvailability.name(model.settings.captionLocale))\(percent)"
        case .unavailable(let reason): return reason
        case .failed: return "Captions stopped"
        case .off, .finished: return nil
        }
    }
}

// MARK: - The iPhone's own pieces

/// Take Photo while recording: the photo joins the recording at its shutter moment, like a bookmark, and the count
/// shows on it as Bookmark's does. The hand feels the camera's own shutter; nothing else taps it.
struct CameraControl: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat = 44
    @State private var showingCamera = false
    /// Photos the person took, for the tap that says one landed (a new recording's count going back isn't one).
    @State private var taken = 0
    /// The recording the camera was opened for: a photo that arrives after it ends still joins it.
    @State private var recordingID: UUID?

    var body: some View {
        let count = model.recorder.photos.count
        // Only where there's a camera: a camera that can't open isn't shown at all.
        if CameraPicker.isAvailable {
            Button {
                recordingID = model.recorder.captureID
                showingCamera = true
            } label: {
                Image(systemName: "camera")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(DaybookPalette.Ink.title)
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(DaybookPalette.Ink.title)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(.regularMaterial, in: Capsule())
                        .offset(x: 4, y: -4)
                        .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(count)))
                        .animation(DaybookMotion.resolved(DaybookMotion.tick, reduceMotion: reduceMotion), value: count)
                        .accessibilityHidden(true)
                }
            }
            .daybookControl(.standard, shape: .circle)
            .disabled(!model.recorder.isCapturing || model.recorder.state == .starting)
            .onChange(of: count) { old, new in if new > old { taken += 1 } }
            .sensoryFeedback(.success, trigger: taken)
            .accessibilityLabel(count > 0 ? "Take Photo, \(count) so far" : "Take Photo")
            .cameraCover(isPresented: $showingCamera, capture: { [recordingID] photo in Task { await model.addPhoto(photo, recording: recordingID) } },
                         failed: { model.say(PhoneAppModel.photoNotSaved) })
        }
    }
}

/// The conversation so far on one line: bookmarks in amber and notes in ink at their times, with "now" at the
/// right edge. No labels: the clock above has the time, Bookmark has the count.
struct LiveTimelineBar: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            // The conversation's timeline keeps running through a pause, so the bar runs to now.
            let elapsed = max(1, recorder.elapsedTime)
            let notes = NoteTimeline.paragraphTimes(anchors: recorder.timedNotes, text: recorder.notes).compactMap { $0 }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(RecordingStyle.quietFill)
                    if let paused = recorder.pausedAt {
                        // The pause so far, in the colour of what needs you.
                        UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: 7, topTrailingRadius: 7)
                            .fill(DaybookPalette.Ink.warning.opacity(0.35))
                            .frame(width: max(6, width * (1 - min(1, paused / elapsed))))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, time in
                        Capsule().fill(DaybookPalette.Ink.meta)
                            .frame(width: 2, height: proxy.size.height * 0.45)
                            .offset(x: min(width - 2, width * time / elapsed))
                    }
                    ForEach(recorder.highlights) { mark in
                        Capsule().fill(DaybookPalette.bookmark)
                            .frame(width: 3, height: proxy.size.height)
                            .offset(x: min(width - 3, width * mark.time / elapsed))
                    }
                    Circle().fill(recorder.state == .recording ? DaybookPalette.Ink.record : DaybookPalette.Ink.faint)
                        .frame(width: 8, height: 8)
                        .offset(x: width - 8)
                }
            }
            .frame(height: 14)
            .accessibilityElement()
            .accessibilityLabel("Timeline")
            .accessibilityValue("\(recorder.bookmarkCount) bookmarks, \(notes.count) notes, \(TimeLabel.short(recorder.elapsedTime)) recorded")
        }
    }
}

/// This recording's bookmarks, newest first, each with the note written just before it. Nothing until the first
/// one: Bookmark below says what it does, and carries the count.
struct BookmarkLog: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        let marks = recorder.highlights.sorted { $0.time > $1.time }
        VStack(alignment: .leading, spacing: 10) {
            if !marks.isEmpty {
                Text("Bookmarks")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DaybookPalette.Ink.meta)
                    .accessibilityAddTraits(.isHeader)
                ForEach(marks) { mark in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "bookmark.fill").foregroundStyle(DaybookPalette.bookmark).imageScale(.small)
                        Text(TimeLabel.short(mark.time))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(DaybookPalette.Ink.body)
                            .frame(minWidth: 40, alignment: .leading)
                        Text(NotesTimeline.paragraph(before: mark.time, notes: recorder.notes, anchors: recorder.timedNotes) ?? "")
                            .font(.subheadline)
                            .foregroundStyle(DaybookPalette.Ink.secondary)
                            .lineLimit(1)
                    }
                    .daybookTransition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybookMotion(DaybookMotion.land, value: marks.count)
    }
}

/// One line when something needs saying (a recovered recording, a Mac that declined, a problem the recorder
/// reports while it keeps recording): what happened, the fix when there is one, and the system's own words only
/// behind Details. VoiceOver hears each as it appears.
struct RecordingNotice: View {
    @Environment(PhoneAppModel.self) private var model
    @State private var details: NoticeDetails?

    /// Whether it has anything to say now, for the recorder to make room for.
    static func isShowing(_ model: PhoneAppModel) -> Bool {
        model.notice != nil || (model.recorder.isCapturing && PhoneAppModel.recorderWarning(model.recorder.lastError) != nil)
            || model.multipoints.leadOutOfReach != nil
    }

    var body: some View {
        let warning = model.recorder.isCapturing ? PhoneAppModel.recorderWarning(model.recorder.lastError) : nil
        let outOfReach = model.multipoints.leadOutOfReach
        Group {
            // Nothing at all when there's nothing to say, so the stack around it keeps its spacing.
            if warning != nil || model.notice != nil || outOfReach != nil {
                VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                    if let warning {
                        NoticeRow(message: warning.message, details: warning.details, showDetails: show)
                    }
                    // The Mac this recording follows is out of reach: this iPhone keeps recording until it's stopped.
                    if let outOfReach {
                        NoticeRow(message: outOfReach, stop: { Task { try? await model.stopRecording() } }, showDetails: show)
                    }
                    if let notice = model.notice {
                        NoticeRow(message: notice, details: model.noticeDetails, fix: model.noticeFix,
                                  dismiss: { model.dismissNotice() }, showDetails: show)
                    }
                }
                .transition(.opacity)
                .sheet(item: $details) { DetailsSheet(title: "Details", text: $0.text) }
            }
        }
        .onChange(of: model.notice) { _, notice in if let notice { AccessibilityNotification.Announcement(notice).post() } }
        .onChange(of: outOfReach) { _, words in if let words { AccessibilityNotification.Announcement(words).post() } }
        .onChange(of: warning?.message) { _, message in if let message { AccessibilityNotification.Announcement(message).post() } }
    }

    private func show(_ text: String) { details = NoticeDetails(text: text) }

    private struct NoticeDetails: Identifiable {
        let text: String
        var id: String { text }
    }
}

/// A notice: the warning glyph, the sentence, its fix and Details as text buttons, and dismiss.
private struct NoticeRow: View {
    let message: String
    var details: String?
    var fix: PhoneAppModel.NoticeFix?
    /// Stop, for a notice about the recording itself (the Mac it follows is out of reach).
    var stop: (() -> Void)?
    var dismiss: (() -> Void)?
    let showDetails: (String) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(DaybookPalette.Ink.warning).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.footnote).foregroundStyle(DaybookPalette.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if fix != nil || details != nil || stop != nil {
                    HStack(spacing: DaybookSpacing.s4) {
                        if let stop {
                            Button("Stop", action: stop)
                        }
                        if fix == .openSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                            Button("Open Settings") { openURL(url) }
                        }
                        if let details {
                            Button("Details") { showDetails(details) }
                        }
                    }
                    .buttonStyle(.daybookLink)
                    .font(.footnote.weight(.semibold))
                }
            }
            Spacer(minLength: 0)
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(DaybookPalette.Ink.meta)
                .padding(.vertical, -13)
                .padding(.trailing, -12)
                .accessibilityLabel("Dismiss")
            }
        }
    }
}

/// The notes while recording: the editor the conversation's page uses, with each paragraph's time in the lane and
/// this recording's bookmarks and photos as ticks beside the paragraphs written after them. Typing and handwriting
/// go in the same notes.
struct RecordingNotes: View {
    @Environment(PhoneAppModel.self) private var model
    var focusOnAppear = false
    @State private var inkSession = InkSession()

    var body: some View {
        let recorder = model.recorder
        let notes = Binding(get: { recorder.notes }, set: { model.editNotes($0) })
        WritableNotes(session: inkSession) {
            MarginNotesEditor(
                text: notes,
                times: NoteTimeline.paragraphTimes(anchors: recorder.timedNotes, text: recorder.notes),
                marks: NotesTimeline.marks(bookmarks: recorder.highlights, photos: recorder.photos),
                scrolls: true,
                focusOnAppear: focusOnAppear,
                bottomInset: WritableNotes<EmptyView>.toolsHeight,
                ink: .recording(model, session: inkSession))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if model.options.demoInkWriting { inkSession.isWriting = true } }
    }
}
