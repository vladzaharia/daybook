import AppKit
import DaybookCore
import DaybookDesign
import DaybookKit
import SwiftUI

// The call prompt (docs/capture.md, "Calls"; docs/interface.md, "Call prompt"): a small panel where Floating Notes
// opens, asking whether to record a call that has just started (Record grows it into Floating Notes), or, when a call
// ends during a recording the person started, whether to stop. Like Floating Notes it floats over a full-screen call on
// every Space, never takes focus from it, and stays out of screen shares.

/// What the person answered, or the answer the prompt gave itself when its time ran out.
enum CallPromptAnswer: Equatable, Sendable {
    case record, alwaysRecord, notNow, never
    case stop, keepRecording
}

/// What the prompt asks.
enum CallPromptQuestion: Equatable, Sendable {
    /// A call has started, in the calendar's meeting when it has one: record it?
    case record(MeetingCandidate, event: MeetingEvent?)
    /// The call ended while a recording the person started went on: stop it?
    case ended(MeetingCandidate)
    /// A meeting with other people is starting, with no call announcing it: record it?
    case meetingStarts(MeetingEvent)
    /// The meeting recorded from its start has ended: stop it?
    case meetingEnded(MeetingEvent)

    /// Whether it asks to start a recording, rather than whether to stop one.
    var asksToRecord: Bool {
        switch self {
        case .record, .meetingStarts: true
        case .ended, .meetingEnded: false
        }
    }

    /// The call's app, whose icon it shows; none for a meeting, which shows the calendar's.
    var app: String? {
        switch self {
        case .record(let call, _), .ended(let call): call.bundleID
        case .meetingStarts, .meetingEnded: nil
        }
    }

    /// How long it waits for an answer, and the one it gives itself then: a call is left alone, a recording goes on.
    var wait: TimeInterval { asksToRecord ? 15 : 30 }
    var unanswered: CallPromptAnswer { asksToRecord ? .notNow : .keepRecording }

    var title: String {
        switch self {
        case .record(let call, _): call.callName.prefix(1).uppercased() + call.callName.dropFirst()
        case .ended(let call): "The \(call.callName) ended"
        case .meetingStarts(let event): event.title
        case .meetingEnded(let event): "\(event.title) ended"
        }
    }

    var subtitle: String {
        switch self {
        case .record(let call, let event?): [event.title, event.peopleLine].compactMap { $0 }.joined(separator: " · ")
        case .record(let call, nil): call.windowTitle == call.appName ? "Record it?" : call.windowTitle
        case .meetingStarts(let event): ["Starting now", event.peopleLine].compactMap { $0 }.joined(separator: " · ")
        case .ended, .meetingEnded: "Stop recording?"
        }
    }

    /// What VoiceOver says as it appears.
    var announcement: String {
        switch self {
        case .record: "\(title) started. Record it?"
        case .ended(let call): "The \(call.callName) ended. Stop recording?"
        case .meetingStarts(let event): "\(event.title) is starting. Record it?"
        case .meetingEnded(let event): "\(event.title) ended. Stop recording?"
        }
    }
}

@MainActor
@Observable
final class CallPromptModel {
    let question: CallPromptQuestion
    /// What's left of the wait, from 1 to 0.
    var remaining: Double = 1
    var isHovering = false
    @ObservationIgnored var answer: (CallPromptAnswer) -> Void = { _ in }

    init(question: CallPromptQuestion) { self.question = question }
}

/// The prompt's one panel, made when first needed and kept, hidden rather than closed.
@MainActor
final class CallPromptWindow {
    static let shared = CallPromptWindow()

    static let size = NSSize(width: 340, height: 108)

    private var panel: NSPanel?
    private var model: CallPromptModel?
    private var answered: ((CallPromptAnswer) -> Void)?
    private var countdown: Task<Void, Never>?
    private let hover = CallPromptHover()

    var question: CallPromptQuestion? { panel?.isVisible == true ? model?.question : nil }

    /// Shows `question`, replacing one already showing (which gets no answer). `answer` hears what the person chose,
    /// or the question's own answer when its time runs out.
    func ask(_ question: CallPromptQuestion, answer: @escaping (CallPromptAnswer) -> Void) {
        countdown?.cancel()
        let panel = self.panel ?? makePanel()
        let model = CallPromptModel(question: question)
        model.answer = { [weak self] in self?.finish($0) }
        self.model = model
        answered = answer
        hover.model = model
        let hosting = NSHostingView(rootView: CallPromptView(model: model))
        hover.track(hosting)
        panel.contentView = hosting
        panel.setFrame(Self.frame(under: FloatingNotesWindow.shared.restingFrame), display: true)
        panel.alphaValue = 1
        // Appearing must not take typing focus from the call.
        panel.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: question.announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        countdown = Task { [weak self] in await self?.count(down: question.wait) }
    }

    /// Takes the prompt away without an answer: the setting went Off.
    func dismiss() {
        countdown?.cancel()
        answered = nil
        panel?.orderOut(nil)
    }

    /// The call it asks about to record has ended: the question goes with it, answered Not Now.
    func callEnded() {
        if let question, case .record = question { finish(.notNow) }
    }

    /// The recording it asks about stopping has ended some other way: the question goes, unanswered.
    func recordingEnded() {
        if let question, !question.asksToRecord { dismiss() }
    }

    /// Where it shows: the top-trailing corner of where Floating Notes opens, so Record can grow it into the notes.
    static func frame(under notes: NSRect) -> NSRect {
        NSRect(x: notes.maxX - size.width, y: notes.maxY - size.height, width: size.width, height: size.height)
    }

    private func count(down seconds: TimeInterval) async {
        let step = 0.1
        var left = seconds
        while left > 0 {
            try? await Task.sleep(for: .seconds(step))
            guard !Task.isCancelled, let model else { return }
            // The pointer over the prompt holds the time, so reading it never costs the answer.
            if !model.isHovering { left -= step }
            model.remaining = max(0, left / seconds)
        }
        guard !Task.isCancelled, let model else { return }
        finish(model.question.unanswered)
    }

    private func finish(_ answer: CallPromptAnswer) {
        countdown?.cancel()
        guard let answered else { return }
        self.answered = nil
        answered(answer)
        guard let panel else { return }
        let showsNotes = LaunchOptions.defaults.object(forKey: AppState.Preference.showsFloatingNotesWhileRecording) as? Bool ?? true
        if answer == .record || answer == .alwaysRecord, showsNotes, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Record grows the prompt into Floating Notes, which takes its place as the recording starts.
            let notes = FloatingNotesWindow.shared.restingFrame
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(notes, display: true)
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    panel.alphaValue = 1
                }
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    panel.alphaValue = 1
                }
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // It names the call: kept out of screen shares and screenshots, as Floating Notes is.
        panel.sharingType = .none
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.title = "Call"
        self.panel = panel
        return panel
    }
}

/// The pointer over the prompt. SwiftUI's own hover tracking isn't reliable in a non-key panel of an inactive app,
/// which is the prompt's only state.
@MainActor
final class CallPromptHover: NSResponder {
    weak var model: CallPromptModel?
    private var area: NSTrackingArea?

    func track(_ view: NSView) {
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        view.addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { model?.isHovering = true }
    override func mouseExited(with event: NSEvent) { model?.isHovering = false }
}

/// The prompt: the app's icon, what happened, and the answers, with the time left drawn along its foot.
struct CallPromptView: View {
    let model: CallPromptModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String { model.question.title }
    private var subtitle: String { model.question.subtitle }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .top, spacing: Space.s3) {
                if let app = model.question.app {
                    AppIcon(bundleID: app)
                } else {
                    CalendarIcon()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if case .record(let call, _) = model.question {
                    let appName = CallPolicy.appName(for: call.bundleID)
                    Menu {
                        Button("Always Record \(appName) Calls") { model.answer(.alwaysRecord) }
                        Button("Never for \(appName)") { model.answer(.never) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More")
                }
            }
            HStack(spacing: Space.s2) {
                Spacer(minLength: 0)
                if model.question.asksToRecord {
                    Button("Not Now") { model.answer(.notNow) }
                    // The panel is never active, so a prominent button would draw grey: the record dot keeps its red.
                    Button { model.answer(.record) } label: {
                        Label {
                            Text("Record")
                        } icon: {
                            Image(systemName: "record.circle.fill").foregroundStyle(DaybookPalette.Ink.record)
                        }
                    }
                } else {
                    Button("Keep Recording") { model.answer(.keepRecording) }
                    Button("Stop") { model.answer(.stop) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.regular)
        }
        .padding(Space.s4)
        .frame(width: CallPromptWindow.size.width, height: CallPromptWindow.size.height, alignment: .topLeading)
        .background(DaybookPalette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottom) {
            // The time left: a hairline that drains, holding while the pointer is over the prompt.
            GeometryReader { geometry in
                Capsule()
                    .fill(DaybookPalette.Ink.link.opacity(0.55))
                    .frame(width: geometry.size.width * model.remaining, height: 2)
                    .animation(reduceMotion ? nil : .linear(duration: 0.1), value: model.remaining)
            }
            .frame(height: 2)
            .padding(.horizontal, 14)
            .padding(.bottom, 3)
            .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

}

/// A meeting's icon, in the calendar's red.
private struct CalendarIcon: View {
    var body: some View {
        Image(systemName: "calendar")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The app's own icon, or a phone for an app this Mac doesn't have.
private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "phone.fill").resizable().scaledToFit().padding(6).foregroundStyle(.secondary)
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}

// MARK: - Answers

extension AppState {
    /// Asks whether to record `call`, which has just started (When a call starts: Ask, or the app's own Ask). Record
    /// grows the prompt into Floating Notes as the recording starts; Not Now, or no answer in time, leaves the call alone
    /// until it ends; Always Record and Never are the app's from then on.
    func askToRecord(_ call: MeetingCandidate, in event: MeetingEvent? = nil) {
        CallPromptWindow.shared.ask(.record(call, event: event)) { [weak self] answer in
            self?.answered(answer, about: call, in: event)
        }
    }

    /// Asks whether to record a meeting with other people that's starting with no call to announce it (Use Calendar).
    /// Record records it under its title, as the person's own recording, and asks again once it's over whether to stop.
    func askToRecord(_ meeting: MeetingEvent) {
        askedMeetings.insert(meeting.id)
        CallPromptWindow.shared.ask(.meetingStarts(meeting)) { [weak self] answer in
            guard let self, answer == .record, self.recordingID == nil, !self.isStartingRecording else { return }
            Task {
                await self.startRecording(title: meeting.title)
                if let id = self.recordingID { self.calendarMeeting = (id, meeting) }
            }
        }
    }

    /// The meeting recorded from its start is over: asked whether to stop, never stopped.
    func askToStop(after meeting: MeetingEvent) {
        let recording = recordingID
        CallPromptWindow.shared.ask(.meetingEnded(meeting)) { [weak self] answer in
            guard answer == .stop, let self, self.recordingID == recording else { return }
            Task { await self.stopRecording(manual: true) }
        }
    }

    /// A recording the person started, during `call`, which has now ended: asked whether to stop, never stopped. No
    /// answer in time keeps it recording.
    func askToStop(after call: MeetingCandidate) {
        let recording = recordingID
        CallPromptWindow.shared.ask(.ended(call)) { [weak self] answer in
            // Only the recording it asked about: never one started since.
            guard answer == .stop, let self, self.recordingID == recording else { return }
            Task { await self.stopRecording(manual: true) }
        }
    }

    func answered(_ answer: CallPromptAnswer, about call: MeetingCandidate, in event: MeetingEvent? = nil) {
        switch answer {
        case .record, .alwaysRecord:
            if answer == .alwaysRecord { callAppChoices[call.bundleID] = .always }
            // A recording already under way (started by the person meanwhile) is the call's, as when the call started
            // during it: the line says so, and the call ending asks whether to stop it.
            monitor.callRecordingStarted()
            guard recordingID == nil, !isStartingRecording else { return }
            // Started for a call, it stops when the call ends, as one recorded automatically does.
            Task { await startRecording(title: event?.title ?? call.windowTitle, automatic: true) }
        case .never:
            callAppChoices[call.bundleID] = .never
            monitor.suppressCurrentMeeting()
        case .notNow:
            monitor.suppressCurrentMeeting()
        case .stop, .keepRecording:
            break
        }
    }
}

// MARK: - Demo

/// `--call-prompt-demo record|ended|meeting|meeting-ended` (debug builds): the prompt about a Zoom call or a calendar
/// meeting, for screenshots, answering nothing.
@MainActor
enum CallPromptDemo {
    static func apply(to state: AppState) {
        #if DEBUG
        guard let kind = LaunchOptions.value(after: "--call-prompt-demo") else { return }
        let call = MeetingCandidate(bundleID: "us.zoom.xos", appName: "Zoom", windowTitle: "Zoom Meeting",
                                    hasInputActivity: true, hasOutputActivity: true, hasMeetingWindow: true, isBrowser: false)
        let meeting = MeetingEvent(id: "demo", title: "Weekly product sync", start: Date(), end: Date().addingTimeInterval(1800), attendees: 4)
        let question: CallPromptQuestion = switch kind {
        case "ended": .ended(call)
        case "meeting": .meetingStarts(meeting)
        case "meeting-ended": .meetingEnded(meeting)
        default: .record(call, event: meeting)
        }
        CallPromptWindow.shared.ask(question) { _ in }
        #endif
    }
}
