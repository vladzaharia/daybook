import DaybookCore
import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI

/// A Stop seen on the recorder: the conversation, and how filing stood when the recording began, so the outcome
/// of this Stop is told from an earlier one.
struct AfterStop: Equatable {
    var conversationID: UUID
    var title: String
    var startedAt: Date?
    /// `PhoneAppModel.lastFiling` as the recording began.
    var before: PhoneAppModel.Filing?

    /// What became of the recording.
    enum Outcome: Equatable {
        /// Still being added to the library.
        case saving
        case saved(UUID)
        /// Not added; the sentence says why and what happens to it.
        case failed(String)
        /// Nothing to show (nothing was recorded): back to the library.
        case none
    }

    static func outcome(isActive: Bool, isFiling: Bool, filing: PhoneAppModel.Filing?, since before: PhoneAppModel.Filing?) -> Outcome {
        if isActive || isFiling { return .saving }
        guard let filing, filing != before else { return .none }
        switch filing {
        case .saved(let id, _): return .saved(id)
        case .failed(let sentence): return .failed(sentence)
        }
    }

    /// How long the Saved moment stays before the library comes back, unless the person is writing.
    static let lingers: Duration = .seconds(10)
}

/// After Stop on the iPhone, as Floating Notes shows it on the Mac: Saved with the conversation's length, its title
/// and notes, Open where Bookmark was and Keep Recording where Stop was, for about ten seconds. Keep Recording records
/// into the same conversation, after what was saved, so a Stop pressed by mistake doesn't split a meeting in two.
struct PhoneAfterStop: View {
    let afterStop: AfterStop
    let style: SurfaceStyle
    let done: () -> Void
    @Environment(PhoneAppModel.self) private var model
    @Environment(ReadingSession.self) private var reading
    @State private var writing = false

    private var outcome: AfterStop.Outcome {
        AfterStop.outcome(isActive: model.recorder.isActive, isFiling: model.isFiling, filing: model.lastFiling, since: afterStop.before)
    }

    var body: some View {
        let outcome = self.outcome
        GeometryReader { proxy in
            RecorderAfterStop(state: state(outcome), actions: actions(outcome), notes: AnyView(notes(outcome)))
                .daybookSurface(layout(proxy), density: .touch)
        }
        .sensoryFeedback(trigger: outcome) { _, new in
            // Whether it saved, felt when it's known, not at the press.
            switch new {
            case .saved: return .success
            case .failed: return .error
            case .saving, .none: return nil
            }
        }
        .onChange(of: outcome, initial: true) { _, new in
            switch new {
            case .saved: AccessibilityNotification.Announcement("Saved").post()
            case .failed(let sentence): AccessibilityNotification.Announcement(sentence).post()
            case .none: done()
            case .saving: break
            }
        }
        .task(id: outcome) {
            guard case .saved = outcome else { return }
            try? await Task.sleep(for: AfterStop.lingers)
            guard !Task.isCancelled, !writing else { return }
            done()
        }
        .onChange(of: writing) { _, writing in
            // Writing holds the moment; done writing, it gives the library back after a pause.
            guard !writing else { return }
            Task { @MainActor in
                try? await Task.sleep(for: AfterStop.lingers)
                if !self.writing, case .saved = self.outcome { done() }
            }
        }
    }

    private func layout(_ proxy: GeometryProxy) -> SurfaceLayout {
        guard style == .notebook else { return .column }
        return .spread(crease: CreaseGeometry.crease(width: proxy.size.width, leadingInset: proxy.safeAreaInsets.leading,
                                                     trailingInset: proxy.safeAreaInsets.trailing))
    }

    private func meeting(_ outcome: AfterStop.Outcome) -> Meeting? {
        guard case .saved(let id) = outcome else { return nil }
        return model.library.controller.meeting(id)
    }

    private func state(_ outcome: AfterStop.Outcome) -> RecorderAfterStopState {
        let meeting = meeting(outcome)
        var inputs = RecordingStatusInputs()
        inputs.phase = outcome == .saving ? .saving : .saved
        inputs.duration = meeting?.duration
        let library = model.library.controller
        var problem: RecorderProblem?
        if case .failed(let sentence) = outcome { problem = RecorderProblem(title: "Couldn’t add the recording", message: sentence) }
        let date = meeting?.date ?? afterStop.startedAt
        return RecorderAfterStopState(
            phase: problem == nil ? RecordingStatusWords.phase(inputs) : nil,
            title: meeting?.title ?? afterStop.title,
            rename: meeting.map { meeting in { title in library.rename(meeting.id, to: title) } },
            meta: date.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) },
            problem: problem,
            openTitle: meeting?.summary != nil ? "Open Summary" : "Open",
            canOpen: meeting != nil,
            recordTitle: meeting != nil ? "Keep Recording" : "Record",
            canRecord: model.recorder.state == .idle && !model.isFiling)
    }

    private func actions(_ outcome: AfterStop.Outcome) -> RecorderAfterStopActions {
        let model = self.model, reading = self.reading, done = self.done
        let meeting = meeting(outcome)
        return RecorderAfterStopActions(
            open: {
                guard let meeting else { return }
                reading.open(meeting.id)
                done()
            },
            record: {
                // Into the same conversation, after what was saved; a recording that couldn't be added starts anew.
                Task { try? await model.startRecording(into: meeting?.id, title: meeting?.title, multipoint: nil) }
            })
    }

    @ViewBuilder
    private func notes(_ outcome: AfterStop.Outcome) -> some View {
        if let meeting = meeting(outcome) {
            let library = model.library.controller
            MarginNotesEditor(
                text: Binding(get: { library.meeting(meeting.id)?.notes ?? meeting.notes }, set: { library.editNotes(meeting.id, text: $0) }),
                times: meeting.paragraphTimes(),
                marks: meeting.highlights.map { NoteMark(id: $0.id.uuidString, kind: .bookmark, time: meeting.alignedTime(for: $0) ?? $0.time) },
                scrolls: true,
                bottomInset: DaybookSpacing.s3,
                onFocusChange: { writing = $0 })
        } else {
            Color.clear
        }
    }
}
