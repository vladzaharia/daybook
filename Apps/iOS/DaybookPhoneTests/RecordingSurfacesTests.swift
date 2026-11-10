import DaybookCore
import DaybookDesign
import DaybookKit
import DaybookLink
import DaybookUI
import SwiftUI
import UIKit
import XCTest

@testable import DaybookPhone

/// What the widgets, the Control Center control, and the Live Activity show, and until when: a
/// recording the app stops confirming (it crashed, or the system stopped it) turns into "Not
/// confirmed" on its own instead of "Recording" forever; a paused clock is frozen; titles are private
/// on the Lock Screen; the Live Activity's buttons are readable. The state and timeline logic, not pixels.
@MainActor
final class RecordingSurfacesTests: XCTestCase {
 private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

 private func state(_ phase: SharedRecordingState.Phase, asOf: Date?) -> SharedRecordingState {
  var state = SharedRecordingState()
  state.phase = phase
  state.startedAt = now.addingTimeInterval(-723)
  state.pausedElapsed = phase == .paused ? 723 : nil
  state.title = "Design review"
  state.asOf = asOf
  state.lastRecordingTitle = "Standup"
  return state
 }

 // MARK: Widgets and the control

 func testARecordingTheAppStopsConfirmingBecomesNotConfirmed() {
  let recording = state(.recording, asOf: now)
  XCTAssertEqual(recording.display(at: now), .recording(since: now.addingTimeInterval(-723)))
  XCTAssertEqual(
   recording.display(at: now.addingTimeInterval(149)),
   .recording(since: now.addingTimeInterval(-723)))
  XCTAssertEqual(
   recording.display(at: now.addingTimeInterval(150)), .unconfirmed, "two confirmations missed")
  XCTAssertTrue(recording.isConfirmedActive(at: now))
  XCTAssertFalse(
   recording.isConfirmedActive(at: now.addingTimeInterval(151)), "the control turns off")

  // The widget's timeline changes on its own when the confirmation runs out.
  XCTAssertEqual(recording.timelineDates(from: now), [now, now.addingTimeInterval(150)])
  XCTAssertEqual(
   recording.timelineDates(from: now.addingTimeInterval(200)), [now.addingTimeInterval(200)])
  XCTAssertEqual(SharedRecordingState().timelineDates(from: now), [now])

  // A state an earlier build wrote while recording has no time: it isn't confirmed.
  XCTAssertEqual(state(.recording, asOf: nil).display(at: now), .unconfirmed)
  XCTAssertEqual(SharedRecordingState().display(at: now), .idle)
 }

 func testAPausedClockIsFrozenAndAPauseOutlastsACall() {
  let paused = state(.paused, asOf: now)
  XCTAssertEqual(
   paused.display(at: now.addingTimeInterval(3_000)), .paused(elapsed: 723),
   "the app may sleep through a call")
  XCTAssertEqual(paused.display(at: now.addingTimeInterval(2 * 3_600)), .unconfirmed)
  XCTAssertEqual(SharedRecordingState.inlineLine(.paused(elapsed: 723)), "Paused · 12:03")
  XCTAssertEqual(SharedRecordingState.inlineLine(.unconfirmed), "Open Daybook to check")
  XCTAssertEqual(SharedRecordingState.inlineLine(.idle), "Daybook ready")
  XCTAssertEqual(SharedRecordingState.headline(.paused(elapsed: 1)), "Paused")
  XCTAssertEqual(SharedRecordingState.headline(.unconfirmed), "Open Daybook to check")
 }

 func testBookmarksAreCountedInWords() {
  XCTAssertEqual(SharedRecordingState.bookmarks(1), "1 bookmark")
  XCTAssertEqual(SharedRecordingState.bookmarks(2), "2 bookmarks")
  XCTAssertEqual(SharedRecordingState.bookmarks(0), "0 bookmarks")
 }

 func testALaunchClearsWhatAnEarlierRunLeftRecording() throws {
  let left = state(.recording, asOf: now.addingTimeInterval(-30))
  let cleared = left.clearedAtLaunch()
  XCTAssertEqual(cleared.phase, .idle)
  XCTAssertNil(cleared.startedAt)
  XCTAssertNil(cleared.title)
  XCTAssertEqual(cleared.lastRecordingTitle, "Standup", "the last recording stays")
  let idle = SharedRecordingState()
  XCTAssertEqual(idle.clearedAtLaunch(), idle)

  // Through the app group's storage, as the app does at every launch.
  let defaults = makeTestDefaults("RecordingSurfacesTests")
  left.save(to: defaults)
  RecordingActivityController.clearLeftoversAtLaunch(defaults: defaults)
  XCTAssertEqual(SharedRecordingState.load(from: defaults).phase, .idle)
  XCTAssertEqual(SharedRecordingState.load(from: defaults).lastRecordingTitle, "Standup")
 }

 func testAStateFromAnEarlierBuildDecodes() throws {
  let earlier =
   #"{"phase":"recording","startedAt":800000000,"bookmarkCount":2,"lastRecordingTitle":"Standup"}"#
  let decoded = try JSONDecoder().decode(SharedRecordingState.self, from: Data(earlier.utf8))
  XCTAssertEqual(decoded.phase, .recording)
  XCTAssertNil(decoded.asOf)
  XCTAssertNil(decoded.pausedElapsed)
  XCTAssertEqual(decoded.bookmarkCount, 2)
 }

 func testTheAppConfirmsARecordingOnceAMinute() {
  let publisher = SharedStatePublisher()
  publisher.writes = false
  var recording = state(.recording, asOf: nil)
  publisher.publish(recording, now: now)
  XCTAssertEqual(publisher.published?.asOf, now)
  XCTAssertFalse(publisher.isDue(now: now.addingTimeInterval(59)))
  publisher.publish(recording, now: now.addingTimeInterval(30))
  XCTAssertEqual(
   publisher.published?.asOf, now, "unchanged and confirmed recently: nothing written")
  XCTAssertTrue(publisher.isDue(now: now.addingTimeInterval(60)))
  publisher.publish(recording, now: now.addingTimeInterval(60))
  XCTAssertEqual(publisher.published?.asOf, now.addingTimeInterval(60))
  recording.bookmarkCount = 1
  publisher.publish(recording, now: now.addingTimeInterval(61))
  XCTAssertEqual(publisher.published?.bookmarkCount, 1, "a change goes at once")
  publisher.publish(SharedRecordingState(), now: now.addingTimeInterval(62))
  XCTAssertFalse(
   publisher.isDue(now: now.addingTimeInterval(1_000)), "nothing to confirm when idle")
 }

 // MARK: The Live Activity

 func testTheLiveActivityGoesStaleWithoutTheAppAndSaysSo() {
  let recording = RecordingActivityAttributes.ContentState(
   phase: .recording, timerStart: now, level: 0.33, bookmarkCount: 1)
  XCTAssertEqual(recording.staleDate(from: now), now.addingTimeInterval(90))
  XCTAssertEqual(recording.title(isStale: false), "Recording")
  XCTAssertEqual(recording.title(isStale: true), "Open Daybook to check")
  var paused = recording
  paused.phase = .paused
  XCTAssertEqual(paused.staleDate(from: now), now.addingTimeInterval(2 * 3_600))
  XCTAssertEqual(paused.title(isStale: false), "Paused")
  var saved = recording
  saved.phase = .saved
  XCTAssertNil(saved.staleDate(from: now))
  XCTAssertEqual(saved.title(isStale: true), "Saved")
 }

 func testTheLiveActivityIsRefreshedAtLeastOnceAMinute() {
  let recording = RecordingActivityAttributes.ContentState(
   phase: .recording, timerStart: now, level: 0.33, bookmarkCount: 1)
  let send = {
   (state: RecordingActivityAttributes.ContentState, sentAt: Date, levelAt: Date, at: Date) in
   RecordingActivityController.shouldSend(
    state, current: recording, sentAt: sentAt, levelSentAt: levelAt, now: at)
  }
  XCTAssertFalse(send(recording, now, now, now.addingTimeInterval(30)), "nothing changed")
  XCTAssertTrue(
   send(recording, now, now, now.addingTimeInterval(60)), "the stale date keeps rolling")
  XCTAssertTrue(
   RecordingActivityController.shouldSend(
    recording, current: nil, sentAt: .distantPast, levelSentAt: .distantPast, now: now))
  var louder = recording
  louder.level = 0.66
  XCTAssertFalse(send(louder, now, now, now.addingTimeInterval(1)), "level-only changes wait")
  XCTAssertTrue(send(louder, now, now, now.addingTimeInterval(2)))
  var bookmarked = recording
  bookmarked.bookmarkCount = 2
  XCTAssertTrue(send(bookmarked, now, now, now.addingTimeInterval(0.1)), "a change goes at once")
 }

 func testTheCaptionLineIsShortAndEndsWithWhatWasJustSaid() {
  typealias State = RecordingActivityAttributes.ContentState
  XCTAssertEqual(
   State.captionLine("  So the first   screen\nasks for a name "),
   "So the first screen asks for a name")
  XCTAssertNil(State.captionLine(nil))
  XCTAssertNil(State.captionLine("   "))
  let long =
   "Then we skip straight to inviting people, which tested well in the last round, though the empty state needs another pass"
  let line = State.captionLine(long)
  XCTAssertLessThanOrEqual(line?.count ?? .max, State.captionLength)
  XCTAssertEqual(line?.first, "…", "the start goes")
  XCTAssertTrue(
   line?.hasSuffix("the empty state needs another pass") == true, "the newest words stay")
  XCTAssertFalse(line?.dropFirst().hasPrefix(" ") ?? true, "whole words")
  XCTAssertEqual(State.captionLine(String(repeating: "a", count: 200))?.count, State.captionLength)
 }

 func testTheActivityShowsACaptionOnlyWhileCaptionsAreOnAndShowing() {
  let say = "Let's hold the fourteenth."
  XCTAssertEqual(
   PhoneAppModel.activityCaption(
    captionsOn: true, showing: true, forThisRecording: true, paused: false, unlocked: true, newest: say), say)
  XCTAssertNil(
   PhoneAppModel.activityCaption(
    captionsOn: false, showing: true, forThisRecording: true, paused: false, unlocked: true, newest: say))
  XCTAssertNil(
   PhoneAppModel.activityCaption(
    captionsOn: true, showing: false, forThisRecording: true, paused: false, unlocked: true, newest: say))
  XCTAssertNil(
   PhoneAppModel.activityCaption(
    captionsOn: true, showing: true, forThisRecording: false, paused: false, unlocked: true, newest: say))
  XCTAssertNil(
   PhoneAppModel.activityCaption(
    captionsOn: true, showing: true, forThisRecording: true, paused: true, unlocked: true, newest: say))
  XCTAssertNil(
   PhoneAppModel.activityCaption(
    captionsOn: true, showing: true, forThisRecording: true, paused: false, unlocked: true, newest: nil),
   "nothing heard yet, no line")
  XCTAssertNil(
   PhoneAppModel.activityCaption(
    captionsOn: true, showing: true, forThisRecording: true, paused: false, unlocked: false, newest: say),
   "locked, what was said never leaves the app, whatever a surface does with redaction")
 }

 /// A Personal conversation is never named outside the app: its Live Activity says only "Recording", and the
 /// Lock Screen leaves the name's line out rather than say it twice.
 func testBehaviorAPersonalConversationsLiveActivityIsCalledRecording() {
  XCTAssertEqual(
   RecordingActivityController.activityTitle("Session with Dr. Lee", personal: true), "Recording")
  XCTAssertEqual(
   RecordingActivityController.activityTitle("Design review", personal: false), "Design review")
  let personal = RecordingActivityAttributes(
   conversationID: UUID(),
   title: RecordingActivityController.activityTitle("Session with Dr. Lee", personal: true))
  XCTAssertFalse(personal.namesConversation)
  XCTAssertTrue(
   RecordingActivityAttributes(conversationID: UUID(), title: "Design review").namesConversation)
 }

 /// The Recorder widget names the newest conversation Daybook may name outside the app, never a Personal one, and
 /// follows the library: a conversation made Personal leaves it at once.
 func testBehaviorTheRecorderWidgetNeverNamesAPersonalConversation() async throws {
  let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "INSTALL-1")
  let model = PhoneAppModel(
   recorder: RecorderRig().recorder, library: library, posture: DevicePosture(),
   options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]))
  try await library.reload()
  let start = Date(timeIntervalSince1970: 1_800_000_000)
  let sync = library.controller.newMeeting(title: "Weekly product sync", date: start)
  _ = library.controller.newMeeting(
   title: "Session with Dr. Lee", date: start.addingTimeInterval(60), placement: .personal)
  try await waitUntil("the newest it may name") {
   model.sharedState.published?.lastRecordingTitle == "Weekly product sync"
  }
  XCTAssertEqual(model.sharedState.published?.lastRecordingDate, start)

  let call = library.controller.newMeeting(title: "Call with Mum", date: start.addingTimeInterval(120))
  try await waitUntil("a newer one") { model.sharedState.published?.lastRecordingTitle == "Call with Mum" }
  library.controller.update(call) { $0.placement = .personal }
  try await waitUntil("made Personal") {
   model.sharedState.published?.lastRecordingTitle == "Weekly product sync"
  }
  // Found Personal by its template: nothing left to name.
  library.controller.update(sync) { $0.kind = .therapy }
  try await waitUntil("nothing it may name") {
   model.sharedState.published != nil && model.sharedState.published?.lastRecordingTitle == nil
  }
  XCTAssertNil(PhoneAppModel.lastRecording(in: library.controller.meetings))
 }

 func testANewCaptionUpdatesTheActivityAtMostEveryFewSeconds() {
  var shown = RecordingActivityAttributes.ContentState(
   phase: .recording, timerStart: now, level: 0.33, bookmarkCount: 0)
  shown.caption = "So the first screen"
  var next = shown
  next.caption = "So the first screen asks for a name"
  let interval = RecordingActivityAttributes.ContentState.captionInterval
  let held = RecordingActivityController.paced(
   next, current: shown, captionSentAt: now, now: now.addingTimeInterval(interval - 1))
  XCTAssertEqual(held.caption, "So the first screen", "the line on screen stays until it's due")
  XCTAssertFalse(
   RecordingActivityController.shouldSend(
    held, current: shown, sentAt: now, levelSentAt: now,
    now: now.addingTimeInterval(interval - 1)), "so nothing is sent")
  let due = RecordingActivityController.paced(
   next, current: shown, captionSentAt: now, now: now.addingTimeInterval(interval))
  XCTAssertEqual(due.caption, next.caption)
  XCTAssertTrue(
   RecordingActivityController.shouldSend(
    due, current: shown, sentAt: now, levelSentAt: now, now: now.addingTimeInterval(interval)))
  var off = shown
  off.caption = nil
  XCTAssertNil(
   RecordingActivityController.paced(
    off, current: shown, captionSentAt: now, now: now.addingTimeInterval(1)
   ).caption,
   "a caption going away (captions off, paused) goes at once")
  var louder = next
  louder.level = 0.66
  XCTAssertEqual(
   RecordingActivityController.paced(
    louder, current: shown, captionSentAt: now, now: now.addingTimeInterval(3)
   ).caption,
   shown.caption, "a level update doesn't bring a new caption early")
 }

 func testAnActivityStateFromAnEarlierBuildDecodes() throws {
  let earlier =
   #"{"phase":"recording","timerStart":800000000,"level":0.33,"bookmarkCount":1,"multipoint":"Also on Studio Mac"}"#
  let decoded = try JSONDecoder().decode(
   RecordingActivityAttributes.ContentState.self, from: Data(earlier.utf8))
  XCTAssertNil(decoded.caption)
  XCTAssertEqual(decoded.multipoint, "Also on Studio Mac")
 }

 /// WCAG 2 contrast of each Live Activity button's label on its fill, in light, dark, and both with
 /// Increase Contrast.
 func testTheLiveActivitysButtonLabelsAreReadableOnTheirFills() {
  func luminance(_ rgb: UInt32) -> Double {
   func channel(_ value: UInt32) -> Double {
    let c = Double(value & 0xFF) / 255
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
   }
   return 0.2126 * channel(rgb >> 16) + 0.7152 * channel(rgb >> 8) + 0.0722 * channel(rgb)
  }
  func contrast(_ a: UInt32, _ b: UInt32) -> Double {
   let (x, y) = (luminance(a), luminance(b))
   return (max(x, y) + 0.05) / (min(x, y) + 0.05)
  }
  for (name, ink) in [
   ("bookmark", PhoneStyle.ActivityButton.bookmark), ("resume", PhoneStyle.ActivityButton.resume),
   ("stop", PhoneStyle.ActivityButton.stop),
  ] {
   for variant in 0..<4 {
    XCTAssertGreaterThanOrEqual(
     contrast(ink.fill[variant], ink.label[variant]), 4.5, "\(name), appearance \(variant)")
   }
  }
  XCTAssertEqual(PhoneStyle.ActivityButton.all.count, 3)
 }

 // MARK: Hearing and background cost

 private func recordingModel(_ rig: RecorderRig) throws -> PhoneAppModel {
  PhoneAppModel(
   recorder: rig.recorder,
   library: PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: "INSTALL-1"),
   posture: DevicePosture(),
   options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
   environment: try .test(self))
 }

 /// The recording surface and the Live Activity say "Microphone silent" while the hearing check does (five seconds of
 /// zeros here), and stop as soon as it hears again. The activity's level is only that, so the voice sends nothing.
 func testBehaviorMicrophoneSilentFollowsTheHearingCheckOnTheSurfaceAndTheLiveActivity() async throws {
  let rig = RecorderRig()
  let model = try recordingModel(rig)
  try await model.startRecording()
  rig.pump(1)
  rig.recorder.updateLevels()
  XCTAssertEqual(RecordingStatusWords.phase(PhoneRecorderStatus.inputs(model))?.detail, RecordingStatusWords.inputChoice("Synthetic Microphone"))
  XCTAssertEqual(model.activityState().level, 1)
  XCTAssertEqual(model.activityState().title(isStale: false), "Recording")

  rig.inputs.current.signal = .silence
  rig.pump(5.2)
  rig.recorder.updateLevels()
  let silent = try XCTUnwrap(RecordingStatusWords.phase(PhoneRecorderStatus.inputs(model)))
  XCTAssertEqual(silent.detail, "Microphone silent")
  XCTAssertTrue(silent.detailIsWarning)
  XCTAssertEqual(model.activityState().level, 0)
  XCTAssertEqual(model.activityState().title(isStale: false), "Microphone silent")

  rig.inputs.current.signal = .tone(frequency: 440, amplitude: 0.3)
  rig.pump(0.2)
  rig.recorder.updateLevels()
  XCTAssertEqual(RecordingStatusWords.phase(PhoneRecorderStatus.inputs(model))?.detail, RecordingStatusWords.inputChoice("Synthetic Microphone"))
  XCTAssertEqual(model.activityState().title(isStale: false), "Recording")
  try await model.stopRecording()
 }

 /// Out of sight, the meter reads twice a second (enough for the hearing check, the Live Activity, and the widgets)
 /// unless a Mac draws this iPhone's level; in front, fifteen times.
 func testBehaviorTheMeterSlowsOutOfSightUnlessAMacDrawsTheLevel() async throws {
  XCTAssertEqual(PhoneAppModel.meterInterval(inFront: true, macsDrawingLevel: false), PhoneRecorder.levelInterval)
  XCTAssertEqual(PhoneAppModel.meterInterval(inFront: false, macsDrawingLevel: true), PhoneRecorder.levelInterval)
  XCTAssertEqual(PhoneAppModel.meterInterval(inFront: false, macsDrawingLevel: false), 0.5)

  let rig = RecorderRig()
  let model = try recordingModel(rig)
  try await model.startRecording()
  XCTAssertEqual(rig.recorder.meterInterval, PhoneRecorder.levelInterval)
  model.scenePhaseChanged(.background)
  XCTAssertEqual(rig.recorder.meterInterval, PhoneRecorder.backgroundLevelInterval)
  model.scenePhaseChanged(.active)
  XCTAssertEqual(rig.recorder.meterInterval, PhoneRecorder.levelInterval)
  try await model.stopRecording()
 }
}

/// The recorder on the iPhone, as the recorder both apps share draws it: what it says about the recording and the
/// devices recording along, the pause, what VoiceOver hears, table mode's screen, the moment after Stop, and the
/// notes editor at the largest text sizes. Values and views in isolation: nothing is recorded.
@MainActor
final class RecorderScreenTests: XCTestCase {
 private func mac(_ name: String = "Studio Mac", recording conversation: UUID? = nil)
  -> PhoneLink.Mac
 {
  var mac = PhoneLink.Mac(id: UUID(), name: name, pairedAt: Date(timeIntervalSince1970: 0))
  mac.state = .connected
  if let conversation {
   mac.recording = LinkRecordingState(phase: .recording, conversationID: conversation)
  }
  return mac
 }

 func testBehaviorThePhaseIsTheRecordersAndSavingLastsUntilItsFiled() {
  XCTAssertEqual(PhoneRecorderStatus.phase(.starting, isFiling: false), .starting)
  XCTAssertEqual(PhoneRecorderStatus.phase(.recording, isFiling: false), .recording)
  XCTAssertEqual(PhoneRecorderStatus.phase(.paused(.interruption), isFiling: false), .paused)
  XCTAssertEqual(PhoneRecorderStatus.phase(.stopping, isFiling: true), .saving)
  XCTAssertEqual(
   PhoneRecorderStatus.phase(.idle, isFiling: true), .saving, "Saving until it's in the library")
  XCTAssertEqual(PhoneRecorderStatus.phase(.idle, isFiling: false), .idle)
 }

 /// Regression: the iPhone named only Macs ("Also recording on Studio Mac"); a recorder that didn't start said
 /// nothing until the transcript lacked its audio. Each now has the chip Floating Notes shows for it.
 func testBehaviorTheIPhoneShowsEachMacAndRecorderAlongAsFloatingNotesDoes() throws {
  let conversation = UUID()
  let asked = mac("Studio Mac")
  let onItsOwn = mac("Alex’s MacBook", recording: conversation)
  let free = mac("Desk Mac")
  let session = MultipointSession(
   conversationID: conversation, role: .phoneLed,
   macs: [.init(id: asked.id, name: asked.name, state: .recording, startedByPhone: true)])
  var inputs = RecordingStatusInputs()
  inputs.phase = .recording
  inputs.here = "this iPhone"
  inputs.peers = PhoneRecorderStatus.peers(
   multipoint: session, connected: [asked, onItsOwn, free], conversation: conversation)
  var soundcore = RecorderFacts(
   id: "sc", name: "Soundcore Work", shortName: "Soundcore", symbol: "recordingtape",
   isDirect: true,
   state: .connected, isLinked: true)
  soundcore.along = PhoneRecorderStatus.along(.unavailable("It's in its case."), role: .started)
  inputs.recorders = [soundcore]

  let chips = RecordingStatusWords.chips(inputs)
  XCTAssertEqual(chips.map(\.label), ["Not recording", "Studio Mac", "Alex’s MacBook", "Desk Mac"])
  XCTAssertEqual(chips[0].tone, .attention, "a recorder that didn't start says so during the call")
  XCTAssertEqual(
   chips.map(\.showsDot), [false, true, true, false], "the red dot on each Mac recording too")
  XCTAssertEqual(
   chips[3].detail, "Desk Mac · Connected",
   "a Mac that could record too, with the offer in its menu")
  XCTAssertEqual(
   RecordingStatusWords.meters(inputs).map(\.source), [.microphone],
   "a Mac's levels never reach the iPhone")

  soundcore.along = PhoneRecorderStatus.along(.recording, role: .started)
  inputs.recorders = [soundcore]
  XCTAssertEqual(
   RecordingStatusWords.meters(inputs).map(\.source), [.microphone, .recorder("sc")],
   "a recorder along gets its meter")
  XCTAssertEqual(PhoneRecorderStatus.along(.recording, role: .alreadyRecording), .alreadyRecording)
  XCTAssertEqual(PhoneRecorderStatus.along(.asking), .starting)
  XCTAssertEqual(PhoneRecorderStatus.along(.noAnswer("No answer")), .unavailable)
 }

 func testBehaviorAPauseSaysWhyAndWhenItCanGoOn() throws {
  let call = try XCTUnwrap(
   PhoneRecorderStatus.pause(
    .paused(.interruption), message: PhoneRecorder.unspecifiedInterruption, canResume: false))
  XCTAssertEqual(call.title, "Paused for a call")
  XCTAssertEqual(
   call.message, "Everything so far is saved. Recording can continue when the call ends.")
  XCTAssertFalse(call.canResume)
  let ended = try XCTUnwrap(
   PhoneRecorderStatus.pause(
    .paused(.interruption), message: PhoneRecorder.unspecifiedInterruption, canResume: true))
  XCTAssertEqual(ended.message, "The call has ended. Everything so far is saved.")
  XCTAssertEqual(
   PhoneRecorderStatus.pause(.paused(.inputFailed), message: nil, canResume: true)?.title,
   "The microphone stopped")
  XCTAssertNil(PhoneRecorderStatus.pause(.recording, message: nil, canResume: false))
 }

 /// Regression: VoiceOver was told nothing as a recording paused for a call or went on again.
 func testBehaviorVoiceOverHearsAPauseAndAResume() {
  let pause = PhoneRecorderStatus.pause(
   .paused(.interruption), message: PhoneRecorder.unspecifiedInterruption, canResume: false)
  XCTAssertEqual(
   PhoneRecorderStatus.announcement(from: .recording, to: .paused, pause: pause),
   "Recording paused. Paused for a call.")
  XCTAssertEqual(
   PhoneRecorderStatus.announcement(from: .paused, to: .recording, pause: nil), "Recording resumed")
  XCTAssertNil(
   PhoneRecorderStatus.announcement(from: .starting, to: .recording, pause: nil),
   "the screen changing says that")
 }

 /// Regression: table mode never held Auto-Lock off, so a phone standing on the table locked partway through a
 /// meeting. It keeps the screen on while it's in front and was touched in the last ten minutes.
 func testBehaviorTableModeKeepsTheScreenOnOnlyWhileItsInFrontAndRecentlyTouched() {
  XCTAssertTrue(TableIdle.keepsScreenOn(isActive: true, sinceTouch: 0))
  XCTAssertTrue(TableIdle.keepsScreenOn(isActive: true, sinceTouch: 9 * 60))
  XCTAssertFalse(
   TableIdle.keepsScreenOn(isActive: true, sinceTouch: 10 * 60),
   "a phone forgotten on the table locks itself")
  XCTAssertFalse(
   TableIdle.keepsScreenOn(isActive: false, sinceTouch: 0), "never when Daybook isn't in front")
 }

 /// Regression: under Reduce Motion the table cut from paper to black, and waking took as long as dimming.
 func testBehaviorTableModeDimsSlowlyWakesQuicklyAndFadesUnderReduceMotion() {
  XCTAssertEqual(TableIdle.animation(dimming: true, reduceMotion: false), DaybookMotion.dim)
  XCTAssertEqual(TableIdle.animation(dimming: false, reduceMotion: false), DaybookMotion.fade)
  XCTAssertEqual(
   TableIdle.animation(dimming: true, reduceMotion: true), DaybookMotion.reduced,
   "a fade, never a cut")
  XCTAssertEqual(TableIdle.animation(dimming: false, reduceMotion: true), DaybookMotion.reduced)
 }

 /// After Stop the recorder says what became of this recording, not an earlier one.
 func testBehaviorAfterStopSaysWhatBecameOfThisRecording() {
  let earlier = PhoneAppModel.Filing.saved(UUID(), Date(timeIntervalSince1970: 1))
  let id = UUID()
  let now = PhoneAppModel.Filing.saved(id, Date(timeIntervalSince1970: 2))
  XCTAssertEqual(
   AfterStop.outcome(isActive: true, isFiling: false, filing: earlier, since: earlier), .saving)
  XCTAssertEqual(
   AfterStop.outcome(isActive: false, isFiling: true, filing: earlier, since: earlier), .saving)
  XCTAssertEqual(
   AfterStop.outcome(isActive: false, isFiling: false, filing: now, since: earlier), .saved(id))
  XCTAssertEqual(
   AfterStop.outcome(
    isActive: false, isFiling: false, filing: .failed("Not added."), since: earlier),
   .failed("Not added."))
  XCTAssertEqual(
   AfterStop.outcome(isActive: false, isFiling: false, filing: earlier, since: earlier), .none,
   "nothing new filed (nothing was recorded): back to the library")
  XCTAssertEqual(AfterStop.lingers, .seconds(10))
 }

 /// Regression: a recording that couldn't be added left the person on the moment after Stop, Open disabled, with
 /// only Record to leave by. It gives the library back as Saved does, and its notice stays there.
 func testBehaviorAFailedFilingGivesTheLibraryBack() {
  XCTAssertEqual(AfterStop.stay(for: .failed(PhoneAppModel.notFiled)), AfterStop.lingers)
  XCTAssertEqual(AfterStop.stay(for: .failed(PhoneAppModel.notFinished)), AfterStop.lingers)
  XCTAssertEqual(AfterStop.stay(for: .saved(UUID())), AfterStop.lingers)
  XCTAssertNil(AfterStop.stay(for: .saving), "never while it's still being added")
  XCTAssertNil(
   AfterStop.stay(for: .none), "nothing to show: the library at once, not after a pause")
 }

 /// After Stop the iPhone follows the Mac's rule (`RecordMore`): Keep Recording into the same conversation for two
 /// minutes, said while it's still being added too; then Record. A recording that stopped on its own says Record
 /// Again; one that couldn't be added records anew.
 func testBehaviorAfterStopKeepRecordingFollowsTheRuleBothAppsShare() {
  let stop = Date(timeIntervalSinceReferenceDate: 800_000_000)
  let saved = AfterStop.Outcome.saved(UUID())
  XCTAssertEqual(
   AfterStop.recordMore(saved, stoppedShort: false, stoppedAt: stop, now: stop.addingTimeInterval(9)),
   .keepRecording)
  XCTAssertEqual(
   AfterStop.recordMore(.saving, stoppedShort: false, stoppedAt: stop, now: stop), .keepRecording,
   "the words don't change as it lands")
  XCTAssertEqual(
   AfterStop.recordMore(saved, stoppedShort: false, stoppedAt: stop, now: stop.addingTimeInterval(121)),
   .record, "writing held the moment past two minutes")
  XCTAssertEqual(
   AfterStop.recordMore(saved, stoppedShort: true, stoppedAt: stop, now: stop), .recordAgain)
  XCTAssertEqual(
   AfterStop.recordMore(
    .failed(PhoneAppModel.notFiled), stoppedShort: false, stoppedAt: stop, now: stop), .record)
  XCTAssertEqual(
   AfterStop.recordMore(saved, stoppedShort: false, stoppedAt: stop, now: stop).title,
   "Keep Recording")
 }

 func testBehaviorBookmarksAndPhotosAreMarksInTheNotesLane() {
  let mark = Highlight(time: 4, text: "")
  let photo = CapturePhoto(fileName: "photo-a.heic", capturedAt: Date(), time: 6)
  let marks = NotesTimeline.marks(bookmarks: [mark], photos: [photo])
  XCTAssertEqual(marks.map(\.kind), [.bookmark, .photo])
  XCTAssertEqual(marks.map(\.time), [4, 6])
  let anchors = [TimedNote(time: 2, text: "One"), TimedNote(time: 10, text: "Two")]
  XCTAssertEqual(
   NotesTimeline.paragraph(before: 5, notes: "One\nTwo", anchors: anchors), "One",
   "what a bookmark was about")
  XCTAssertNil(NotesTimeline.paragraph(before: 1, notes: "One\nTwo", anchors: anchors))
 }

 /// Regression: at the largest text size, a pause that offered Resume left the notes no room at all on the closed
 /// Duo's cover screen. The captions give way while it's paused, and the notes keep at least two lines, paused or
 /// recording, with nothing pushed off the screen.
 func testBehaviorAtTheLargestTextSizeTheNotesKeepTwoLinesThroughAPause() throws {
  final class Measured { var height: CGFloat = 0 }
  let size = CGSize(width: 466, height: 636)  // the cover screen inside its safe area
  let line = UIFont.preferredFont(
   forTextStyle: .body,
   compatibleWith: UITraitCollection(
    preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
  ).lineHeight
  for paused in [true, false] {
   let measured = Measured()
   let notes = GeometryReader { proxy in
    Color.clear
     .onAppear { measured.height = proxy.size.height }
     .onChange(of: proxy.size.height) { _, height in measured.height = height }
   }
   let pause =
    paused
    ? RecorderPause(
     title: "Paused for a call", message: "The call has ended. Everything so far is saved.",
     canResume: true) : nil
   let state = RecorderSurfaceState(
    phase: RecorderPhase(
     phase: paused ? .paused : .recording, title: paused ? "Paused" : "Recording"),
    title: "Conversation at 4:07 AM", clock: .since(Date()), isLive: !paused, bookmarkCount: 2,
    pause: pause)
   let captions = Text("Then everything waits for the Mac to finish").font(.system(size: 26))
    .lineLimit(1)
   let slots = RecorderSlots(
    notes: AnyView(notes), captions: AnyView(captions),
    accessory: AnyView(Circle().frame(width: 44, height: 44)))
   let surface = RecorderSurface(
    state: state, levels: RecorderLevels(), actions: RecorderSurfaceActions(bookmark: {}, stop: {}),
    slots: slots
   )
   .daybookSurface(.column, density: .touch)
   .dynamicTypeSize(.accessibility5)
   let host = UIHostingController(rootView: surface)
   host.safeAreaRegions = []
   let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
   let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
   window.frame = CGRect(origin: .zero, size: size)
   window.rootViewController = host
   window.isHidden = false
   defer { window.isHidden = true }
   host.view.frame = CGRect(origin: .zero, size: size)
   host.view.layoutIfNeeded()
   XCTAssertGreaterThanOrEqual(measured.height, line * 2, "two lines of notes (paused: \(paused))")
   XCTAssertLessThanOrEqual(
    host.sizeThatFits(in: size).height, size.height + 0.5,
    "nothing pushed off the screen (paused: \(paused))")
  }
 }

 /// Regression: on the open Duo at the accessibility sizes, a page of live captions pushed Bookmark and Stop off the
 /// recorder's page. The captions give way first: the page fits, controls and all.
 func testBehaviorOnTheOpenDuoCaptionsGiveWayBeforeBookmarkAndStop() throws {
  let size = CGSize(width: 867, height: 635)  // the inner display inside its safe area
  let state = RecorderSurfaceState(
   phase: RecorderPhase(phase: .recording, title: "Recording"), title: "Conversation at 4:07 AM",
   clock: .since(Date()), isLive: true, bookmarkCount: 2)
  let lines = [
   "Okay, let's start with what the phone app records on its own.",
   "It keeps recording with the screen locked, and a call pauses it.",
   "Then everything waits for the Mac to transcribe.",
   "Can we measure both displays on the Duo before fixing layout constants?",
  ]
  .map { CaptionLine(id: UUID(), text: $0, isTentative: false) }
  let captions = LiveCaptionStrip(lines: lines, status: nil, style: .page)
  let slots = RecorderSlots(
   notes: AnyView(Color.clear), captions: AnyView(captions),
   accessory: AnyView(Circle().frame(width: 44, height: 44)),
   details: AnyView(Capsule().frame(height: 24)))
  for expansion in [nil, RecorderSheetSize.collapsed, .expanded, .full] {
   let surface = RecorderSurface(
    state: state, levels: RecorderLevels(), actions: RecorderSurfaceActions(bookmark: {}, stop: {}),
    slots: slots, sheetExpansion: .constant(expansion)
   )
   .daybookSurface(.spread(crease: 475.5), density: .touch)
   .dynamicTypeSize(.accessibility5)
   let host = UIHostingController(rootView: surface)
   host.safeAreaRegions = []
   let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
   let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
   window.frame = CGRect(origin: .zero, size: size)
   window.rootViewController = host
   window.isHidden = false
   defer { window.isHidden = true }
   host.view.frame = CGRect(origin: .zero, size: size)
   host.view.layoutIfNeeded()
   XCTAssertLessThanOrEqual(
    host.sizeThatFits(in: size).height, size.height + 0.5,
    "nothing pushed off the page (expansion: \(String(describing: expansion)))")
  }
 }

 // MARK: The recorder's sheet

 private func hosted(
  expansion: RecorderSheetSize?, paused: Bool = false, notice: Bool = false, size: CGSize,
  layout: SurfaceLayout = .column, notes measuring: AnyView
 ) -> (host: UIHostingController<AnyView>, window: UIWindow) {
  let pause =
   paused
   ? RecorderPause(
    title: "Paused for a call", message: "The call has ended. Everything so far is saved.",
    canResume: true) : nil
  let state = RecorderSurfaceState(
   phase: RecorderPhase(phase: paused ? .paused : .recording, title: paused ? "Paused" : "Recording"),
   title: "Conversation at 4:07 AM", clock: .since(Date()), isLive: !paused, bookmarkCount: 2,
   pause: pause, hasNotice: notice)
  let slots = RecorderSlots(
   notes: measuring,
   captions: AnyView(Text("Then everything waits for the Mac to finish").font(.system(size: 26)).lineLimit(1)),
   accessory: AnyView(Circle().frame(width: 44, height: 44)),
   notice: notice ? AnyView(Text("The Mac declined to record too.").font(.footnote)) : nil)
  let surface = RecorderSurface(
   state: state, levels: RecorderLevels(), actions: RecorderSurfaceActions(bookmark: {}, stop: {}),
   slots: slots, sheetExpansion: .constant(expansion)
  )
  .daybookSurface(layout, density: .touch)
  .dynamicTypeSize(.accessibility5)
  let host = UIHostingController(rootView: AnyView(surface))
  host.safeAreaRegions = []
  let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
  let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
  window.frame = CGRect(origin: .zero, size: size)
  window.rootViewController = host
  window.isHidden = false
  host.view.frame = CGRect(origin: .zero, size: size)
  host.view.layoutIfNeeded()
  return (host, window)
 }

 /// At every level on the cover at the largest text size the sheet and two lines of notes fit, so Stop, the sheet's
 /// foot, is on screen; at the full level the sheet takes the whole column and the notes leave the layout.
 func testBehaviorEverySheetSizeFitsTheCoverAtTheLargestTextSizeWithStopOnScreen() throws {
  final class Measured { var height: CGFloat = 0 }
  let size = CGSize(width: 466, height: 636)
  let line = UIFont.preferredFont(
   forTextStyle: .body,
   compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
  ).lineHeight
  for expansion in [nil, RecorderSheetSize.mini, .collapsed, .expanded, .full] {
   for paused in [true, false] {
    let measured = Measured()
    let notes = GeometryReader { proxy in
     Color.clear
      .onAppear { measured.height = proxy.size.height }
      .onChange(of: proxy.size.height) { _, height in measured.height = height }
    }
    let (host, window) = hosted(expansion: expansion, paused: paused, size: size, notes: AnyView(notes))
    defer { window.isHidden = true }
    XCTAssertLessThanOrEqual(
     host.sizeThatFits(in: size).height, size.height + 0.5,
     "nothing pushed off the screen (\(String(describing: expansion)), paused: \(paused))")
    if expansion != .full {
     XCTAssertGreaterThanOrEqual(
      measured.height, line * 2, "two lines of notes (\(String(describing: expansion)), paused: \(paused))")
    }
   }
  }
 }

 /// Regression: over the keyboard the sheet is one row whatever its level, with Stop above the keyboard and the
 /// notes given the room, and it comes back when the keyboard goes. A notice is never folded away.
 func testBehaviorTheKeyboardFoldsTheSheetToOneRowAndANoticeHoldsItOpen() throws {
  XCTAssertEqual(RecorderSheetSize.expanded.rendered(keyboardUp: true, hasNotice: false), .mini)
  XCTAssertEqual(RecorderSheetSize.full.rendered(keyboardUp: true, hasNotice: false), .mini)
  XCTAssertEqual(
   RecorderSheetSize.mini.rendered(keyboardUp: true, hasNotice: true), .collapsed,
   "a notice is never hidden, even over a keyboard")
  XCTAssertEqual(RecorderSheetSize.mini.rendered(keyboardUp: false, hasNotice: true), .collapsed)
  XCTAssertEqual(RecorderSheetSize.expanded.rendered(keyboardUp: false, hasNotice: true), .expanded)
  XCTAssertEqual(RecorderSheetSize.expanded.rendered(keyboardUp: false, hasNotice: false), .expanded)
  XCTAssertTrue(RecorderSheetSize.keyboardTakesTheScreen(height: 336))
  XCTAssertFalse(RecorderSheetSize.keyboardTakesTheScreen(height: 55), "a hardware keyboard's bar")

  final class Measured { var height: CGFloat = 0 }
  let measured = Measured()
  let notes = GeometryReader { proxy in
   Color.clear
    .onAppear { measured.height = proxy.size.height }
    .onChange(of: proxy.size.height) { _, height in measured.height = height }
  }
  let size = CGSize(width: 466, height: 636)
  let (host, window) = hosted(expansion: .expanded, size: size, notes: AnyView(notes))
  defer { window.isHidden = true }
  let beforeKeyboard = measured.height
  let info: [AnyHashable: Any] = [
   UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: CGRect(x: 0, y: 300, width: 466, height: 336)),
   UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
  ]
  NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil, userInfo: info)
  RunLoop.current.run(until: Date().addingTimeInterval(0.1))
  host.view.layoutIfNeeded()
  XCTAssertGreaterThan(
   measured.height, beforeKeyboard + 100, "with the keyboard up the notes take what the sheet gives back")
  NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil, userInfo: info)
  RunLoop.current.run(until: Date().addingTimeInterval(0.1))
  host.view.layoutIfNeeded()
  XCTAssertEqual(measured.height, beforeKeyboard, accuracy: 1, "the sheet comes back, its level untouched")
 }

 func testBehaviorTheSheetRestsAtTheSizeItsPostureCallsFor() {
  XCTAssertEqual(RecorderSheetSize.resting(in: .column, isWide: false), .collapsed, "closed, upright")
  XCTAssertEqual(RecorderSheetSize.resting(in: .column, isWide: true), .mini, "closed, on its side")
  XCTAssertEqual(RecorderSheetSize.resting(in: .spread(crease: 475.5), isWide: true), .mini, "open")
 }

 func testBehaviorAnExpansionSurvivesFoldingAndNilRestsAtEachPosturesSize() {
  // The person's level stays through a fold or a turn; only at rest does the posture choose.
  let open = RecorderSheetSize.resting(in: .spread(crease: 475.5), isWide: false)
  let closed = RecorderSheetSize.resting(in: .column, isWide: false)
  let turned = RecorderSheetSize.resting(in: .column, isWide: true)
  XCTAssertEqual(RecorderSheetSize.selected(expansion: nil, rest: open, hasNotice: false), .mini)
  XCTAssertEqual(RecorderSheetSize.selected(expansion: nil, rest: closed, hasNotice: false), .collapsed)
  for expansion in [RecorderSheetSize.expanded, .full] {
   XCTAssertEqual(RecorderSheetSize.selected(expansion: expansion, rest: open, hasNotice: false), expansion, "unfolded")
   XCTAssertEqual(RecorderSheetSize.selected(expansion: expansion, rest: closed, hasNotice: false), expansion, "folded")
   XCTAssertEqual(RecorderSheetSize.selected(expansion: expansion, rest: turned, hasNotice: false), expansion, "turned")
  }
  XCTAssertEqual(
   RecorderSheetSize.selected(expansion: .mini, rest: closed, hasNotice: false), .collapsed, "rest is the floor")
  XCTAssertEqual(
   RecorderSheetSize.selected(expansion: nil, rest: turned, hasNotice: true), .collapsed,
   "a notice holds mini open")
 }

 func testBehaviorEachWayOfDismissingReturnsTheSheetToRest() {
  let heights: [RecorderSheetSize: CGFloat] = [.mini: 64, .collapsed: 190, .expanded: 430, .full: 640]
  // A tap: up one size, and at the top back to rest.
  XCTAssertEqual(RecorderSheetSize.expansionAfterTap(drawn: .mini), .collapsed)
  XCTAssertEqual(RecorderSheetSize.expansionAfterTap(drawn: .expanded), .full)
  XCTAssertNil(RecorderSheetSize.expansionAfterTap(drawn: .full), "a tap at full dismisses")
  // A downward flick, from any level.
  for start in [RecorderSheetSize.collapsed, .expanded, .full] {
   XCTAssertNil(
    RecorderSheetSize.expansionAfterDrag(from: start, translation: 40, velocity: 1_400, floor: .mini, heights: heights),
    "a flick from \(start)")
  }
  // A drag that lands at or below rest.
  XCTAssertNil(
   RecorderSheetSize.expansionAfterDrag(from: .expanded, translation: 260, velocity: 0, floor: .collapsed, heights: heights),
   "landing on the floor")
  XCTAssertNil(
   RecorderSheetSize.expansionAfterDrag(from: .expanded, translation: 400, velocity: 0, floor: .collapsed, heights: heights),
   "dragged past it")
  // Collapse steps down, at the floor back to rest.
  XCTAssertEqual(RecorderSheetSize.expansionAfterCollapse(drawn: .full, floor: .collapsed), .expanded)
  XCTAssertNil(RecorderSheetSize.expansionAfterCollapse(drawn: .expanded, floor: .collapsed), "one step is the floor")
 }

 func testBehaviorADragLandsOnTheNearestSizeAndRestIsTheFloor() {
  let heights: [RecorderSheetSize: CGFloat] = [.mini: 64, .collapsed: 190, .expanded: 430, .full: 640]
  let drag = { (from: RecorderSheetSize, by: CGFloat, floor: RecorderSheetSize) in
   RecorderSheetSize.expansionAfterDrag(from: from, translation: by, velocity: 0, floor: floor, heights: heights)
  }
  XCTAssertEqual(drag(.expanded, 30, .mini), .expanded, "a short drag down stays on a level above rest")
  XCTAssertEqual(drag(.full, 90, .collapsed), .full, "still nearest where it started")
  XCTAssertEqual(drag(.full, 120, .collapsed), .expanded, "one level down, above rest")
  XCTAssertEqual(drag(.expanded, 160, .mini), .collapsed, "a long drag down to the size under it")
  XCTAssertEqual(drag(.collapsed, -300, .mini), .expanded, "up to the nearest")
  XCTAssertEqual(drag(.collapsed, -560, .mini), .full, "a long drag jumps sizes")
  XCTAssertEqual(drag(.mini, -130, .mini), .collapsed, "from rest")
  XCTAssertNil(drag(.collapsed, -20, .collapsed), "a drag back to rest is rest")
  // A release's speed counts for a little.
  XCTAssertEqual(
   RecorderSheetSize.expansionAfterDrag(from: .collapsed, translation: -60, velocity: -800, floor: .mini, heights: heights),
   .expanded, "thrown upward")
  // The sheet tracks the finger exactly between its ends and resists past them.
  XCTAssertEqual(RecorderSheetSize.trackedHeight(300, minimum: 64, maximum: 640), 300)
  let past = RecorderSheetSize.trackedHeight(640 + 100, minimum: 64, maximum: 640)
  XCTAssertGreaterThan(past, 640)
  XCTAssertLessThan(past, 640 + 40, "past the end it hardly moves")
  let under = RecorderSheetSize.trackedHeight(64 - 100, minimum: 64, maximum: 640)
  XCTAssertLessThan(under, 64)
  XCTAssertGreaterThan(under, 64 - 40)
  XCTAssertEqual(RecorderSheetSize.nearest(to: 200, floor: .collapsed, heights: heights), .collapsed)
  XCTAssertEqual(RecorderSheetSize.nearest(to: 60, floor: .collapsed, heights: heights), .collapsed, "never under the floor")
 }

 // MARK: The notes editor

 /// Regression: at the largest text sizes the lane of times grew to half the width and notes wrapped a word a
 /// line. There the times move above their paragraphs and the notes keep the whole width.
 func testBehaviorAtTheAccessibilitySizesTimesSitAboveTheirParagraphs() throws {
  let view = DaybookUI.MarginTextView()
  view.frame = CGRect(x: 0, y: 0, width: 360, height: 600)
  view.traitOverrides.preferredContentSizeCategory = .large
  view.updateTraitsIfNeeded()
  view.times = [2, 75]
  view.setText("First thought\nA second paragraph")
  view.layoutIfNeeded()
  XCTAssertGreaterThan(view.lane, 0, "at the default size, a lane")
  XCTAssertLessThanOrEqual(view.lane, ReadingGeometry.lane * ReadingGeometry.laneGrowth)
  let beside = view.laneTimes

  view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
  view.updateTraitsIfNeeded()
  view.applyStyle()
  view.layoutIfNeeded()
  XCTAssertEqual(view.lane, 0, "no lane: the notes start at the edge")
  XCTAssertEqual(view.textContainerInset.left, 0)
  XCTAssertGreaterThan(
   view.textContainerInset.top, 0, "room above the first paragraph for its time")
  let above = view.laneTimes
  XCTAssertEqual(above.map(\.text), ["0:02", "1:15"])
  XCTAssertEqual(beside.map(\.text), above.map(\.text))
  XCTAssertLessThan(
   above[0].baseline, view.textContainerInset.top, "the first time sits above its paragraph")
 }

 /// The times are buttons VoiceOver hears ("Play from 1 minute 15 seconds") where they play, and the marks say
 /// themselves; both are reachable beside the text, which VoiceOver reads as one field.
 func testBehaviorVoiceOverReachesTheTimesAndMarksBesideTheNotes() throws {
  var played: [TimeInterval] = []
  let editor = DaybookUI.MarginNotesEditor(
   text: .constant("First\nSecond"), times: [2, 75],
   marks: [NoteMark(id: "b", kind: .bookmark, time: 30)],
   playTime: { played.append($0) })
  let host = UIHostingController(rootView: editor.frame(width: 360, height: 400))
  let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
  let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
  window.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
  window.rootViewController = host
  window.isHidden = false
  defer { window.isHidden = true }
  host.view.layoutIfNeeded()
  let container = try XCTUnwrap(Self.find(NotesContainerView.self, in: host.view))
  container.textView.layoutIfNeeded()
  let items = try XCTUnwrap(container.accessibilityElements)
  XCTAssertTrue(items.first as AnyObject === container.textView, "the notes first")
  let labels = items.dropFirst().compactMap { ($0 as? NSObject)?.accessibilityLabel }
  XCTAssertEqual(
   labels,
   [
    "Play from \(SpokenTime.format(2))", "Bookmark at \(SpokenTime.format(30))",
    "Play from \(SpokenTime.format(75))",
   ])
  XCTAssertEqual(
   container.textView.accessibilityCustomActions?.map(\.name),
   [DaybookUI.MarginNotesEditor.playFromHere])
  container.textView.selectedRange = NSRange(location: 8, length: 0)
  XCTAssertEqual(container.textView.playableTime(), 75)
 }

 /// Regression: a Stop pressed by mistake left Record to start a second conversation. Keep Recording records into
 /// the one just saved, after what was saved, and the moment after Stop says what became of this recording.
 func testBehaviorKeepRecordingRecordsIntoTheConversationJustSaved() async throws {
  let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "INSTALL-1")
  let rig = RecorderRig()
  let model = PhoneAppModel(
   recorder: rig.recorder, library: library, posture: DevicePosture(),
   options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]))
  try await model.startRecording()
  let before = model.lastFiling
  rig.pump(2)
  try await model.stopRecording()
  let outcome = AfterStop.outcome(
   isActive: model.recorder.isActive, isFiling: model.isFiling, filing: model.lastFiling,
   since: before)
  guard case .saved(let id) = outcome else { return XCTFail("\(outcome)") }
  let first = try XCTUnwrap(library.controller.meeting(id))
  XCTAssertEqual(first.tracks.count, 1)

  // Keep Recording, as the after-Stop moment does it.
  try await model.startRecording(into: id, title: first.title, multipoint: nil)
  XCTAssertEqual(model.recorder.captureID, id, "the same conversation")
  // Longer than the first, as a real second recording is: identical bytes would be the same recording.
  rig.pump(3)
  try await model.stopRecording()
  let kept = try XCTUnwrap(library.controller.meeting(id))
  XCTAssertEqual(kept.tracks.count, 2, "a second recording in the same conversation")
  XCTAssertEqual(kept.title, first.title)
  XCTAssertEqual(library.controller.meetings.count, 1, "no second conversation")
  guard case .saved(let again, _)? = model.lastFiling else { return XCTFail() }
  XCTAssertEqual(again, id)
 }

 private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
  if let found = view as? T { return found }
  for subview in view.subviews { if let found = find(type, in: subview) { return found } }
  return nil
 }
}
