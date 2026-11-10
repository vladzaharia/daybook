import DaybookCore
import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI
import UIKit

/// The recorder while a recording is under way, in each posture (docs/iphone.md, "iPhone Duo"), and for a moment
/// after Stop. It's the recorder Floating Notes shows on the Mac (DaybookUI's `RecorderSurface`), filled from the
/// app model, with what only the iPhone has around it: the camera, the live timeline, and table mode's dimming.
///
/// - **Pocket** (closed, and every other iPhone held upright): the title and byline, your notes, and the newest
///   caption on top, and under them the recorder in one sheet of four sizes (mini, collapsed, expanded, full), with
///   Bookmark and Stop at the thumb at every size and the camera and Write by Hand from collapsed up.
/// - **Notebook** (open): the title and notes on the left page; the whole recorder on the right. Split at the crease,
///   never across it.
/// - **Table** (partly open, standing): glanceable from across a table, and dimmed between touches.
///
/// Folding mid-recording only rearranges the same pieces: nothing about the recording restarts.
/// `RootView` shows it while `model.isRecordingActive`, and after Stop while `afterStop` is set.
struct RecorderScreen: View {
    let style: SurfaceStyle
    /// After Stop: the conversation it was filed into, for a few seconds (Saved, Open, Keep Recording).
    var afterStop: AfterStop?
    /// Hands back to the library.
    var done: () -> Void = {}
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var levels = RecorderLevels()
    @AccessibilityFocusState private var clockFocused: Bool
    /// How far the person has expanded the recorder's sheet; nil rests it at the posture's size. Lives here, so
    /// it survives folding and turning (`style` changes), and a new recording starts at rest.
    @State private var sheetExpansion: RecorderSheetSize?
    /// How the notes are being written: shared by the notes and Write by Hand in the sheet, and kept through folding.
    @State private var inkSession = InkSession()

    var body: some View {
        Group {
            if let afterStop, !model.recorder.isActive {
                PhoneAfterStop(afterStop: afterStop, style: style, done: done)
            } else {
                recorder
            }
        }
        .environment(\.recorderInputControl, PhoneInputButton.control)
        .background(PhoneStyle.paper.ignoresSafeArea())
        .onAppear {
            if let launch = model.options.recorderSheet { sheetExpansion = launch }
            levels.adopt(model.levels, for: .microphone)
            runLevels()
            // VoiceOver: the screen changed under the person's finger; it starts on the clock.
            AccessibilityNotification.ScreenChanged(nil).post()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                clockFocused = true
            }
        }
        .onChange(of: model.recorder.isActive) { runLevels() }
        .onChange(of: PhoneRecorderStatus.phase(model.recorder.state, isFiling: model.isFiling)) { old, new in
            let pause = PhoneRecorderStatus.pause(model.recorder.state, message: model.recorder.pauseMessage, canResume: model.recorder.canResume)
            if let words = PhoneRecorderStatus.announcement(from: old, to: new, pause: pause) {
                AccessibilityNotification.Announcement(words).post()
            }
        }
        .onChange(of: model.recorder.isMicrophoneSilent) { _, silent in
            if silent, model.recorder.isCapturing { AccessibilityNotification.Announcement("Microphone silent").post() }
        }
        .onDisappear { levels.run(false, readers: readers) }
    }

    @ViewBuilder private var recorder: some View {
        switch style {
        case .pocket:
            surface(asleep: false)
                .daybookSurface(.column, density: .touch)
        case .notebook:
            GeometryReader { proxy in
                surface(asleep: false)
                    .daybookSurface(.spread(crease: CreaseGeometry.crease(width: proxy.size.width, leadingInset: proxy.safeAreaInsets.leading,
                                                                          trailingInset: proxy.safeAreaInsets.trailing)), density: .touch)
            }
        case .table:
            TableRecording { asleep, writing in surface(asleep: asleep, writing: writing) }
        }
    }

    private func surface(asleep: Bool, writing: Binding<Bool> = .constant(false)) -> RecorderSurface {
        let inputs = PhoneRecorderStatus.inputs(model)
        let recorder = model.recorder
        let started = recorder.startedAt ?? Date()
        let state = RecorderSurfaceState(
            phase: RecordingStatusWords.phase(inputs),
            title: recorder.title,
            byline: ["Today", started.formatted(date: .omitted, time: .shortened)].joined(separator: " · "),
            chips: RecordingStatusWords.chips(inputs),
            meters: RecordingStatusWords.meters(inputs),
            clock: .elapsed(isLive: recorder.state == .recording, frozenAt: recorder.pausedAt, value: { recorder.elapsedTime }),
            isLive: recorder.state == .recording,
            bookmarkCount: recorder.bookmarkCount,
            canBookmark: recorder.isCapturing && recorder.state != .starting,
            isSaving: recorder.state == .stopping || model.isFiling,
            pause: PhoneRecorderStatus.pause(recorder.state, message: recorder.pauseMessage, canResume: recorder.canResume),
            asleep: asleep,
            hasNotice: RecordingNotice.isShowing(model))
        let model = self.model
        let actions = RecorderSurfaceActions(
            bookmark: { Task { try? await model.addBookmark() } },
            stop: { Task { try? await model.stopRecording() } },
            resume: { Task { try? await model.resumeRecording() } })
        return RecorderSurface(state: state, levels: levels, actions: actions, slots: slots(writing: writing), writing: writing,
                               clockFocus: $clockFocused, sheetExpansion: $sheetExpansion)
    }

    private func slots(writing: Binding<Bool>) -> RecorderSlots {
        let session = inkSession
        // Write by Hand between Bookmark and Stop: a finger writes on the notes, and the tools dock under them.
        let write: (RecorderControlMetrics) -> AnyView = { AnyView(WriteByHandControl(session: session, metrics: $0)) }
        // `--write-notes`: the notes take the caret, so the keyboard and its bar are up.
        let focus = model.options.writeNotes
        switch style {
        case .pocket:
            // In the hand the notes come first: the captions' strip stops growing at the largest standard size, and
            // at the accessibility sizes keeps only its newest line. Under the whole recorder, the newest line alone
            // sits on the sheet, inset like the title over the notes.
            return RecorderSlots(notes: AnyView(RecordingNotes(session: session, focusOnAppear: focus).padding(.horizontal, DaybookSpacing.s4)),
                                 captions: AnyView(PhoneCaptions(style: typeSize.isAccessibilitySize ? .stripNewest : .strip)
                                    .padding(.horizontal, DaybookSpacing.s2)
                                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)),
                                 captionLine: AnyView(PhoneCaptionLine()
                                    .padding(.horizontal, DaybookSpacing.s5 + DaybookSpacing.s2)
                                    .padding(.vertical, DaybookSpacing.s2)
                                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)),
                                 accessory: AnyView(CameraControl.phaseRow), details: AnyView(LiveTimelineBar()), notice: AnyView(RecordingNotice()),
                                 log: AnyView(ScrollView { BookmarkLog() }.scrollBounceBehavior(.basedOnSize)), write: write,
                                 menu: { AnyView(PhoneChipMenu(chip: $0)) })
        case .notebook:
            // Captions take the space when they're on: they're the live sign that the audio is being heard, while
            // bookmarks already show twice (the notes' lane and the timeline's amber ticks). Without captions, the
            // bookmark log returns. At the accessibility sizes, as in the hand, only the newest line.
            let captions = model.captions.isShowing
                ? AnyView(PhoneCaptions(style: typeSize.isAccessibilitySize ? .stripNewest : .page)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge))
                : AnyView(ScrollView { BookmarkLog().padding(.top, DaybookSpacing.s1) }.scrollBounceBehavior(.basedOnSize))
            return RecorderSlots(notes: AnyView(RecordingNotes(session: session, focusOnAppear: focus)), captions: captions,
                                 accessory: AnyView(CameraControl.phaseRow), details: AnyView(LiveTimelineBar()), notice: AnyView(RecordingNotice()),
                                 write: write, menu: { AnyView(PhoneChipMenu(chip: $0)) })
        case .table:
            return RecorderSlots(notes: AnyView(RecordingNotes(session: session, focusOnAppear: writing.wrappedValue)),
                                 captions: AnyView(PhoneCaptions(style: .stage)),
                                 tools: AnyView(TableTools(writing: writing)), menu: { AnyView(PhoneChipMenu(chip: $0)) })
        }
    }

    private var readers: RecorderLevels.Readers {
        let model = self.model
        return RecorderLevels.Readers(recorder: { id in
            guard let conversation = model.recorder.captureID else { return nil }
            return model.devices.hub.session(id)?.liveLevel(into: conversation)
        })
    }

    /// Samples the recorders' levels while recording; the microphone's trail is fed by the app as levels arrive.
    private func runLevels() {
        levels.run(model.recorder.isActive, readers: readers)
    }
}

/// What a chip's menu offers on the iPhone: a Mac that could record this conversation too.
private struct PhoneChipMenu: View {
    @Environment(PhoneAppModel.self) private var model
    let chip: RecorderChip

    var body: some View {
        if case .peer(let id) = chip.target, let mac = model.macsToRecordWith.first(where: { $0.id.uuidString == id }) {
            Button("Record on \(mac.name) Too") { Task { await model.recordOnMac(mac.id) } }
        }
    }
}

// MARK: - Table

/// How long table mode keeps the screen on after the last touch: long enough for a meeting read from across the
/// table, short enough that a phone forgotten on the table locks itself.
enum TableIdle {
    static let dimAfter: Duration = RecordingStyle.dimAfter
    static let awake: TimeInterval = 10 * 60

    /// Whether table mode holds Auto-Lock off: only while Daybook is in front and a touch was recent.
    static func keepsScreenOn(isActive: Bool, sinceTouch: TimeInterval) -> Bool { isActive && sinceTouch < awake }

    /// How the screen moves between awake and dimmed: a slow, calm dim; a quick wake; a short fade under Reduce
    /// Motion, never a cut from paper to black.
    static func animation(dimming: Bool, reduceMotion: Bool) -> Animation {
        DaybookMotion.resolved(dimming ? DaybookMotion.dim : DaybookMotion.fade, reduceMotion: reduceMotion)
    }
}

/// Partly open, standing on a table: readable from across it. A touch anywhere wakes it; Bookmark always works,
/// dimmed or not, while Stop and the tools ignore the touch that only wakes the screen. It keeps the screen on while
/// it's in front (Auto-Lock would otherwise lock a phone nobody touches), until a long stretch without a touch.
private struct TableRecording<Content: View>: View {
    @ViewBuilder let content: (_ asleep: Bool, _ writing: Binding<Bool>) -> Content
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var dimmed = false
    @State private var lastTouch = Date()
    @State private var writing = false

    var body: some View {
        GeometryReader { proxy in
            if model.options.interfaceOrientation == "preview-portrait", proxy.size.width > proxy.size.height {
                // Debug: the simulator can't turn the device, so draw flex mode turned within the landscape window, as
                // the turned display would show it.
                let full = CGSize(width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                                  height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
                stage
                    .frame(width: full.height, height: full.width)
                    .rotationEffect(.degrees(-90))
                    .frame(width: full.width, height: full.height)
                    .offset(x: -proxy.safeAreaInsets.leading, y: -proxy.safeAreaInsets.top)
            } else {
                stage
            }
        }
        // Dimmed, it goes dark: black ground (cheap on OLED), the clock and target in their dark inks at low
        // brightness, still readable from across the table.
        .environment(\.colorScheme, dimmed ? .dark : colorScheme)
        .opacity(dimmed ? RecordingStyle.dimmedOpacity : 1)
        .background((dimmed ? Color.black : PhoneStyle.paper).ignoresSafeArea())
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { wake() })
        .animation(TableIdle.animation(dimming: dimmed, reduceMotion: reduceMotion), value: dimmed)
        .task(id: lastTouch) {
            keepAwake()
            try? await Task.sleep(for: TableIdle.dimAfter)
            guard !Task.isCancelled else { return }
            if !model.recorder.isPaused, !writing { dimmed = true }
            // After a long stretch with nobody touching it, Auto-Lock may take over again.
            try? await Task.sleep(for: .seconds(TableIdle.awake) - TableIdle.dimAfter)
            guard !Task.isCancelled else { return }
            keepAwake()
        }
        .onChange(of: model.recorder.isPaused) { _, paused in if paused { wake() } }
        .onChange(of: writing) { wake() }
        .onChange(of: scenePhase) { keepAwake() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .persistentSystemOverlays(.hidden)
        .onAppear {
            InterfaceOrientation.apply(model.options.interfaceOrientation)
            if model.options.writeNotes { writing = true }
        }
    }

    private var stage: some View {
        content(dimmed, $writing).daybookSurface(.stage, density: .touch)
    }

    private func wake() {
        dimmed = false
        lastTouch = Date()
    }

    private func keepAwake() {
        UIApplication.shared.isIdleTimerDisabled = TableIdle.keepsScreenOn(isActive: scenePhase == .active,
                                                                          sinceTouch: Date().timeIntervalSince(lastTouch))
    }
}

/// Write Notes (Done while writing) and Take Photo, beside Stop, labelled like the controls around them.
private struct TableTools: View {
    @Binding var writing: Bool
    private let size: CGFloat = 52

    var body: some View {
        HStack(alignment: .top, spacing: DaybookSpacing.s3) {
            VStack(spacing: DaybookSpacing.s1) {
                Button { writing.toggle() } label: {
                    Image(systemName: writing ? "keyboard.chevron.compact.down" : "square.and.pencil")
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundStyle(DaybookPalette.Ink.title)
                        .frame(width: size, height: size)
                        .contentShape(Circle())
                }
                .daybookControl(.standard, shape: .circle)
                .accessibilityLabel(writing ? "Done Writing" : "Write Notes")
                label(writing ? "Done" : "Notes")
            }
            if CameraPicker.isAvailable {
                VStack(spacing: DaybookSpacing.s1) {
                    CameraControl(size: size)
                    label("Photo")
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(DaybookPalette.Ink.secondary)
            .lineLimit(1)
            .accessibilityHidden(true)
    }
}
