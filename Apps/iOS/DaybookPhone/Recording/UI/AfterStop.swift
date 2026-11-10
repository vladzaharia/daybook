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

 static func outcome(
  isActive: Bool, isFiling: Bool, filing: PhoneAppModel.Filing?, since before: PhoneAppModel.Filing?
 ) -> Outcome {
  if isActive || isFiling { return .saving }
  guard let filing, filing != before else { return .none }
  switch filing {
  case .saved(let id, _): return .saved(id)
  case .failed(let sentence): return .failed(sentence)
  }
 }

 /// How long the Saved moment stays before the library comes back, unless the person is writing.
 static let lingers: Duration = .seconds(10)

 /// How long the moment stays before it gives the library back on its own: `lingers`, once the recording is saved
 /// or couldn't be added (that notice stays in the library, over Record); nil while it's saving. With nothing to
 /// show, the library comes back at once.
 static func stay(for outcome: Outcome) -> Duration? {
  switch outcome {
  case .saved, .failed: return lingers
  case .saving, .none: return nil
  }
 }

 /// What the control where Stop was does, by the rule both apps share (`RecordMore`): Keep Recording into the
 /// conversation within two minutes of the Stop (said while it's still being added, so the words don't change as it
 /// lands), Record Again after a recording that stopped on its own, else Record. One that couldn't be added records
 /// anew.
 static func recordMore(
  _ outcome: Outcome, stoppedShort: Bool, stoppedAt: Date?, now: Date = Date()
 ) -> RecordMore {
  switch outcome {
  case .saving, .saved: return RecordMore(stoppedShort: stoppedShort, stoppedAt: stoppedAt, now: now)
  case .failed, .none: return .record
  }
 }
}

/// One cancellable timer for the saved moment. Any note-editing surface suspends it; leaving that
/// surface starts a fresh full linger instead of allowing an older timer to expire underneath it.
@MainActor
final class AfterStopLinger {
 private var task: Task<Void, Never>?

 func update(stay: Duration?, writing: Bool, done: @escaping () -> Void) {
  task?.cancel()
  task = nil
  guard !writing, let stay else { return }
  task = Task { @MainActor [weak self] in
   do { try await Task.sleep(for: stay) } catch { return }
   guard !Task.isCancelled, let self else { return }
   self.task = nil
   done()
  }
 }
}

/// After Stop on the iPhone, as Floating Notes shows it on the Mac: Saved with the conversation's length, what's
/// becoming of it in a chip ("Transcribing · 40%", "Waiting for your Mac"), its title and notes, Open where Bookmark
/// was and Keep Recording where Stop was, for about ten seconds. Keep Recording records into the same conversation,
/// after what was saved, so a Stop pressed by mistake doesn't split a meeting in two; two minutes on (writing holds
/// the moment), it's Record, for a new one (`RecordMore`).
struct PhoneAfterStop: View {
 let afterStop: AfterStop
 let style: SurfaceStyle
 let done: () -> Void
 @Environment(PhoneAppModel.self) private var model
 @Environment(ReadingSession.self) private var reading
 @State private var writing = false
 @State private var inkSession = InkSession()
 @State private var linger = AfterStopLinger()
 /// The Stop: the moment appears with it.
 @State private var stoppedAt = Date()
 /// Keep Recording's two minutes have passed.
 @State private var windowPassed = false

 private var outcome: AfterStop.Outcome {
  AfterStop.outcome(
   isActive: model.recorder.isActive, isFiling: model.isFiling, filing: model.lastFiling,
   since: afterStop.before)
 }

 var body: some View {
  let outcome = self.outcome
  // Read once, so the words and what the press does agree.
  let more = AfterStop.recordMore(
   outcome, stoppedShort: model.recorder.unexpectedStop != nil,
   stoppedAt: windowPassed ? nil : stoppedAt)
  GeometryReader { proxy in
   RecorderAfterStop(
    state: state(outcome, more: more), actions: actions(outcome, more: more),
    notes: AnyView(notes(outcome))
   )
   .daybookSurface(layout(proxy), density: .touch)
  }
  .task {
   // Keep Recording gives way to Record once its two minutes pass.
   do { try await Task.sleep(for: .seconds(RecordMore.window)) } catch { return }
   windowPassed = true
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
   linger.update(stay: AfterStop.stay(for: new), writing: writing || inkSession.showsTools, done: done)
  }
  .onChange(of: writing) { _, isWriting in
   // Writing holds the moment; done writing, it gives the library back after a pause.
   linger.update(stay: AfterStop.stay(for: outcome), writing: isWriting || inkSession.showsTools, done: done)
  }
  .onChange(of: inkSession.showsTools) { _, isHandwriting in
   linger.update(stay: AfterStop.stay(for: outcome), writing: writing || isHandwriting, done: done)
  }
 }

 private func layout(_ proxy: GeometryProxy) -> SurfaceLayout {
  guard style == .notebook else { return .column }
  return .spread(
   crease: CreaseGeometry.crease(
    width: proxy.size.width, leadingInset: proxy.safeAreaInsets.leading,
    trailingInset: proxy.safeAreaInsets.trailing))
 }

 private func meeting(_ outcome: AfterStop.Outcome) -> Meeting? {
  guard case .saved(let id) = outcome else { return nil }
  return model.library.controller.meeting(id)
 }

 private func state(_ outcome: AfterStop.Outcome, more: RecordMore) -> RecorderAfterStopState {
  let meeting = meeting(outcome)
  var inputs = RecordingStatusInputs()
  inputs.phase = outcome == .saving ? .saving : .saved
  inputs.duration = meeting?.duration
  let library = model.library.controller
  var problem: RecorderProblem?
  if case .failed(let sentence) = outcome {
   problem = RecorderProblem(title: "Couldn’t add the recording", message: sentence)
  }
  let date = meeting?.date ?? afterStop.startedAt
  return RecorderAfterStopState(
   phase: problem == nil ? RecordingStatusWords.phase(inputs) : nil,
   title: meeting?.title ?? afterStop.title,
   rename: meeting.map { meeting in { title in library.rename(meeting.id, to: title) } },
   chips: chips(meeting),
   meta: date.map {
    $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
   },
   problem: problem,
   openTitle: meeting?.summary != nil ? "Open Summary" : "Open",
   canOpen: meeting != nil,
   recordMore: more,
   canRecord: model.recorder.state == .idle && !model.isFiling)
 }

 /// What's becoming of the recording, as the Mac's panel says it: the conversation's processing, in the words its
 /// library row says.
 private func chips(_ meeting: Meeting?) -> [RecorderChip] {
  guard let meeting else { return [] }
  let context = PhoneRowStatus.context(
   model: model, library: model.library.controller, player: reading.player)
  let row = PhoneRowStatus.make(meeting, context: context, now: Date())
  return RecordingStatusWords.processingChip(row).map { [$0] } ?? []
 }

 private func actions(_ outcome: AfterStop.Outcome, more: RecordMore) -> RecorderAfterStopActions {
  let model = self.model
  let reading = self.reading
  let done = self.done
  let meeting = meeting(outcome)
  let into = more.recordsIntoSameConversation ? meeting : nil
  return RecorderAfterStopActions(
   open: {
    guard let meeting else { return }
    reading.open(meeting.id)
    done()
   },
   record: {
    // Into the same conversation, after what was saved; Record, or one that couldn't be added, starts anew.
    Task {
     try? await model.startRecording(into: into?.id, title: into?.title, multipoint: nil)
    }
   })
 }

 @ViewBuilder
 private func notes(_ outcome: AfterStop.Outcome) -> some View {
  if let meeting = meeting(outcome) {
   let library = model.library.controller
   let notes = Binding(
    get: { library.meeting(meeting.id)?.notes ?? meeting.notes },
    set: { library.editNotes(meeting.id, text: $0) })
   WritableNotes(session: inkSession) {
    MarginNotesEditor(
     text: notes,
     times: meeting.paragraphTimes(),
     marks: meeting.highlights.map {
      NoteMark(id: $0.id.uuidString, kind: .bookmark, time: meeting.alignedTime(for: $0) ?? $0.time)
     },
     scrolls: true,
     bottomInset: WritableNotes<EmptyView>.toolsHeight,
     onFocusChange: { writing = $0 },
     ink: .conversation(meeting.id, library: library, session: inkSession))
   }
   // Inset as the recording's notes are in the column, so they stay put as Stop lands.
   .padding(.horizontal, style == .notebook ? 0 : DaybookSpacing.s4)
  } else {
   Color.clear
  }
 }
}
